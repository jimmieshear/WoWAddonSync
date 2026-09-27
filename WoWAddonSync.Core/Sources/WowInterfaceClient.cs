using System.Globalization;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using WoWAddonSync.Core.Models;

namespace WoWAddonSync.Core.Sources;

/// <summary>
/// A tiny client for WowInterface's public file-details API. Ported from
/// WowInterfaceAPI.swift. No key or approval process needed — a plain
/// anonymous GET against
/// <c>https://api.mmoui.com/v3/game/WOW/filedetails/{id}.json</c>, where
/// <c>{id}</c> is WowInterface's numeric file ID (the number in a
/// wowinterface.com/downloads/info{id}-Name.html URL, or a .toc's
/// <c>X-WoWI-ID</c> field — see <see cref="Models.TocMetadata.WowInterfaceId"/>).
///
/// Same disclosure as the Swift original: the exact response shape here
/// was verified against a third-party open-source client's notes, not a
/// live response from this sandboxed environment, so it's worth
/// confirming once this can actually be tested against WowInterface's
/// servers. <c>UIDate</c>'s exact format in particular isn't confirmed —
/// that only affects the displayed release date, never sync correctness,
/// which compares <c>UIMD5</c> instead.
/// </summary>
public sealed class WowInterfaceClient
{
    private static readonly Uri BaseUri = new("https://api.mmoui.com/v3/game/WOW/filedetails/");
    private readonly HttpClient _http;

    public WowInterfaceClient(HttpClient? http = null)
    {
        _http = http ?? new HttpClient();
    }

    private sealed record FileDetails
    {
        [JsonPropertyName("UID")] public string? Uid { get; init; }
        [JsonPropertyName("UIName")] public string? UiName { get; init; }
        [JsonPropertyName("UIVersion")] public string? UiVersion { get; init; }
        [JsonPropertyName("UIDate"), JsonConverter(typeof(FlexibleStringConverter))] public string? UiDate { get; init; }
        [JsonPropertyName("UIDownload")] public string? UiDownload { get; init; }
        [JsonPropertyName("UIMD5")] public string? UiMd5 { get; init; }
    }

    /// <summary>
    /// The live API turns out to send <c>UIDate</c> as a bare JSON number
    /// (a Unix timestamp), not the numeric-looking *string* the type
    /// comment above assumed when this was ported — that mismatch is what
    /// "Couldn't parse WowInterface's response: The JSON value could not
    /// be converted to System.String. Path: $[0].UIDate" was. Every other
    /// field here really is a string on the live API, so this converter is
    /// scoped to just <c>UIDate</c> rather than applied generally.
    /// </summary>
    private sealed class FlexibleStringConverter : JsonConverter<string?>
    {
        public override string? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            return reader.TokenType switch
            {
                JsonTokenType.String => reader.GetString(),
                // Utf8JsonReader has no GetRawText (that's a JsonElement
                // method) — decode ValueSpan instead, which is exactly the
                // token's UTF-8 bytes with no escaping to worry about for a
                // number. Keeps a large epoch value's exact digits, unlike
                // GetDouble().ToString(); ParseUiDate below re-parses this
                // same textual form either way.
                JsonTokenType.Number => Encoding.UTF8.GetString(reader.ValueSpan),
                JsonTokenType.Null => null,
                _ => throw new JsonException($"Unexpected token {reader.TokenType} for UIDate."),
            };
        }

        public override void Write(Utf8JsonWriter writer, string? value, JsonSerializerOptions options)
        {
            if (value is null) writer.WriteNullValue();
            else writer.WriteStringValue(value);
        }
    }

    /// <summary>
    /// Fetches the current listing for a WowInterface file ID. Returns
    /// null (rather than throwing) for a 404 or a response missing the
    /// fields sync needs — "this ID doesn't exist" or "nothing usable
    /// here" are normal outcomes, not errors worth surfacing.
    /// </summary>
    public async Task<WowInterfaceLatestRelease?> LatestFileAsync(int id, CancellationToken ct = default)
    {
        var url = new Uri(BaseUri, $"{id}.json");
        HttpResponseMessage response;
        try
        {
            response = await _http.GetAsync(url, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            throw new WowInterfaceException($"Network error talking to WowInterface: {ex.Message}", ex);
        }

        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        if (!response.IsSuccessStatusCode)
            throw new WowInterfaceException($"WowInterface API returned HTTP {(int)response.StatusCode}.");

        List<FileDetails>? details;
        try
        {
            details = await response.Content.ReadFromJsonAsync<List<FileDetails>>(cancellationToken: ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            throw new WowInterfaceException($"Couldn't parse WowInterface's response: {ex.Message}", ex);
        }

        var file = details?.FirstOrDefault();
        if (file?.UiVersion is null || file.UiMd5 is null) return null;

        var namePrefix = string.IsNullOrEmpty(file.UiName) ? "" : $"{file.UiName} ";
        Uri? downloadUrl = file.UiDownload is not null && Uri.TryCreate(file.UiDownload, UriKind.Absolute, out var du) ? du : null;

        return new WowInterfaceLatestRelease
        {
            WowInterfaceId = id,
            Version = file.UiVersion,
            Md5 = file.UiMd5,
            DisplayName = $"{namePrefix}{file.UiVersion}",
            FileDate = ParseUiDate(file.UiDate),
            DownloadUrl = downloadUrl,
        };
    }

    /// <summary>
    /// See the type-level comment: UIDate's exact format isn't confirmed
    /// from here, so this tries a couple of plausible ones and otherwise
    /// falls back to "now" — a display-only inaccuracy, never a sync one.
    /// </summary>
    private static DateTimeOffset ParseUiDate(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return DateTimeOffset.UtcNow;

        if (double.TryParse(raw, CultureInfo.InvariantCulture, out var epochValue))
        {
            // Confirmed live: the API sends this as epoch *milliseconds*,
            // not the epoch-seconds this originally assumed — a
            // seconds-reading of today's date is a ~10-digit number, but
            // FromUnixTimeSeconds threw "Valid values are between
            // -62135596800 and 253402300799" (its ~year-9999 ceiling),
            // which only happens when the real number is ~1000x too big
            // for seconds, i.e. it's actually milliseconds. Guard by
            // magnitude rather than assuming either unit unconditionally,
            // and never let a bad guess crash sync a second time — this
            // field is display-only.
            var epoch = (long)epochValue;
            try
            {
                return Math.Abs(epoch) > 253402300799L
                    ? DateTimeOffset.FromUnixTimeMilliseconds(epoch)
                    : DateTimeOffset.FromUnixTimeSeconds(epoch);
            }
            catch (ArgumentOutOfRangeException)
            {
                return DateTimeOffset.UtcNow;
            }
        }

        foreach (var format in new[] { "MM-dd-yy", "yyyy-MM-dd", "MM/dd/yyyy" })
        {
            if (DateTimeOffset.TryParseExact(raw, format, CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
            {
                return parsed;
            }
        }
        return DateTimeOffset.UtcNow;
    }

    /// <summary>
    /// Downloads a release zip to a fresh temp file, whose lifetime the
    /// caller owns (matching the Swift client's own temp-file handling).
    /// </summary>
    public async Task<string> DownloadFileAsync(Uri url, CancellationToken ct = default)
    {
        HttpResponseMessage response;
        try
        {
            response = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            throw new WowInterfaceException($"Network error talking to WowInterface: {ex.Message}", ex);
        }
        if (!response.IsSuccessStatusCode)
            throw new WowInterfaceException($"WowInterface API returned HTTP {(int)response.StatusCode}.");

        var destination = Path.Combine(Path.GetTempPath(), $"WoWAddonSync-wowi-download-{Guid.NewGuid()}.zip");
        await using var fileStream = File.Create(destination);
        await response.Content.CopyToAsync(fileStream, ct).ConfigureAwait(false);
        return destination;
    }
}

public sealed class WowInterfaceException : Exception
{
    public WowInterfaceException(string message, Exception? inner = null) : base(message, inner) { }
}

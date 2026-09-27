//
//  WowInterfaceAPI.swift
//  WoWAddonSync
//
//  A tiny client for WowInterface's public file-details API. Unlike
//  CurseForge, this needs no API key and no application/approval process
//  at all — it's a plain, anonymous GET:
//
//    https://api.mmoui.com/v3/game/WOW/filedetails/{id}.json
//
//  where {id} is WowInterface's numeric file ID for the addon (the number
//  in a wowinterface.com/downloads/info{id}-Name.html URL).
//
//  We get that ID for an addon from its .toc file's `## X-WoWI-ID:`
//  custom field — see TocParser.swift / AddonModels.swift. The widely
//  used "BigWigs Packager" GitHub Action (and similar tools) writes this
//  field into every addon it publishes to WowInterface, so a large chunk
//  of the addon ecosystem carries it already, with zero setup needed on
//  this app's end. There's no search or fingerprint API here the way
//  CurseForge has one — an addon whose .toc doesn't have this field just
//  isn't checked against WowInterface.
//
//  Endpoint and response shape verified against AcidWeb/CurseBreaker's
//  open-source WowInterface.py from this sandboxed environment — I don't
//  have a Mac or live network access here to test a real response
//  against, so treat the exact field list as "best effort, worth
//  confirming once you're testing for real." `UIDate`'s exact format in
//  particular isn't confirmed (I handle a couple of plausible formats
//  below) — that only affects the displayed release date though, never
//  sync correctness, which compares `UIMD5` instead.
//

import Foundation

struct WowInterfaceFileDetails: Decodable {
    let UID: String?
    let UIName: String?
    let UIVersion: String?
    let UIDate: String?
    let UIDownload: String?
    let UIMD5: String?
}

struct WowInterfaceLatestRelease: Equatable, Codable {
    var wowInterfaceId: Int
    var version: String
    var md5: String
    var displayName: String
    var fileDate: Date
    var downloadUrl: URL?
}

enum WowInterfaceError: LocalizedError {
    case httpError(status: Int)
    case decodingFailed(Error)
    case transportError(Error)
    case missingDownloadURL

    var errorDescription: String? {
        switch self {
        case .httpError(let status):
            return "WowInterface API returned HTTP \(status)."
        case .decodingFailed(let error):
            return "Couldn't parse WowInterface's response: \(error.localizedDescription)"
        case .transportError(let error):
            return "Network error talking to WowInterface: \(error.localizedDescription)"
        case .missingDownloadURL:
            return "WowInterface didn't provide a download URL for that file."
        }
    }
}

final class WowInterfaceClient {
    private let baseURL = URL(string: "https://api.mmoui.com/v3/game/WOW/filedetails/")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches the current listing for a WowInterface file ID. No key, no
    /// auth header, no application process — a plain public GET. Returns
    /// nil (rather than throwing) for a 404, since "this ID doesn't
    /// exist" is a normal outcome, not an error worth surfacing.
    func latestFile(id: Int) async throws -> WowInterfaceLatestRelease? {
        let url = baseURL.appendingPathComponent("\(id).json")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw WowInterfaceError.transportError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WowInterfaceError.transportError(URLError(.badServerResponse))
        }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw WowInterfaceError.httpError(status: http.statusCode)
        }

        let details: [WowInterfaceFileDetails]
        do {
            details = try JSONDecoder().decode([WowInterfaceFileDetails].self, from: data)
        } catch {
            throw WowInterfaceError.decodingFailed(error)
        }
        guard let file = details.first, let version = file.UIVersion, let md5 = file.UIMD5 else {
            return nil
        }

        return WowInterfaceLatestRelease(
            wowInterfaceId: id,
            version: version,
            md5: md5,
            displayName: "\(file.UIName.map { "\($0) " } ?? "")\(version)",
            fileDate: Self.parseUIDate(file.UIDate),
            downloadUrl: file.UIDownload.flatMap(URL.init(string:))
        )
    }

    /// See the file-level comment: UIDate's exact format isn't confirmed
    /// from here, so this tries a couple of plausible ones and otherwise
    /// falls back to "now" — a display-only inaccuracy, never a sync one.
    private static func parseUIDate(_ raw: String?) -> Date {
        guard let raw, !raw.isEmpty else { return Date() }
        if let epochSeconds = Double(raw) {
            return Date(timeIntervalSince1970: epochSeconds)
        }
        for format in ["MM-dd-yy", "yyyy-MM-dd", "MM/dd/yyyy"] {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.timeZone = TimeZone(identifier: "UTC")
            if let date = formatter.date(from: raw) { return date }
        }
        return Date()
    }

    /// URLSession's own temp file isn't guaranteed to outlive this call,
    /// so move it to a URL we own before returning.
    func downloadFile(_ url: URL) async throws -> URL {
        let downloadedURL: URL
        let response: URLResponse
        do {
            (downloadedURL, response) = try await session.download(from: url)
        } catch {
            throw WowInterfaceError.transportError(error)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WowInterfaceError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWAddonSync-wowi-download-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: downloadedURL, to: destination)
        } catch {
            throw WowInterfaceError.transportError(error)
        }
        return destination
    }
}

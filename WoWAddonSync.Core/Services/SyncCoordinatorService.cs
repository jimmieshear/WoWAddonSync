using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using WoWAddonSync.Core.Models;
using WoWAddonSync.Core.Sources;
using WoWAddonSync.Core.Storage;
using WoWAddonSync.Core.Sync;

namespace WoWAddonSync.Core.Services;

/// <summary>
/// The UI-facing orchestration layer — a Windows port of the
/// <c>@MainActor</c> half of SyncCoordinator.swift. Owns the long-lived
/// clients and the current <see cref="Groups"/> list, and drives
/// <see cref="Sync.SyncEngine"/>'s two-phase run (fast local scan first,
/// then one network check per addon, updating that addon's row the moment
/// its own check finishes rather than waiting for the slowest one — see
/// BuildLocalGroupsAsync/EvaluateOneAsync on SyncEngine).
///
/// Deliberately has no reference to any XAML/WPF type, same as the Mac
/// side keeps SyncCoordinator itself free of view code — a future
/// MainViewModel binds to <see cref="Groups"/>/<see cref="IsRunning"/>/
/// <see cref="Log"/> directly. All public methods here are safe to call
/// from the UI thread: <see cref="Sync.SyncEngine"/>'s own work runs on a
/// background <see cref="Task"/>, and because these methods don't
/// <c>ConfigureAwait(false)</c> their own awaits, execution resumes back
/// on whatever context called them (the UI thread, under WPF) before
/// touching <see cref="Groups"/> — the same "off-main-actor work, then
/// back on the main actor to publish it" shape SyncCoordinator.swift uses.
///
/// One binding gap worth flagging for whoever wires up the WPF views:
/// <see cref="AddonGroup"/> is a plain mutable class, not one that raises
/// <c>INotifyPropertyChanged</c> itself (mirroring the Mac side, where
/// SwiftUI's array-level <c>@Published</c> diffing is what makes an
/// in-place struct mutation visible, not per-property notification). A
/// whole-group replacement in <see cref="Groups"/> (see <see cref="RunAsync"/>'s
/// <c>Groups[index] = updatedGroup</c>) raises a collection Replace
/// notification WPF will pick up; an in-place field mutation like the
/// <c>IsSyncing</c> toggles below does not. If a future binding needs to
/// react to just that flag, either make <see cref="AddonGroup"/> implement
/// <c>INotifyPropertyChanged</c> or have the view model re-fetch/replace
/// the item after these calls.
/// </summary>
public sealed class SyncCoordinatorService : INotifyPropertyChanged
{
    private readonly AppSettings _settings;
    private readonly ICloudAddonStore _cloudStore = new();
    private readonly WowInterfaceClient _wowInterfaceClient = new();
    private readonly GitHubReleasesClient _gitHubClient = new();
    private readonly CurseForgeDownloader _curseForgeDownloader = new();
    private readonly CurseForgeWebScrapeClient _curseForgeWebScrapeClient = new();
    private readonly object _runLock = new();
    private bool _isRunning;

    public SyncCoordinatorService(AppSettings settings)
    {
        _settings = settings;
    }

    public ObservableCollection<AddonGroup> Groups { get; } = new();
    public ObservableCollection<string> Log { get; } = new();

    private bool _isRunningPublic;
    public bool IsRunning
    {
        get => _isRunningPublic;
        private set { _isRunningPublic = value; OnPropertyChanged(); }
    }

    private DateTimeOffset? _lastRunAt;
    public DateTimeOffset? LastRunAt
    {
        get => _lastRunAt;
        private set { _lastRunAt = value; OnPropertyChanged(); }
    }

    private string? _lastRunError;
    public string? LastRunError
    {
        get => _lastRunError;
        private set { _lastRunError = value; OnPropertyChanged(); }
    }

    // MARK: Public entry points

    /// <summary>Scans local + the sync folder and computes status, without changing any files. Cheap enough to call whenever the UI appears.</summary>
    public Task RefreshStatusOnlyAsync() => RunAsync(performActions: false);

    /// <summary>Scans, then performs whatever copy/download actions are needed to bring the sync folder and this machine in line with the source of truth.</summary>
    public Task SyncNowAsync() => RunAsync(performActions: true);

    public void SetManualWowInterfaceId(string folderName, int? id) => _settings.SetManualWowInterfaceId(folderName, id);
    public void SetManualGitHubRepo(string folderName, string? repo) => _settings.SetManualGitHubRepo(folderName, repo);
    public void SetManualCurseForgeSlug(string folderName, string? slug) => _settings.SetManualCurseForgeSlug(folderName, slug);

    public async Task ResolveConflictAsync(string groupId, ConflictResolution keep)
    {
        var index = IndexOf(groupId);
        if (index < 0) return;
        Groups[index].IsSyncing = true;

        try
        {
            if (_settings.AddOnsPath is not { } addOnsRoot)
            {
                AppendToLog(new List<string> { $"Can't resolve {Groups[index].DisplayName}: no AddOns folder set." });
                return;
            }
            if (_settings.SyncFolderPath is not { } cloudRoot)
            {
                AppendToLog(new List<string> { $"Can't resolve {Groups[index].DisplayName}: no sync folder set." });
                return;
            }
            _cloudStore.RootPath = cloudRoot;

            var group = Groups[index];
            var engine = new SyncEngine(_cloudStore, _wowInterfaceClient, _gitHubClient, _curseForgeDownloader, _curseForgeWebScrapeClient);
            var lines = await Task.Run(() => engine.ResolveConflictAsync(group, keep, addOnsRoot, _settings.DeviceLabel)).ConfigureAwait(true);
            AppendToLog(lines);
        }
        finally
        {
            var i = IndexOf(groupId);
            if (i >= 0) Groups[i].IsSyncing = false;
        }

        await RunAsync(performActions: false).ConfigureAwait(true);
    }

    /// <summary>Removes an addon from this machine only, by moving its folder(s) to the Recycle Bin (recoverable) — never touches the sync folder or any other machine.</summary>
    public async Task DeleteLocalAddonAsync(string groupId)
    {
        var index = IndexOf(groupId);
        if (index < 0) return;
        Groups[index].IsSyncing = true;

        try
        {
            if (_settings.AddOnsPath is not { } addOnsRoot)
            {
                AppendToLog(new List<string> { $"Can't remove {Groups[index].DisplayName}: no AddOns folder set." });
                return;
            }

            var group = Groups[index];
            var engine = new SyncEngine(_cloudStore, _wowInterfaceClient, _gitHubClient, _curseForgeDownloader, _curseForgeWebScrapeClient);
            var lines = await Task.Run(() => engine.DeleteLocalFolders(group, addOnsRoot)).ConfigureAwait(true);
            AppendToLog(lines);
        }
        finally
        {
            var i = IndexOf(groupId);
            if (i >= 0) Groups[i].IsSyncing = false;
        }

        await RunAsync(performActions: false).ConfigureAwait(true);
    }

    /// <summary>Installs an addon that's in the sync folder but not in this machine's AddOns folder — the "install" side of the choice offered for an <see cref="AddonGroup.IsCloudOnly"/> row.</summary>
    public async Task InstallFromCloudAsync(string groupId)
    {
        var index = IndexOf(groupId);
        if (index < 0) return;
        Groups[index].IsSyncing = true;

        try
        {
            if (_settings.AddOnsPath is not { } addOnsRoot)
            {
                AppendToLog(new List<string> { $"Can't install {Groups[index].DisplayName}: no AddOns folder set." });
                return;
            }
            if (_settings.SyncFolderPath is not { } cloudRoot)
            {
                AppendToLog(new List<string> { $"Can't install {Groups[index].DisplayName}: no sync folder set." });
                return;
            }
            _cloudStore.RootPath = cloudRoot;

            var group = Groups[index];
            var engine = new SyncEngine(_cloudStore, _wowInterfaceClient, _gitHubClient, _curseForgeDownloader, _curseForgeWebScrapeClient);
            var lines = await Task.Run(() => engine.InstallFromCloudAsync(group, addOnsRoot)).ConfigureAwait(true);
            AppendToLog(lines);
        }
        finally
        {
            var i = IndexOf(groupId);
            if (i >= 0) Groups[i].IsSyncing = false;
        }

        await RunAsync(performActions: false).ConfigureAwait(true);
    }

    /// <summary>Removes an addon from the shared sync folder — the "remove" side of the same choice. Unlike <see cref="DeleteLocalAddonAsync"/>, this DOES reach the user's other machines. Callers should confirm with the user first.</summary>
    public async Task RemoveFromCloudAsync(string groupId)
    {
        var index = IndexOf(groupId);
        if (index < 0) return;
        Groups[index].IsSyncing = true;

        try
        {
            if (_settings.SyncFolderPath is not { } cloudRoot)
            {
                AppendToLog(new List<string> { $"Can't remove {Groups[index].DisplayName} from the sync folder: no sync folder set." });
                return;
            }
            _cloudStore.RootPath = cloudRoot;

            var group = Groups[index];
            var engine = new SyncEngine(_cloudStore, _wowInterfaceClient, _gitHubClient, _curseForgeDownloader, _curseForgeWebScrapeClient);
            var lines = await Task.Run(() => engine.RemoveFromCloudAsync(group)).ConfigureAwait(true);
            AppendToLog(lines);
        }
        finally
        {
            var i = IndexOf(groupId);
            if (i >= 0) Groups[i].IsSyncing = false;
        }

        await RunAsync(performActions: false).ConfigureAwait(true);
    }

    // MARK: Core run loop

    /// <summary>
    /// Runs in two phases so the sidebar shows something almost
    /// immediately instead of sitting empty while every addon's version
    /// source is checked over the network — see SyncEngine.BuildLocalGroupsAsync/EvaluateOneAsync.
    /// </summary>
    private async Task RunAsync(bool performActions)
    {
        lock (_runLock)
        {
            if (_isRunning) return;
            _isRunning = true;
        }
        IsRunning = true;
        LastRunError = null;

        try
        {
            if (_settings.AddOnsPath is not { } addOnsRoot || !Directory.Exists(addOnsRoot))
            {
                LastRunError = "No WoW AddOns folder set yet. Pick one in Settings.";
                return;
            }
            if (_settings.SyncFolderPath is not { } cloudRoot || !Directory.Exists(cloudRoot))
            {
                LastRunError = "No sync folder set yet. Pick one (inside iCloud Drive, normally) in Settings.";
                return;
            }
            _cloudStore.RootPath = cloudRoot;

            // Entirely optional and never fatal if not set (or set but
            // CurseForge's app has never run) — an empty scan just means
            // every addon falls through to the sources below it.
            var curseForgeMatches = new Dictionary<string, CurseForgeAddonMatch>();
            if (_settings.CurseForgeGameInstancesPath is { } cfRoot && Directory.Exists(cfRoot))
            {
                curseForgeMatches = await Task.Run(() => CurseForgeLocalScan.Scan(cfRoot)).ConfigureAwait(true);
            }

            AppendToLog(new List<string> { performActions ? "Starting sync..." : "Checking status..." });

            var context = new SyncContext
            {
                AddOnsRoot = addOnsRoot,
                DeviceLabel = _settings.DeviceLabel,
                PerformActions = performActions,
                ManualWowInterfaceIds = _settings.ManualWowInterfaceIds,
                ManualGitHubRepos = _settings.ManualGitHubRepos,
                ManualCurseForgeSlugs = _settings.ManualCurseForgeSlugs,
                CurseForgeMatches = curseForgeMatches,
            };
            var engine = new SyncEngine(_cloudStore, _wowInterfaceClient, _gitHubClient, _curseForgeDownloader, _curseForgeWebScrapeClient);

            // Phase 1: fast, local-only. Populates the sidebar before any
            // network call has even started.
            var localResult = await Task.Run(() => engine.BuildLocalGroupsAsync(context)).ConfigureAwait(true);

            var sortedGroups = localResult.Groups
                .OrderBy(g => g.DisplayName, StringComparer.OrdinalIgnoreCase)
                .ToList();
            Groups.Clear();
            foreach (var g in sortedGroups) Groups.Add(g);
            AppendToLog(localResult.Log);

            // Phase 2: one addon at a time. Each row updates the instant
            // its own check finishes instead of everyone waiting on the
            // last one.
            foreach (var initialGroup in sortedGroups)
            {
                var (updatedGroup, lines) = await Task.Run(() => engine.EvaluateOneAsync(initialGroup, localResult.Manifest, context)).ConfigureAwait(true);

                // Not "Groups[index] = updatedGroup" — EvaluateOneAsync
                // mutates and returns the very same AddonGroup instance it
                // was given, so that assignment reassigns the identical
                // reference to itself. AddonGroup doesn't implement
                // INotifyPropertyChanged (see the class doc comment above),
                // and WPF's ListView treats a Replace of a reference onto
                // itself as nothing worth redrawing, so every row — not
                // just LastError — was frozen at its Phase-1 (pre-network)
                // state no matter what Phase 2 found. Remove+Insert forces
                // the container to be torn down and rebuilt from scratch,
                // which reads the (already-mutated) properties fresh
                // regardless of reference identity.
                var index = IndexOf(updatedGroup.Id);
                if (index >= 0)
                {
                    Groups.RemoveAt(index);
                    Groups.Insert(index, updatedGroup);
                }
                AppendToLog(lines);
            }

            AppendToLog(new List<string> { performActions ? "Sync finished." : "Status check finished." });
        }
        finally
        {
            lock (_runLock) { _isRunning = false; }
            IsRunning = false;
            LastRunAt = DateTimeOffset.UtcNow;
        }
    }

    private int IndexOf(string groupId)
    {
        for (var i = 0; i < Groups.Count; i++)
        {
            if (Groups[i].Id == groupId) return i;
        }
        return -1;
    }

    private void AppendToLog(List<string> lines)
    {
        if (lines.Count == 0) return;
        foreach (var line in lines) Log.Add(line);
        while (Log.Count > 200) Log.RemoveAt(0);
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

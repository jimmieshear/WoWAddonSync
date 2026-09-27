//
//  SyncCoordinator.swift
//  WoWAddonSync
//
//  Orchestrates the sync check the app is built around:
//
//    1. Ask the addon's version source for its latest release, checked
//       in this order:
//         - WowInterface, whenever the addon's .toc names a WowInterface
//           ID (`X-WoWI-ID`) or one was entered manually — see
//           TocParser.swift and WowInterfaceAPI.swift.
//         - GitHub Releases, whenever the addon's .toc `X-Website` points
//           at a github.com repo, or one was entered manually — see
//           GitHubReleasesAPI.swift.
//         - A CurseForge local scan match, whenever the CurseForge desktop
//           app's own on-disk record of your installed addons (which you
//           optionally grant access to in Settings) names this folder —
//           see CurseForgeLocalScanAPI.swift for why this isn't the same
//           thing as using CurseForge's gated API.
//         - Last resort: a CurseForge page scrape, whenever none of the
//           three above matched — see CurseForgeWebScrapeAPI.swift for
//           why this is the least trusted source in the app.
//       None of these need a key or account setup on this app's end.
//    2. If iCloud's copy isn't at that version, update iCloud first.
//    3. If this Mac's local copy isn't at iCloud's version, update it
//       from iCloud.
//
//  When an addon matches neither source, there's no independent "source
//  of truth" to check against — the coordinator falls back to treating
//  iCloud itself as the shared reference point (first machine to see the
//  addon seeds iCloud, every other machine matches whatever iCloud has),
//  the same last-writer-wins model a synced Dropbox/iCloud Drive folder
//  uses. `resolveConflict` lets you force one side to win by hand for a
//  specific addon if you ever need to override that.
//
//  All the actual file/network work (SyncEngine below) runs inside a
//  detached Task, off the main actor — it involves synchronous disk
//  copies and a polling wait for iCloud downloads that would otherwise
//  block the UI if run on SyncCoordinator's own (@MainActor) executor.
//

import Foundation

// MARK: - Coordinator (MainActor-facing, drives the UI)

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var groups: [AddonGroup] = []
    @Published private(set) var isRunning = false
    @Published private(set) var log: [String] = []
    @Published var lastRunAt: Date?
    @Published var lastRunError: String?

    private let folderAccess: FolderAccess
    private let cloudFolderAccess: CloudFolderAccess
    private let curseForgeFolderAccess: CurseForgeFolderAccess
    private let settings: AppSettings
    private let cloudStore = iCloudAddonStore()
    /// None of these need a key or a settings dependency — all three
    /// always run (CurseForge's scan is empty, not an error, if you never
    /// grant that folder). See WowInterfaceAPI.swift / GitHubReleasesAPI.swift
    /// / CurseForgeLocalScanAPI.swift.
    private let wowInterfaceClient = WowInterfaceClient()
    private let gitHubClient = GitHubReleasesClient()
    private let curseForgeDownloader = CurseForgeDownloader()
    /// Last-resort source, tried only when nothing else matched — see
    /// CurseForgeWebScrapeAPI.swift.
    private let curseForgeWebScrapeClient = CurseForgeWebScrapeClient()

    init(folderAccess: FolderAccess, cloudFolderAccess: CloudFolderAccess, curseForgeFolderAccess: CurseForgeFolderAccess, settings: AppSettings) {
        self.folderAccess = folderAccess
        self.cloudFolderAccess = cloudFolderAccess
        self.curseForgeFolderAccess = curseForgeFolderAccess
        self.settings = settings
    }

    // MARK: Public entry points

    /// Scans local + iCloud and computes status, without changing any
    /// files. Cheap enough to call whenever the UI appears.
    func refreshStatusOnly() async {
        await run(performActions: false)
    }

    /// Scans, then performs whatever copy/download actions are needed to
    /// bring iCloud and this Mac in line with the source of truth.
    func syncNow() async {
        await run(performActions: true)
    }

    /// Manual version-source overrides, for addons that don't carry (or
    /// that you'd rather not rely on) the relevant `.toc` field. Keyed by
    /// the addon's primary folder name, same as the automatic match.
    func setManualWowInterfaceId(folderName: String, id: Int?) {
        if let id {
            settings.manualWowInterfaceIds[folderName] = id
        } else {
            settings.manualWowInterfaceIds.removeValue(forKey: folderName)
        }
    }

    func setManualGitHubRepo(folderName: String, repo: String?) {
        let trimmed = repo?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            settings.manualGitHubRepos[folderName] = trimmed
        } else {
            settings.manualGitHubRepos.removeValue(forKey: folderName)
        }
    }

    /// Manual override for the last-resort CurseForge page-scrape source
    /// — a bare slug like "clique" (the last path component of
    /// https://www.curseforge.com/wow/addons/clique), not a full URL,
    /// though a pasted full URL is accepted too. See
    /// CurseForgeWebScrapeAPI.swift.
    func setManualCurseForgeSlug(folderName: String, slug: String?) {
        let trimmed = slug?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            settings.manualCurseForgeSlugs[folderName] = CurseForgeSlug.parse(fromWebsite: trimmed) ?? trimmed
        } else {
            settings.manualCurseForgeSlugs.removeValue(forKey: folderName)
        }
    }

    /// Manual override for a specific addon: force one side to win
    /// regardless of what the automatic check would decide.
    func resolveConflict(groupId: String, keep: SyncEngine.ConflictResolution) async {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[index].isSyncing = true
        defer {
            if let i = groups.firstIndex(where: { $0.id == groupId }) {
                groups[i].isSyncing = false
            }
        }

        guard folderAccess.startAccessingIfNeeded(), let addOnsRoot = folderAccess.addOnsURL else {
            log.append("Can't resolve \(groups[index].displayName): no access to the local AddOns folder.")
            return
        }
        defer { folderAccess.stopAccessing() }

        guard cloudFolderAccess.startAccessingIfNeeded(), let cloudRoot = cloudFolderAccess.url else {
            log.append("Can't resolve \(groups[index].displayName): no access to the sync folder.")
            return
        }
        defer { cloudFolderAccess.stopAccessing() }
        cloudStore.rootURL = cloudRoot

        let group = groups[index]
        let engine = SyncEngine(cloudStore: cloudStore, wowInterfaceClient: wowInterfaceClient, gitHubClient: gitHubClient, curseForgeDownloader: curseForgeDownloader, curseForgeWebScrapeClient: curseForgeWebScrapeClient)
        let deviceLabel = settings.deviceLabel

        let lines = await Task.detached(priority: .userInitiated) {
            engine.resolveConflict(group: group, keep: keep, addOnsRoot: addOnsRoot, deviceLabel: deviceLabel)
        }.value
        appendToLog(lines)

        await run(performActions: false)
    }

    /// Removes an addon from this Mac only, by moving its folder(s) to the
    /// Trash (recoverable) — never touches iCloud or your other Macs, and
    /// never permanently deletes anything itself.
    func deleteLocalAddon(groupId: String) async {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[index].isSyncing = true
        defer {
            if let i = groups.firstIndex(where: { $0.id == groupId }) {
                groups[i].isSyncing = false
            }
        }

        guard folderAccess.startAccessingIfNeeded(), let addOnsRoot = folderAccess.addOnsURL else {
            appendToLog(["Can't remove \(groups[index].displayName): no access to the local AddOns folder."])
            return
        }
        defer { folderAccess.stopAccessing() }

        let group = groups[index]
        let engine = SyncEngine(cloudStore: cloudStore, wowInterfaceClient: wowInterfaceClient, gitHubClient: gitHubClient, curseForgeDownloader: curseForgeDownloader, curseForgeWebScrapeClient: curseForgeWebScrapeClient)

        let lines = await Task.detached(priority: .userInitiated) {
            engine.deleteLocalFolders(group: group, addOnsRoot: addOnsRoot)
        }.value
        appendToLog(lines)

        await run(performActions: false)
    }

    /// Installs an addon that's in the sync folder but not in this Mac's
    /// AddOns folder — the "install" side of the choice the UI offers for
    /// an `AddonGroup.isCloudOnly` row. Additive: iCloud is untouched, and
    /// `deleteLocalAddon` above undoes it.
    func installFromCloud(groupId: String) async {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[index].isSyncing = true
        defer {
            if let i = groups.firstIndex(where: { $0.id == groupId }) {
                groups[i].isSyncing = false
            }
        }

        guard folderAccess.startAccessingIfNeeded(), let addOnsRoot = folderAccess.addOnsURL else {
            appendToLog(["Can't install \(groups[index].displayName): no access to the local AddOns folder."])
            return
        }
        defer { folderAccess.stopAccessing() }

        guard cloudFolderAccess.startAccessingIfNeeded(), let cloudRoot = cloudFolderAccess.url else {
            appendToLog(["Can't install \(groups[index].displayName): no access to the sync folder."])
            return
        }
        defer { cloudFolderAccess.stopAccessing() }
        cloudStore.rootURL = cloudRoot

        let group = groups[index]
        let engine = SyncEngine(cloudStore: cloudStore, wowInterfaceClient: wowInterfaceClient, gitHubClient: gitHubClient, curseForgeDownloader: curseForgeDownloader, curseForgeWebScrapeClient: curseForgeWebScrapeClient)

        let lines = await Task.detached(priority: .userInitiated) {
            engine.installFromCloud(group: group, addOnsRoot: addOnsRoot)
        }.value
        appendToLog(lines)

        await run(performActions: false)
    }

    /// Removes an addon from the shared sync folder, by moving its
    /// folder(s) to the Trash — the "remove" side of the same choice.
    /// Unlike `deleteLocalAddon`, this one does reach the user's other
    /// Macs: they'll drop their copies on their next sync. Callers should
    /// confirm with the user first; ContentView does.
    func removeFromCloud(groupId: String) async {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[index].isSyncing = true
        defer {
            if let i = groups.firstIndex(where: { $0.id == groupId }) {
                groups[i].isSyncing = false
            }
        }

        guard cloudFolderAccess.startAccessingIfNeeded(), let cloudRoot = cloudFolderAccess.url else {
            appendToLog(["Can't remove \(groups[index].displayName) from iCloud: no access to the sync folder."])
            return
        }
        defer { cloudFolderAccess.stopAccessing() }
        cloudStore.rootURL = cloudRoot

        let group = groups[index]
        let engine = SyncEngine(cloudStore: cloudStore, wowInterfaceClient: wowInterfaceClient, gitHubClient: gitHubClient, curseForgeDownloader: curseForgeDownloader, curseForgeWebScrapeClient: curseForgeWebScrapeClient)

        let lines = await Task.detached(priority: .userInitiated) {
            engine.removeFromCloud(group: group)
        }.value
        appendToLog(lines)

        await run(performActions: false)
    }

    // MARK: Core run loop

    /// Runs in two phases so the sidebar shows something almost
    /// immediately instead of sitting empty while every addon's version
    /// source is checked over the network:
    ///
    ///   Phase 1 — `buildLocalGroups`: scan of the local AddOns folder plus
    ///   whatever's already in the iCloud manifest on disk. No network
    ///   calls. `groups` is populated from this right away.
    ///
    ///   Phase 2 — `evaluateOne`, once per addon, sequentially: the actual
    ///   WowInterface/GitHub/CurseForge check (and push/pull if
    ///   `performActions`). Each addon's row updates in place as soon as
    ///   its own check finishes, rather than the whole list waiting on the
    ///   slowest one. Sequential rather than concurrent on purpose — see
    ///   the doc comment on SyncEngine.evaluateOne.
    private func run(performActions: Bool) async {
        guard !isRunning else { return }
        isRunning = true
        lastRunError = nil
        defer { isRunning = false; lastRunAt = Date() }

        guard folderAccess.startAccessingIfNeeded(), let addOnsRoot = folderAccess.addOnsURL else {
            lastRunError = "No access to a WoW AddOns folder yet. Pick one in Settings."
            return
        }
        defer { folderAccess.stopAccessing() }

        guard cloudFolderAccess.startAccessingIfNeeded(), let cloudRoot = cloudFolderAccess.url else {
            lastRunError = "No sync folder set yet. Pick one (inside iCloud Drive, normally) in Settings."
            return
        }
        defer { cloudFolderAccess.stopAccessing() }
        cloudStore.rootURL = cloudRoot

        // Entirely optional and never fatal if not granted (or if granted
        // but CurseForge's app has never run) — an empty scan just means
        // every addon falls through to the sources below it.
        var curseForgeMatches: [String: CurseForgeAddonMatch] = [:]
        if curseForgeFolderAccess.startAccessingIfNeeded(), let curseForgeRoot = curseForgeFolderAccess.url {
            curseForgeMatches = CurseForgeLocalScan.scan(gameInstancesFolder: curseForgeRoot)
            curseForgeFolderAccess.stopAccessing()
        }

        appendToLog([performActions ? "Starting sync…" : "Checking status…"])

        let context = SyncEngine.Context(
            addOnsRoot: addOnsRoot,
            deviceLabel: settings.deviceLabel,
            performActions: performActions,
            manualWowInterfaceIds: settings.manualWowInterfaceIds,
            manualGitHubRepos: settings.manualGitHubRepos,
            manualCurseForgeSlugs: settings.manualCurseForgeSlugs,
            curseForgeMatches: curseForgeMatches
        )
        let engine = SyncEngine(cloudStore: cloudStore, wowInterfaceClient: wowInterfaceClient, gitHubClient: gitHubClient, curseForgeDownloader: curseForgeDownloader, curseForgeWebScrapeClient: curseForgeWebScrapeClient)

        // Phase 1: fast, local-only. Populates the sidebar before any
        // network call has even started.
        let localResult = await Task.detached(priority: .userInitiated) {
            engine.buildLocalGroups(context: context)
        }.value

        let sortedGroups = localResult.groups.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        groups = sortedGroups
        appendToLog(localResult.log)

        // Phase 2: one addon at a time. Each row updates the instant its
        // own check finishes instead of everyone waiting on the last one.
        for initialGroup in sortedGroups {
            let (updatedGroup, lines) = await Task.detached(priority: .userInitiated) {
                await engine.evaluateOne(group: initialGroup, manifest: localResult.manifest, context: context)
            }.value

            if let index = groups.firstIndex(where: { $0.id == updatedGroup.id }) {
                groups[index] = updatedGroup
            }
            appendToLog(lines)
        }

        appendToLog([performActions ? "Sync finished." : "Status check finished."])
    }

    private func appendToLog(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        log.append(contentsOf: lines)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

// MARK: - SyncEngine (runs off the main actor)

/// Everything below does real file I/O and network calls and must never
/// run on the main thread. It's deliberately self-contained — no
/// reference back to SyncCoordinator or any `@Published`/`@MainActor`
/// state — so it's safe to invoke from inside a detached Task.
struct SyncEngine {
    let cloudStore: iCloudAddonStore
    let wowInterfaceClient: WowInterfaceClient
    let gitHubClient: GitHubReleasesClient
    let curseForgeDownloader: CurseForgeDownloader
    /// Last-resort source, tried only when nothing else matched — see
    /// CurseForgeWebScrapeAPI.swift.
    let curseForgeWebScrapeClient: CurseForgeWebScrapeClient

    struct Context {
        var addOnsRoot: URL
        var deviceLabel: String
        var performActions: Bool
        var manualWowInterfaceIds: [String: Int] = [:]
        var manualGitHubRepos: [String: String] = [:]
        /// Manual folder-name -> CurseForge slug overrides for the
        /// page-scrape source. See AppSettings.manualCurseForgeSlugs.
        var manualCurseForgeSlugs: [String: String] = [:]
        /// Folder name -> match, from this run's CurseForge local scan (see
        /// CurseForgeLocalScanAPI.swift). Empty when that folder isn't
        /// granted, which is a normal, non-error state.
        var curseForgeMatches: [String: CurseForgeAddonMatch] = [:]
    }

    /// Result of the fast, local-only pass — see `buildLocalGroups`.
    struct LocalBuildResult {
        var groups: [AddonGroup]
        /// The iCloud manifest as read during this pass, handed back so
        /// the caller can pass the *same* snapshot into every `evaluateOne`
        /// call in phase two, rather than each one re-reading it (matching
        /// how the old single-pass `run` only ever loaded it once too).
        var manifest: AddonManifest
        var log: [String]
    }

    enum ConflictResolution { case local, cloud }

    // MARK: Entry points

    /// Phase 1: scans the local AddOns folder and groups those folders
    /// into `AddonGroup`s using the iCloud manifest already on disk. Pure
    /// local disk I/O — no network calls to WowInterface, GitHub, or
    /// CurseForge — so this is fast enough to populate the sidebar with
    /// before checking a single addon's actual version status.
    func buildLocalGroups(context: Context) -> LocalBuildResult {
        var log: [String] = []
        let scan = AddonScanner.scan(addOnsURL: context.addOnsRoot)
        for error in scan.scanErrors { log.append("⚠️ \(error)") }
        let manifest = cloudStore.loadManifest()
        let built = buildGroups(localFolders: scan.folders, manifest: manifest, context: context)
        return LocalBuildResult(groups: built, manifest: manifest, log: log)
    }

    /// Phase 2, called once per group: the actual version-source check
    /// (WowInterface/GitHub/CurseForge, whichever applies) and, if
    /// `context.performActions`, whatever push/pull it implies. Deliberately
    /// takes and returns a single group rather than a whole array, so the
    /// caller can run these one at a time and update its UI after each one
    /// finishes instead of waiting for all of them.
    ///
    /// Callers should run these sequentially, not concurrently: a push
    /// does a read-modify-write of iCloud's manifest.json (see
    /// `updateManifestEntry`), and interleaving that across addons running
    /// in parallel could drop one addon's write.
    func evaluateOne(group: AddonGroup, manifest: AddonManifest, context: Context) async -> (group: AddonGroup, log: [String]) {
        var log: [String] = []
        var mutableGroup = group
        await evaluateAndMaybeAct(group: &mutableGroup, manifest: manifest, context: context, log: &log)
        return (mutableGroup, log)
    }

    func resolveConflict(group: AddonGroup, keep: ConflictResolution, addOnsRoot: URL, deviceLabel: String) -> [String] {
        var log: [String] = []
        do {
            switch keep {
            case .local:
                for folder in group.folders {
                    try cloudStore.copyFolderToCloud(from: addOnsRoot.appendingPathComponent(folder.folderName), folderName: folder.folderName)
                }
                try updateManifestEntry(for: group, deviceLabel: deviceLabel)
                log.append("Kept this Mac's copy of \(group.displayName) and pushed it to iCloud.")
            case .cloud:
                // Driven by what iCloud actually has rather than by
                // `group.folders`, which is built from the local scan and
                // so can't name a folder that's missing here — the exact
                // case a forced pull is most useful for. Falls back to the
                // local names when iCloud has no record, which pulls
                // nothing and reports that honestly.
                let folderNames = group.cloudFolderNames.isEmpty
                    ? group.folders.map(\.folderName)
                    : group.cloudFolderNames
                for folderName in folderNames {
                    let dest = addOnsRoot.appendingPathComponent(folderName)
                    try cloudStore.copyFolderFromCloud(folderName: folderName, to: dest)
                }
                log.append("Kept the iCloud copy of \(group.displayName) and applied it locally.")
            }
        } catch {
            log.append("Failed to resolve \(group.displayName): \(error.localizedDescription)")
        }
        return log
    }

    /// Moves each of this group's folders to the Trash, locally only.
    /// Never touches iCloud or the manifest — this Mac's copy is simply
    /// removed (recoverably) from Interface/AddOns; iCloud and every other
    /// Mac keep whatever they already had. A folder that's already
    /// missing is skipped rather than treated as an error, and one
    /// folder's failure doesn't stop the rest from being tried.
    func deleteLocalFolders(group: AddonGroup, addOnsRoot: URL) -> [String] {
        var log: [String] = []
        for folder in group.folders {
            let localURL = addOnsRoot.appendingPathComponent(folder.folderName)
            guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
            do {
                try FileManager.default.trashItem(at: localURL, resultingItemURL: nil)
                log.append("Moved \(folder.folderName) to the Trash.")
            } catch {
                log.append("Couldn't move \(folder.folderName) to the Trash: \(error.localizedDescription)")
            }
        }
        return log
    }

    // MARK: Cloud-only addons (in the sync folder, not installed here)

    /// Copies an addon that's in iCloud but missing from this Mac down
    /// into Interface/AddOns — the "install" half of the choice offered
    /// for an `isCloudOnly` group. Nothing about iCloud changes, so this
    /// is undoable with the existing local-only delete.
    ///
    /// One folder failing doesn't stop the rest, so a multi-folder addon
    /// (WeakAuras and friends) lands as far as it can and says which part
    /// didn't, rather than leaving you guessing which of five folders is
    /// the problem.
    func installFromCloud(group: AddonGroup, addOnsRoot: URL) -> [String] {
        var log: [String] = []
        var installed = 0

        for folderName in group.cloudFolderNames {
            do {
                try cloudStore.copyFolderFromCloud(
                    folderName: folderName,
                    to: addOnsRoot.appendingPathComponent(folderName)
                )
                installed += 1
            } catch {
                log.append("Couldn't install \(folderName) from iCloud: \(error.localizedDescription)")
            }
        }

        if installed > 0 {
            log.append("Installed \(group.displayName) from iCloud into this Mac's AddOns folder (\(installed) folder\(installed == 1 ? "" : "s")).")
        }
        return log
    }

    /// Removes an addon from the shared sync folder — the "remove" half of
    /// the choice offered for an `isCloudOnly` group, and the only action
    /// in the app that reaches the user's other Macs. Folders go to the
    /// Trash rather than being deleted outright (see
    /// iCloudAddonStore.trashFolderInCloud).
    ///
    /// The manifest entry is dropped only if every folder came out
    /// cleanly: a half-removed addon still has folders in iCloud, and
    /// should keep its entry so the next scan still describes it properly
    /// instead of rediscovering the remnants as unclaimed orphans.
    func removeFromCloud(group: AddonGroup) -> [String] {
        var log: [String] = []
        var failures = 0

        for folderName in group.cloudFolderNames {
            do {
                try cloudStore.trashFolderInCloud(folderName)
                log.append("Moved \(folderName) to the Trash in the sync folder.")
            } catch {
                failures += 1
                log.append("Couldn't remove \(folderName) from iCloud: \(error.localizedDescription)")
            }
        }

        guard failures == 0 else { return log }

        do {
            try cloudStore.removeManifestEntry(id: group.id)
            log.append("Removed \(group.displayName) from iCloud. Your other Macs will drop it on their next sync.")
        } catch {
            log.append("Removed \(group.displayName)'s folders from iCloud but couldn't update the manifest: \(error.localizedDescription)")
        }
        return log
    }

    // MARK: Grouping

    /// Manual override takes priority over whatever's parsed from the
    /// addon's own `.toc` — that's the point of "override."
    private func resolvedWowInterfaceId(folderName: String, tocValue: Int?, context: Context) -> Int? {
        context.manualWowInterfaceIds[folderName] ?? tocValue
    }

    /// Checked in order: your own manual override, then whatever the
    /// addon's own `.toc` claims, then the app's small hand-curated list
    /// of addons confirmed (by hand, not auto-detection) to publish real
    /// GitHub releases despite not saying so in their `.toc` — see
    /// KnownGitHubAddons.swift.
    private func resolvedGitHubRepo(folderName: String, website: String?, context: Context) -> GitHubRepoRef? {
        if let manual = context.manualGitHubRepos[folderName], let parsed = GitHubRepoRef(spec: manual) {
            return parsed
        }
        if let fromToc = GitHubRepoRef(website: website) {
            return fromToc
        }
        return KnownGitHubAddons.repo(forFolderName: folderName)
    }

    /// No manual-override concept here — see the doc comment on
    /// AddonGroup.curseForgeMatch for why.
    private func resolvedCurseForgeMatch(folderName: String, context: Context) -> CurseForgeAddonMatch? {
        context.curseForgeMatches[folderName]
    }

    /// Checked in order: manual override, then whatever the addon's own
    /// `.toc` `X-Website` points at, if it's a curseforge.com addon URL.
    /// This is only ever *tried* — see evaluateAndMaybeAct — when none of
    /// WowInterface, GitHub, or the CurseForge local scan matched, so it
    /// never overrides a better source even when both happen to be set.
    private func resolvedCurseForgeSlug(folderName: String, website: String?, context: Context) -> String? {
        if let manual = context.manualCurseForgeSlugs[folderName], !manual.isEmpty {
            return manual
        }
        return CurseForgeSlug.parse(fromWebsite: website)
    }

    private func buildGroups(localFolders: [LocalAddonFolder], manifest: AddonManifest, context: Context) -> [AddonGroup] {
        var remaining = Dictionary(uniqueKeysWithValues: localFolders.map { ($0.folderName, $0) })
        var groups: [AddonGroup] = []

        // Everything iCloud actually has on disk right now, so passes (c)
        // and (d) below can find addons this Mac has never installed. Read
        // once rather than per-folder — see iCloudAddonStore.cloudFolderNames.
        let cloudNames = Set(cloudStore.cloudFolderNames())
        var claimedCloudNames: Set<String> = []
        /// Manifest entries none of whose folders are installed here —
        /// candidates for pass (c). Carries the dictionary key alongside
        /// the entry because that key, not `entry.id`, is what the rest of
        /// the app looks entries up by (`manifest.entries[group.id]`) and
        /// what `removeManifestEntry` deletes.
        var unmatchedEntries: [(key: String, entry: AddonManifestEntry)] = []

        // a) Manifest-driven grouping first: if an earlier sync recorded
        // several folders together as one addon, keep them grouped, even
        // though fresh grouping (below) can only ever discover one folder
        // at a time on its own.
        for (entryId, entry) in manifest.entries {
            let matchedFolders = entry.folderNames.compactMap { remaining[$0] }
            guard !matchedFolders.isEmpty else {
                unmatchedEntries.append((key: entryId, entry: entry))
                continue
            }
            for name in entry.folderNames { remaining.removeValue(forKey: name) }

            let inCloud = entry.folderNames.filter { cloudNames.contains($0) }
            claimedCloudNames.formUnion(inCloud)

            let primaryName = matchedFolders.first?.folderName ?? entryId
            groups.append(AddonGroup(
                id: entryId,
                displayName: entry.displayName,
                folders: matchedFolders,
                cloudFolderNames: inCloud,
                cloudManifestEntry: entry,
                groupingSource: matchedFolders.count > 1 ? .manifestGrouped : .singleFolder,
                wowInterfaceId: resolvedWowInterfaceId(folderName: primaryName, tocValue: entry.wowInterfaceId ?? matchedFolders.first?.toc.wowInterfaceId, context: context),
                githubRepo: resolvedGitHubRepo(folderName: primaryName, website: matchedFolders.first?.toc.website, context: context) ?? entry.githubRepo,
                curseForgeMatch: resolvedCurseForgeMatch(folderName: primaryName, context: context),
                curseForgeSlug: resolvedCurseForgeSlug(folderName: primaryName, website: matchedFolders.first?.toc.website, context: context),
                installedVersionDisplay: matchedFolders.first?.toc.version
            ))
        }

        // b) Everything else: one group per folder. If its .toc (or a
        // manual override) names a WowInterface ID or a GitHub repo, that
        // becomes the version source (see evaluateAndMaybeAct) instead of
        // falling back to iCloud-as-reference. A CurseForge local-scan
        // match is checked last, and only used at all when neither of the
        // other two applies.
        for folder in remaining.values.sorted(by: { $0.folderName < $1.folderName }) {
            let inCloud = cloudNames.contains(folder.folderName) ? [folder.folderName] : []
            claimedCloudNames.formUnion(inCloud)

            groups.append(AddonGroup(
                id: folder.folderName,
                displayName: folder.toc.title ?? folder.folderName,
                folders: [folder],
                cloudFolderNames: inCloud,
                cloudManifestEntry: manifest.entries[folder.folderName],
                groupingSource: .singleFolder,
                wowInterfaceId: resolvedWowInterfaceId(folderName: folder.folderName, tocValue: folder.toc.wowInterfaceId, context: context),
                githubRepo: resolvedGitHubRepo(folderName: folder.folderName, website: folder.toc.website, context: context),
                curseForgeMatch: resolvedCurseForgeMatch(folderName: folder.folderName, context: context),
                curseForgeSlug: resolvedCurseForgeSlug(folderName: folder.folderName, website: folder.toc.website, context: context),
                installedVersionDisplay: folder.toc.version
            ))
        }

        // c) Addons iCloud knows about that aren't installed on this Mac
        // at all — normally because another Mac pushed one you've never
        // had, or because you removed it here and iCloud still has it.
        // These get a group purely so the UI can surface them and offer
        // "install" or "remove from iCloud"; sync itself won't touch them
        // (see evaluateAndMaybeAct). Entries whose folders are gone from
        // iCloud too are skipped rather than shown as phantom addons — a
        // stale manifest entry isn't something there's anything to install.
        for (entryId, entry) in unmatchedEntries.sorted(by: { $0.entry.displayName.localizedCaseInsensitiveCompare($1.entry.displayName) == .orderedAscending }) {
            let inCloud = entry.folderNames.filter { cloudNames.contains($0) && !claimedCloudNames.contains($0) }
            guard !inCloud.isEmpty else { continue }
            claimedCloudNames.formUnion(inCloud)

            groups.append(AddonGroup(
                id: entryId,
                displayName: entry.displayName,
                folders: [],
                cloudFolderNames: inCloud,
                cloudManifestEntry: entry,
                groupingSource: inCloud.count > 1 ? .manifestGrouped : .singleFolder,
                wowInterfaceId: entry.wowInterfaceId,
                githubRepo: entry.githubRepo
            ))
        }

        // d) Folders sitting in the sync folder that no manifest entry
        // claims at all — a partially-finished push, or something copied
        // in by hand. Treated the same as (c): shown, never auto-acted on.
        for name in cloudNames.subtracting(claimedCloudNames).sorted() {
            groups.append(AddonGroup(
                id: name,
                displayName: name,
                folders: [],
                cloudFolderNames: [name],
                groupingSource: .singleFolder
            ))
        }

        return groups
    }

    // MARK: Per-group evaluation + action

    private func evaluateAndMaybeAct(group: inout AddonGroup, manifest: AddonManifest, context: Context, log: inout [String]) async {
        let manifestEntry = manifest.entries[group.id]

        // In iCloud, not installed here. Checked before any version source
        // because this state is deliberately inert: resolving it either
        // way is a real decision (install it on this Mac, or delete it
        // from the shared folder and so from every other Mac), and the app
        // doesn't get to make that for you. The UI surfaces both choices —
        // see AddonGroup.isCloudOnly and installFromCloud/removeFromCloud
        // below. There's also nothing to check a version against: without
        // a local copy there's no `.toc` to read and nothing to compare a
        // release to.
        if group.isCloudOnly {
            group.cloudState = .upToDateWithSource
            group.localState = .notInstalled
            return
        }

        if let wowiId = group.wowInterfaceId {
            await evaluateWithWowInterfaceSource(group: &group, wowiId: wowiId, manifestEntry: manifestEntry, context: context, log: &log)
        } else if let repo = group.githubRepo {
            await evaluateWithGitHubSource(group: &group, repo: repo, manifestEntry: manifestEntry, context: context, log: &log)
        } else if let match = group.curseForgeMatch {
            await evaluateWithCurseForgeSource(group: &group, match: match, manifestEntry: manifestEntry, context: context, log: &log)
        } else if let slug = group.curseForgeSlug {
            await evaluateWithCurseForgeScrapeSource(group: &group, slug: slug, manifestEntry: manifestEntry, context: context, log: &log)
        } else {
            evaluateWithoutSource(group: &group, manifestEntry: manifestEntry, context: context, log: &log)
        }
    }

    private func evaluateWithWowInterfaceSource(group: inout AddonGroup, wowiId: Int, manifestEntry: AddonManifestEntry?, context: Context, log: inout [String]) async {
        do {
            guard let latest = try await wowInterfaceClient.latestFile(id: wowiId) else {
                group.lastError = "No WowInterface listing found for ID \(wowiId)."
                group.cloudState = .unknown
                return
            }
            group.latestWowInterfaceRelease = latest

            let cloudHasLatest = manifestEntry?.wowInterfaceMD5 == latest.md5 && cloudStore.folderExistsInCloud(group.primaryFolderName)
            group.cloudState = cloudHasLatest ? .upToDateWithSource : .behindSource

            if !cloudHasLatest, context.performActions {
                try await pushWowInterfaceReleaseToCloud(group: group, release: latest, deviceLabel: context.deviceLabel, log: &log)
                group.cloudState = .upToDateWithSource
            }

            evaluateLocalAgainstCloud(group: &group, addOnsRoot: context.addOnsRoot, performActions: context.performActions, log: &log)

        } catch {
            group.lastError = error.localizedDescription
            log.append("\(group.displayName): \(error.localizedDescription)")
        }
    }

    private func evaluateWithGitHubSource(group: inout AddonGroup, repo: GitHubRepoRef, manifestEntry: AddonManifestEntry?, context: Context, log: inout [String]) async {
        do {
            guard let latest = try await gitHubClient.latestRelease(for: repo) else {
                group.lastError = "No GitHub releases found for \(repo.spec)."
                group.cloudState = .unknown
                return
            }
            group.latestGitHubRelease = latest

            let cloudHasLatest = manifestEntry?.githubTag == latest.tag
                && manifestEntry?.githubRepo == repo
                && cloudStore.folderExistsInCloud(group.primaryFolderName)
            group.cloudState = cloudHasLatest ? .upToDateWithSource : .behindSource

            if !cloudHasLatest, context.performActions {
                try await pushGitHubReleaseToCloud(group: group, release: latest, deviceLabel: context.deviceLabel, log: &log)
                group.cloudState = .upToDateWithSource
            }

            evaluateLocalAgainstCloud(group: &group, addOnsRoot: context.addOnsRoot, performActions: context.performActions, log: &log)

        } catch {
            group.lastError = error.localizedDescription
            log.append("\(group.displayName): \(error.localizedDescription)")
        }
    }

    private func evaluateWithCurseForgeSource(group: inout AddonGroup, match: CurseForgeAddonMatch, manifestEntry: AddonManifestEntry?, context: Context, log: inout [String]) async {
        guard let latestFileId = match.latestFileId else {
            // The scan found this addon but doesn't have latest-file info
            // for it yet (CurseForge's app may not have finished checking
            // it) — nothing to compare against, so don't claim out of date.
            group.lastError = "CurseForge's local scan for \(match.addonName) doesn't have latest-version info yet."
            group.cloudState = .unknown
            return
        }

        let cloudHasLatest = manifestEntry?.curseForgeFileId == latestFileId
            && manifestEntry?.curseForgeAddonID == match.addonID
            && cloudStore.folderExistsInCloud(group.primaryFolderName)
        group.cloudState = cloudHasLatest ? .upToDateWithSource : .behindSource

        if !cloudHasLatest, context.performActions {
            do {
                try await pushCurseForgeReleaseToCloud(group: group, match: match, deviceLabel: context.deviceLabel, log: &log)
                group.cloudState = .upToDateWithSource
            } catch {
                group.lastError = error.localizedDescription
                log.append("\(group.displayName): \(error.localizedDescription)")
                return
            }
        }

        evaluateLocalAgainstCloud(group: &group, addOnsRoot: context.addOnsRoot, performActions: context.performActions, log: &log)
    }

    /// Last resort: scrapes the addon's public CurseForge page instead of
    /// reading anything CurseForge itself hands over — see the header
    /// comment on CurseForgeWebScrapeAPI.swift for why this is the
    /// lowest-trust, most fragile source in the app, and never used when
    /// any of the three sources above matched instead.
    private func evaluateWithCurseForgeScrapeSource(group: inout AddonGroup, slug: String, manifestEntry: AddonManifestEntry?, context: Context, log: inout [String]) async {
        do {
            guard let latest = try await curseForgeWebScrapeClient.latestFile(slug: slug) else {
                group.lastError = "Couldn't read a version off CurseForge's page for \"\(slug)\" — this scrapes an unofficial page layout as a last resort, so this can happen if CurseForge's site changed, or the slug is wrong."
                group.cloudState = .unknown
                return
            }
            group.curseForgeScraped = latest

            let cloudHasLatest: Bool
            if let fileId = latest.fileId {
                cloudHasLatest = manifestEntry?.curseForgeScrapedFileId == fileId
                    && manifestEntry?.curseForgeScrapedSlug == slug
                    && cloudStore.folderExistsInCloud(group.primaryFolderName)
            } else {
                // The page didn't yield a file id this time (still
                // best-effort) — fall back to comparing the display
                // string alone, same trust level as the no-independent-
                // source path below.
                cloudHasLatest = manifestEntry?.versionDisplay == latest.displayName
                    && cloudStore.folderExistsInCloud(group.primaryFolderName)
            }
            group.cloudState = cloudHasLatest ? .upToDateWithSource : .behindSource

            if !cloudHasLatest, context.performActions {
                guard let downloadURL = latest.downloadURL else {
                    group.lastError = "Found \"\(latest.displayName)\" on CurseForge's page for \(group.displayName) but no download link to push it from — this addon may need updating by hand this once."
                    return
                }
                try await pushCurseForgeScrapedReleaseToCloud(group: group, release: latest, downloadURL: downloadURL, deviceLabel: context.deviceLabel, log: &log)
                group.cloudState = .upToDateWithSource
            }

            evaluateLocalAgainstCloud(group: &group, addOnsRoot: context.addOnsRoot, performActions: context.performActions, log: &log)

        } catch {
            group.lastError = error.localizedDescription
            log.append("\(group.displayName): \(error.localizedDescription)")
        }
    }

    /// No known WowInterface, GitHub, or CurseForge-scan identity for this
    /// addon. There's no independent version source to check against, so
    /// iCloud itself becomes the shared reference point — see the
    /// file-level doc comment above for the reasoning.
    private func evaluateWithoutSource(group: inout AddonGroup, manifestEntry: AddonManifestEntry?, context: Context, log: inout [String]) {
        guard manifestEntry != nil, cloudStore.folderExistsInCloud(group.primaryFolderName) else {
            group.cloudState = .notInCloud
            if context.performActions {
                do {
                    for folder in group.folders {
                        try cloudStore.copyFolderToCloud(from: context.addOnsRoot.appendingPathComponent(folder.folderName), folderName: folder.folderName)
                    }
                    try updateManifestEntry(for: group, deviceLabel: context.deviceLabel)
                    group.cloudState = .upToDateWithSource
                    group.localState = .matchesCloud
                    log.append("Seeded iCloud with \(group.displayName) from this Mac (no version source match).")
                } catch {
                    group.lastError = error.localizedDescription
                }
            }
            return
        }

        group.cloudState = .upToDateWithSource // "up to date" here just means "iCloud has a copy"
        evaluateLocalAgainstCloud(group: &group, addOnsRoot: context.addOnsRoot, performActions: context.performActions, log: &log)
    }

    private func evaluateLocalAgainstCloud(group: inout AddonGroup, addOnsRoot: URL, performActions: Bool, log: inout [String]) {
        let manifest = cloudStore.loadManifest()
        let recordedFingerprints = manifest.entries[group.id]?.folderFingerprints ?? [:]

        var allMatch = true
        var anyMissingLocally = false

        for folder in group.folders {
            let localURL = addOnsRoot.appendingPathComponent(folder.folderName)
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                anyMissingLocally = true
                allMatch = false
                continue
            }
            if recordedFingerprints[folder.folderName] != folder.folderFingerprint {
                allMatch = false
            }
        }

        group.localState = anyMissingLocally ? .notInstalled : (allMatch ? .matchesCloud : .behindCloud)

        guard performActions, group.localState != .matchesCloud else { return }

        do {
            var refreshedFolders: [LocalAddonFolder] = []
            for folder in group.folders {
                let localURL = addOnsRoot.appendingPathComponent(folder.folderName)
                try cloudStore.copyFolderFromCloud(folderName: folder.folderName, to: localURL)
                if let refreshed = try AddonScanner.scanSingleFolder(localURL) {
                    refreshedFolders.append(refreshed)
                } else {
                    refreshedFolders.append(folder)
                }
            }
            group.folders = refreshedFolders
            group.localState = .matchesCloud
            group.lastSyncedAt = Date()
            log.append("Updated this Mac's copy of \(group.displayName) from iCloud.")
        } catch {
            group.lastError = error.localizedDescription
            log.append("Failed to copy \(group.displayName) from iCloud: \(error.localizedDescription)")
        }
    }

    // MARK: Downloading + installing a release into iCloud

    private func pushWowInterfaceReleaseToCloud(group: AddonGroup, release: WowInterfaceLatestRelease, deviceLabel: String, log: inout [String]) async throws {
        guard let downloadURL = release.downloadUrl else { throw WowInterfaceError.missingDownloadURL }

        log.append("Downloading \(group.displayName) \(release.displayName) from WowInterface…")
        let tempZip = try await wowInterfaceClient.downloadFile(downloadURL)
        defer { try? FileManager.default.removeItem(at: tempZip) }

        let topLevelFolders = try Self.extractAddonFolders(fromZipAt: tempZip, displayName: group.displayName)
        for folderURL in topLevelFolders {
            try cloudStore.copyFolderToCloud(from: folderURL, folderName: folderURL.lastPathComponent)
        }

        try updateManifestEntry(
            for: group,
            wowInterfaceSource: release,
            deviceLabel: deviceLabel,
            folderNamesOverride: topLevelFolders.map { $0.lastPathComponent }
        )
        log.append("Updated iCloud copy of \(group.displayName) to \(release.displayName).")
    }

    private func pushGitHubReleaseToCloud(group: AddonGroup, release: GitHubLatestRelease, deviceLabel: String, log: inout [String]) async throws {
        guard let downloadURL = release.downloadUrl else { throw GitHubReleasesError.missingDownloadURL }

        log.append("Downloading \(group.displayName) \(release.displayName) from GitHub…")
        let tempZip = try await gitHubClient.downloadFile(downloadURL)
        defer { try? FileManager.default.removeItem(at: tempZip) }

        let topLevelFolders = try Self.extractAddonFolders(fromZipAt: tempZip, displayName: group.displayName)
        for folderURL in topLevelFolders {
            try cloudStore.copyFolderToCloud(from: folderURL, folderName: folderURL.lastPathComponent)
        }

        try updateManifestEntry(
            for: group,
            gitHubSource: release,
            deviceLabel: deviceLabel,
            folderNamesOverride: topLevelFolders.map { $0.lastPathComponent }
        )
        log.append("Updated iCloud copy of \(group.displayName) to \(release.displayName) (GitHub).")
    }

    private func pushCurseForgeReleaseToCloud(group: AddonGroup, match: CurseForgeAddonMatch, deviceLabel: String, log: inout [String]) async throws {
        guard let downloadURL = match.latestDownloadUrl else { throw CurseForgeDownloadError.missingDownloadURL }

        log.append("Downloading \(group.displayName) \(match.latestFileName ?? "latest") from CurseForge (via the local scan, not CurseForge's API)…")
        let tempZip = try await curseForgeDownloader.download(downloadURL)
        defer { try? FileManager.default.removeItem(at: tempZip) }

        let topLevelFolders = try Self.extractAddonFolders(fromZipAt: tempZip, displayName: group.displayName)
        for folderURL in topLevelFolders {
            try cloudStore.copyFolderToCloud(from: folderURL, folderName: folderURL.lastPathComponent)
        }

        try updateManifestEntry(
            for: group,
            curseForgeSource: match,
            deviceLabel: deviceLabel,
            folderNamesOverride: topLevelFolders.map { $0.lastPathComponent }
        )
        log.append("Updated iCloud copy of \(group.displayName) to \(match.latestFileName ?? "latest") (CurseForge).")
    }

    /// Downloads via CurseForge's website "direct download" redirect
    /// (`CurseForgeScrapedRelease.downloadURL`) rather than any API —
    /// reuses the generic `curseForgeDownloader`, which just follows
    /// whatever URL it's given, the same way it downloads from the local
    /// scan's CDN links.
    private func pushCurseForgeScrapedReleaseToCloud(group: AddonGroup, release: CurseForgeScrapedRelease, downloadURL: URL, deviceLabel: String, log: inout [String]) async throws {
        log.append("Downloading \(group.displayName) \(release.displayName) from CurseForge's page (scraped — last resort, no API)…")
        let tempZip = try await curseForgeDownloader.download(downloadURL)
        defer { try? FileManager.default.removeItem(at: tempZip) }

        let topLevelFolders = try Self.extractAddonFolders(fromZipAt: tempZip, displayName: group.displayName)
        for folderURL in topLevelFolders {
            try cloudStore.copyFolderToCloud(from: folderURL, folderName: folderURL.lastPathComponent)
        }

        try updateManifestEntry(
            for: group,
            curseForgeScrapedSource: release,
            deviceLabel: deviceLabel,
            folderNamesOverride: topLevelFolders.map { $0.lastPathComponent }
        )
        log.append("Updated iCloud copy of \(group.displayName) to \(release.displayName) (CurseForge, scraped).")
    }

    private func updateManifestEntry(
        for group: AddonGroup,
        wowInterfaceSource: WowInterfaceLatestRelease? = nil,
        gitHubSource: GitHubLatestRelease? = nil,
        curseForgeSource: CurseForgeAddonMatch? = nil,
        curseForgeScrapedSource: CurseForgeScrapedRelease? = nil,
        deviceLabel: String,
        folderNamesOverride: [String]? = nil
    ) throws {
        var manifest = cloudStore.loadManifest()
        let folderNames = folderNamesOverride ?? group.folders.map { $0.folderName }

        var fingerprints: [String: UInt32] = [:]
        for name in folderNames {
            if let cloudURL = cloudStore.cloudURL(forFolder: name),
               let folder = try? AddonScanner.scanSingleFolder(cloudURL) {
                fingerprints[name] = folder.folderFingerprint
            }
        }

        manifest.entries[group.id] = AddonManifestEntry(
            id: group.id,
            displayName: group.displayName,
            folderNames: folderNames,
            wowInterfaceId: wowInterfaceSource?.wowInterfaceId ?? group.wowInterfaceId,
            wowInterfaceMD5: wowInterfaceSource?.md5 ?? manifest.entries[group.id]?.wowInterfaceMD5,
            githubRepo: gitHubSource?.repo ?? group.githubRepo,
            githubTag: gitHubSource?.tag ?? manifest.entries[group.id]?.githubTag,
            curseForgeAddonID: curseForgeSource?.addonID ?? manifest.entries[group.id]?.curseForgeAddonID,
            curseForgeFileId: curseForgeSource?.latestFileId ?? manifest.entries[group.id]?.curseForgeFileId,
            curseForgeScrapedSlug: curseForgeScrapedSource?.slug ?? manifest.entries[group.id]?.curseForgeScrapedSlug,
            curseForgeScrapedFileId: curseForgeScrapedSource?.fileId ?? manifest.entries[group.id]?.curseForgeScrapedFileId,
            versionDisplay: wowInterfaceSource?.displayName ?? gitHubSource?.displayName ?? curseForgeSource?.latestFileName ?? curseForgeScrapedSource?.displayName ?? group.installedVersionDisplay,
            folderFingerprints: fingerprints,
            updatedAt: Date(),
            updatedByDevice: deviceLabel
        )
        try cloudStore.saveManifest(manifest)
    }

    // MARK: Zip extraction

    /// Shells out to `/usr/bin/ditto`, which every Mac has, rather than
    /// pulling in a third-party zip library.
    private static func extractZip(at zipURL: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWAddonSync-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destination.path]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "unknown ditto error"
            throw NSError(domain: "WoWAddonSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't unzip the download: \(message)"])
        }
        return destination
    }

    /// Extracts a downloaded release zip and returns its top-level addon
    /// folders, cleaning up the extraction scratch directory itself
    /// (callers are still responsible for the zip file).
    private static func extractAddonFolders(fromZipAt zipURL: URL, displayName: String) throws -> [URL] {
        let extractedRoot = try extractZip(at: zipURL)
        defer { try? FileManager.default.removeItem(at: extractedRoot) }

        let topLevelFolders = (try? FileManager.default.contentsOfDirectory(at: extractedRoot, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }) ?? []

        guard !topLevelFolders.isEmpty else {
            throw NSError(domain: "WoWAddonSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "Downloaded archive for \(displayName) didn't contain any addon folders."])
        }

        // Copy out of the about-to-be-deleted extraction directory into a
        // fresh scratch location per folder, since the caller needs these
        // to outlive this function (the `defer` above removes
        // `extractedRoot` on return).
        var persisted: [URL] = []
        for folder in topLevelFolders {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("WoWAddonSync-folder-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: folder, to: dest)
            persisted.append(dest)
        }
        return persisted
    }
}

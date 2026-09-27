//
//  ContentView.swift
//  WoWAddonSync
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var folderAccess: FolderAccess
    @EnvironmentObject private var cloudFolderAccess: CloudFolderAccess
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var coordinator: SyncCoordinator

    @State private var showingSettings = false
    @State private var selectedGroupId: String?
    @State private var showingLog = false
    /// The cloud-only addon whose "Remove…" button was pressed in the
    /// sidebar, if any. Removing from iCloud reaches every Mac, so it
    /// always goes through a confirmation first.
    @State private var pendingCloudRemovalId: String?

    private var cloudOnlyGroups: [AddonGroup] {
        coordinator.groups.filter(\.isCloudOnly)
    }

    private var pendingCloudRemoval: AddonGroup? {
        pendingCloudRemovalId.flatMap { id in coordinator.groups.first { $0.id == id } }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let selectedGroupId, let group = coordinator.groups.first(where: { $0.id == selectedGroupId }) {
                AddonDetailView(group: group)
                    .id(group.id)
            } else {
                ContentUnavailableCompat(
                    title: "Select an Addon",
                    message: "Choose an addon on the left to see its sync details.",
                    systemImage: "puzzlepiece.extension"
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingLog.toggle()
                } label: {
                    Label("Activity", systemImage: "list.bullet.rectangle")
                }
                .popover(isPresented: $showingLog) {
                    ActivityLogView()
                        .frame(width: 420, height: 320)
                }

                Button {
                    Task { await coordinator.syncNow() }
                } label: {
                    if coordinator.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(coordinator.isRunning || folderAccess.addOnsURL == nil || cloudFolderAccess.url == nil)

                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .frame(width: 520, height: 480)
        }
        .confirmationDialog(
            "Remove \(pendingCloudRemoval?.displayName ?? "this addon") from iCloud?",
            isPresented: Binding(
                get: { pendingCloudRemovalId != nil },
                set: { if !$0 { pendingCloudRemovalId = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingCloudRemoval
        ) { group in
            Button("Move to Trash in iCloud", role: .destructive) {
                Task { await coordinator.removeFromCloud(groupId: group.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            Text(CloudOnlyCopy.removalWarning(for: group))
        }
        .task {
            await runOnboardingIfNeeded()
        }
    }

    /// Walks through whichever grants are still missing, in order, then
    /// runs the first sync once both are in place.
    private func runOnboardingIfNeeded() async {
        if folderAccess.addOnsURL == nil {
            await withCheckedContinuation { continuation in
                folderAccess.presentPicker { _ in continuation.resume() }
            }
        }
        guard folderAccess.addOnsURL != nil else { return }

        if cloudFolderAccess.url == nil {
            await withCheckedContinuation { continuation in
                cloudFolderAccess.presentPicker { _ in continuation.resume() }
            }
        }
        guard cloudFolderAccess.url != nil else { return }

        await runInitialSync()
    }

    private func runInitialSync() async {
        if settings.autoSyncOnLaunch {
            await coordinator.syncNow()
        } else {
            await coordinator.refreshStatusOnly()
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            if folderAccess.addOnsURL == nil {
                grantBanner(
                    title: "Choose your WoW AddOns folder…",
                    action: { folderAccess.presentPicker { _ in Task { await runOnboardingIfNeeded() } } }
                )
            } else if cloudFolderAccess.url == nil {
                grantBanner(
                    title: "Choose a sync folder (in iCloud Drive)…",
                    action: { cloudFolderAccess.presentPicker { _ in Task { await coordinator.syncNow() } } }
                )
            } else if let error = coordinator.lastRunError {
                errorBanner(error)
            }

            if !cloudOnlyGroups.isEmpty {
                cloudOnlyBanner
            }

            if coordinator.groups.isEmpty && !coordinator.isRunning {
                ContentUnavailableCompat(
                    title: "No Addons Found",
                    message: folderAccess.addOnsURL == nil || cloudFolderAccess.url == nil
                        ? "Grant access to your AddOns folder and a sync folder to get started."
                        : "This AddOns folder looks empty, and there's nothing in the sync folder either.",
                    systemImage: "tray"
                )
                .frame(maxHeight: .infinity)
            } else {
                List(coordinator.groups, selection: $selectedGroupId) { group in
                    AddonRowView(
                        group: group,
                        onInstall: { Task { await coordinator.installFromCloud(groupId: group.id) } },
                        onRemove: { pendingCloudRemovalId = group.id }
                    )
                    .tag(group.id)
                }
                .listStyle(.sidebar)
            }

            statusFooter
        }
        .navigationSplitViewColumnWidth(min: 300, ideal: 360)
    }

    private func grantBanner(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "folder.badge.plus")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(Color.accentColor.opacity(0.12))
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
    }

    /// Cloud-only rows keep their alphabetical place in the list rather
    /// than being sorted to the top, so the list stays predictable — this
    /// banner is what makes sure they're not missed in a long one.
    private var cloudOnlyBanner: some View {
        let count = cloudOnlyGroups.count
        return Label(
            count == 1
                ? "1 addon is in iCloud but not installed on this Mac."
                : "\(count) addons are in iCloud but not installed on this Mac.",
            systemImage: "exclamationmark.icloud"
        )
        .font(.caption)
        .foregroundStyle(.purple)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.10))
    }

    private var statusFooter: some View {
        HStack {
            Label(settings.deviceLabel, systemImage: "laptopcomputer")
                .foregroundStyle(.secondary)
            Spacer()
            if let lastRunAt = coordinator.lastRunAt {
                Text(lastRunAt, style: .relative)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct AddonDetailView: View {
    let group: AddonGroup
    @EnvironmentObject private var coordinator: SyncCoordinator
    @EnvironmentObject private var settings: AppSettings

    @State private var wowiIdText: String = ""
    @State private var githubRepoText: String = ""
    @State private var curseForgeSlugText: String = ""
    @State private var showingDeleteConfirm = false
    @State private var showingCloudRemoveConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.displayName)
                            .font(.title2.bold())
                        Text(group.effectiveFolderNames.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Room to spare here, unlike the sidebar row, so these
                    // sit side by side.
                    HStack(spacing: 6) {
                        ForEach(group.statusBadges, id: \.self) { badge in
                            StatusBadge(status: badge)
                        }
                    }
                }

                if group.isCloudOnly {
                    cloudOnlyBox
                }

                GroupBox("Versions") {
                    VStack(alignment: .leading, spacing: 8) {
                        if group.isCloudOnly {
                            // Nothing is installed here, so there's no
                            // .toc to read and no version check to run —
                            // iCloud's manifest is all there is to show.
                            LabeledRow(label: "Version in iCloud", value: group.cloudManifestEntry?.versionDisplay ?? "Unknown")
                            if let entry = group.cloudManifestEntry {
                                LabeledRow(label: "Last updated in iCloud", value: entry.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                LabeledRow(label: "Pushed by", value: entry.updatedByDevice)
                            } else {
                                Text("The folder is in your sync folder but no machine recorded pushing it, so there's no version on record. Installing it here will record one on the next sync.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            LabeledRow(label: "This Mac", value: localStatusText)
                        } else {
                            LabeledRow(label: "Installed (this Mac)", value: group.installedVersionDisplay ?? "Not set in this addon's .toc")
                            if group.installedVersionDisplay == nil {
                                Text("That's just a display string the addon's author puts in its .toc file — plenty of addons leave it blank. It's never used to decide whether to sync; the status below is.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let latest = group.latestWowInterfaceRelease {
                                LabeledRow(label: "Latest on WowInterface", value: latest.displayName)
                                LabeledRow(label: "Released", value: latest.fileDate.formatted(date: .abbreviated, time: .shortened))
                            }
                            if let latest = group.latestGitHubRelease {
                                LabeledRow(label: "Latest on GitHub", value: latest.displayName)
                                LabeledRow(label: "Released", value: latest.publishedAt.formatted(date: .abbreviated, time: .shortened))
                            }
                            if let match = group.curseForgeMatch {
                                LabeledRow(label: "Latest per CurseForge scan", value: match.latestFileName ?? "Unknown")
                                if let date = match.latestFileDate {
                                    LabeledRow(label: "Released", value: date.formatted(date: .abbreviated, time: .shortened))
                                }
                            }
                            if let scraped = group.curseForgeScraped {
                                LabeledRow(label: "Latest per CurseForge page (scraped)", value: scraped.displayName)
                                if let date = scraped.fileDate {
                                    LabeledRow(label: "Released", value: date.formatted(date: .abbreviated, time: .shortened))
                                }
                            }
                            LabeledRow(label: "Version check", value: cloudStatusText)
                            LabeledRow(label: "This Mac vs. iCloud", value: localStatusText)
                            if !group.missingLocalFolderNames.isEmpty {
                                // Partly installed. Sync won't fill this in
                                // by itself — the local scan can only see
                                // the folders that exist, so as far as the
                                // fingerprint comparison is concerned the
                                // ones that are here match fine. Say so
                                // rather than showing a clean status.
                                Text("In iCloud but missing from this Mac: \(group.missingLocalFolderNames.joined(separator: ", ")). Use Force Pull iCloud → This Mac below to put \(group.missingLocalFolderNames.count == 1 ? "it" : "them") back.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            if let lastSynced = group.lastSyncedAt {
                                LabeledRow(label: "Last synced here", value: lastSynced.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if let error = group.lastError {
                    GroupBox {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                // All three are about an addon that's actually installed
                // here: which source to check it against, which direction
                // to force a sync, and removing this Mac's copy. None of
                // them mean anything for a cloud-only addon — `cloudOnlyBox`
                // above is that case's entire set of choices.
                if !group.isCloudOnly {
                    versionSourceBox
                    forceSyncDirectionBox
                    removeFromThisMacBox
                }
            }
            .padding(20)
        }
        .onAppear {
            // Prefill with whatever's actually active for this addon, not
            // just a manual override — so e.g. an auto-detected GitHub
            // repo shows up here too, rather than the field looking empty
            // for an addon that's already matched.
            wowiIdText = settings.manualWowInterfaceIds[group.primaryFolderName].map(String.init)
                ?? group.wowInterfaceId.map(String.init) ?? ""
            githubRepoText = settings.manualGitHubRepos[group.primaryFolderName]
                ?? group.githubRepo?.spec ?? ""
            curseForgeSlugText = settings.manualCurseForgeSlugs[group.primaryFolderName]
                ?? group.curseForgeSlug ?? ""
        }
        .confirmationDialog(
            "Delete \(group.displayName) from this Mac?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await coordinator.deleteLocalAddon(groupId: group.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only removes it from Interface/AddOns on this Mac. iCloud and your other Macs are unaffected, and it's recoverable from the Trash if this was a mistake.")
        }
        .confirmationDialog(
            "Remove \(group.displayName) from iCloud?",
            isPresented: $showingCloudRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash in iCloud", role: .destructive) {
                Task { await coordinator.removeFromCloud(groupId: group.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CloudOnlyCopy.removalWarning(for: group))
        }
    }

    /// The whole set of choices for an addon that's in the sync folder but
    /// not in this Mac's AddOns folder. Sync won't resolve this state on
    /// its own (see SyncEngine.evaluateAndMaybeAct), so both directions it
    /// could go are offered here, with what each one actually does spelled
    /// out — one of them reaches the user's other Macs and the other
    /// doesn't, and that's not guessable from the button labels.
    private var cloudOnlyBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("In iCloud, not installed on this Mac", systemImage: "exclamationmark.icloud")
                    .font(.headline)
                    .foregroundStyle(.purple)
                Text("Sync leaves this one alone on purpose: installing it here and deleting it from the shared folder are both decisions the app shouldn't make for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Install on This Mac") {
                        Task { await coordinator.installFromCloud(groupId: group.id) }
                    }
                    Button("Remove from iCloud…", role: .destructive) {
                        showingCloudRemoveConfirm = true
                    }
                }

                Text("Install copies \(CloudOnlyCopy.folderPhrase(for: group)) from iCloud into Interface/AddOns. Nothing in iCloud changes, and \"Delete from This Mac\" undoes it afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(CloudOnlyCopy.removalWarning(for: group))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var versionSourceBox: some View {
        GroupBox("Version Source") {
            VStack(alignment: .leading, spacing: 10) {
                if let wowiId = group.wowInterfaceId {
                    Label("Matched to WowInterface #\(wowiId) via its .toc file — no API key needed.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else if let repo = group.githubRepo {
                    Label("Matched to GitHub repo \(repo.spec) — no API key needed.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else if let match = group.curseForgeMatch {
                    Label("Matched to \"\(match.addonName)\" via CurseForge's own local scan — not CurseForge's API.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else if let slug = group.curseForgeSlug {
                    Label("Matched to CurseForge page \"\(slug)\" — scraped as a last resort, no API or local scan needed. Least reliable of the four sources; see below.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.yellow)
                } else {
                    Label("Not matched to WowInterface, GitHub, the CurseForge scan, or a CurseForge page — synced via iCloud as the shared reference point instead.", systemImage: "icloud")
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("Manual override")
                    .font(.subheadline.bold())
                Text("Point this addon at a specific WowInterface listing or GitHub repo, if its .toc doesn't already do that automatically (or you'd rather use a different one). Clearing removes the override and falls back to whatever the .toc says, if anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("WowInterface ID (number)", text: $wowiIdText)
                        .textFieldStyle(.roundedBorder)
                    Button("Set") {
                        coordinator.setManualWowInterfaceId(folderName: group.primaryFolderName, id: Int(wowiIdText.trimmingCharacters(in: .whitespaces)))
                        Task { await coordinator.syncNow() }
                    }
                    .disabled(Int(wowiIdText.trimmingCharacters(in: .whitespaces)) == nil)
                    Button("Clear") {
                        wowiIdText = ""
                        coordinator.setManualWowInterfaceId(folderName: group.primaryFolderName, id: nil)
                        Task { await coordinator.syncNow() }
                    }
                }

                HStack {
                    TextField("GitHub repo (owner/repo or URL)", text: $githubRepoText)
                        .textFieldStyle(.roundedBorder)
                    Button("Set") {
                        coordinator.setManualGitHubRepo(folderName: group.primaryFolderName, repo: githubRepoText)
                        Task { await coordinator.syncNow() }
                    }
                    .disabled(githubRepoText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Clear") {
                        githubRepoText = ""
                        coordinator.setManualGitHubRepo(folderName: group.primaryFolderName, repo: nil)
                        Task { await coordinator.syncNow() }
                    }
                    Button("View on GitHub ↗") {
                        if let url = githubOverrideLinkURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .disabled(githubOverrideLinkURL == nil)
                }

                Text("Last resort: a CurseForge addon-page slug (e.g. \"clique\" from curseforge.com/wow/addons/clique), only ever used if none of the above match. This scrapes that page's HTML directly — no API, no CurseForge app needed — so it's the least reliable option here; see the warning above if this is the active source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("CurseForge slug or page URL", text: $curseForgeSlugText)
                        .textFieldStyle(.roundedBorder)
                    Button("Set") {
                        coordinator.setManualCurseForgeSlug(folderName: group.primaryFolderName, slug: curseForgeSlugText)
                        Task { await coordinator.syncNow() }
                    }
                    .disabled(curseForgeSlugText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Clear") {
                        curseForgeSlugText = ""
                        coordinator.setManualCurseForgeSlug(folderName: group.primaryFolderName, slug: nil)
                        Task { await coordinator.syncNow() }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var forceSyncDirectionBox: some View {
        GroupBox("Force Sync Direction") {
            HStack {
                Button("Force Push This Mac → iCloud") {
                    Task { await coordinator.resolveConflict(groupId: group.id, keep: .local) }
                }
                Button("Force Pull iCloud → This Mac") {
                    Task { await coordinator.resolveConflict(groupId: group.id, keep: .cloud) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var removeFromThisMacBox: some View {
        GroupBox("Remove Addon") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Moves \(group.folders.count > 1 ? "these folders" : "this folder") to the Trash on this Mac only — iCloud and your other Macs keep their copies untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete from This Mac…", role: .destructive) {
                    showingDeleteConfirm = true
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    /// What "View on GitHub" in the manual-override row should open:
    /// whatever's currently typed in the override field, if it parses as
    /// a repo, so you can preview a repo before hitting Set — falling
    /// back to the addon's actual matched repo when the field's empty or
    /// not a valid repo/URL yet.
    private var githubOverrideLinkURL: URL? {
        GitHubRepoRef(spec: githubRepoText)?.htmlURL ?? group.githubRepo?.htmlURL
    }

    /// The version axis in words — what, if anything, independently
    /// confirms iCloud's copy is the addon's current release. Says nothing
    /// about this Mac; `localStatusText` covers that.
    private var cloudStatusText: String {
        guard group.hasIndependentVersionSource else {
            return "Nothing has checked this against a real release — no version source matched it"
        }
        switch group.cloudState {
        case .unknown: return "Unknown"
        case .notInCloud: return "Not in iCloud yet"
        case .upToDateWithSource:
            if group.wowInterfaceId != nil {
                return "Up to date (verified against WowInterface)"
            } else if group.githubRepo != nil {
                return "Up to date (verified against GitHub Releases)"
            } else if group.curseForgeMatch != nil {
                return "Up to date (verified against CurseForge's local scan)"
            } else {
                return "Up to date (verified against CurseForge's page — scraped, last resort)"
            }
        case .behindSource: return "Newer version available"
        }
    }

    private var localStatusText: String {
        switch group.localState {
        case .unknown: return "Unknown"
        case .matchesCloud: return "Matches iCloud"
        case .behindCloud: return "Needs update from iCloud"
        case .aheadOfCloud: return "Differs from iCloud"
        case .notInstalled: return "Not installed on this Mac"
        }
    }
}

/// Wording shared between the sidebar's inline "Remove…" confirmation and
/// the detail view's, so the two can't drift into describing the same
/// destructive action differently.
enum CloudOnlyCopy {
    static func folderPhrase(for group: AddonGroup) -> String {
        let count = group.cloudFolderNames.count
        return count == 1 ? "1 folder" : "\(count) folders"
    }

    /// Leads with the "other Macs" part on purpose — it's the half of this
    /// action that isn't obvious from a button labelled "Remove".
    static func removalWarning(for group: AddonGroup) -> String {
        "Moves \(folderPhrase(for: group)) to the Trash in your sync folder. That folder is shared, so your other Macs will drop \(group.displayName) on their next sync. Nothing changes on this Mac — it isn't installed here."
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.callout)
    }
}

#Preview {
    let folderAccess = FolderAccess()
    let cloudFolderAccess = CloudFolderAccess()
    let curseForgeFolderAccess = CurseForgeFolderAccess()
    let settings = AppSettings()
    return ContentView()
        .environmentObject(folderAccess)
        .environmentObject(cloudFolderAccess)
        .environmentObject(curseForgeFolderAccess)
        .environmentObject(settings)
        .environmentObject(SyncCoordinator(folderAccess: folderAccess, cloudFolderAccess: cloudFolderAccess, curseForgeFolderAccess: curseForgeFolderAccess, settings: settings))
}

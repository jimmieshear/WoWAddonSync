//
//  AddonModels.swift
//  WoWAddonSync
//
//  Core data types shared across the scanner, the WowInterface client,
//  the iCloud store, and the UI.
//

import Foundation

// MARK: - Parsed .toc metadata

/// The subset of a WoW `.toc` file's `## Key: Value` header lines that we
/// care about. See https://warcraft.wiki.gg/wiki/TOC_format
struct TocMetadata: Equatable, Codable {
    var title: String?
    var version: String?
    var interface: String?
    var author: String?
    var notes: String?

    /// Raw, un-stripped title (WoW TOC titles often contain color escape
    /// codes like `|cff...Title|r`); `title` above has those stripped for
    /// display.
    var rawTitle: String?

    // MARK: Source-site IDs

    /// These `X-`-prefixed custom fields aren't part of the official TOC
    /// format, but they're a de facto standard: the widely-used "BigWigs
    /// Packager" GitHub Action (and similar tools) writes them into every
    /// addon it publishes, so its single `.toc` file also serves as a
    /// manifest of where that addon lives. When present, they let the app
    /// identify an addon's version source directly from the file on disk.
    var wowInterfaceId: Int?        // ## X-WoWI-ID: 12345
    var wagoId: String?             // ## X-Wago-ID: aBcDeFgH (a slug, not numeric) — parsed but not yet used as a source, see README
    var website: String?            // ## X-Website: https://...
}

// MARK: - A single folder on disk under Interface/AddOns

/// One top-level folder directly inside `Interface/AddOns`. A "logical"
/// addon is sometimes made of several of these — e.g. "Details",
/// "Details_Streamer", "Details_Damage_Meter_Skins" all ship together but
/// are separate folders on disk.
struct LocalAddonFolder: Identifiable, Equatable, Codable {
    var id: String { folderName }
    var folderName: String
    var toc: TocMetadata

    /// Per-file content fingerprints (murmur2, seed 1, whitespace stripped)
    /// for every file directly inside this folder, keyed by path relative
    /// to the folder. Used to build the folder-level fingerprint and to
    /// notice local file changes cheaply.
    var fileFingerprints: [String: UInt32]

    /// Combined fingerprint for the whole folder tree.
    /// See `Murmur2Fingerprint.folderFingerprint`.
    var folderFingerprint: UInt32

    var fileCount: Int
    var totalBytes: Int64
}

// MARK: - A logical addon (one or more folders that update together)

/// What the UI shows as a single row. Groups one or more `LocalAddonFolder`s
/// that we believe belong together, and carries whatever we know about its
/// version source and sync status.
struct AddonGroup: Identifiable, Equatable {
    /// Stable identity for this group: the primary folder's name, unless
    /// an earlier sync recorded this addon in the iCloud manifest under a
    /// different id (see `groupingSource`), in which case that id is
    /// reused so the group's identity survives relaunches.
    var id: String
    var displayName: String
    var folders: [LocalAddonFolder]

    /// The folder names this addon occupies in the sync folder. Usually
    /// the same names as `folders`, but it's also populated for addons
    /// that exist in iCloud with nothing installed on this Mac — those
    /// have no `LocalAddonFolder`s at all, since those are built by
    /// scanning the local AddOns folder. See `isCloudOnly`.
    var cloudFolderNames: [String] = []

    /// What iCloud's manifest.json recorded for this addon as of the scan
    /// that built this group. Display only — every sync decision re-reads
    /// the manifest rather than trusting this snapshot.
    var cloudManifestEntry: AddonManifestEntry? = nil

    /// How this group's folders were determined to belong together.
    var groupingSource: GroupingSource

    /// WowInterface's numeric file ID for this addon, read from its .toc
    /// (`X-WoWI-ID`) or set manually. When set, WowInterface is this
    /// addon's version source — see SyncEngine. Takes priority over
    /// `githubRepo` when both are somehow set.
    var wowInterfaceId: Int? = nil

    /// GitHub repo this addon is released from, either parsed from its
    /// .toc `X-Website` field or set manually. Used as the version source
    /// only when there's no WowInterface match — see SyncEngine.
    var githubRepo: GitHubRepoRef? = nil

    /// This addon's entry in CurseForge's own local scan (see
    /// CurseForgeLocalScanAPI.swift), matched by AddOns folder name. Used
    /// as the version source only when there's no WowInterface or GitHub
    /// match — see SyncEngine. Unlike the other two, this can't be set
    /// manually since it's not "an ID you look up," just "is this folder
    /// in the scan or not."
    var curseForgeMatch: CurseForgeAddonMatch? = nil

    /// A CurseForge addon-page slug (e.g. "clique"), either set manually
    /// or parsed from the .toc `X-Website` field — the identity used by
    /// the last-resort page-scrape source (CurseForgeWebScrapeAPI.swift).
    /// Only tried when none of WowInterface, GitHub, or the CurseForge
    /// local scan matched; see SyncEngine.
    var curseForgeSlug: String? = nil

    /// The version string as read from the primary folder's .toc, purely
    /// for display — never used for sync decisions (TOC version strings
    /// are inconsistent across authors; see SyncCoordinator).
    var installedVersionDisplay: String?

    var localState: LocalSyncState = .unknown
    var cloudState: CloudSyncState = .unknown
    var latestWowInterfaceRelease: WowInterfaceLatestRelease? = nil
    var latestGitHubRelease: GitHubLatestRelease? = nil

    /// Filled in when `curseForgeSlug` was actually used — the result of
    /// scraping that addon's CurseForge page. See the doc comment on
    /// CurseForgeScrapedRelease for why this is the lowest-trust source
    /// in the app.
    var curseForgeScraped: CurseForgeScrapedRelease? = nil

    /// Set while an actual copy operation is happening, so the UI can
    /// show a spinner independent of the state enums above.
    var isSyncing: Bool = false
    var lastError: String?
    var lastSyncedAt: Date?

    enum GroupingSource: Equatable {
        /// Multiple folders that an earlier sync recorded together in the
        /// iCloud manifest (fresh grouping only ever discovers one folder
        /// at a time — see buildGroups in SyncCoordinator.swift).
        case manifestGrouped
        case singleFolder
    }

    var primaryFolderName: String {
        folders.first?.folderName ?? cloudFolderNames.first ?? displayName
    }

    /// This addon is in the shared iCloud folder but isn't installed in
    /// this Mac's AddOns folder at all. Sync deliberately leaves these
    /// alone rather than picking a side: installing it here and deleting
    /// it from iCloud (which removes it from every other Mac too) are both
    /// choices only you can make, so the UI offers both instead. See
    /// `SyncEngine.evaluateAndMaybeAct`.
    var isCloudOnly: Bool {
        folders.isEmpty && !cloudFolderNames.isEmpty
    }

    /// The folder names this addon occupies: the local ones when it's
    /// installed here, iCloud's record of them when it isn't.
    var effectiveFolderNames: [String] {
        folders.isEmpty ? cloudFolderNames : folders.map(\.folderName)
    }

    /// Folders this addon has in iCloud that aren't in this Mac's AddOns
    /// folder. Empty for a normally-installed addon, and all of them for
    /// an `isCloudOnly` one — the case worth surfacing is the middle:
    /// an addon that's mostly installed but missing a folder or two, which
    /// otherwise reads as a perfectly healthy row, since the local scan
    /// can only see the folders that are actually there.
    var missingLocalFolderNames: [String] {
        let installed = Set(folders.map(\.folderName))
        return cloudFolderNames.filter { !installed.contains($0) }
    }

    /// The most trustworthy "version" string available for display,
    /// preferring an independent source's actual latest release over the
    /// addon's own `.toc` string — which, per `installedVersionDisplay`'s
    /// doc comment, is author-supplied and often inconsistent. Checked in
    /// the same priority order as the version source itself: GitHub
    /// (explicitly what this was added for), then WowInterface, then the
    /// CurseForge local scan, then the CurseForge page scrape (last
    /// resort — see CurseForgeWebScrapeAPI.swift), falling back to the
    /// `.toc` value only when none of the four matched — and finally to
    /// whatever iCloud's manifest last recorded, which is the only version
    /// string there is for an addon that isn't installed here at all (see
    /// `isCloudOnly`). Paired with `bestVersionDate` below.
    var bestVersionDisplay: String? {
        latestGitHubRelease?.displayName
            ?? latestWowInterfaceRelease?.displayName
            ?? curseForgeMatch?.latestFileName
            ?? curseForgeScraped?.displayName
            ?? installedVersionDisplay
            ?? cloudManifestEntry?.versionDisplay
    }

    /// The release date that goes with `bestVersionDisplay`, from that
    /// same source — nil when `bestVersionDisplay` fell back to the
    /// `.toc` string (no reliable date at all) or to the CurseForge
    /// scrape when that particular fetch couldn't parse a date out of the
    /// page even though it found a version string.
    var bestVersionDate: Date? {
        latestGitHubRelease?.publishedAt
            ?? latestWowInterfaceRelease?.fileDate
            ?? curseForgeMatch?.latestFileDate
            ?? curseForgeScraped?.fileDate
    }

    /// A link to the addon's actual page on whatever site is acting as
    /// its version source, so you can go look at it yourself — release
    /// notes, comments, whether it's actually still maintained, etc.
    /// Falls back to the addon's own `.toc` `X-Website` field when it
    /// isn't matched to either source (still useful even though the app
    /// isn't using it for version checks in that case).
    var sourceSiteURL: URL? {
        if let wowInterfaceId {
            return URL(string: "https://www.wowinterface.com/downloads/info\(wowInterfaceId).html")
        }
        if let githubRepo {
            return githubRepo.htmlURL
        }
        if let curseForgeMatch, let webSiteURL = curseForgeMatch.webSiteURL {
            return webSiteURL
        }
        if let curseForgeScraped {
            return curseForgeScraped.pageURL
        }
        if let website = folders.first?.toc.website {
            return URL(string: website)
        }
        return nil
    }

    /// Whether anything independent of iCloud has an opinion about this
    /// addon's latest version — see `versionStatus` for why that matters.
    var hasIndependentVersionSource: Bool {
        wowInterfaceId != nil || githubRepo != nil || curseForgeMatch != nil || curseForgeSlug != nil
    }

    /// Where iCloud's copy stands against the addon's *actual* latest
    /// release, per whichever of the four sources matched.
    ///
    /// Deliberately independent of `syncStatus`: your Macs all agreeing on
    /// a version says nothing about whether that version is current, and a
    /// new release being out says nothing about whether your Macs agree.
    /// Collapsing the two into one badge meant "Synced" had to double as
    /// "and nothing checked this", which is a lot to load onto one word.
    var versionStatus: StatusKind {
        guard hasIndependentVersionSource else { return .unverified }
        switch cloudState {
        case .upToDateWithSource: return .upToDate
        case .behindSource: return .updateAvailable
        case .notInCloud, .unknown: return .unknown
        }
    }

    /// Where this Mac's copy stands against iCloud's.
    var syncStatus: StatusKind {
        if cloudState == .notInCloud { return .notInCloud }
        // Checked before `localState`, which is computed by walking the
        // folders the local scan found — so it can only ever compare the
        // folders that are actually here. An addon missing two of its five
        // folders would otherwise report a clean "Synced" on the strength
        // of the three that survived.
        if !missingLocalFolderNames.isEmpty { return .missingFolders }
        switch localState {
        case .matchesCloud: return .synced
        case .behindCloud: return .localBehindCloud
        case .notInstalled: return .missingFolders
        // Nothing sets this today — evaluateLocalAgainstCloud only ever
        // produces the three above — so there's no honest badge for it yet.
        case .aheadOfCloud: return .unknown
        case .unknown: return .unknown
        }
    }

    /// The badges to show, in display order. Normally two, one per axis, so
    /// an addon that's both verified-current and in sync says so twice
    /// rather than making you infer the second from the first.
    ///
    /// Collapses to one badge whenever a single state already says
    /// everything there is to say: mid-sync, errored, or not installed here
    /// at all — that last one has no local copy to be in sync with and
    /// never gets a version check (see SyncEngine.evaluateAndMaybeAct), so
    /// a second badge would only ever read "Unknown".
    var statusBadges: [StatusKind] {
        if isSyncing { return [.syncing] }
        if lastError != nil { return [.error] }
        if isCloudOnly { return [.inCloudOnly] }
        return [versionStatus, syncStatus]
    }

    enum StatusKind: Hashable {
        // MARK: Version axis — iCloud vs. the addon's real latest release

        /// Verified against an independent version source (WowInterface,
        /// GitHub Releases, a CurseForge local scan match, or a CurseForge
        /// page scrape).
        case upToDate
        /// That source has something newer than what's in iCloud.
        case updateAvailable
        /// No independent source matched this addon, so nothing has
        /// actually checked it against a real release. iCloud is the only
        /// reference point there is — see the README's note on why these
        /// don't get to claim "Up to Date".
        case unverified

        // MARK: Sync axis — this Mac vs. iCloud

        /// This Mac's copy matches iCloud's.
        case synced
        /// iCloud has something this Mac doesn't have yet.
        case localBehindCloud
        /// Some of this addon's folders are in iCloud but not here — see
        /// `missingLocalFolderNames`. Distinct from `inCloudOnly`, which is
        /// an addon with nothing installed at all.
        case missingFolders
        /// This Mac has it, iCloud doesn't yet.
        case notInCloud

        // MARK: Whole-addon states, shown on their own

        /// In the shared iCloud folder, not installed on this Mac at all.
        /// See `isCloudOnly`.
        case inCloudOnly
        case syncing, error, unknown
    }
}

/// Where the iCloud copy stands relative to the "source of truth" (the
/// WowInterface, GitHub Releases, or CurseForge-local-scan latest file
/// when the addon matches one of those, otherwise the newest version any
/// of the user's own machines has reported).
enum CloudSyncState: Equatable {
    case unknown
    case notInCloud
    case upToDateWithSource
    case behindSource
}

/// Where THIS machine's local copy stands relative to the iCloud copy.
enum LocalSyncState: Equatable {
    case unknown
    case matchesCloud
    case behindCloud
    case aheadOfCloud   // local has changes iCloud doesn't (e.g. never synced yet)
    case notInstalled
}

// MARK: - The manifest stored in iCloud (manifest.json at the container root)

/// One entry per addon group, stored in iCloud so every machine agrees on
/// what "the current synced version" is.
struct AddonManifestEntry: Codable, Equatable {
    var id: String
    var displayName: String
    var folderNames: [String]
    var wowInterfaceId: Int? = nil
    /// WowInterface's file MD5 — the "what's currently in iCloud" token
    /// for that source (WowInterface doesn't hand out a stable numeric
    /// file/version id the way some other sources do).
    var wowInterfaceMD5: String? = nil
    var githubRepo: GitHubRepoRef? = nil
    /// The GitHub release tag — the "what's currently in iCloud" token
    /// for that source.
    var githubTag: String? = nil
    var curseForgeAddonID: Int? = nil
    /// CurseForge's numeric file id for the release currently in iCloud —
    /// the "what's currently in iCloud" token for that source, compared
    /// against a fresh scan's `latestFileId`.
    var curseForgeFileId: Int? = nil
    /// The slug and file id last pushed from the CurseForge page-scrape
    /// source (CurseForgeWebScrapeAPI.swift) — kept separate from
    /// `curseForgeAddonID`/`curseForgeFileId` above since those are real
    /// CurseForge project/file IDs from the authenticated local scan,
    /// while these are best-effort numbers parsed out of an HTML page and
    /// shouldn't be compared against each other.
    var curseForgeScrapedSlug: String? = nil
    var curseForgeScrapedFileId: Int? = nil
    var versionDisplay: String?
    var folderFingerprints: [String: UInt32]   // folderName -> folderFingerprint, as stored in iCloud
    var updatedAt: Date
    var updatedByDevice: String
}

struct AddonManifest: Codable {
    var schemaVersion: Int = 1
    var entries: [String: AddonManifestEntry] = [:]
}

// MARK: - Small helpers

extension TocMetadata {
    /// Strips WoW's inline color/escape codes (`|cAARRGGBB...|r`, `|T...|t`)
    /// from a raw TOC string for display. Falls back to returning the input
    /// unchanged if the regex ever fails to compile.
    static func stripColorCodes(_ raw: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "\\|c[0-9A-Fa-f]{8}|\\|r|\\|T.*?\\|t",
            options: []
        ) else {
            return raw
        }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return regex.stringByReplacingMatches(in: raw, options: [], range: range, withTemplate: "")
    }
}

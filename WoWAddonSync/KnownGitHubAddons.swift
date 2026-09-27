//
//  KnownGitHubAddons.swift
//  WoWAddonSync
//
//  A small, hand-curated fallback for addons that ARE genuinely
//  distributed as real GitHub Releases, but whose `.toc` doesn't say so
//  (no `X-Website` field pointing at GitHub) — true of most
//  CurseForge-primary addons, since that packaging convention is mainly a
//  WowInterface/BigWigs-Packager thing.
//
//  Unlike everything else feeding this app's GitHub source, these matches
//  were found by hand: checking each addon's actual GitHub releases page
//  for a real `.zip` asset whose version and date line up with what's
//  actually installed (not just "a repo with the right name"). If you add
//  to this list, hold it to the same bar — a repo that merely looks right
//  but publishes no releases (several were found and deliberately left
//  out; see below) is worse than useless as an entry here: once an addon
//  resolves to a GitHub repo, that's its version source exclusively (see
//  evaluateWithGitHubSource in SyncCoordinator.swift) — there's no
//  automatic fallback to iCloud-only syncing if it turns out to have
//  nothing to check, it just shows an error instead.
//
//  Checked only when neither a manual override (Settings/detail view) nor
//  the addon's own `.toc` `X-Website` resolves a repo — see
//  resolvedGitHubRepo in SyncCoordinator.swift. Keyed by AddOns folder
//  name, same as everywhere else in this app. An addon distributed as
//  several folders needs every one of those folder names listed, since
//  fresh grouping resolves one folder at a time before any of them are
//  known to belong together (see buildGroups) — every folder below that
//  shares a repo will converge onto one AddonGroup after its first sync
//  anyway, but each needs its own entry to get there.
//
//  Checked and confirmed as of September 2026:
//   - Clique (github.com/kxseven/Clique), TomTom
//     (github.com/MURPHYENGINEERING/tomtom), and BeQuiet
//     (github.com/Xorag/BeQuiet) all have real, matching source on GitHub
//     but zero published releases — deliberately left out of this table.
//   - Class Codex: no findable repo from its credited original author at
//     all (only unrelated/unconfirmed forks) — nothing to add.
//

import Foundation

enum KnownGitHubAddons {
    /// folderName -> "owner/repo".
    private static let table: [String: String] = [
        // WeakAuras — github.com/WeakAuras/WeakAuras2. Note: GitHub's
        // latest tag (5.22.0, Sep 2026) was briefly ahead of CurseForge's
        // own latest file (5.21.1) when this was checked — this source
        // can occasionally be *more* current than CurseForge, not just an
        // alternative to it.
        "WeakAuras": "WeakAuras/WeakAuras2",
        "WeakAurasArchive": "WeakAuras/WeakAuras2",
        "WeakAurasModelPaths": "WeakAuras/WeakAuras2",
        "WeakAurasOptions": "WeakAuras/WeakAuras2",
        "WeakAurasTemplates": "WeakAuras/WeakAuras2",

        // Bartender4 — github.com/Nevcairiel/Bartender4. Confirmed exact
        // match: GitHub's latest release asset was named
        // Bartender4-4.17.9.1.zip, same version and date CurseForge had.
        "Bartender4": "Nevcairiel/Bartender4",

        // Grid2 — github.com/michaelnpsp/Grid2. Confirmed exact match
        // (Grid2-4.0.27.zip, same version/date as CurseForge).
        "Grid2": "michaelnpsp/Grid2",
        "Grid2LDB": "michaelnpsp/Grid2",
        "Grid2Options": "michaelnpsp/Grid2",

        // Deadly Boss Mods is split across two separate CurseForge
        // projects/GitHub repos that update independently — Core (and its
        // sub-modules) and the Dungeons/Delves party-size pack. Both
        // confirmed exact matches (same tag + release date as CurseForge's
        // installed files).
        "DBM-Core": "DeadlyBossMods/DeadlyBossMods",
        "DBM-GUI": "DeadlyBossMods/DeadlyBossMods",
        "DBM-Brawlers": "DeadlyBossMods/DeadlyBossMods",
        "DBM-StatusBarTimers": "DeadlyBossMods/DeadlyBossMods",
        "DBM-Test": "DeadlyBossMods/DeadlyBossMods",
        "DBM-VPVEM": "DeadlyBossMods/DeadlyBossMods",
        "DBM-Lairs-Midnight": "DeadlyBossMods/DeadlyBossMods",
        "DBM-Midnight": "DeadlyBossMods/DeadlyBossMods",
        "DBM-Raids-Midnight": "DeadlyBossMods/DeadlyBossMods",

        "DBM-Challenges": "DeadlyBossMods/DBM-Dungeons",
        "DBM-WorldEvents": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Test-Dungeons": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Delves-Midnight": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Delves-WarWithin": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Party-BC": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Party-BfA": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Party-Cataclysm": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Party-Dragonflight": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Party-Legion": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Party-Midnight": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Party-MoP": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Party-Shadowlands": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Party-Vanilla": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Party-WarWithin": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Party-WoD": "DeadlyBossMods/DBM-Dungeons",
        "DBM-Party-WotLK": "DeadlyBossMods/DBM-Dungeons",
    ]

    static func repo(forFolderName folderName: String) -> GitHubRepoRef? {
        guard let spec = table[folderName] else { return nil }
        return GitHubRepoRef(spec: spec)
    }
}

//
//  AppSettings.swift
//  WoWAddonSync
//

import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    @Published var autoSyncOnLaunch: Bool {
        didSet { UserDefaults.standard.set(autoSyncOnLaunch, forKey: Keys.autoSyncOnLaunch) }
    }

    /// A human-readable label for this Mac, stored in the iCloud manifest
    /// so you can see which machine last touched an addon.
    @Published var deviceLabel: String {
        didSet { UserDefaults.standard.set(deviceLabel, forKey: Keys.deviceLabel) }
    }

    /// Manual folder-name -> WowInterface ID overrides, for addons whose
    /// `.toc` doesn't carry `X-WoWI-ID` (or where you want to point it at
    /// a different listing than the automatic one). Persisted locally
    /// (not in iCloud) since it's a per-user convenience, but every
    /// machine that sets one up will get it recorded into the shared
    /// iCloud manifest the next time that addon syncs, so other machines
    /// benefit too without needing to enter it themselves.
    @Published var manualWowInterfaceIds: [String: Int] {
        didSet { saveDict(manualWowInterfaceIds, key: Keys.manualWowInterfaceIds) }
    }

    /// Manual folder-name -> GitHub "owner/repo" overrides, for addons
    /// whose `.toc` doesn't point at GitHub in a way the app can parse
    /// automatically (see GitHubRepoRef.init(website:)). Same
    /// persistence/sharing behavior as `manualWowInterfaceIds` above.
    @Published var manualGitHubRepos: [String: String] {
        didSet { saveDict(manualGitHubRepos, key: Keys.manualGitHubRepos) }
    }

    /// Manual folder-name -> CurseForge slug overrides, for the
    /// last-resort page-scrape source (CurseForgeWebScrapeAPI.swift).
    /// Same persistence/sharing behavior as the two above.
    @Published var manualCurseForgeSlugs: [String: String] {
        didSet { saveDict(manualCurseForgeSlugs, key: Keys.manualCurseForgeSlugs) }
    }

    private enum Keys {
        static let autoSyncOnLaunch = "autoSyncOnLaunch"
        static let deviceLabel = "deviceLabel"
        static let manualWowInterfaceIds = "manualWowInterfaceIds"
        static let manualGitHubRepos = "manualGitHubRepos"
        static let manualCurseForgeSlugs = "manualCurseForgeSlugs"
    }

    init() {
        self.autoSyncOnLaunch = UserDefaults.standard.object(forKey: Keys.autoSyncOnLaunch) as? Bool ?? true
        self.deviceLabel = UserDefaults.standard.string(forKey: Keys.deviceLabel) ?? Host.current().localizedName ?? "This Mac"
        self.manualWowInterfaceIds = Self.loadDict(key: Keys.manualWowInterfaceIds) ?? [:]
        self.manualGitHubRepos = Self.loadDict(key: Keys.manualGitHubRepos) ?? [:]
        self.manualCurseForgeSlugs = Self.loadDict(key: Keys.manualCurseForgeSlugs) ?? [:]
    }

    private func saveDict<T: Encodable>(_ dict: [String: T], key: String) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func loadDict<T: Decodable>(key: String) -> [String: T]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([String: T].self, from: data)
    }
}

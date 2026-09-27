//
//  iCloudAddonStore.swift
//  WoWAddonSync
//
//  Stores synced addon folders and a shared manifest.json under a
//  user-chosen folder (normally somewhere inside iCloud Drive — see
//  CloudFolderAccess for why it's a plain user-selected folder rather
//  than an app-private iCloud container):
//    <chosen folder>/Addons/<folderName>/...
//    <chosen folder>/manifest.json
//
//  `rootURL` is set by SyncCoordinator from CloudFolderAccess before each
//  run. Files under it are still genuinely "ubiquitous" (iCloud-tracked)
//  items as far as the OS is concerned as long as the folder itself lives
//  inside iCloud Drive, so the eviction/download handling below still
//  applies — it just doesn't require any special entitlement to use.
//

import Foundation

enum iCloudAddonStoreError: LocalizedError {
    case rootNotSet
    case notDownloaded(String)

    var errorDescription: String? {
        switch self {
        case .rootNotSet:
            return "No sync folder is set yet. Pick one in Settings."
        case .notDownloaded(let name):
            return "\(name) exists in the sync folder but hasn't finished downloading to this Mac yet."
        }
    }
}

final class iCloudAddonStore {
    private let fm = FileManager.default

    /// The folder the user picked (normally inside iCloud Drive). Set by
    /// SyncCoordinator before each run, from CloudFolderAccess.
    var rootURL: URL?

    var addonsURL: URL? {
        rootURL?.appendingPathComponent("Addons", isDirectory: true)
    }

    var manifestURL: URL? {
        rootURL?.appendingPathComponent("manifest.json", isDirectory: false)
    }

    func ensureDirectoriesExist() throws {
        guard let addonsURL else { throw iCloudAddonStoreError.rootNotSet }
        if !fm.fileExists(atPath: addonsURL.path) {
            try fm.createDirectory(at: addonsURL, withIntermediateDirectories: true)
        }
    }

    // MARK: Manifest

    func loadManifest() -> AddonManifest {
        guard let manifestURL, fm.fileExists(atPath: manifestURL.path) else {
            return AddonManifest()
        }
        do {
            try downloadIfNeeded(manifestURL)
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder.wowAddonSync.decode(AddonManifest.self, from: data)
        } catch {
            return AddonManifest()
        }
    }

    func saveManifest(_ manifest: AddonManifest) throws {
        try ensureDirectoriesExist()
        guard let manifestURL else { throw iCloudAddonStoreError.rootNotSet }
        let data = try JSONEncoder.wowAddonSync.encode(manifest)
        // Write to a temp file then replace, so a half-written file never
        // lands in the synced location.
        let tempURL = manifestURL.deletingLastPathComponent()
            .appendingPathComponent(".manifest-\(UUID().uuidString).json")
        try data.write(to: tempURL, options: .atomic)
        _ = try fm.replaceItemAt(manifestURL, withItemAt: tempURL)
    }

    /// Drops one addon's entry from the manifest. A no-op (not an error)
    /// if there was no such entry — the caller's goal is "iCloud no longer
    /// records this addon", which is already true in that case.
    func removeManifestEntry(id: String) throws {
        var manifest = loadManifest()
        guard manifest.entries.removeValue(forKey: id) != nil else { return }
        try saveManifest(manifest)
    }

    // MARK: Folder listing

    /// Every top-level folder name under `Addons/`. Unlike the local scan
    /// this doesn't read any file contents — it's only used to find out
    /// *which* addons iCloud has, including ones this Mac has never
    /// installed, so the names are all that's needed. Evicted "cloud only"
    /// placeholders still show up here, since the folder entries
    /// themselves are always local even when their contents aren't.
    func cloudFolderNames() -> [String] {
        guard let addonsURL, fm.fileExists(atPath: addonsURL.path) else { return [] }
        let contents = (try? fm.contentsOfDirectory(
            at: addonsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent }.sorted()
    }

    // MARK: Folder copy

    func cloudURL(forFolder name: String) -> URL? {
        addonsURL?.appendingPathComponent(name, isDirectory: true)
    }

    func folderExistsInCloud(_ name: String) -> Bool {
        guard let url = cloudURL(forFolder: name) else { return false }
        return fm.fileExists(atPath: url.path)
    }

    /// Copies a folder from local disk into the sync folder, replacing
    /// whatever's there. `downloadIfNeeded` is intentionally NOT called on
    /// the destination since we're about to overwrite it.
    func copyFolderToCloud(from localURL: URL, folderName: String) throws {
        try ensureDirectoriesExist()
        guard let destination = cloudURL(forFolder: folderName) else {
            throw iCloudAddonStoreError.rootNotSet
        }
        try replaceDirectory(at: destination, withContentsOf: localURL)
    }

    /// Copies a folder from the sync folder down to local disk, replacing
    /// whatever's there. Downloads the iCloud copy first if it's evicted
    /// (a "cloud only" placeholder).
    func copyFolderFromCloud(folderName: String, to localURL: URL) throws {
        guard let source = cloudURL(forFolder: folderName) else {
            throw iCloudAddonStoreError.rootNotSet
        }
        try downloadIfNeeded(source, isDirectory: true)
        try replaceDirectory(at: localURL, withContentsOf: source)
    }

    /// Moves a folder in the sync folder to the Trash. Deliberately
    /// `trashItem` rather than `removeItem`: this is the one operation in
    /// the app that propagates to the user's *other* Macs, so it stays
    /// recoverable. If the volume won't accept a trash operation the error
    /// is thrown rather than quietly falling back to a real delete.
    func trashFolderInCloud(_ name: String) throws {
        guard let url = cloudURL(forFolder: name) else {
            throw iCloudAddonStoreError.rootNotSet
        }
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.trashItem(at: url, resultingItemURL: nil)
    }

    private func replaceDirectory(at destination: URL, withContentsOf source: URL) throws {
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        } else {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try fm.copyItem(at: source, to: destination)
    }

    /// Forces download of an evicted iCloud item and waits (briefly,
    /// polling) for it to materialize. Ubiquitous files can be
    /// "cloud only" placeholders until requested. If the sync folder isn't
    /// actually inside an iCloud-tracked location (e.g. a plain local or
    /// Dropbox folder), `startDownloadingUbiquitousItem` simply fails and
    /// we fall through — the file is already local in that case anyway.
    private func downloadIfNeeded(_ url: URL, isDirectory: Bool = false, timeout: TimeInterval = 30) throws {
        try? fm.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if values?.ubiquitousItemDownloadingStatus == .current {
                return
            }
            if fm.fileExists(atPath: url.path), !isDirectory {
                // Best-effort: for files, existence plus a readable size
                // is good enough evidence it's usable.
                return
            }
            if values?.ubiquitousItemDownloadingStatus == nil, fm.fileExists(atPath: url.path) {
                // Not a ubiquitous item at all (e.g. a local-only sync
                // folder) — it's just a normal file/folder, nothing to wait
                // for.
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        // Not necessarily fatal — proceed and let the caller's own
        // read/copy surface a clearer error if the data truly isn't there.
    }
}

// MARK: - Shared JSON coders

extension JSONEncoder {
    static let wowAddonSync: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let wowAddonSync: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

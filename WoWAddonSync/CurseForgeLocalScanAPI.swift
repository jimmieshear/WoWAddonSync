//
//  CurseForgeLocalScanAPI.swift
//  WoWAddonSync
//
//  A version source for the addons that don't have anywhere else to turn:
//  CurseForge doesn't publish a WowInterface-style `.toc` field to identify
//  them by, and CurseForge's own API is gated behind a developer
//  application. This file deliberately does NOT talk to that API.
//
//  What it does instead: the CurseForge desktop app (if you have it
//  installed and use it to manage addons — most CurseForge-sourced addons
//  are) keeps a local scan of every installed addon on disk, refreshed
//  periodically while that app runs, at:
//
//    ~/Library/Application Support/CurseForge/agent/GameInstances/*.json
//
//  Each file already contains, per installed addon, both `installedFile`
//  (what's on disk) and `latestFile` (what CurseForge's servers say is
//  newest) — CurseForge's own app already did the real API call and wrote
//  the answer to disk. This app just reads that file, the same way it
//  reads a `.toc`. The one live network request this file ever makes is
//  downloading a release zip from `latestFile.downloadUrl`, which points
//  at CurseForge's CDN (`edge.forgecdn.net`) — a plain, unauthenticated
//  HTTPS GET, same as clicking a direct download link in a browser.
//
//  Trade-offs, to be upfront about:
//   - Only helps addons the CurseForge app actually manages.
//   - Freshness depends entirely on when CurseForge's app last refreshed
//     that file — this app has no way to trigger or verify that.
//   - This is CurseForge's own internal app format, not a published,
//     versioned API — it's what a real installed copy of the app writes
//     as of when this was built, but nothing guarantees it stays in this
//     shape across CurseForge app updates. Worth a glance if it ever
//     seems to stop matching addons that should match.
//   - macOS won't let this app request access to that folder on your
//     behalf (it's under ~/Library) — you grant it once yourself, via the
//     folder picker in Settings. See CurseForgeFolderAccess in
//     FolderAccess.swift.
//

import Foundation

// MARK: - Resolved match

/// What the local CurseForge scan says about one installed addon, looked
/// up by the AddOns folder name(s) it occupies. `installedFileName`/`Id`
/// are purely for display (like a `.toc`'s version string elsewhere) —
/// never used for sync decisions, since this app can't verify a locally
/// modified copy actually matches what CurseForge thinks is there.
/// `latestFileId` is what sync decisions compare against.
struct CurseForgeAddonMatch: Equatable {
    var addonID: Int
    var addonName: String
    var webSiteURL: URL?
    var installedFileName: String?
    var installedFileId: Int?
    var latestFileName: String?
    var latestFileId: Int?
    var latestFileDate: Date?
    var latestDownloadUrl: URL?
}

// MARK: - Raw JSON shape (CurseForge's own internal format — see file header)

private struct CFFileInfo: Decodable {
    let id: Int?
    let fileName: String?
    let fileDate: String?
    let downloadUrl: String?
}

private struct CFInstalledAddon: Decodable {
    let addonID: Int
    let name: String
    let webSiteURL: String?
    let filePaths: [String]?
    let installedFile: CFFileInfo?
    let latestFile: CFFileInfo?
}

private struct CFGameInstance: Decodable {
    let installPath: String?
    let installedAddons: [CFInstalledAddon]?
}

// MARK: - Scanner

enum CurseForgeLocalScan {
    /// Reads every `.json` file directly inside `gameInstancesFolder`,
    /// keeps only game instances whose `installPath` looks like a
    /// `_retail_` install, and returns a lookup from AddOns folder name to
    /// whatever addon owns that folder. An addon with several folders
    /// (e.g. a raid-mod pack with many sub-modules) maps every one of its
    /// folders to the same match.
    ///
    /// Never throws — a missing/unreadable folder, or a file that doesn't
    /// parse, is treated the same as "nothing to report" (an empty
    /// dictionary), since this source is always best-effort.
    static func scan(gameInstancesFolder: URL) -> [String: CurseForgeAddonMatch] {
        var result: [String: CurseForgeAddonMatch] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: gameInstancesFolder,
            includingPropertiesForKeys: nil
        ) else {
            return result
        }

        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            for instance in decodeInstances(from: data) {
                guard let installPath = instance.installPath,
                      installPath.localizedCaseInsensitiveContains("_retail_") else { continue }
                for addon in instance.installedAddons ?? [] {
                    let match = makeMatch(for: addon)
                    for folder in topLevelFolders(for: addon) {
                        result[folder] = match
                    }
                }
            }
        }
        return result
    }

    /// CurseForge's agent has written this either as a single game-instance
    /// object or an array of them, depending on version — handle both
    /// rather than guessing wrong and silently matching nothing.
    private static func decodeInstances(from data: Data) -> [CFGameInstance] {
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([CFGameInstance].self, from: data) {
            return array
        }
        if let single = try? decoder.decode(CFGameInstance.self, from: data) {
            return [single]
        }
        return []
    }

    /// `filePaths` lists every file the addon owns, absolute-pathed. The
    /// AddOns folder name is whatever comes right after ".../Interface/AddOns/".
    private static func topLevelFolders(for addon: CFInstalledAddon) -> [String] {
        var tops = Set<String>()
        let marker = "/Interface/AddOns/"
        for path in addon.filePaths ?? [] {
            guard let range = path.range(of: marker) else { continue }
            let rest = path[range.upperBound...]
            if let slash = rest.firstIndex(of: "/") {
                tops.insert(String(rest[rest.startIndex..<slash]))
            } else if !rest.isEmpty {
                tops.insert(String(rest))
            }
        }
        return Array(tops)
    }

    private static func makeMatch(for addon: CFInstalledAddon) -> CurseForgeAddonMatch {
        CurseForgeAddonMatch(
            addonID: addon.addonID,
            addonName: addon.name,
            webSiteURL: addon.webSiteURL.flatMap { URL(string: $0) },
            installedFileName: addon.installedFile?.fileName,
            installedFileId: addon.installedFile?.id,
            latestFileName: addon.latestFile?.fileName,
            latestFileId: addon.latestFile?.id,
            latestFileDate: addon.latestFile?.fileDate.flatMap(parseDate),
            latestDownloadUrl: addon.latestFile?.downloadUrl.flatMap { URL(string: $0) }
        )
    }

    private static func parseDate(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}

// MARK: - Downloading a matched release

enum CurseForgeDownloadError: LocalizedError {
    case missingDownloadURL
    case httpError(status: Int)
    case transportError(Error)

    var errorDescription: String? {
        switch self {
        case .missingDownloadURL:
            return "The CurseForge scan doesn't have a download link for this addon's latest file — try refreshing addons inside the CurseForge app itself."
        case .httpError(let status):
            return "CurseForge's download server returned HTTP \(status)."
        case .transportError(let error):
            return "Network error downloading from CurseForge: \(error.localizedDescription)"
        }
    }
}

/// Downloads a matched release's zip from CurseForge's CDN — a plain,
/// unauthenticated GET, not a call to CurseForge's actual API.
final class CurseForgeDownloader {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Same temp-file-lifetime handling as the other clients — URLSession's
    /// own temp file isn't guaranteed to outlive this call.
    func download(_ url: URL) async throws -> URL {
        let downloadedURL: URL
        let response: URLResponse
        do {
            (downloadedURL, response) = try await session.download(from: url)
        } catch {
            throw CurseForgeDownloadError.transportError(error)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CurseForgeDownloadError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWAddonSync-curseforge-download-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: downloadedURL, to: destination)
        } catch {
            throw CurseForgeDownloadError.transportError(error)
        }
        return destination
    }
}

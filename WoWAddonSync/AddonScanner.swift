//
//  AddonScanner.swift
//  WoWAddonSync
//
//  Walks a WoW `_retail_/Interface/AddOns` folder and builds
//  `LocalAddonFolder` values: parsed .toc metadata plus per-file and
//  per-folder content fingerprints (see Murmur2Fingerprint.swift).
//

import Foundation

enum AddonScanner {

    /// Files we deliberately skip when fingerprinting/copying — noise that
    /// isn't part of the addon's identity and that WoW itself writes.
    private static let ignoredFileNames: Set<String> = [".DS_Store"]
    private static let ignoredExtensions: Set<String> = []

    struct ScanResult {
        var folders: [LocalAddonFolder]
        var scanErrors: [String]
    }

    /// `addOnsURL` should point directly at `.../Interface/AddOns`.
    static func scan(addOnsURL: URL) -> ScanResult {
        let fm = FileManager.default
        var folders: [LocalAddonFolder] = []
        var errors: [String] = []

        let topLevel: [URL]
        do {
            topLevel = try fm.contentsOfDirectory(
                at: addOnsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return ScanResult(folders: [], scanErrors: ["Couldn't list AddOns folder: \(error.localizedDescription)"])
        }

        for entryURL in topLevel.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: entryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            do {
                if let folder = try scanFolder(entryURL) {
                    folders.append(folder)
                }
            } catch {
                errors.append("\(entryURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return ScanResult(folders: folders, scanErrors: errors)
    }

    /// Scans a single known addon folder directly, without listing its
    /// parent directory. Used when we only need to re-check one folder
    /// (e.g. right after copying it) rather than a full AddOns scan.
    static func scanSingleFolder(_ folderURL: URL) throws -> LocalAddonFolder? {
        try scanFolder(folderURL)
    }

    private static func scanFolder(_ folderURL: URL) throws -> LocalAddonFolder? {
        let fm = FileManager.default
        let folderName = folderURL.lastPathComponent

        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var fingerprints: [String: UInt32] = [:]
        var fileCount = 0
        var totalBytes: Int64 = 0

        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues?.isRegularFile == true else { continue }

            let name = fileURL.lastPathComponent
            if ignoredFileNames.contains(name) { continue }
            if ignoredExtensions.contains(fileURL.pathExtension.lowercased()) { continue }

            guard let fingerprint = Murmur2Fingerprint.fileFingerprint(contentsOf: fileURL) else { continue }

            let relativePath = fileURL.path
                .replacingOccurrences(of: folderURL.path + "/", with: "")
            fingerprints[relativePath] = fingerprint
            fileCount += 1
            totalBytes += Int64(resourceValues?.fileSize ?? 0)
        }

        // A directory with no readable files at all isn't a real addon
        // folder (could be an empty leftover directory) — skip it.
        guard fileCount > 0 else { return nil }

        let toc: TocMetadata
        if let tocURL = TocParser.primaryTocURL(inFolder: folderURL), let parsed = TocParser.parse(fileAt: tocURL) {
            toc = parsed
        } else {
            toc = TocMetadata()
        }

        let folderFingerprint = Murmur2Fingerprint.folderFingerprint(fileFingerprints: fingerprints)

        return LocalAddonFolder(
            folderName: folderName,
            toc: toc,
            fileFingerprints: fingerprints,
            folderFingerprint: folderFingerprint,
            fileCount: fileCount,
            totalBytes: totalBytes
        )
    }

    /// Best-effort default location, before the user has picked a folder
    /// via the sandbox-safe picker in FolderAccess.
    static func defaultAddOnsPath() -> String {
        "/Applications/World of Warcraft/_retail_/Interface/AddOns"
    }
}

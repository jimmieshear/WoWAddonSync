//
//  FolderAccess.swift
//  WoWAddonSync
//
//  Three folder-access types, same pattern for all: because the app runs
//  in the App Sandbox, any folder outside the app's own container
//  ("/Applications/World of Warcraft/...", or wherever you keep your
//  synced addons) needs a one-time grant via NSOpenPanel. We keep that
//  grant alive across launches with a security-scoped bookmark stored in
//  UserDefaults (the bookmark data itself isn't secret, so Keychain isn't
//  needed for it).
//
//   - FolderAccess: your WoW `_retail_/Interface/AddOns` folder.
//   - CloudFolderAccess: the folder inside iCloud Drive (or wherever you
//     want) that this app syncs addons through. See its own doc comment
//     below for why this isn't the app-private iCloud container API.
//   - CurseForgeFolderAccess: CurseForge's own local "GameInstances" scan
//     folder under ~/Library — see CurseForgeLocalScanAPI.swift for why
//     this app reads it instead of calling CurseForge's API. Folders
//     under ~/Library can't be requested automatically the way the other
//     two can (macOS treats it as sensitive), so this one's picker is the
//     only way to grant it.
//

import Foundation
import AppKit

@MainActor
final class FolderAccess: ObservableObject {
    private static let bookmarkKey = "wowAddOnsFolderBookmark"

    @Published private(set) var addOnsURL: URL?
    @Published private(set) var isAccessing = false

    init() {
        restoreFromBookmark()
    }

    /// Call before touching files under `addOnsURL`, and `stopAccessing()`
    /// when done. Safe to call redundantly.
    func startAccessingIfNeeded() -> Bool {
        guard let url = addOnsURL else { return false }
        guard !isAccessing else { return true }
        let ok = url.startAccessingSecurityScopedResource()
        isAccessing = ok
        return ok
    }

    func stopAccessing() {
        guard isAccessing, let url = addOnsURL else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessing = false
    }

    /// Presents the folder picker, defaulting to the standard WoW retail
    /// AddOns path if it exists.
    func presentPicker(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select your WoW AddOns Folder"
        panel.message = "Choose Interface/AddOns inside your World of Warcraft _retail_ folder."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        let defaultPath = AddonScanner.defaultAddOnsPath()
        if FileManager.default.fileExists(atPath: defaultPath) {
            panel.directoryURL = URL(fileURLWithPath: defaultPath)
        } else {
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                completion(nil)
                return
            }
            self?.setAddOnsURL(url)
            completion(url)
        }
    }

    func setAddOnsURL(_ url: URL) {
        stopAccessing()
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            addOnsURL = url
        } catch {
            // Keep the URL for this session even if the bookmark couldn't
            // be persisted; it just won't survive a relaunch.
            addOnsURL = url
        }
        _ = startAccessingIfNeeded()
    }

    func clear() {
        stopAccessing()
        addOnsURL = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    }

    private func restoreFromBookmark() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            addOnsURL = url
            _ = startAccessingIfNeeded()
            if isStale {
                // Refresh the stored bookmark so it keeps working.
                setAddOnsURL(url)
            }
        } catch {
            addOnsURL = nil
        }
    }
}

// MARK: - CloudFolderAccess

/// The same grant-once-and-bookmark pattern as `FolderAccess`, but for a
/// folder you pick *inside your regular iCloud Drive* — not an app-private
/// iCloud container.
///
/// The app-private container (`com.apple.developer.icloud-container-identifiers`
/// / the iCloud capability in Signing & Capabilities) requires a paid
/// Apple Developer Program membership; a free "Personal Team" can build an
/// app that claims that entitlement but the OS refuses to launch it
/// (RunningBoard/code-signing failure). Writing into a folder that's
/// simply *located* inside iCloud Drive needs no special entitlement at
/// all — the OS syncs it the same way it syncs anything else you drag
/// into iCloud Drive in Finder — so that's what this app actually uses.
/// `NSOpenPanel` itself always shows "iCloud Drive" in its sidebar
/// regardless of sandboxing or account type, so the user can navigate
/// there (or anywhere else they'd rather sync from — a shared Dropbox
/// folder works exactly the same way) and pick or create a folder.
@MainActor
final class CloudFolderAccess: ObservableObject {
    private static let bookmarkKey = "cloudSyncFolderBookmark"

    @Published private(set) var url: URL?
    @Published private(set) var isAccessing = false

    init() {
        restoreFromBookmark()
    }

    func startAccessingIfNeeded() -> Bool {
        guard let url else { return false }
        guard !isAccessing else { return true }
        let ok = url.startAccessingSecurityScopedResource()
        isAccessing = ok
        return ok
    }

    func stopAccessing() {
        guard isAccessing, let url else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessing = false
    }

    /// Presents the folder picker, defaulting into the user's personal
    /// iCloud Drive if it's reachable, so "iCloud Drive" is what's showing
    /// when the panel opens.
    func presentPicker(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose (or Create) a Sync Folder"
        panel.message = "Pick a folder inside iCloud Drive — WoWAddonSync will keep your addons there and sync it across your Macs. You can also create a new folder from here."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        let iCloudDriveRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: iCloudDriveRoot.path) {
            panel.directoryURL = iCloudDriveRoot
        }

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                completion(nil)
                return
            }
            self?.setURL(url)
            completion(url)
        }
    }

    func setURL(_ url: URL) {
        stopAccessing()
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            self.url = url
        } catch {
            self.url = url
        }
        _ = startAccessingIfNeeded()
    }

    func clear() {
        stopAccessing()
        url = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    }

    private func restoreFromBookmark() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        do {
            let resolved = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            url = resolved
            _ = startAccessingIfNeeded()
            if isStale {
                setURL(resolved)
            }
        } catch {
            url = nil
        }
    }
}

// MARK: - CurseForgeFolderAccess

/// The same grant-once-and-bookmark pattern again, this time for
/// CurseForge's own local scan folder — normally
/// `~/Library/Application Support/CurseForge/agent/GameInstances`. Entirely
/// optional: addons still sync fine without this, they just fall back to
/// iCloud-as-reference like any other unmatched addon. See
/// CurseForgeLocalScanAPI.swift for what this folder is and why the app
/// reads it instead of calling CurseForge's API.
@MainActor
final class CurseForgeFolderAccess: ObservableObject {
    private static let bookmarkKey = "curseForgeGameInstancesFolderBookmark"

    @Published private(set) var url: URL?
    @Published private(set) var isAccessing = false

    init() {
        restoreFromBookmark()
    }

    func startAccessingIfNeeded() -> Bool {
        guard let url else { return false }
        guard !isAccessing else { return true }
        let ok = url.startAccessingSecurityScopedResource()
        isAccessing = ok
        return ok
    }

    func stopAccessing() {
        guard isAccessing, let url else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessing = false
    }

    /// Presents the folder picker, defaulting to CurseForge's standard
    /// GameInstances location if it exists. You can point this at either
    /// that folder itself, or its `CurseForge` parent — the scanner just
    /// needs to end up with a folder that directly contains the
    /// per-instance `.json` files, so pick `GameInstances` if you're
    /// offered a choice.
    func presentPicker(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select CurseForge's GameInstances Folder"
        panel.message = "Optional: lets WoWAddonSync check installed-vs-latest for addons managed by the CurseForge app, by reading its own local scan — no CurseForge account or API key involved. Normally at ~/Library/Application Support/CurseForge/agent/GameInstances."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CurseForge/agent/GameInstances", isDirectory: true)
        if FileManager.default.fileExists(atPath: defaultPath.path) {
            panel.directoryURL = defaultPath
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                completion(nil)
                return
            }
            self?.setURL(url)
            completion(url)
        }
    }

    func setURL(_ url: URL) {
        stopAccessing()
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            self.url = url
        } catch {
            self.url = url
        }
        _ = startAccessingIfNeeded()
    }

    func clear() {
        stopAccessing()
        url = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    }

    private func restoreFromBookmark() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        do {
            let resolved = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            url = resolved
            _ = startAccessingIfNeeded()
            if isStale {
                setURL(resolved)
            }
        } catch {
            url = nil
        }
    }
}

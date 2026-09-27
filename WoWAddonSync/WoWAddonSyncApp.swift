//
//  WoWAddonSyncApp.swift
//  WoWAddonSync
//

import SwiftUI

@main
struct WoWAddonSyncApp: App {
    @StateObject private var folderAccess: FolderAccess
    @StateObject private var cloudFolderAccess: CloudFolderAccess
    @StateObject private var curseForgeFolderAccess: CurseForgeFolderAccess
    @StateObject private var settings: AppSettings
    @StateObject private var coordinator: SyncCoordinator

    init() {
        // SwiftUI doesn't let one @StateObject's init read another's
        // wrapped value directly, so build them together here.
        let folderAccess = FolderAccess()
        let cloudFolderAccess = CloudFolderAccess()
        let curseForgeFolderAccess = CurseForgeFolderAccess()
        let settings = AppSettings()
        _folderAccess = StateObject(wrappedValue: folderAccess)
        _cloudFolderAccess = StateObject(wrappedValue: cloudFolderAccess)
        _curseForgeFolderAccess = StateObject(wrappedValue: curseForgeFolderAccess)
        _settings = StateObject(wrappedValue: settings)
        _coordinator = StateObject(wrappedValue: SyncCoordinator(folderAccess: folderAccess, cloudFolderAccess: cloudFolderAccess, curseForgeFolderAccess: curseForgeFolderAccess, settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(folderAccess)
                .environmentObject(cloudFolderAccess)
                .environmentObject(curseForgeFolderAccess)
                .environmentObject(settings)
                .environmentObject(coordinator)
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Sync Now") {
                    Task { await coordinator.syncNow() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(folderAccess)
                .environmentObject(cloudFolderAccess)
                .environmentObject(curseForgeFolderAccess)
                .environmentObject(settings)
                .environmentObject(coordinator)
                .frame(width: 520, height: 480)
        }
    }
}

//
//  SettingsView.swift
//  WoWAddonSync
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var folderAccess: FolderAccess
    @EnvironmentObject private var cloudFolderAccess: CloudFolderAccess
    @EnvironmentObject private var curseForgeFolderAccess: CurseForgeFolderAccess
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var coordinator: SyncCoordinator

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("WoW Installation") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AddOns Folder")
                            Text(folderAccess.addOnsURL?.path ?? "Not set")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Change…") {
                            folderAccess.presentPicker { _ in
                                Task { await coordinator.refreshStatusOnly() }
                            }
                        }
                    }
                }

                Section("Sync Folder") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This app writes your synced addons here rather than into a private iCloud container, so it works with any Apple ID — no paid developer account needed. Pick a folder inside iCloud Drive (or Dropbox, or anywhere else you sync between Macs) and use the *same* folder on every Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Folder")
                                Text(cloudFolderAccess.url?.path ?? "Not set")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button("Change…") {
                                cloudFolderAccess.presentPicker { _ in
                                    Task { await coordinator.refreshStatusOnly() }
                                }
                            }
                        }
                    }
                }

                Section("Version Sources") {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("WowInterface").font(.caption.bold())
                            Text("Used automatically for any addon whose .toc file names a WowInterface ID (\"## X-WoWI-ID\") — a de facto standard most addons published there already carry, written by their own build tooling.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("GitHub Releases").font(.caption.bold())
                            Text("Used automatically when an addon isn't matched to WowInterface but its .toc \"X-Website\" field points at a github.com repo that publishes .zip releases — or when it's on the app's small built-in list of addons confirmed by hand to do that despite not saying so (WeakAuras, Bartender4, Grid2, both Deadly Boss Mods projects, as of this build).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("None of these need an API key or account. If an addon matches none of them, its detail view lets you set a WowInterface ID or GitHub repo by hand; select it in the sidebar to find that option.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("CurseForge (local scan)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Optional. Used automatically, for addons matched to neither source above, by reading the CurseForge desktop app's own local record of your installed addons — not CurseForge's API, which requires a gated developer application this app deliberately avoids. If you use the CurseForge app to manage addons, this covers those.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("GameInstances Folder")
                                Text(curseForgeFolderAccess.url?.path ?? "Not connected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button(curseForgeFolderAccess.url == nil ? "Connect…" : "Change…") {
                                curseForgeFolderAccess.presentPicker { _ in
                                    Task { await coordinator.refreshStatusOnly() }
                                }
                            }
                        }

                        Text("Normally at ~/Library/Application Support/CurseForge/agent/GameInstances. This is CurseForge's own internal app format, not a published API, so treat it as best-effort — worth a look if it ever seems to stop matching addons that should match.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("CurseForge (page scrape — last resort)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Optional, and the least reliable source in the app. Used automatically, only for addons matched to none of the three sources above, by reading the addon's public curseforge.com page directly — no API, no CurseForge app needed. This exists for CurseForge-only addons when you don't run the CurseForge desktop app, since there's otherwise no way to check their version at all.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("This works by matching text patterns in that page's HTML, which CurseForge can change at any time without notice — when that happens, it just stops matching (no wrong data, just no data) until this app is updated for the new layout. An addon picks up a CurseForge slug either automatically, when its .toc already links to its CurseForge page, or by entering one by hand in that addon's detail view.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Sync") {
                    Toggle("Sync automatically when the app opens", isOn: $settings.autoSyncOnLaunch)
                    TextField("This Mac's name (shown in the shared activity)", text: $settings.deviceLabel)
                }

                Section("About") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How this app decides what's current")
                            .font(.subheadline.bold())
                        Text("""
                        1. If an addon's .toc names a WowInterface ID (or one was set manually), that's the source of truth.
                        2. Otherwise, if it's matched to a GitHub repo with .zip releases, that's the source of truth instead.
                        3. Otherwise, if CurseForge's local scan (optional, see above) knows this addon, that's the source of truth instead.
                        4. Otherwise, if it's matched to a CurseForge page (optional, last resort, see above), that's the source of truth instead.
                        5. iCloud is updated first if it doesn't already have that version.
                        6. This Mac is then updated from iCloud if it's behind.

                        Addons matched to none of those four are kept in sync using iCloud itself as the shared reference point instead — every Mac just matches whatever iCloud has, with no independent "is this actually current" check.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    let folderAccess = FolderAccess()
    let cloudFolderAccess = CloudFolderAccess()
    let curseForgeFolderAccess = CurseForgeFolderAccess()
    let settings = AppSettings()
    return SettingsView()
        .environmentObject(folderAccess)
        .environmentObject(cloudFolderAccess)
        .environmentObject(curseForgeFolderAccess)
        .environmentObject(settings)
        .environmentObject(SyncCoordinator(folderAccess: folderAccess, cloudFolderAccess: cloudFolderAccess, curseForgeFolderAccess: curseForgeFolderAccess, settings: settings))
        .frame(width: 520, height: 480)
}

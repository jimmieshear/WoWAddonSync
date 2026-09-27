//
//  SupportingViews.swift
//  WoWAddonSync
//

import SwiftUI

// MARK: - Status badge

struct StatusBadge: View {
    let status: AddonGroup.StatusKind

    var body: some View {
        Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel(accessibilityText)
    }

    private var text: String {
        switch status {
        case .upToDate: return "Up to Date"
        case .updateAvailable: return "Update Available"
        case .unverified: return "Unverified"
        case .synced: return "Synced"
        case .localBehindCloud: return "Needs Local Update"
        case .missingFolders: return "Missing Folders"
        case .notInCloud: return "Not in iCloud"
        case .inCloudOnly: return "In iCloud Only"
        case .syncing: return "Syncing…"
        case .error: return "Error"
        case .unknown: return "Unknown"
        }
    }

    /// The badges are terse enough that two of them side by side could be
    /// read as one claim; VoiceOver gets the longer form that says which
    /// axis each one is talking about.
    private var accessibilityText: String {
        switch status {
        case .upToDate: return "Up to date with its version source"
        case .updateAvailable: return "A newer release is available from its version source"
        case .unverified: return "No version source — not checked against a real release"
        case .synced: return "This Mac matches iCloud"
        case .localBehindCloud: return "This Mac needs an update from iCloud"
        case .missingFolders: return "Some of this addon's folders are in iCloud but missing from this Mac"
        case .notInCloud: return "Not in iCloud yet"
        case .inCloudOnly: return "In iCloud, not installed on this Mac"
        case .syncing: return "Syncing"
        case .error: return "Error"
        case .unknown: return "Unknown"
        }
    }

    private var icon: String {
        switch status {
        case .upToDate: return "checkmark.circle.fill"
        case .updateAvailable: return "arrow.up.circle.fill"
        case .unverified: return "minus.circle"
        case .synced: return "checkmark.icloud"
        case .localBehindCloud: return "icloud.and.arrow.down"
        case .missingFolders: return "exclamationmark.triangle"
        case .notInCloud: return "icloud.slash"
        // Not one of the arrow icons: the other iCloud states are all
        // "the app is moving this somewhere", and this one is waiting on
        // you to say which direction it should go.
        case .inCloudOnly: return "exclamationmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch status {
        // Green for the version axis' good state, teal for the sync axis'
        // — different enough to tell apart at a glance when both are
        // showing, which is the normal case for a healthy addon.
        case .upToDate: return .green
        case .synced: return .teal
        // Grey, not orange: nothing is wrong with an addon that has no
        // version source, there's just nothing to report about it.
        case .unverified: return .secondary
        case .updateAvailable, .localBehindCloud, .missingFolders: return .orange
        case .notInCloud: return .blue
        // Deliberately not orange: orange here means "mid-sync, it'll
        // sort itself out". This one won't, until you pick.
        case .inCloudOnly: return .purple
        case .syncing: return .accentColor
        case .error: return .red
        case .unknown: return .secondary
        }
    }
}

// MARK: - Activity log

struct ActivityLogView: View {
    @EnvironmentObject private var coordinator: SyncCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity")
                .font(.headline)
                .padding(12)
            Divider()
            if coordinator.log.isEmpty {
                Text("Nothing yet — run a sync to see activity here.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding()
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(coordinator.log.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: coordinator.log.count) { newCount in
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Empty state (macOS 13-compatible stand-in for ContentUnavailableView)

struct ContentUnavailableCompat: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

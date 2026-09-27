//
//  AddonRowView.swift
//  WoWAddonSync
//

import SwiftUI

struct AddonRowView: View {
    let group: AddonGroup

    /// Only ever called for an `AddonGroup.isCloudOnly` row, which is the
    /// only kind that shows inline actions — every other state either
    /// resolves itself during a sync or is handled in the detail view.
    var onInstall: () -> Void = {}
    var onRemove: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.displayName)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let version = group.bestVersionDisplay, !version.isEmpty {
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let releasedAt = group.bestVersionDate {
                        Text(releasedAt.formatted(date: .numeric, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if group.effectiveFolderNames.count > 1 {
                        Text("\(group.effectiveFolderNames.count) folders")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if group.isCloudOnly {
                    Text("In iCloud, not installed on this Mac")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                        .lineLimit(1)

                    HStack(spacing: 10) {
                        Button("Install", action: onInstall)
                        // Trailing ellipsis because this one confirms
                        // first — it removes the addon from every Mac,
                        // not just this one.
                        Button("Remove…", role: .destructive, action: onRemove)
                    }
                    // .borderless so the buttons stay clickable inside a
                    // List row without swallowing the row's selection.
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.caption)
                    .padding(.top, 1)
                }
            }
            Spacer()
            // Stacked rather than side by side: two badges laid out
            // horizontally leave almost nothing for the addon's name in a
            // sidebar this narrow, and vertically they line up with the
            // two lines of text on the left.
            VStack(alignment: .trailing, spacing: 3) {
                ForEach(group.statusBadges, id: \.self) { badge in
                    StatusBadge(status: badge)
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, group.isCloudOnly ? 8 : 0)
        .background {
            if group.isCloudOnly {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.purple.opacity(0.12))
            }
        }
    }
}

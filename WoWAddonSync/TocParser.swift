//
//  TocParser.swift
//  WoWAddonSync
//
//  Minimal parser for WoW `.toc` files. Format reference:
//  https://warcraft.wiki.gg/wiki/TOC_format
//
//  A .toc file is a plain text list of files (loaded by the game client)
//  interleaved with `## Key: Value` metadata comment lines. We only care
//  about the metadata lines.
//

import Foundation

enum TocParser {

    /// Flavor suffixes WoW itself recognizes on TOC keys, e.g.
    /// `## Title-Classic:` alongside a plain `## Title:`. Only these exact
    /// suffixes get stripped when normalizing a key — see `normalizedKey`.
    private static let knownFlavorSuffixes: Set<String> = [
        "mainline", "classic", "vanilla", "tbc", "bcc", "wrath", "wotlkc", "cata", "mists"
    ]

    /// Normalizes a TOC key so flavor-suffixed variants (`Title-Classic`)
    /// fall back onto the same slot as the bare key (`Title`) when no
    /// bare version is present. Deliberately leaves custom `X-`-prefixed
    /// fields alone: things like `X-WoWI-ID` and `X-Curse-Project-ID`
    /// contain hyphens that aren't flavor suffixes at all, and naively
    /// splitting on the first "-" (an earlier bug here) would have
    /// collapsed every `X-...` field into a single "X" slot and silently
    /// dropped all but the first one.
    private static func normalizedKey(for key: String) -> String {
        guard !key.hasPrefix("X-") else { return key }
        guard let dashIndex = key.lastIndex(of: "-") else { return key }
        let suffix = key[key.index(after: dashIndex)...].lowercased()
        guard knownFlavorSuffixes.contains(suffix) else { return key }
        return String(key[key.startIndex..<dashIndex])
    }

    /// Parses a `.toc` file's contents into `TocMetadata`. Handles the
    /// `## Key: Value` header lines; ignores everything else (file list,
    /// blank lines, `#` non-metadata comments).
    static func parse(contents: String) -> TocMetadata {
        var values: [String: String] = [:]

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("##") else { continue }

            // Strip the leading "##" and any following whitespace.
            var rest = line.dropFirst(2)
            while rest.first == " " || rest.first == "\t" {
                rest = rest.dropFirst()
            }

            guard let colonIndex = rest.firstIndex(of: ":") else { continue }
            let key = rest[rest.startIndex..<colonIndex]
                .trimmingCharacters(in: .whitespaces)
            let value = String(rest[rest.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)

            let normalizedKey = Self.normalizedKey(for: key)

            if value.isEmpty { continue }
            if values[normalizedKey] == nil || key == normalizedKey {
                values[normalizedKey] = value
            }
        }

        let rawTitle = values["Title"]
        var meta = TocMetadata()
        meta.rawTitle = rawTitle
        meta.title = rawTitle.map(TocMetadata.stripColorCodes)
        meta.version = values["Version"]
        meta.interface = values["Interface"]
        meta.author = values["Author"]
        meta.notes = values["Notes"].map(TocMetadata.stripColorCodes)

        // Source-site IDs, when the addon's packaging tooling wrote them.
        // See the doc comment on TocMetadata for why these matter.
        meta.wowInterfaceId = values["X-WoWI-ID"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        meta.wagoId = values["X-Wago-ID"]
        meta.website = values["X-Website"]

        return meta
    }

    static func parse(fileAt url: URL) -> TocMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // TOC files are usually UTF-8, occasionally Windows-1252 from older
        // addons; fall back if strict UTF-8 decoding fails.
        let contents = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? ""
        return parse(contents: contents)
    }

    /// Finds the "primary" .toc file inside a folder: prefers one whose
    /// name (minus extension) matches the folder name exactly, then falls
    /// back to a flavor-suffixed variant (`-Mainline`, `-Classic`, etc.),
    /// then to any .toc file present.
    static func primaryTocURL(inFolder folderURL: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let tocFiles = entries.filter { $0.pathExtension.lowercased() == "toc" }
        guard !tocFiles.isEmpty else { return nil }

        let folderName = folderURL.lastPathComponent

        if let exact = tocFiles.first(where: { $0.deletingPathExtension().lastPathComponent == folderName }) {
            return exact
        }
        if let mainline = tocFiles.first(where: {
            $0.deletingPathExtension().lastPathComponent == "\(folderName)-Mainline"
        }) {
            return mainline
        }
        return tocFiles.first
    }
}

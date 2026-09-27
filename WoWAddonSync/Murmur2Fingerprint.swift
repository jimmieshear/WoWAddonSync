//
//  Murmur2Fingerprint.swift
//  WoWAddonSync
//
//  A per-file and per-folder content fingerprint, used to notice when this
//  Mac's local copy of an addon differs from what's recorded in the
//  iCloud manifest (see `evaluateLocalAgainstCloud` in
//  SyncCoordinator.swift) — cheaper than re-comparing file contents byte
//  for byte on every sync.
//
//  This happens to be the same algorithm CurseForge's API uses for its own
//  fingerprint matching (classic 32-bit MurmurHash2 by Austin Appleby,
//  over whitespace-stripped bytes, seed 1) — verified against their own Go
//  client (github.com/packwiz/packwiz/curseforge/murmur2) — but the app
//  itself no longer talks to CurseForge; this is purely a local/iCloud
//  change-detection tool now:
//
//    1. Strip whitespace bytes (tab 9, LF 10, CR 13, space 32) from the
//       file's raw bytes.
//    2. Run MurmurHash2 (32-bit, little-endian reads) with seed = 1 over
//       what's left.
//
//  `folderFingerprint` combines a folder's many per-file fingerprints
//  (concatenate each file's fingerprint bytes, sorted by relative path,
//  and hash the result) into one number for the whole folder.
//

import Foundation

enum Murmur2Fingerprint {

    /// Classic 32-bit MurmurHash2 by Austin Appleby.
    static func murmurHash2(_ data: [UInt8], seed: UInt32) -> UInt32 {
        let m: UInt32 = 0x5bd1e995
        let r: UInt32 = 24

        var h: UInt32 = seed ^ UInt32(truncatingIfNeeded: data.count)

        var length = data.count
        var offset = 0

        while length >= 4 {
            var k = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)

            k = k &* m
            k ^= k >> r
            k = k &* m

            h = h &* m
            h ^= k

            offset += 4
            length -= 4
        }

        switch length {
        case 3:
            h ^= UInt32(data[offset + 2]) << 16
            fallthrough
        case 2:
            h ^= UInt32(data[offset + 1]) << 8
            fallthrough
        case 1:
            h ^= UInt32(data[offset])
            h = h &* m
        default:
            break
        }

        h ^= h >> 13
        h = h &* m
        h ^= h >> 15

        return h
    }

    private static func isWhitespaceByte(_ b: UInt8) -> Bool {
        b == 9 || b == 10 || b == 13 || b == 32
    }

    /// Per-file fingerprint: whitespace-stripped bytes, murmur2 with seed 1.
    static func fileFingerprint(data: Data) -> UInt32 {
        var filtered = [UInt8]()
        filtered.reserveCapacity(data.count)
        for byte in data where !isWhitespaceByte(byte) {
            filtered.append(byte)
        }
        return murmurHash2(filtered, seed: 1)
    }

    static func fileFingerprint(contentsOf url: URL) -> UInt32? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return fileFingerprint(data: data)
    }

    /// Folder-level fingerprint. `fileFingerprints` should be
    /// relative-path -> per-file fingerprint, as produced by AddonScanner.
    static func folderFingerprint(fileFingerprints: [String: UInt32]) -> UInt32 {
        var bytes = [UInt8]()
        for path in fileFingerprints.keys.sorted() {
            var value = fileFingerprints[path]!.littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        return murmurHash2(bytes, seed: 1)
    }
}

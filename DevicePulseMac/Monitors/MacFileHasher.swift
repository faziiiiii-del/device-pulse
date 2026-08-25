//
//  MacFileHasher.swift
//  DevicePulseMac
//
//  Small, standalone SHA-256 utility — deliberately not shared with the
//  Security module's own hasher (SecuritySHA256), matching this app's
//  practice of keeping feature areas independent rather than reaching
//  across modules for a few lines of code (see the Security module's
//  own notes on this). Used by the Duplicate Finder to confirm two
//  same-size files are actually byte-identical, not just same-sized.
//

import Foundation
import CryptoKit

enum MacFileHasher {
    /// Streams the file in 1 MB chunks rather than loading it whole.
    /// Gives up past `maxBytes` (default 2 GB — duplicates of files
    /// that large are rare and hashing one would dominate scan time)
    /// rather than stalling on one huge file.
    static func sha256(ofFileAt path: String, maxBytes: Int64 = 2_000_000_000) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        var totalRead: Int64 = 0
        while true {
            guard let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            totalRead += Int64(chunk.count)
            if totalRead > maxBytes { return nil }
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }
}

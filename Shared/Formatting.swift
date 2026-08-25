//
//  Formatting.swift
//  Shared (macOS target only for now)
//

import Foundation

enum ByteFormat {
    /// Decimal (1000-based) formatting, matching Finder/disk-capacity
    /// convention — use for storage/volume/file sizes.
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func string(_ bytes: UInt64) -> String {
        string(Int64(bytes))
    }

    /// Binary (1024-based) formatting for RAM — the number stamped on
    /// the box ("16 GB") is actually 16 GiB (17,179,869,184 bytes).
    /// Formatting that with `.file`'s decimal divisor renders it as
    /// "17.18 GB", which reads as a bug even though the raw byte count
    /// (from `hw.memsize`) is correct — it's just labeled with the
    /// wrong convention. `.memory` style divides by 1024 instead,
    /// matching Activity Monitor and About This Mac, so a real 16 GB
    /// Mac reads as "16 GB" here, not "17.18 GB".
    static func memoryString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    static func memoryString(_ bytes: UInt64) -> String {
        memoryString(Int64(bytes))
    }
}

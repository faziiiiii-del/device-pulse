//
//  Formatting.swift
//  DevicePulse
//

import Foundation

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func string(_ bytes: UInt64) -> String {
        string(Int64(bytes))
    }
}

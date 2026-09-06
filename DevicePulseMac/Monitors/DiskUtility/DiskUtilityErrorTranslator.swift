//
//  DiskUtilityErrorTranslator.swift
//  DevicePulseMac
//
//  Translates raw diskutil output into a plain-language explanation.
//  The real diskutil text is never discarded — the caller still has it
//  available as "Show Diagnostic Output" — this only supplies a better
//  headline than "diskutil failed".
//

import Foundation

enum DiskUtilityErrorTranslator {
    static func translate(_ rawOutput: String) -> String {
        let lower = rawOutput.lowercased()

        if lower.contains("cannot erase the boot disk") || lower.contains("cannot erase the boot volume") {
            return "macOS refused this operation because it targets the current startup disk or volume."
        }
        if lower.contains("resource busy") || lower.contains("in use") || lower.contains("couldn't unmount") {
            return "The disk is currently being used by another application or system process. Close files and applications using this disk and try again."
        }
        if lower.contains("not permitted") || lower.contains("permission denied") || lower.contains("must be root") || lower.contains("ownership") {
            return "macOS did not allow this operation. Additional authorization may be required."
        }
        if lower.contains("no such file or directory") || lower.contains("could not find disk") || lower.contains("invalid disk") {
            return "The selected disk is no longer connected."
        }
        if lower.isEmpty {
            return "The operation failed with no further detail from diskutil."
        }
        // Fall back to diskutil's own first line rather than a generic message — still
        // more useful than "diskutil failed", and the full text remains available below.
        return rawOutput.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? rawOutput
    }
}

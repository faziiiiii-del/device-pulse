//
//  DiskIdentityValidator.swift
//  DevicePulseMac
//
//  A BSD identifier like "disk4" is not a stable name for a physical
//  disk — if the original disk is disconnected and something else is
//  connected before an action actually runs, the OS can and does hand
//  that same identifier to the new device. This validator re-enumerates
//  disks fresh (never trusts a cached DiskInfo) and compares every field
//  it can against what the user actually selected, immediately before
//  any destructive diskutil call — never relying on "diskutil will
//  refuse the wrong thing" as the safety mechanism, since diskutil has
//  no way to know what the user *intended* to select in this app.
//

import Foundation

/// A snapshot of everything used to confirm a disk is still the one the user selected.
struct DiskFingerprint: Equatable {
    let deviceIdentifier: String
    let mediaName: String
    let totalSizeBytes: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let mediaUUID: String?
}

enum DiskIdentityValidationResult: Equatable {
    case verified
    case mismatch(reason: String)
    case disappeared
}

/// A snapshot of everything used to confirm a specific volume is still the one the user
/// selected. Deliberately separate from `DiskFingerprint`: a destructive action scoped to
/// one volume (e.g. eraseVolume) must not be gated on the *disk's* boot status, since a
/// non-boot volume can legitimately share a disk with the boot volume (e.g. a second data
/// partition on the internal SSD) — reusing the disk-level check there would over-block a
/// safe operation, not just under-block an unsafe one.
struct DiskVolumeFingerprint: Equatable {
    let deviceIdentifier: String
    let name: String
    let filesystemName: String?
    let isBootVolume: Bool
}

enum DiskIdentityValidator {
    /// Re-enumerates every disk fresh and confirms the specific volume is still present,
    /// still not the boot volume, and its name/filesystem still match what was selected.
    static func revalidateVolume(_ expected: DiskVolumeFingerprint) async -> DiskIdentityValidationResult {
        let freshDisks = await Task.detached { DiskDiscoveryService.listDisks() }.value
        guard let current = freshDisks.flatMap(\.allVolumes).first(where: { $0.deviceIdentifier == expected.deviceIdentifier }) else {
            return .disappeared
        }
        if current.isBootVolume {
            return .mismatch(reason: "This volume is now the current startup volume.")
        }
        if current.name != expected.name {
            return .mismatch(reason: "Volume name changed (expected \u{201C}\(expected.name)\u{201D}, found \u{201C}\(current.name)\u{201D}).")
        }
        if current.filesystemName != expected.filesystemName {
            return .mismatch(reason: "This volume's file system changed unexpectedly.")
        }
        return .verified
    }

    /// Re-enumerates disks fresh and compares every field of `expected` against what's
    /// actually attached right now. Returns `.verified` only if every field still matches
    /// exactly (UUID comparison only applied when both sides actually have one — many
    /// internal/Apple Fabric disks don't report a DiskUUID at all, which must never be
    /// misread as "no UUID means it's fine").
    static func revalidate(_ expected: DiskFingerprint) async -> DiskIdentityValidationResult {
        // Off the calling actor deliberately — this shells out to diskutil several times,
        // and must never block the UI (or, when called from DiskOperationService, the
        // MainActor the operation console is observed on) while it runs.
        let freshDisks = await Task.detached { DiskDiscoveryService.listDisks() }.value
        guard let current = freshDisks.first(where: { $0.deviceIdentifier == expected.deviceIdentifier }) else {
            return .disappeared
        }
        let currentFingerprint = current.fingerprint

        if currentFingerprint.mediaName != expected.mediaName {
            return .mismatch(reason: "Media name changed (expected \u{201C}\(expected.mediaName)\u{201D}, found \u{201C}\(currentFingerprint.mediaName)\u{201D}).")
        }
        if currentFingerprint.totalSizeBytes != expected.totalSizeBytes {
            return .mismatch(reason: "Capacity changed (expected \(ByteFormat.string(expected.totalSizeBytes)), found \(ByteFormat.string(currentFingerprint.totalSizeBytes))).")
        }
        if currentFingerprint.isInternal != expected.isInternal || currentFingerprint.isRemovable != expected.isRemovable {
            return .mismatch(reason: "This disk's internal/removable status changed since it was selected.")
        }
        if let expectedUUID = expected.mediaUUID, let currentUUID = currentFingerprint.mediaUUID, expectedUUID != currentUUID {
            return .mismatch(reason: "This disk's identity (UUID) does not match — it is a different physical disk than the one selected.")
        }
        return .verified
    }
}

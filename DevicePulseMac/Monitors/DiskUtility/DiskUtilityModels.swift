//
//  DiskUtilityModels.swift
//  DevicePulseMac
//
//  Data model for Disk Utility. Reflects the real macOS storage hierarchy
//  (confirmed by direct inspection against this project's own dev
//  machines, not assumed from documentation alone):
//
//      Physical Disk (e.g. "disk0")
//      ├── GPT partition (e.g. "disk0s1") — may be EFI, Recovery, or a
//      │   plain formatted volume (ExFAT/FAT32/HFS+) that IS the volume
//      └── GPT partition that is an APFS *container* (e.g. "disk0s2") —
//          hosts one or more independently-named APFS *volumes*
//          (e.g. "Macintosh HD", "Macintosh HD - Data"), each with its
//          own role (System/Data/Preboot/Recovery/VM/Unknown)
//
//  Every field that macOS doesn't expose is `nil`/`.unknown`, never
//  guessed — matching this app's existing rule everywhere else.
//

import Foundation

/// APFS volume role, read directly from `diskutil apfs list`'s `Roles` array
/// (e.g. ["System"], ["Data"]) — never inferred from a volume's name.
enum DiskVolumeRole: String {
    case system = "System"
    case data = "Data"
    case preboot = "Preboot"
    case recovery = "Recovery"
    case vm = "VM"
    case unknown = "Unknown"

    static func from(rawRoles: [String]) -> DiskVolumeRole {
        guard let first = rawRoles.first else { return .unknown }
        return DiskVolumeRole(rawValue: first) ?? .unknown
    }

    var label: String { rawValue }
}

enum DiskEncryptionState {
    case encrypted
    case notEncrypted
    case locked
    case unavailable

    var label: String {
        switch self {
        case .encrypted: return "Encrypted"
        case .notEncrypted: return "Not Encrypted"
        case .locked: return "Encrypted (Locked)"
        case .unavailable: return "Unknown"
        }
    }
}

struct DiskVolumeInfo: Identifiable {
    var id: String { deviceIdentifier }
    let deviceIdentifier: String
    let name: String
    /// Real capacity in use, where available (APFS: CapacityInUse; plain volumes: Size
    /// minus FreeSpace where both are known). `nil` means genuinely unknown, never 0.
    let sizeBytes: Int64?
    let freeBytes: Int64?
    let filesystemName: String?
    let mountPoint: String?
    let volumeUUID: String?
    let role: DiskVolumeRole
    let encryption: DiskEncryptionState
    let isBootVolume: Bool

    /// A snapshot used to re-verify this exact volume is still the one the user selected,
    /// immediately before a destructive action — see DiskIdentityValidator.revalidateVolume.
    var fingerprint: DiskVolumeFingerprint {
        DiskVolumeFingerprint(deviceIdentifier: deviceIdentifier, name: name, filesystemName: filesystemName, isBootVolume: isBootVolume)
    }
}

struct DiskPartitionInfo: Identifiable {
    var id: String { deviceIdentifier }
    let deviceIdentifier: String
    /// Raw `diskutil` partition type, e.g. "Apple_APFS", "EFI", "Windows_FAT_32", "Apple_HFS".
    let content: String
    let sizeBytes: Int64
    /// Populated when this partition is an APFS container hosting named volumes.
    let apfsVolumes: [DiskVolumeInfo]
    /// Populated only when `apfsVolumes` is empty — this partition IS the one volume.
    let plainVolume: DiskVolumeInfo?
    let containerUUID: String?

    var isFreeSpace: Bool { content == "Apple_Free" || content.isEmpty }
    var isEFI: Bool { content.uppercased().contains("EFI") }
    var kind: String {
        if isEFI { return "EFI" }
        if isFreeSpace { return "Free Space" }
        if !apfsVolumes.isEmpty { return "APFS Container" }
        return content
    }
}

struct DiskInfo: Identifiable {
    var id: String { deviceIdentifier }
    let deviceIdentifier: String
    let mediaName: String
    let totalSizeBytes: Int64
    let partitionScheme: String?
    let isInternal: Bool
    let isRemovable: Bool
    let isSolidState: Bool?
    /// e.g. "USB", "Thunderbolt", "SATA", "Apple Fabric" — read directly from
    /// `diskutil info`'s BusProtocol, never inferred.
    let busProtocol: String?
    let partitions: [DiskPartitionInfo]
    /// True when this disk hosts the currently-running boot volume. Used to hard-block
    /// destructive actions in-app (see DiskOperationService) — not merely informational.
    let containsBootVolume: Bool
    let mediaUUID: String?
    let smart: DiskSMARTStatus?

    var allVolumes: [DiskVolumeInfo] {
        partitions.flatMap { $0.apfsVolumes.isEmpty ? ($0.plainVolume.map { [$0] } ?? []) : $0.apfsVolumes }
    }

    /// A snapshot of everything used to re-verify this exact disk is still the one the
    /// user selected, immediately before a destructive action — see DiskIdentityValidator.
    var fingerprint: DiskFingerprint {
        DiskFingerprint(
            deviceIdentifier: deviceIdentifier, mediaName: mediaName, totalSizeBytes: totalSizeBytes,
            isInternal: isInternal, isRemovable: isRemovable, mediaUUID: mediaUUID
        )
    }
}

/// Formats offered for erase/partition actions. `diskutilName` is the exact personality
/// name `diskutil` expects (confirmed against `diskutil listFilesystems` on this
/// project's own dev machine, not assumed from documentation alone).
enum MacDiskFormat: String, CaseIterable, Identifiable {
    case apfs, apfsEncrypted, macOSExtendedJournaled, exFAT, msDosFAT32

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apfs: return "APFS"
        case .apfsEncrypted: return "APFS (Encrypted)"
        case .macOSExtendedJournaled: return "Mac OS Extended (Journaled)"
        case .exFAT: return "ExFAT"
        case .msDosFAT32: return "MS-DOS (FAT32)"
        }
    }

    var explanation: String {
        switch self {
        case .apfs: return "Recommended for Mac-only SSD storage."
        case .apfsEncrypted: return "Mac-only storage with built-in encryption. You'll set a passphrase before this runs."
        case .macOSExtendedJournaled: return "Older Mac-only format, mainly for compatibility with pre-APFS systems."
        case .exFAT: return "Compatible with modern macOS and Windows."
        case .msDosFAT32: return "Broadest compatibility, including older devices — 4GB max file size."
        }
    }

    /// `diskutil`'s own personality name for `eraseDisk`/`eraseVolume`/`partitionDisk`.
    /// There is no single-step "encrypted APFS" format string — `diskutil listFilesystems`
    /// confirms only plain "APFS" is a formattable personality. `.apfsEncrypted` erases as
    /// plain APFS and then runs `diskutil apfs encryptVolume` as a second step (see
    /// DiskOperationService.eraseWithFormat), piping the passphrase via `-stdinpassphrase`
    /// — never as a command-line argument, which would be visible to any process via
    /// `ps aux`, and never stored by this app.
    var diskutilName: String {
        switch self {
        case .apfs, .apfsEncrypted: return "APFS"
        case .macOSExtendedJournaled: return "JHFS+"
        case .exFAT: return "ExFAT"
        case .msDosFAT32: return "MS-DOS FAT32"
        }
    }

    var needsPassphrase: Bool { self == .apfsEncrypted }
}

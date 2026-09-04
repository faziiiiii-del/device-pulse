//
//  MacDiskHealthMonitor.swift
//  DevicePulseMac
//
//  Real S.M.A.R.T. status per physical disk via `diskutil info -plist`,
//  Apple's own documented CLI for exactly this — there is no public
//  framework API for SMART. Verified/Failing/Not Supported are read
//  directly from the drive controller, never inferred.
//

import Foundation

enum DiskSMARTStatus: String {
    case verified = "Verified"
    case failing = "Failing"
    case notSupported = "Not Supported"
    case unknown = "Unknown"

    var label: String {
        switch self {
        case .verified: return "Verified — no problems reported"
        case .failing: return "Failing — back up this drive immediately"
        case .notSupported: return "This drive doesn't report SMART status"
        case .unknown: return "Unknown"
        }
    }

    var level: StatusLevel {
        switch self {
        case .verified: return .good
        case .failing: return .bad
        case .notSupported, .unknown: return .neutral
        }
    }
}

struct DiskHealthInfo: Identifiable {
    var id: String { deviceIdentifier }
    let deviceIdentifier: String
    let mediaName: String
    let isInternal: Bool
    let totalSizeBytes: Int64?
    let smart: DiskSMARTStatus
}

enum MacDiskHealthMonitor {
    static func scan() -> [DiskHealthInfo] {
        guard let wholeDisks = wholeDiskIdentifiers() else { return [] }
        return wholeDisks.compactMap { diskInfo(for: $0) }
    }

    private static func wholeDiskIdentifiers() -> [String]? {
        guard let data = run(["/usr/sbin/diskutil", "list", "-plist"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let disks = plist["WholeDisks"] as? [String]
        else { return nil }
        return disks
    }

    /// Skips disks reported as "Virtual". On Apple Silicon especially, one physical SSD
    /// is fronted by many synthesized APFS container/volume disk devices (System, Data,
    /// Preboot, Recovery, VM, local snapshots...), each of which reports the identical
    /// SMART status as the one real physical disk underneath — showing all of them would
    /// mean a dozen+ duplicate "Verified" rows for a single drive. Physical external
    /// drives, and the internal disk's own raw whole-disk entry (which reports
    /// "Unknown" rather than "Physical" on Apple Silicon — a real, observed quirk, not a
    /// guess), both pass through as the one real result per drive.
    private static func diskInfo(for identifier: String) -> DiskHealthInfo? {
        guard let data = run(["/usr/sbin/diskutil", "info", "-plist", identifier]),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }

        if (plist["VirtualOrPhysical"] as? String) == "Virtual" { return nil }
        guard let smartRaw = plist["SMARTStatus"] as? String else { return nil }

        let mediaName = plist["MediaName"] as? String ?? identifier
        let isInternal = plist["Internal"] as? Bool ?? true
        let totalSize = (plist["TotalSize"] as? NSNumber)?.int64Value

        return DiskHealthInfo(
            deviceIdentifier: identifier, mediaName: mediaName, isInternal: isInternal,
            totalSizeBytes: totalSize, smart: DiskSMARTStatus(rawValue: smartRaw) ?? .unknown
        )
    }

    private static func run(_ args: [String]) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: args[0])
        task.arguments = Array(args.dropFirst())
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return task.terminationStatus == 0 ? data : nil
    }
}

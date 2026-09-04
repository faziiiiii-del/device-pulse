//
//  MacTimeMachineMonitor.swift
//  DevicePulseMac
//
//  Real Time Machine backup status via `tmutil` — Apple's own documented
//  CLI for this, no public framework API exists. Every field here comes
//  from an actual tmutil query; if a destination is configured but
//  unreachable (network share offline, external disk unmounted), that's
//  reported honestly rather than silently treated as "no backup."
//

import Foundation

struct TimeMachineStatus {
    let isConfigured: Bool
    let destinationName: String?
    let destinationKind: String?
    let isRunning: Bool
    /// 0...1, only meaningful while `isRunning` is true.
    let percentComplete: Double?
    let lastBackupDate: Date?
    /// Set when `isConfigured` but no usable last-backup date could be
    /// determined — e.g. the destination is currently unreachable, or no
    /// backup has ever completed. Never fabricated as a date.
    let lastBackupUnavailableReason: String?
}

enum MacTimeMachineMonitor {
    static func currentStatus() -> TimeMachineStatus {
        let destinations = destinationInfo()
        let (running, percent) = backupSessionStatus()
        let (lastDate, unavailableReason) = destinations.isEmpty ? (nil, nil) : latestBackup()

        return TimeMachineStatus(
            isConfigured: !destinations.isEmpty,
            destinationName: destinations.first?.name,
            destinationKind: destinations.first?.kind,
            isRunning: running,
            percentComplete: percent,
            lastBackupDate: lastDate,
            lastBackupUnavailableReason: unavailableReason
        )
    }

    private static func destinationInfo() -> [(name: String, kind: String)] {
        guard let data = run(["/usr/bin/tmutil", "destinationinfo", "-X"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let dests = plist["Destinations"] as? [[String: Any]]
        else { return [] }
        return dests.compactMap { dest in
            guard let name = dest["Name"] as? String else { return nil }
            return (name, dest["Kind"] as? String ?? "Unknown")
        }
    }

    private static func backupSessionStatus() -> (running: Bool, percent: Double?) {
        guard let data = run(["/usr/bin/tmutil", "status", "-X"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return (false, nil) }
        let running = (plist["Running"] as? Bool) ?? false
        let percentValue = (plist["Percent"] as? NSNumber)?.doubleValue
        let percent = (running && (percentValue ?? -1) >= 0) ? percentValue : nil
        return (running, percent)
    }

    /// `tmutil latestbackup` prints the path to the most recent successful backup on
    /// success, or a human-readable error on failure (e.g. destination currently
    /// unreachable) — it has no -X/plist mode, so success is distinguished by whether the
    /// trimmed output looks like an absolute path rather than an error sentence.
    private static func latestBackup() -> (date: Date?, unavailableReason: String?) {
        guard let data = run(["/usr/bin/tmutil", "latestbackup"]) else {
            return (nil, "Could not determine last backup time.")
        }
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard output.hasPrefix("/") else {
            return (nil, output.isEmpty ? "No successful backup found yet." : output)
        }
        // The backup path's own modification date reflects when that backup actually
        // completed - read via FileManager rather than parsing the path's date-formatted
        // directory name, which isn't a documented, stable format to rely on.
        let attrs = try? FileManager.default.attributesOfItem(atPath: output)
        let date = attrs?[.modificationDate] as? Date
        return (date, date == nil ? "Backup found but its date could not be read." : nil)
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
        return data
    }
}

//
//  MacProcessMonitor.swift
//  DevicePulseMac
//
//  Process listing via /bin/ps, the standard system utility — the same
//  data source Activity Monitor's command-line equivalent uses. This
//  avoids any private libproc/private-API surface: it's a plain process
//  launch and text parse, which is legitimate for a non-sandboxed
//  personal utility (this Mac target does not use App Sandbox, matching
//  a normal system-monitoring tool's needs).
//

import Foundation
import AppKit

struct ProcessInfoEntry: Identifiable {
    let id: Int32
    let pid: Int32
    let cpuPercent: Double
    let memoryPercent: Double
    let residentBytes: Int64
    let name: String
    let path: String
}

enum ProcessSortKey {
    case cpu, memory, name
}

enum MacProcessMonitor {
    static func snapshot() -> [ProcessInfoEntry] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,pcpu=,pmem=,rss=,comm="]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var entries: [ProcessInfoEntry] = []
        for line in output.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let mem = Double(parts[2]),
                  let rssKB = Int64(parts[3])
            else { continue }

            let fullPath = String(parts[4])
            let name = fullPath.components(separatedBy: "/").last ?? fullPath
            entries.append(ProcessInfoEntry(id: pid, pid: pid, cpuPercent: cpu, memoryPercent: mem, residentBytes: rssKB * 1024, name: name, path: fullPath))
        }
        return entries
    }

    static func sorted(_ entries: [ProcessInfoEntry], by key: ProcessSortKey) -> [ProcessInfoEntry] {
        switch key {
        case .cpu: return entries.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: return entries.sorted { $0.residentBytes > $1.residentBytes }
        case .name: return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// Cumulative bytes in/out per process since it started, via `nettop`
    /// (a bundled system utility, no root needed) — only processes with
    /// active network sockets appear. Cumulative, not a rate: callers
    /// sample this periodically and derive a rate from the delta, the
    /// same pattern used for CPU ticks.
    static func networkTotals() -> [Int32: (bytesIn: Int64, bytesOut: Int64)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        task.arguments = ["-x", "-P", "-L", "1", "-J", "bytes_in,bytes_out"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var result: [Int32: (bytesIn: Int64, bytesOut: Int64)] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3,
                  let dotIndex = parts[0].lastIndex(of: "."),
                  let pid = Int32(parts[0][parts[0].index(after: dotIndex)...]),
                  let bytesIn = Int64(parts[1]),
                  let bytesOut = Int64(parts[2])
            else { continue }
            result[pid] = (bytesIn, bytesOut)
        }
        return result
    }

    /// PIDs of regular, user-visible applications (as opposed to
    /// background daemons/helpers) — the same population
    /// `MacMemoryOptimizer` scopes quitting to. Anything not in this set
    /// is left alone here: quitting arbitrary system/background
    /// processes can destabilize the Mac.
    static func regularAppPIDs() -> Set<Int32> {
        Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { $0.processIdentifier })
    }
}

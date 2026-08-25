//
//  MacMemoryOptimizer.swift
//  DevicePulseMac
//
//  This is a real diagnostic tool, not a "RAM booster". There is no
//  legitimate public API on macOS that magically frees memory — macOS
//  already manages memory (paging, compression, purging file caches)
//  far better than any userland trick. The only real lever a normal app
//  has is: identify which user-facing apps are using a lot of memory,
//  and let the person quit the ones they choose. Everything here is
//  built around that, with an honest before/after re-measurement.
//
//  Quitting is scoped to NSRunningApplication (regular, user-visible
//  apps only) — never arbitrary background/system processes from the ps
//  listing, and never without explicit confirmation from the caller.
//

import Foundation
import AppKit

struct MemoryFinding: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let severity: DiagnosticStatus
}

struct QuitCandidate: Identifiable {
    var id: pid_t { app.processIdentifier }
    let app: NSRunningApplication
    let residentBytes: Int64
}

enum MacMemoryOptimizer {
    static func analyze(processes: [ProcessInfoEntry], memory: MacMemoryStats, swap: SwapStats?) -> [MemoryFinding] {
        var findings: [MemoryFinding] = []

        let pressure = MacMemoryPressureReader.current()
        let usedText = "\(Int(memory.usedFraction * 100))% of \(ByteFormat.memoryString(memory.total)) physical RAM is in use"
        switch pressure {
        case .critical:
            findings.append(MemoryFinding(title: "Memory pressure is critical", detail: "macOS is actively reclaiming memory. \(usedText).", severity: .warning))
        case .warning:
            findings.append(MemoryFinding(title: "Memory pressure is elevated", detail: usedText + ".", severity: .warning))
        case .normal:
            findings.append(MemoryFinding(title: "Memory pressure is normal", detail: "\(usedText) — macOS is managing memory normally. High usage alone isn't a problem; it's mostly caching.", severity: .pass))
        }

        if let swap, swap.used > DevicePulseThresholds.swapWarningBytes {
            findings.append(MemoryFinding(
                title: "Heavy swap usage",
                detail: "\(ByteFormat.memoryString(swap.used)) swapped to disk. This usually means real demand for RAM exceeds what's physically installed.",
                severity: .warning
            ))
        }

        if memory.compressed > 4_000_000_000 {
            findings.append(MemoryFinding(
                title: "Significant memory compression",
                detail: "\(ByteFormat.memoryString(memory.compressed)) of RAM is compressed. This is normal macOS behavior under load, not a problem by itself.",
                severity: .info
            ))
        }

        let heavy = processes.filter { $0.residentBytes > 1_000_000_000 }.sorted { $0.residentBytes > $1.residentBytes }
        if !heavy.isEmpty {
            let names = heavy.prefix(5).map { "\($0.name) (\(ByteFormat.memoryString($0.residentBytes)))" }.joined(separator: ", ")
            findings.append(MemoryFinding(
                title: "\(heavy.count) process\(heavy.count == 1 ? "" : "es") using over 1 GB",
                detail: names,
                severity: .info
            ))
        }

        return findings
    }

    /// User-facing running applications, cross-referenced with ps memory
    /// data, sorted by memory descending. Only apps NSWorkspace itself
    /// reports as regular running applications are eligible — this
    /// deliberately excludes background daemons and system processes.
    static func quitCandidates(processes: [ProcessInfoEntry]) -> [QuitCandidate] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

        return apps.compactMap { app in
            guard let entry = byPID[app.processIdentifier] else { return nil }
            return QuitCandidate(app: app, residentBytes: entry.residentBytes)
        }.sorted { $0.residentBytes > $1.residentBytes }
    }

    /// Gracefully asks the app to terminate (equivalent to Cmd-Q). Returns
    /// immediately; the app may still show its own "unsaved changes" prompt.
    static func quit(_ candidate: QuitCandidate) -> Bool {
        candidate.app.terminate()
    }

    /// Force-terminates — only ever called after the caller has shown an
    /// explicit confirmation to the user.
    static func forceQuit(_ candidate: QuitCandidate) -> Bool {
        candidate.app.forceTerminate()
    }
}

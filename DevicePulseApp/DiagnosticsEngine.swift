//
//  DiagnosticsEngine.swift
//  DevicePulse
//
//  Runs every check this app can legitimately make and reports PASS /
//  WARNING / INFO / UNAVAILABLE per check, with the exact threshold that
//  produced the result spelled out in its detail text. There is no single
//  blended "health score" — Apple doesn't expose enough to compute one
//  honestly, so this reports individual findings instead.
//

import Foundation
import UIKit
import Network

enum DiagnosticStatus: String {
    case pass = "Pass"
    case warning = "Warning"
    case info = "Info"
    case unavailable = "Unavailable"
}

struct DiagnosticCheck: Identifiable {
    let id = UUID()
    let name: String
    let status: DiagnosticStatus
    let detail: String
}

enum DiagnosticsEngine {
    /// Synchronous checks only (no network round-trip) — safe to call from
    /// the main thread without blocking the UI.
    static func syncChecks() -> [DiagnosticCheck] {
        var checks: [DiagnosticCheck] = []
        checks.append(batteryCheck())
        checks.append(thermalCheck())
        checks.append(memoryPressureCheck())
        checks.append(memoryCheck())
        checks.append(storageCheck())
        return checks
    }

    /// Full quick-check set including a live network reachability read.
    /// Async because NWPathMonitor is callback-based; never blocks the
    /// calling thread while waiting.
    static func quickChecks() async -> [DiagnosticCheck] {
        var checks = syncChecks()
        checks.append(await networkCheck())
        return checks
    }

    static func fullDiagnostic(includeSpeedTest: Bool) async -> [DiagnosticCheck] {
        var checks = await quickChecks()
        checks.append(deviceInfoCheck())

        let (dnsOK, dnsMs) = await NetworkDiagnostics.resolveDNS()
        if dnsOK, let ms = dnsMs {
            checks.append(DiagnosticCheck(name: "DNS Resolution", status: .pass, detail: "Resolved in \(Int(ms)) ms."))
        } else {
            checks.append(DiagnosticCheck(name: "DNS Resolution", status: .warning, detail: "Could not resolve www.apple.com. Check connectivity."))
        }

        if let latency = await NetworkDiagnostics.tcpLatency() {
            let status: DiagnosticStatus = latency > 400 ? .warning : .pass
            checks.append(DiagnosticCheck(name: "Connection Latency", status: status, detail: "TCP connect to www.apple.com:443 took \(Int(latency)) ms (threshold: warning above 400 ms). This is a TCP handshake time, not ICMP ping — iOS doesn't expose raw ping to apps."))
        } else {
            checks.append(DiagnosticCheck(name: "Connection Latency", status: .unavailable, detail: "Could not establish a TCP connection to test with."))
        }

        if includeSpeedTest {
            if let down = await NetworkDiagnostics.downloadSpeedMbps() {
                checks.append(DiagnosticCheck(name: "Download Speed", status: .info, detail: String(format: "%.1f Mbps (estimate, via speed.cloudflare.com).", down)))
            } else {
                checks.append(DiagnosticCheck(name: "Download Speed", status: .unavailable, detail: "Speed test could not complete."))
            }
            if let up = await NetworkDiagnostics.uploadSpeedMbps() {
                checks.append(DiagnosticCheck(name: "Upload Speed", status: .info, detail: String(format: "%.1f Mbps (estimate, via speed.cloudflare.com).", up)))
            } else {
                checks.append(DiagnosticCheck(name: "Upload Speed", status: .unavailable, detail: "Speed test could not complete."))
            }
        } else {
            checks.append(DiagnosticCheck(name: "Speed Test", status: .info, detail: "Skipped — enable \"Include speed test\" to measure download/upload throughput (uses several MB of data)."))
        }

        return checks
    }

    // MARK: - Individual checks (thresholds documented inline)

    static func batteryCheck() -> DiagnosticCheck {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        let state = device.batteryState
        guard level >= 0 else {
            return DiagnosticCheck(name: "Battery", status: .unavailable, detail: "Battery level unavailable (common in Simulator).")
        }
        let percent = Int((level * 100).rounded())
        let isCharging = state == .charging || state == .full
        if !isCharging && percent < 15 {
            return DiagnosticCheck(name: "Battery", status: .warning, detail: "\(percent)% and not charging (threshold: warning below 15%).")
        }
        return DiagnosticCheck(name: "Battery", status: .pass, detail: "\(percent)%, \(isCharging ? "charging" : "not charging").")
    }

    static func thermalCheck() -> DiagnosticCheck {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return DiagnosticCheck(name: "Thermal State", status: .pass, detail: "Nominal.")
        case .fair:
            return DiagnosticCheck(name: "Thermal State", status: .pass, detail: "Fair — slightly elevated but normal under load.")
        case .serious:
            return DiagnosticCheck(name: "Thermal State", status: .warning, detail: "Serious — the system is actively limiting performance to cool down.")
        case .critical:
            return DiagnosticCheck(name: "Thermal State", status: .warning, detail: "Critical — significant thermal throttling in effect.")
        @unknown default:
            return DiagnosticCheck(name: "Thermal State", status: .info, detail: "Unknown state.")
        }
    }

    static func memoryPressureCheck() -> DiagnosticCheck {
        // This is a used-memory ratio, not actual OS memory pressure — iOS's
        // memory pressure signal isn't queryable as a point-in-time check the
        // way DispatchSourceMemoryPressure only fires on state transitions
        // (see MemoryPressureMonitor for the live version shown in the UI).
        // Named "Memory Usage" (not "Memory Pressure") so it isn't confused
        // with the kernel-pressure-backed check the Mac target now uses.
        if let stats = MemoryReader.read(), stats.usedFraction > 0 {
            if stats.usedFraction > 0.9 {
                return DiagnosticCheck(name: "Memory Usage", status: .warning, detail: "System memory is \(Int(stats.usedFraction * 100))% used (threshold: warning above 90%) — a utilization approximation, not a true memory-pressure signal.")
            }
            return DiagnosticCheck(name: "Memory Usage", status: .pass, detail: "System memory is \(Int(stats.usedFraction * 100))% used.")
        }
        return DiagnosticCheck(name: "Memory Usage", status: .unavailable, detail: "Could not read memory statistics.")
    }

    static func memoryCheck() -> DiagnosticCheck {
        guard let stats = MemoryReader.read() else {
            return DiagnosticCheck(name: "Memory", status: .unavailable, detail: "Could not read memory statistics.")
        }
        return DiagnosticCheck(name: "Memory", status: .info, detail: "\(ByteFormat.string(stats.used)) used of \(ByteFormat.string(stats.total)).")
    }

    static func storageCheck() -> DiagnosticCheck {
        guard let stats = StorageReader.read() else {
            return DiagnosticCheck(name: "Storage", status: .unavailable, detail: "Could not read storage statistics.")
        }
        let freeFraction = 1 - stats.usedFraction
        if freeFraction < 0.05 {
            return DiagnosticCheck(name: "Storage", status: .warning, detail: "Only \(Int(freeFraction * 100))% free (threshold: warning below 5%).")
        }
        return DiagnosticCheck(name: "Storage", status: .pass, detail: "\(ByteFormat.string(stats.free)) free of \(ByteFormat.string(stats.total)).")
    }

    static func networkCheck() async -> DiagnosticCheck {
        let snapshot = await NWPathMonitorSnapshot.current()
        if !snapshot.isConnected {
            return DiagnosticCheck(name: "Network", status: .warning, detail: "No active connection detected.")
        }
        return DiagnosticCheck(name: "Network", status: .pass, detail: "Connected via \(snapshot.typeText).")
    }

    static func deviceInfoCheck() -> DiagnosticCheck {
        DiagnosticCheck(name: "Device", status: .info, detail: "\(DeviceInfo.deviceName) — \(DeviceInfo.modelIdentifier), \(DeviceInfo.systemVersion), uptime \(DeviceInfo.uptimeText).")
    }
}

/// One-shot synchronous snapshot of network path status, for use outside a
/// long-lived NWPathMonitor subscription (e.g. inside a synchronous check).
struct NWPathMonitorSnapshot {
    let isConnected: Bool
    let typeText: String

    static func current() async -> NWPathMonitorSnapshot {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            var didResume = false
            let queue = DispatchQueue(label: "com.devicedashboard.networksnapshot")
            monitor.pathUpdateHandler = { path in
                guard !didResume else { return }
                didResume = true
                let connected = path.status == .satisfied
                var typeText = "No Connection"
                if path.usesInterfaceType(.wifi) {
                    typeText = "Wi-Fi"
                } else if path.usesInterfaceType(.cellular) {
                    typeText = "Cellular"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    typeText = "Ethernet"
                } else if connected {
                    typeText = "Connected"
                }
                monitor.cancel()
                continuation.resume(returning: NWPathMonitorSnapshot(isConnected: connected, typeText: typeText))
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) {
                guard !didResume else { return }
                didResume = true
                monitor.cancel()
                continuation.resume(returning: NWPathMonitorSnapshot(isConnected: false, typeText: "No Connection"))
            }
        }
    }
}

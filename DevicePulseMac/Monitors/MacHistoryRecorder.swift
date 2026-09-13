//
//  MacHistoryRecorder.swift
//  DevicePulseMac
//
//  Samples CPU/Memory/Storage/Battery every 5 minutes and hands the
//  result to MacHistoryStore, so History charts have real data to show
//  instead of an empty state. Runs unconditionally from launch (like
//  MacAlertMonitor) but respects its own Settings toggle — turning
//  history off stops the timer entirely rather than just hiding the
//  charts, matching how the alerts toggle already behaves.
//
//  Deliberately doesn't share MacCPUMonitor/MacMemoryMonitor instances
//  (each owns its own always-running Timer) — this only needs one
//  reading every 5 minutes, so it takes standalone one-shot samples via
//  their static helpers instead of standing up two more live monitors.
//

import Foundation

final class MacHistoryRecorder {
    static let shared = MacHistoryRecorder()

    private var timer: Timer?
    private(set) var isRunning = false
    private let sampleInterval: TimeInterval = 5 * 60

    private init() {}

    private var historyEnabled: Bool {
        UserDefaults.standard.object(forKey: "historyEnabled") == nil
            || UserDefaults.standard.bool(forKey: "historyEnabled")
    }

    /// Safe to call at launch unconditionally — checks the setting itself.
    func start() {
        guard historyEnabled, !isRunning else { return }
        isRunning = true
        sampleNow()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.sampleNow()
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func sampleNow() {
        DispatchQueue.global(qos: .utility).async {
            // The CPU sample blocks for ~1s to measure a tick delta —
            // deliberately done here, off the main thread.
            let cpuFraction = MacCPUMonitor.sampleAggregateUsedFraction()
            let memoryStats = MacMemoryMonitor.currentStats()
            let pressure = MacMemoryPressureReader.current()
            let volume = MacStorageMonitor.mainVolume()
            let battery = MacBatteryMonitor.hasBattery() ? MacBatteryMonitor.current() : nil

            let observation = MacMetricObservation(
                timestamp: Date(),
                cpuUsedFraction: cpuFraction,
                memoryUsedFraction: memoryStats?.usedFraction,
                memoryPressure: pressure.rawValue,
                storageUsedFraction: volume?.usedFraction,
                storageFreeBytes: volume.map { $0.total - $0.used },
                batteryLevel: battery?.percentage,
                batteryCharging: battery?.isCharging,
                thermalState: Self.thermalStateText(ProcessInfo.processInfo.thermalState)
            )
            MacHistoryStore.shared.recordIfDue(observation)
        }
    }

    private static func thermalStateText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

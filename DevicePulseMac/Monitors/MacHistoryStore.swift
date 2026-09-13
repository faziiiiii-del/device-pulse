//
//  MacHistoryStore.swift
//  DevicePulseMac
//
//  Local-only history of lightweight metric samples, persisted as a JSON
//  file in this app's own Application Support directory — nothing leaves
//  this Mac. Same pattern as the iOS target's HistoryStore. Used to show
//  real 24-hour/7-day/30-day trends instead of just the last ~60
//  in-memory samples each tab already keeps since launch.
//

import Foundation

struct MacMetricObservation: Codable, Identifiable, Equatable {
    var id = UUID()
    var timestamp: Date
    var cpuUsedFraction: Double?
    var memoryUsedFraction: Double?
    var memoryPressure: String?
    var storageUsedFraction: Double?
    var storageFreeBytes: Int64?
    var batteryLevel: Int?
    var batteryCharging: Bool?
    var thermalState: String?
}

final class MacHistoryStore {
    static let shared = MacHistoryStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.devicedashboard.mac.historystore", qos: .utility)
    /// 30 days at one sample per 5 minutes, plus headroom — old samples
    /// are dropped FIFO once this is exceeded rather than growing
    /// unbounded.
    private let maxObservations = 9000
    private let minInterval: TimeInterval = 5 * 60

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("mac_history.json")
    }

    /// Only actually records if at least `minInterval` has passed since
    /// the last sample — safe to call more often than that (e.g. right
    /// after a relaunch) without producing near-duplicate rows.
    func recordIfDue(_ observation: MacMetricObservation) {
        queue.sync {
            var existing = loadLocked()
            if let last = existing.last, observation.timestamp.timeIntervalSince(last.timestamp) < minInterval {
                return
            }
            existing.append(observation)
            if existing.count > maxObservations {
                existing.removeFirst(existing.count - maxObservations)
            }
            saveLocked(existing)
        }
    }

    func all() -> [MacMetricObservation] {
        queue.sync { loadLocked() }
    }

    func recent(within interval: TimeInterval) -> [MacMetricObservation] {
        let cutoff = Date().addingTimeInterval(-interval)
        return all().filter { $0.timestamp >= cutoff }
    }

    func clear() {
        queue.sync { saveLocked([]) }
    }

    private func loadLocked() -> [MacMetricObservation] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([MacMetricObservation].self, from: data)) ?? []
    }

    private func saveLocked(_ observations: [MacMetricObservation]) {
        guard let data = try? JSONEncoder().encode(observations) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

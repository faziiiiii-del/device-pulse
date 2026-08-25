//
//  HistoryStore.swift
//  DevicePulse
//
//  Local-only history of lightweight metric observations, persisted as a
//  JSON file inside this app's own Application Support directory (its own
//  sandbox — nothing leaves the device). Used to show trends over time.
//

import Foundation

struct MetricObservation: Codable, Identifiable, Equatable {
    var id = UUID()
    var timestamp: Date
    var batteryLevel: Float?
    var isCharging: Bool?
    var thermalState: String?
    var memoryUsedFraction: Double?
    var memoryPressure: String?
    var storageUsedFraction: Double?
    var storageFreeBytes: Int64?
    var networkType: String?
    var latencyMs: Double?
}

final class HistoryStore {
    static let shared = HistoryStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.devicedashboard.historystore", qos: .utility)
    private let maxObservations = 1000
    private let minInterval: TimeInterval = 5 * 60

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
    }

    func recordIfDue(_ makeObservation: @autoclosure () -> MetricObservation) {
        queue.sync {
            let existing = loadLocked()
            if let last = existing.last, Date().timeIntervalSince(last.timestamp) < minInterval {
                return
            }
            var updated = existing
            updated.append(makeObservation())
            if updated.count > maxObservations {
                updated.removeFirst(updated.count - maxObservations)
            }
            saveLocked(updated)
        }
    }

    func recordNow(_ observation: MetricObservation) {
        queue.sync {
            var existing = loadLocked()
            existing.append(observation)
            if existing.count > maxObservations {
                existing.removeFirst(existing.count - maxObservations)
            }
            saveLocked(existing)
        }
    }

    func all() -> [MetricObservation] {
        queue.sync { loadLocked() }
    }

    func recent(within interval: TimeInterval) -> [MetricObservation] {
        let cutoff = Date().addingTimeInterval(-interval)
        return all().filter { $0.timestamp >= cutoff }
    }

    func last(_ n: Int) -> [MetricObservation] {
        Array(all().suffix(n))
    }

    func clear() {
        queue.sync { saveLocked([]) }
    }

    private func loadLocked() -> [MetricObservation] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([MetricObservation].self, from: data)) ?? []
    }

    private func saveLocked(_ observations: [MetricObservation]) {
        guard let data = try? JSONEncoder().encode(observations) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

//
//  SnapshotStore.swift
//  DevicePulse
//
//  Manually-saved, full-detail snapshots of every metric this app can
//  read at a moment in time, persisted locally so two points in time can
//  be compared. Nothing leaves the device.
//

import Foundation

struct DeviceSnapshot: Codable, Identifiable {
    var id = UUID()
    var timestamp: Date
    var label: String

    var batteryLevel: Float?
    var batteryState: String?
    var lowPowerMode: Bool?
    var thermalState: String?

    var memoryTotal: UInt64?
    var memoryUsed: UInt64?
    var memoryFree: UInt64?
    var memoryPressure: String?
    var appMemoryUsage: UInt64?

    var storageTotal: Int64?
    var storageUsed: Int64?
    var storageFree: Int64?
    var appCacheSize: Int64?
    var appTempSize: Int64?

    var networkType: String?
    var networkConnected: Bool?

    var deviceModel: String?
    var systemVersion: String?
    var uptimeSeconds: Double?
}

final class SnapshotStore {
    static let shared = SnapshotStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.devicedashboard.snapshotstore", qos: .utility)

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = dir.appendingPathComponent("snapshots.json")
    }

    func save(_ snapshot: DeviceSnapshot) {
        queue.sync {
            var existing = loadLocked()
            existing.append(snapshot)
            saveLocked(existing)
        }
    }

    func all() -> [DeviceSnapshot] {
        queue.sync { loadLocked().sorted { $0.timestamp > $1.timestamp } }
    }

    func delete(_ id: UUID) {
        queue.sync {
            var existing = loadLocked()
            existing.removeAll { $0.id == id }
            saveLocked(existing)
        }
    }

    static func captureNow(
        battery: BatteryMonitor,
        thermal: ThermalMonitor,
        memoryPressure: MemoryPressureMonitor,
        network: NetworkMonitor,
        cacheSize: Int64,
        tempSize: Int64,
        label: String
    ) -> DeviceSnapshot {
        let memStats = MemoryReader.read()
        let storageStats = StorageReader.read()
        return DeviceSnapshot(
            timestamp: Date(),
            label: label,
            batteryLevel: battery.level,
            batteryState: battery.stateText,
            lowPowerMode: battery.lowPowerMode,
            thermalState: thermal.text,
            memoryTotal: memStats?.total,
            memoryUsed: memStats?.used,
            memoryFree: memStats?.free,
            memoryPressure: memoryPressure.level.rawValue,
            appMemoryUsage: MemoryReader.appMemoryUsage(),
            storageTotal: storageStats?.total,
            storageUsed: storageStats?.used,
            storageFree: storageStats?.free,
            appCacheSize: cacheSize,
            appTempSize: tempSize,
            networkType: network.connectionType,
            networkConnected: network.isConnected,
            deviceModel: DeviceInfo.modelIdentifier,
            systemVersion: DeviceInfo.systemVersion,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime
        )
    }

    private func loadLocked() -> [DeviceSnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([DeviceSnapshot].self, from: data)) ?? []
    }

    private func saveLocked(_ snapshots: [DeviceSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

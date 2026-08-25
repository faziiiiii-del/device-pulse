//
//  MacGPUMonitor.swift
//  DevicePulseMac
//
//  GPU utilization and memory via IORegistry's "PerformanceStatistics"
//  dictionary on the IOAccelerator service — public IOKit, no root
//  needed (verified directly with `ioreg -r -d 1 -c IOAccelerator` on
//  this Mac before writing this). This is the same technique the
//  open-source "Stats" menu bar app uses; it is not a documented,
//  stable API, so it's treated as best-effort like the battery
//  IORegistry fields elsewhere in this app.
//
//  There is no public API for GPU temperature or clock speed on Apple
//  Silicon, so those are never shown.
//

import Foundation
import IOKit

final class MacGPUMonitor: ObservableObject {
    @Published var utilizationPercent: Int?
    @Published var inUseMemoryBytes: Int64?
    @Published var allocatedMemoryBytes: Int64?
    @Published var model: String?
    @Published var coreCount: Int?
    @Published var history: [Double] = []

    private var timer: Timer?
    private let maxHistory = 60

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        guard let service = Self.findAccelerator() else {
            utilizationPercent = nil
            return
        }
        defer { IOObjectRelease(service) }

        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsUnmanaged?.takeRetainedValue() as? [String: Any]
        else {
            utilizationPercent = nil
            return
        }

        model = props["model"] as? String
        coreCount = props["gpu-core-count"] as? Int

        guard let stats = props["PerformanceStatistics"] as? [String: Any] else {
            utilizationPercent = nil
            return
        }

        let util = stats["Device Utilization %"] as? Int
        utilizationPercent = util
        inUseMemoryBytes = (stats["In use system memory"] as? Int).map(Int64.init)
        allocatedMemoryBytes = (stats["Alloc system memory"] as? Int).map(Int64.init)

        if let util {
            history.append(Double(util) / 100)
            if history.count > maxHistory {
                history.removeFirst(history.count - maxHistory)
            }
        }
    }

    private static func findAccelerator() -> io_object_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        return service != 0 ? service : nil
    }
}

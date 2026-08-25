//
//  MacBatteryMonitor.swift
//  DevicePulseMac
//
//  Battery/power info via the PUBLIC IOKit power source APIs
//  (IOPSCopyPowerSourcesInfo / IOPSCopyPowerSourcesList /
//  IOPSGetPowerSourceDescription) — the standard, documented way any Mac
//  app reads battery percentage/charging state, plus IOKit's public
//  kIOPSTimeToEmptyKey/kIOPSTimeToFullChargeKey for runtime estimates.
//
//  Cycle count, capacities, voltage, and amperage are read from the
//  IORegistry "AppleSmartBattery" service. This is not a private
//  framework — IOKit and IORegistryEntry are public APIs — but the
//  specific property keys on that service aren't part of a stable public
//  contract (they also differ between Intel and Apple Silicon: Apple
//  Silicon nests real capacities under "BatteryData" in mAh, while the
//  top-level "MaxCapacity"/"CurrentCapacity" there are percentages, not
//  mAh, unlike on Intel). Treated as best-effort throughout, reported as
//  Unavailable rather than guessed if a property is missing.
//
//  Confirmed by direct `ioreg -r -c AppleSmartBattery` inspection on
//  Apple Silicon: there is no "Temperature" key anywhere in this
//  service's properties, so battery temperature is never shown — not
//  because we don't try, but because this hardware genuinely doesn't
//  expose it here.
//

import Foundation
import IOKit
import IOKit.ps

struct BatteryInfo {
    let percentage: Int
    let isCharging: Bool
    let isFullyCharged: Bool
    let powerSourceState: String
    let cycleCount: Int?
    let maxCapacityPercent: Int?
    let designCapacityMah: Int?
    let fullChargeCapacityMah: Int?
    let remainingCapacityMah: Int?
    let temperatureCelsius: Double?
    let timeToEmptyMinutes: Int?
    let timeToFullMinutes: Int?
    let voltageMillivolts: Int?
    let amperageMilliamps: Int?

    var wattage: Double? {
        guard let voltageMillivolts, let amperageMilliamps else { return nil }
        return (Double(abs(amperageMilliamps)) * Double(voltageMillivolts)) / 1_000_000
    }

    /// A simple, clearly-labeled threshold on capacity ratio — NOT
    /// Apple's own "Service Recommended" diagnostic, which uses a
    /// private algorithm that can also factor in things besides raw
    /// capacity. This is an honest estimate, captioned as such in the UI.
    var healthLabel: String? {
        guard let maxCapacityPercent else { return nil }
        switch maxCapacityPercent {
        case 80...: return "Good"
        case 60..<80: return "Fair"
        default: return "Poor"
        }
    }
}

enum MacBatteryMonitor {
    static func hasBattery() -> Bool {
        readPowerSource() != nil
    }

    static func current() -> BatteryInfo? {
        guard let power = readPowerSource() else { return nil }
        let registry = readIORegistryBatteryInfo()
        return BatteryInfo(
            percentage: power.percentage,
            isCharging: power.charging,
            isFullyCharged: registry.isFullyCharged,
            powerSourceState: power.state,
            cycleCount: registry.cycleCount,
            maxCapacityPercent: registry.maxCapacityPercent,
            designCapacityMah: registry.designCapacityMah,
            fullChargeCapacityMah: registry.fullChargeCapacityMah,
            remainingCapacityMah: registry.remainingCapacityMah,
            temperatureCelsius: registry.temperatureCelsius,
            timeToEmptyMinutes: power.timeToEmpty,
            timeToFullMinutes: power.timeToFull,
            voltageMillivolts: registry.voltageMillivolts,
            amperageMilliamps: registry.amperageMilliamps
        )
    }

    private static func readPowerSource() -> (percentage: Int, charging: Bool, state: String, timeToEmpty: Int?, timeToFull: Int?)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: AnyObject]
        else { return nil }

        guard let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
              let maxCapacity = description[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0
        else { return nil }

        let percentage = Int((Double(currentCapacity) / Double(maxCapacity) * 100).rounded())
        let stateString = description[kIOPSPowerSourceStateKey] as? String ?? kIOPSOffLineValue
        let isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false

        // IOKit reports -1 when it hasn't calculated an estimate yet;
        // that's not a real value, so it's filtered to nil.
        let timeToEmpty = (description[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 >= 0 ? $0 : nil }
        let timeToFull = (description[kIOPSTimeToFullChargeKey] as? Int).flatMap { $0 >= 0 ? $0 : nil }

        return (percentage, isCharging, stateString == kIOPSACPowerValue ? "AC Power" : "Battery Power", timeToEmpty, timeToFull)
    }

    private static func readIORegistryBatteryInfo() -> (
        cycleCount: Int?, maxCapacityPercent: Int?, designCapacityMah: Int?, fullChargeCapacityMah: Int?,
        remainingCapacityMah: Int?, temperatureCelsius: Double?, voltageMillivolts: Int?, amperageMilliamps: Int?, isFullyCharged: Bool
    ) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil, nil, nil, nil, nil, nil, nil, false) }
        defer { IOObjectRelease(service) }

        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsUnmanaged?.takeRetainedValue() as? [String: AnyObject]
        else { return (nil, nil, nil, nil, nil, nil, nil, nil, false) }

        let cycleCount = props["CycleCount"] as? Int
        let isFullyCharged = (props["FullyCharged"] as? Bool) ?? false

        // Apple Silicon nests real mAh capacities under "BatteryData";
        // Intel Macs expose them at the top level instead (where, unlike
        // Apple Silicon, "MaxCapacity"/"CurrentCapacity" ARE mAh).
        let batteryData = props["BatteryData"] as? [String: Any]
        let designCapacity = (batteryData?["DesignCapacity"] as? Int) ?? (props["DesignCapacity"] as? Int)
        let fullChargeCapacity = (batteryData?["FullChargeCapacity"] as? Int)
            ?? (props["AppleRawMaxCapacity"] as? Int)
            ?? (batteryData == nil ? props["MaxCapacity"] as? Int : nil)
        let remainingCapacity = (batteryData?["RemainingCapacity"] as? Int)
            ?? (props["AppleRawCurrentCapacity"] as? Int)
            ?? (batteryData == nil ? props["CurrentCapacity"] as? Int : nil)

        var maxCapacityPercent: Int?
        if let designCapacity, designCapacity > 0, let fullChargeCapacity {
            maxCapacityPercent = Int((Double(fullChargeCapacity) / Double(designCapacity) * 100).rounded())
        }

        let temperatureCelsius = (props["Temperature"] as? Int).map { Double($0) / 100 }
        let voltage = props["Voltage"] as? Int
        let amperage = signedInt(props["Amperage"]) ?? signedInt(props["InstantAmperage"])

        return (cycleCount, maxCapacityPercent, designCapacity, fullChargeCapacity, remainingCapacity, temperatureCelsius, voltage, amperage, isFullyCharged)
    }

    /// IOKit sometimes hands back a signed quantity (like discharge
    /// current) boxed as an unsigned 64-bit NSNumber — the raw bit
    /// pattern is correct, but reading it naively yields a huge positive
    /// "garbage" number instead of the small negative one it represents.
    /// This reinterprets those bits as two's-complement Int64.
    private static func signedInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.uint64Value
        if raw > UInt64(Int64.max) {
            return Int(Int64(bitPattern: raw))
        }
        return number.intValue
    }
}

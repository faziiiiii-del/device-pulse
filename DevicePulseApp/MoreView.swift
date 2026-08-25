//
//  MoreView.swift
//  DevicePulse
//

import SwiftUI
import UIKit

struct MoreView: View {
    @StateObject private var thermal = ThermalMonitor()
    @StateObject private var battery = BatteryMonitor()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hardwareCard
                    softwareCard
                    capabilitiesCard
                    DisclaimerCard()
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Device")
        }
    }

    private var hardwareCard: some View {
        StatCard(title: "Hardware", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "Name", value: DeviceInfo.deviceName)
                InfoRow(label: "Model Identifier", value: DeviceInfo.modelIdentifier)
                InfoRow(label: "Architecture", value: DeviceInfo.processorArchitecture)
                InfoRow(label: "Physical Memory", value: ByteFormat.string(ProcessInfo.processInfo.physicalMemory))
                InfoRow(label: "Screen Size (points)", value: DeviceInfo.screenSizeText)
                InfoRow(label: "Screen Scale", value: DeviceInfo.screenScaleText)
            }
        }
    }

    private var softwareCard: some View {
        StatCard(title: "Software", systemImage: "gearshape") {
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "System", value: DeviceInfo.systemVersion)
                InfoRow(label: "Uptime", value: DeviceInfo.uptimeText)
                InfoRow(label: "Locale", value: DeviceInfo.localeText)
                InfoRow(label: "Timezone", value: DeviceInfo.timezoneText)
            }
        }
    }

    private var capabilitiesCard: some View {
        StatCard(title: "Current State", systemImage: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "Thermal State", value: thermal.text)
                InfoRow(label: "Low Power Mode", value: battery.lowPowerMode ? "On" : "Off")
                InfoRow(label: "Battery Monitoring", value: UIDevice.current.isBatteryMonitoringEnabled ? "Enabled" : "Unavailable")
                InfoRow(label: "Metal (GPU)", value: DeviceInfo.metalAvailableText)
            }
        }
    }
}

#Preview {
    MoreView()
}

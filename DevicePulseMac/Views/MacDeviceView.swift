//
//  MacDeviceView.swift
//  DevicePulseMac
//

import SwiftUI

struct MacDeviceView: View {
    @StateObject private var thermal = MacThermalMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Device").font(.largeTitle).bold()

                MacCard(title: "Hardware", systemImage: "cpu", tint: MacSection.device.tint) {
                    MacInfoRow(label: "Model Identifier", value: MacDeviceMonitor.modelIdentifier)
                    MacInfoRow(label: "Processor", value: MacDeviceMonitor.processorBrand)
                    MacInfoRow(label: "Architecture", value: MacDeviceMonitor.architecture)
                    MacInfoRow(label: "Logical Cores", value: "\(MacDeviceMonitor.coreCount)")
                    MacInfoRow(label: "Physical Memory", value: ByteFormat.memoryString(MacDeviceMonitor.physicalMemory))
                    ForEach(Array(MacDeviceMonitor.displaySummaries.enumerated()), id: \.offset) { index, summary in
                        MacInfoRow(label: "Display \(index + 1)", value: summary)
                    }
                }

                MacCard(title: "Software", systemImage: "gearshape", tint: MacSection.device.tint) {
                    MacInfoRow(label: "System", value: MacDeviceMonitor.systemVersion)
                    MacInfoRow(label: "Build", value: MacDeviceMonitor.buildVersion)
                    MacInfoRow(label: "Host Name", value: MacDeviceMonitor.hostName)
                    MacInfoRow(label: "Uptime", value: MacDeviceMonitor.uptimeText)
                }

                MacCard(title: "Current State", systemImage: "checkmark.seal", tint: MacSection.device.tint) {
                    MacInfoRow(label: "Thermal State", value: thermal.text)
                }
            }
            .padding(24)
        }
    }
}

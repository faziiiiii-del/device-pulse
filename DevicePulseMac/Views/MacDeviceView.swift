//
//  MacDeviceView.swift
//  DevicePulseMac
//

import SwiftUI

struct MacDeviceView: View {
    @StateObject private var thermal = MacThermalMonitor()

    @State private var bluetooth: [BluetoothPeripheral] = []
    @State private var loadingBluetooth = true

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

                MacCard(title: "Bluetooth Peripherals", systemImage: "dot.radiowaves.left.and.right", tint: MacSection.device.tint) {
                    if loadingBluetooth {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading Bluetooth…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        let connected = bluetooth.filter(\.isConnected)
                        if connected.isEmpty {
                            Text("No Bluetooth devices connected right now.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(connected) { device in
                                bluetoothRow(device)
                                if device.id != connected.last?.id { Divider() }
                            }
                        }
                        Text("Battery levels are shown only for devices that report them over Bluetooth (most Apple peripherals and many third-party mice, keyboards and headsets). Read via system_profiler — the same source as System Report ▸ Bluetooth.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                MacCard(title: "Current State", systemImage: "checkmark.seal", tint: MacSection.device.tint) {
                    MacInfoRow(label: "Thermal State", value: thermal.text)
                }
            }
            .padding(24)
        }
        .onAppear(perform: loadBluetooth)
    }

    @ViewBuilder
    private func bluetoothRow(_ device: BluetoothPeripheral) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.subheadline)
                Text(device.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let low = device.lowestBattery {
                HStack(spacing: 6) {
                    Image(systemName: batterySymbol(low))
                        .foregroundStyle(batteryColor(low))
                    Text(device.statusText).font(.subheadline).monospacedDigit()
                }
            } else {
                Text(device.statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<15: return "battery.25"
        case ..<50: return "battery.50"
        case ..<80: return "battery.75"
        default: return "battery.100"
        }
    }

    private func batteryColor(_ percent: Int) -> Color {
        switch percent {
        case ..<15: return .red
        case ..<30: return .orange
        default: return .green
        }
    }

    private func loadBluetooth() {
        loadingBluetooth = true
        DispatchQueue.global(qos: .utility).async {
            let found = MacBluetoothMonitor.scan()
            DispatchQueue.main.async {
                bluetooth = found
                loadingBluetooth = false
            }
        }
    }
}

//
//  NetworkView.swift
//  DevicePulse
//

import SwiftUI

struct NetworkView: View {
    @StateObject private var network = NetworkMonitor()

    @State private var isTesting = false
    @State private var testStage = ""
    @State private var lastResult: NetworkDiagnostics.Result?
    @State private var includeSpeedTest = false
    @State private var includePublicIP = false
    @State private var latencyHistory: [Double] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    networkCard
                    interfacesCard
                    testCard
                    if !latencyHistory.isEmpty {
                        historyCard
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Network")
            .onAppear {
                latencyHistory = HistoryStore.shared.recent(within: 7 * 24 * 3600).compactMap { $0.latencyMs }
            }
        }
    }

    private var networkCard: some View {
        StatCard(title: "Network", systemImage: "wifi") {
            VStack(alignment: .leading, spacing: 8) {
                Label(network.connectionType, systemImage: network.isConnected ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(network.isConnected ? .green : .red)
                HStack(spacing: 16) {
                    if network.isExpensive {
                        Label("Metered", systemImage: "dollarsign.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if network.isConstrained {
                        Label("Data Saver", systemImage: "tortoise")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("Wi-Fi signal strength (dBm/RSSI) has no public API on iOS — it can't be shown accurately by any App Store app. SSID also isn't shown here: reading it requires either Location permission or the \"Access WiFi Information\" entitlement, and this app doesn't request Location for just that.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var interfacesCard: some View {
        StatCard(title: "Local IP Addresses", systemImage: "network") {
            let interfaces = NetworkDiagnostics.localIPAddresses()
            if interfaces.isEmpty {
                Text("No active interface with an IPv4 address found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(interfaces, id: \.address) { entry in
                    InfoRow(label: entry.interface, value: entry.address)
                }
            }
            Text("Read via getifaddrs(), a public POSIX API.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var testCard: some View {
        StatCard(title: "Test Connection", systemImage: "waveform.path") {
            Toggle("Include speed test (uses several MB of data)", isOn: $includeSpeedTest)
                .font(.subheadline)
            Toggle("Include public IP lookup (queries ipify.org)", isOn: $includePublicIP)
                .font(.subheadline)

            Button {
                runTest()
            } label: {
                if isTesting {
                    HStack { ProgressView(); Text(testStage) }
                } else {
                    Label("Test Connection", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isTesting)
            .frame(maxWidth: .infinity)

            if let result = lastResult {
                Divider()
                if result.dnsSuccess, let ms = result.dnsMs {
                    InfoRow(label: "DNS Resolution", value: "\(Int(ms)) ms")
                } else {
                    InfoRow(label: "DNS Resolution", value: "Failed")
                }
                if let latency = result.tcpLatencyMs {
                    InfoRow(label: "Connection Latency", value: "\(Int(latency)) ms")
                } else {
                    InfoRow(label: "Connection Latency", value: "Unavailable")
                }
                if let down = result.downloadMbps {
                    InfoRow(label: "Download", value: String(format: "%.1f Mbps", down))
                }
                if let up = result.uploadMbps {
                    InfoRow(label: "Upload", value: String(format: "%.1f Mbps", up))
                }
                if let ip = result.publicIP {
                    InfoRow(label: "Public IP", value: ip)
                }
                Text("Latency is a TCP-connect time to www.apple.com:443, not ICMP ping (iOS doesn't expose raw ping to apps). Speed figures are estimates via speed.cloudflare.com.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var historyCard: some View {
        StatCard(title: "Latency History (7 days)", systemImage: "chart.xyaxis.line") {
            let normalized = normalize(latencyHistory)
            Sparkline(values: normalized, tint: .orange)
                .frame(height: 60)
            if let min = latencyHistory.min(), let max = latencyHistory.max() {
                let avg = latencyHistory.reduce(0, +) / Double(latencyHistory.count)
                Text("Best \(Int(min)) ms · Worst \(Int(max)) ms · Avg \(Int(avg)) ms · \(latencyHistory.count) tests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func normalize(_ values: [Double]) -> [Double] {
        guard let min = values.min(), let max = values.max(), max > min else {
            return values.map { _ in 0.5 }
        }
        return values.map { ($0 - min) / (max - min) }
    }

    private func runTest() {
        isTesting = true
        Task {
            await MainActor.run { testStage = "Resolving DNS…" }
            let (dnsOK, dnsMs) = await NetworkDiagnostics.resolveDNS()

            await MainActor.run { testStage = "Measuring latency…" }
            let latency = await NetworkDiagnostics.tcpLatency()

            var download: Double?
            var upload: Double?
            if includeSpeedTest {
                await MainActor.run { testStage = "Testing download…" }
                download = await NetworkDiagnostics.downloadSpeedMbps()
                await MainActor.run { testStage = "Testing upload…" }
                upload = await NetworkDiagnostics.uploadSpeedMbps()
            }

            var publicIP: String?
            if includePublicIP {
                await MainActor.run { testStage = "Looking up public IP…" }
                publicIP = await NetworkDiagnostics.publicIPAddress()
            }

            let result = NetworkDiagnostics.Result(
                dnsMs: dnsMs, dnsSuccess: dnsOK, tcpLatencyMs: latency,
                downloadMbps: download, uploadMbps: upload, publicIP: publicIP
            )

            await MainActor.run {
                lastResult = result
                isTesting = false
                if let latency {
                    HistoryStore.shared.recordNow(MetricObservation(
                        timestamp: Date(),
                        batteryLevel: nil, isCharging: nil, thermalState: nil,
                        memoryUsedFraction: nil, memoryPressure: nil,
                        storageUsedFraction: nil, storageFreeBytes: nil,
                        networkType: network.connectionType, latencyMs: latency
                    ))
                    latencyHistory = HistoryStore.shared.recent(within: 7 * 24 * 3600).compactMap { $0.latencyMs }
                }
            }
        }
    }
}

#Preview {
    NetworkView()
}

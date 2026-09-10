//
//  MacNetworkView.swift
//  DevicePulseMac
//

import SwiftUI

struct MacNetworkView: View {
    @StateObject private var network = MacNetworkMonitor()

    @State private var isTesting = false
    @State private var testStage = ""
    @State private var result: MacNetworkTestResult?
    @State private var includeSpeedTest = false

    @State private var savedNetworks: [SavedWiFiNetwork] = []
    @State private var isLoadingSavedNetworks = true
    @State private var pendingForget: SavedWiFiNetwork?

    @State private var wifiInfo: WiFiConnectionInfo?
    @State private var wifiChecked = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Network").font(.largeTitle).bold()

                MacCard(title: "Connection", systemImage: "wifi", tint: MacSection.network.tint) {
                    HStack {
                        Image(systemName: network.isConnected ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(network.isConnected ? .green : .red)
                        Text(network.connectionType).font(.title3).bold()
                        if network.isExpensive {
                            Text("Metered").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if let interface = network.interfaceName {
                        MacInfoRow(label: "Interface", value: interface)
                    }
                }

                MacCard(title: "Local IP Addresses", systemImage: "network", tint: MacSection.network.tint) {
                    let addresses = MacNetworkMonitor.localIPAddresses()
                    if addresses.isEmpty {
                        Text("No active interface with an IPv4 address found.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(addresses, id: \.address) { entry in
                            MacInfoRow(label: entry.interface, value: entry.address)
                        }
                    }
                }

                if wifiChecked {
                    if let wifiInfo {
                        currentWiFiCard(wifiInfo)
                    } else if network.connectionType.localizedCaseInsensitiveContains("wi-fi") {
                        MacCard(title: "Current Wi-Fi", systemImage: "wifi", tint: MacSection.network.tint) {
                            Text("Connected to Wi-Fi, but macOS didn't return live signal details for the interface.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                MacCard(title: "Saved Wi-Fi Networks", systemImage: "wifi.circle", tint: MacSection.network.tint) {
                    Text("Networks this Mac remembers and will auto-join — not a scan of what's currently nearby. Read via networksetup, the same tool System Settings ▸ Wi-Fi ▸ Advanced uses.")
                        .font(.caption2).foregroundStyle(.secondary)

                    if isLoadingSavedNetworks {
                        ProgressView().controlSize(.small)
                    } else if savedNetworks.isEmpty {
                        Text("No saved networks found, or this Mac has no Wi-Fi hardware.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(savedNetworks) { net in
                                HStack {
                                    Image(systemName: "wifi").foregroundStyle(.secondary)
                                    Text(net.ssid).font(.subheadline)
                                    Spacer()
                                    Button("Forget") { pendingForget = net }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                                .padding(.vertical, 4)
                                if net.id != savedNetworks.last?.id { Divider() }
                            }
                        }
                    }
                }

                MacCard(title: "Test Connection", systemImage: "waveform.path", tint: MacSection.network.tint) {
                    Toggle("Include speed test (uses ~16 MB of data)", isOn: $includeSpeedTest)
                        .font(.subheadline)

                    Button {
                        runTest()
                    } label: {
                        if isTesting {
                            HStack { ProgressView().controlSize(.small); Text(testStage) }
                        } else {
                            Label("Test Connection", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTesting)

                    if let result {
                        Divider()
                        if result.dnsSuccess, let ms = result.dnsMs {
                            MacInfoRow(label: "DNS Resolution", value: "\(Int(ms)) ms")
                        } else {
                            MacInfoRow(label: "DNS Resolution", value: "Failed")
                        }
                        if let latency = result.tcpLatencyMs {
                            MacInfoRow(label: "Connection Latency", value: "\(Int(latency)) ms")
                        }
                        if let down = result.downloadMbps {
                            MacInfoRow(label: "Download", value: String(format: "%.1f Mbps", down))
                        }
                        if let up = result.uploadMbps {
                            MacInfoRow(label: "Upload", value: String(format: "%.1f Mbps", up))
                        }
                        Text("Latency is the median of 3 TCP-connect samples to www.apple.com:443, not ICMP ping. Speed figures use speed.cloudflare.com, with a small warm-up request first so connection setup time isn't counted as part of the measured speed.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            loadSavedNetworks()
            loadWiFiInfo()
        }
        .alert(
            pendingForget.map { "Forget \($0.ssid)?" } ?? "",
            isPresented: Binding(get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingForget = nil }
            Button("Forget", role: .destructive) {
                if let net = pendingForget { forget(net) }
                pendingForget = nil
            }
        } message: {
            Text("This Mac will no longer auto-join this network — you'd need to enter its password again to reconnect. This doesn't affect the network itself, only this Mac's memory of it.")
        }
    }

    @ViewBuilder
    private func currentWiFiCard(_ info: WiFiConnectionInfo) -> some View {
        MacCard(title: "Current Wi-Fi", systemImage: "wifi", tint: MacSection.network.tint) {
            if let ssid = info.ssid {
                MacInfoRow(label: "Network", value: ssid)
            } else if info.ssidRedacted {
                MacInfoRow(label: "Network", value: "Hidden by macOS")
            }

            if let fraction = info.signalFraction, let rssi = info.rssiDbm {
                MacUsageBar(
                    usedLabel: "\(rssi) dBm",
                    totalLabel: info.signalQuality,
                    fraction: fraction,
                    tint: MacSection.network.tint
                )
            }

            if let noise = info.noiseDbm {
                MacInfoRow(label: "Noise", value: "\(noise) dBm")
            }
            if let snr = info.snrDb {
                MacInfoRow(label: "Signal-to-Noise", value: "\(snr) dB")
            }
            if info.channel != nil {
                MacInfoRow(label: "Channel", value: channelText(info))
            }
            if let phy = info.phyMode {
                MacInfoRow(label: "Standard", value: phy)
            }
            if let rate = info.txRateMbps {
                MacInfoRow(label: "Negotiated Rate", value: "\(rate) Mbps")
            }
            if let security = info.security {
                MacInfoRow(label: "Security", value: security)
            }
            if let country = info.countryCode {
                MacInfoRow(label: "Country Code", value: country)
            }

            Text("Live values for the network you're on now, read via system_profiler (System Report ▸ Wi-Fi). Negotiated rate is the PHY link rate, not real throughput — run the connection test below for that. If the network name shows as hidden, grant Location access in System Settings ▸ Privacy & Security to reveal it.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func channelText(_ info: WiFiConnectionInfo) -> String {
        var text = info.channel.map(String.init) ?? "—"
        if let band = info.band { text += " · \(band)" }
        if let width = info.channelWidthMHz { text += " · \(width) MHz" }
        return text
    }

    private func loadWiFiInfo() {
        DispatchQueue.global(qos: .utility).async {
            let found = MacWiFiInfoMonitor.current()
            DispatchQueue.main.async {
                wifiInfo = found
                wifiChecked = true
            }
        }
    }

    private func loadSavedNetworks() {
        isLoadingSavedNetworks = true
        DispatchQueue.global(qos: .utility).async {
            let found = MacWiFiNetworksMonitor.preferredNetworks()
            DispatchQueue.main.async {
                savedNetworks = found
                isLoadingSavedNetworks = false
            }
        }
    }

    private func forget(_ network: SavedWiFiNetwork) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = MacWiFiNetworksMonitor.forget(network)
            DispatchQueue.main.async {
                if ok {
                    savedNetworks.removeAll { $0.id == network.id }
                } else {
                    loadSavedNetworks() // refresh in case it partially changed; don't claim success
                }
            }
        }
    }

    private func runTest() {
        isTesting = true
        Task {
            await MainActor.run { testStage = "Resolving DNS…" }
            let (dnsOK, dnsMs) = await MacNetworkDiagnostics.resolveDNS()

            await MainActor.run { testStage = "Measuring latency…" }
            let latency = await MacNetworkDiagnostics.tcpLatency()

            var download: Double?
            var upload: Double?
            if includeSpeedTest {
                await MainActor.run { testStage = "Testing download…" }
                download = await MacNetworkDiagnostics.downloadSpeedMbps()
                await MainActor.run { testStage = "Testing upload…" }
                upload = await MacNetworkDiagnostics.uploadSpeedMbps()
            }

            await MainActor.run {
                result = MacNetworkTestResult(dnsMs: dnsMs, dnsSuccess: dnsOK, tcpLatencyMs: latency, downloadMbps: download, uploadMbps: upload)
                isTesting = false
            }
        }
    }
}

//
//  WiFiInfoReader.swift
//  DevicePulse
//
//  Reads the name of the Wi-Fi network this iPhone is currently joined
//  to. This is the ONE piece of Wi-Fi identity iOS will hand to a
//  third-party app at all, and only under two conditions, both required:
//   1. The "Access WiFi Information" entitlement (com.apple.developer.
//      networking.wifi-info) — a capability, no manual portal step.
//   2. The user has granted this app Location "When In Use" access —
//      Apple's own gate, not something any entitlement can bypass.
//  Signal strength (RSSI/dBm), channel, and security-type detail are NOT
//  exposed by this or any other public API, regardless of permissions —
//  see NetworkDiagnostics.swift's header comment. Location is requested
//  ONLY when the user explicitly taps to reveal the network name, never
//  automatically, and is never stored, logged, or transmitted — it's
//  used only as the on-device key that unlocks NEHotspotNetwork's
//  answer, per Apple's requirement.
//

import Foundation
import CoreLocation
import NetworkExtension

struct WiFiConnectionInfo: Equatable {
    let ssid: String
    let bssid: String
    let securityLabel: String
}

/// `NEHotspotNetwork.securityType` (iOS 15+) as plain text — the raw enum
/// only distinguishes the security *category*, not a full protocol
/// string (no WPA2 vs WPA3 distinction, unlike macOS's system_profiler
/// route), which is the honest ceiling of what this API exposes.
private func securityLabel(for type: NEHotspotNetworkSecurityType) -> String {
    switch type {
    case .open: return "Open (no password)"
    case .WEP: return "WEP"
    case .personal: return "Secured (WPA/WPA2/WPA3 Personal)"
    case .enterprise: return "Secured (Enterprise)"
    case .unknown: return "Secured (type unknown)"
    @unknown default: return "Secured"
    }
}

@MainActor
final class WiFiInfoReader: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var info: WiFiConnectionInfo?
    @Published private(set) var isLoading = false
    /// Set when authorized but NEHotspotNetwork still returned nothing —
    /// e.g. not actually on Wi-Fi right now, running in the Simulator,
    /// or an MDM restriction. Distinguished from "never asked" so the UI
    /// can say so honestly instead of just showing nothing.
    @Published private(set) var lookupFailed = false

    private let locationManager = CLLocationManager()

    override init() {
        authorizationStatus = CLLocationManager().authorizationStatus
        super.init()
        locationManager.delegate = self
    }

    /// Call only from a user-initiated tap — Location access should be
    /// something the person chose to grant for this specific purpose,
    /// never requested silently on a tab appearing.
    func requestAccessAndFetch() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            fetch()
        default:
            break // denied/restricted — the view shows a Settings deep link instead
        }
    }

    func fetch() {
        isLoading = true
        lookupFailed = false
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                if let network {
                    self.info = WiFiConnectionInfo(ssid: network.ssid, bssid: network.bssid, securityLabel: securityLabel(for: network.securityType))
                } else {
                    self.info = nil
                    self.lookupFailed = true
                }
            }
        }
    }
}

extension WiFiInfoReader: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                fetch()
            }
        }
    }
}

//
//  MacRootView.swift
//  DevicePulseMac
//

import SwiftUI

enum MacSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard = "Dashboard"
    case smartCare = "Smart Care"
    case cpu = "CPU & Thermal"
    case memory = "Memory"
    case ramOptimiser = "RAM Optimiser"
    case storage = "Storage"
    case network = "Network"
    case battery = "Battery"
    case processes = "Processes"
    case startupOptimiser = "Startup Optimiser"
    case bigFiles = "Big Files Finder"
    case duplicates = "Duplicate Finder"
    case spaceMap = "Space Map"
    case diskUtility = "Disk Utility"
    case uninstaller = "Uninstaller"
    case maintenance = "Maintenance"
    case device = "Device"
    case security = "Security"
    case settings = "Settings"

    var id: String { rawValue }

    /// Sidebar navigation list, in display order, flattened from the
    /// conceptual groups below. Settings is intentionally excluded — it
    /// lives in the standard macOS Settings window (⌘,), not the
    /// sidebar, per platform convention.
    static var sidebarCases: [MacSection] { MacSectionGroup.allCases.flatMap(\.sections) }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .smartCare: return "sparkles"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .ramOptimiser: return "wand.and.stars"
        case .storage: return "internaldrive"
        case .network: return "wifi"
        case .battery: return "battery.75"
        case .processes: return "list.bullet.rectangle"
        case .startupOptimiser: return "power"
        case .bigFiles: return "doc.text.magnifyingglass"
        case .duplicates: return "doc.on.doc"
        case .spaceMap: return "square.grid.3x3"
        case .diskUtility: return "externaldrive.badge.plus"
        case .uninstaller: return "trash"
        case .maintenance: return "wrench.and.screwdriver"
        case .device: return "desktopcomputer"
        case .security: return "shield"
        case .settings: return "gearshape"
        }
    }
}

enum MacSectionGroup: String, CaseIterable, Identifiable {
    case care = "Care"
    case monitor = "Monitor"
    case storage = "Storage"
    case optimise = "Optimise"

    var id: String { rawValue }

    var sections: [MacSection] {
        switch self {
        case .care: return [.dashboard, .smartCare]
        case .monitor: return [.cpu, .memory, .network, .battery, .processes, .device, .security]
        case .storage: return [.storage, .bigFiles, .duplicates, .spaceMap, .diskUtility, .uninstaller, .maintenance]
        case .optimise: return [.ramOptimiser, .startupOptimiser]
        }
    }
}

struct MacRootView: View {
    @State private var selection: MacSection? = .dashboard
    @AppStorage(AppTheme.storageKey) private var appThemeRaw: String = AppTheme.classic.rawValue
    private var isFrosted: Bool { appThemeRaw == AppTheme.frosted.rawValue }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(MacSectionGroup.allCases) { group in
                    Section(group.rawValue.uppercased()) {
                        ForEach(group.sections) { section in
                            HStack(spacing: 10) {
                                MacIconTile(systemImage: section.icon, tint: section.tint, size: 22)
                                Text(section.rawValue)
                            }
                            .padding(.vertical, 2)
                            .tag(section)
                        }
                    }
                }
            }
            .navigationTitle("Device Pulse")
            .listStyle(.sidebar)
            .scrollContentBackground(isFrosted ? .hidden : .visible)
            .background {
                if isFrosted { FrostedBackground() }
            }
        } detail: {
            ZStack {
                if isFrosted { FrostedBackground() }
                detailView
            }
            .scrollContentBackground(isFrosted ? .hidden : .visible)
        }
        // Forcing dark here is what makes the sidebar's own vibrant
        // material (and every screen's default .primary/.secondary text)
        // render correctly against the frosted background without this
        // app having to hand-recolor text everywhere. Classic theme
        // passes `nil` through so the app just follows the system.
        .preferredColorScheme(isFrosted ? .dark : nil)
        // A single small toolbar button rather than a persistent sidebar
        // footer — Classic mode should look exactly like it did before
        // this toggle existed, with no extra chrome added to the layout.
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    appThemeRaw = isFrosted ? AppTheme.classic.rawValue : AppTheme.frosted.rawValue
                } label: {
                    Image(systemName: isFrosted ? "moon.stars.fill" : "sun.max")
                }
                .help(isFrosted ? "Switch to Classic theme" : "Switch to Frosted theme")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSection)) { notification in
            if let section = notification.object as? MacSection {
                selection = section
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        Group {
            switch selection ?? .dashboard {
            case .dashboard: MacDashboardView(selection: $selection)
            case .smartCare: MacSmartCareView()
            case .cpu: MacCPUView()
            case .memory: MacMemoryView()
            case .ramOptimiser: MacRAMOptimiserView()
            case .storage: MacStorageView()
            case .network: MacNetworkView()
            case .battery: MacBatteryView()
            case .processes: MacProcessesView()
            case .startupOptimiser: MacStartupOptimiserView()
            case .bigFiles: MacBigFilesView()
            case .duplicates: MacDuplicatesView()
            case .spaceMap: MacSpaceMapView()
            case .diskUtility: MacDiskUtilityView()
            case .uninstaller: MacUninstallerView()
            case .maintenance: MacMaintenanceView()
            case .device: MacDeviceView()
            case .security: SecurityView()
            case .settings: MacSettingsView()
            }
        }
        .id(selection)
        .transition(.opacity.combined(with: .move(edge: .leading)))
        .animation(.easeOut(duration: 0.22), value: selection)
    }
}

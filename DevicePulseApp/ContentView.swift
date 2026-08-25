//
//  ContentView.swift
//  DevicePulse
//
//  Custom bottom bar instead of a plain SwiftUI TabView: with 6 items
//  (the original 5 tabs plus the new Home dashboard), the system TabView
//  auto-folds anything past the 5th into an iOS "More" menu, which would
//  hide Network and Device behind an extra tap. This keeps all 6 directly
//  visible and preserves the original 5 tabs' identity/order.
//

import SwiftUI

enum DashboardTab: CaseIterable, Hashable {
    case home, battery, memory, storage, network, device

    var title: String {
        switch self {
        case .home: return "Home"
        case .battery: return "Battery"
        case .memory: return "Memory"
        case .storage: return "Storage"
        case .network: return "Network"
        case .device: return "Device"
        }
    }

    var icon: String {
        switch self {
        case .home: return "gauge.with.dots.needle.67percent"
        case .battery: return "battery.75"
        case .memory: return "memorychip"
        case .storage: return "internaldrive"
        case .network: return "wifi"
        case .device: return "iphone"
        }
    }
}

struct ContentView: View {
    @State private var selection: DashboardTab = .home

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            CustomTabBar(selection: $selection)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home: HomeView(selection: $selection)
        case .battery: BatteryView()
        case .memory: MemoryView()
        case .storage: StorageView()
        case .network: NetworkView()
        case .device: MoreView()
        }
    }
}

private struct CustomTabBar: View {
    @Binding var selection: DashboardTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DashboardTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20))
                        Text(tab.title)
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }
}

#Preview {
    ContentView()
}

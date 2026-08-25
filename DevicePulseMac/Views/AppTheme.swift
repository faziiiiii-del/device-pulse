//
//  AppTheme.swift
//  DevicePulseMac
//
//  App-wide appearance toggle: Classic (native macOS light/dark,
//  following the system) vs Frosted (the translucent dark-glass look).
//  Stored once in UserDefaults via `@AppStorage("appTheme")` — every
//  view that needs to branch on it reads the same key directly rather
//  than threading an ObservableObject through the whole hierarchy,
//  matching how DevicePulseSettings/MacSettingsView already handle
//  every other preference in this app.
//

import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case classic = "Classic"
    case frosted = "Frosted"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .classic: return "sun.max"
        case .frosted: return "moon.stars"
        }
    }

    static let storageKey = "appTheme"
}

/// The frosted theme's shared backdrop — a dark gradient with a few
/// softly blurred color glows behind it. Used both behind the sidebar
/// and behind every detail screen (via MacRootView), so the whole app
/// shares one consistent background rather than each screen drawing
/// its own slightly different one.
struct FrostedBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.06, blue: 0.16), Color(red: 0.10, green: 0.07, blue: 0.22), Color(red: 0.03, green: 0.11, blue: 0.17)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Circle().fill(Color.blue.opacity(0.35)).frame(width: 420, height: 420).blur(radius: 120).offset(x: -180, y: -220)
            Circle().fill(Color.purple.opacity(0.30)).frame(width: 380, height: 380).blur(radius: 120).offset(x: 220, y: -60)
            Circle().fill(Color.teal.opacity(0.22)).frame(width: 360, height: 360).blur(radius: 130).offset(x: -80, y: 300)
        }
        .ignoresSafeArea()
    }
}

/// Read this in any view that needs to branch its styling on the
/// current theme (e.g. MacDashboardView's two distinct layouts).
struct ThemeReader: DynamicProperty {
    @AppStorage(AppTheme.storageKey) private var raw: String = AppTheme.classic.rawValue
    var current: AppTheme { AppTheme(rawValue: raw) ?? .classic }
}

//
//  DevicePulseMacApp.swift
//  DevicePulseMac
//

import SwiftUI

extension Notification.Name {
    static let navigateToSection = Notification.Name("navigateToSection")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBarOnly = UserDefaults.standard.bool(forKey: "menuBarOnlyMode")
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
        MacAlertMonitor.shared.start()
    }
}

@main
struct DevicePulseMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Go") {
                ForEach(Array(MacSection.sidebarCases.prefix(9).enumerated()), id: \.element) { index, section in
                    Button(section.rawValue) {
                        NotificationCenter.default.post(name: .navigateToSection, object: section)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }

        MenuBarExtra {
            MacMenuBarContent()
        } label: {
            MacMenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView()
        }
    }
}

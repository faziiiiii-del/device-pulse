//
//  MacStartupMonitor.swift
//  DevicePulseMac
//
//  HONESTY NOTE: Modern macOS does NOT provide any public API for a
//  third-party app to enumerate other apps' System Settings ▸ General ▸
//  Login Items entries. The old LSSharedFileList login-items API is
//  deprecated and locked down; ServiceManagement's SMAppService only
//  reports status for services the calling app itself registered. So
//  this app does not — and cannot legitimately — show a full Login Items
//  list. It's honest about that limitation in the UI instead of faking one.
//
//  What IS legitimately, publicly inspectable: LaunchAgents/LaunchDaemons
//  plist files in the standard filesystem locations. These are plain
//  files any process running as the user can read. Enable/disable is
//  done via `launchctl bootout`/`bootstrap` (the standard, documented
//  command-line tool) — never by deleting or blindly editing the plist.
//

import Foundation

enum StartupItemType: String {
    case userLaunchAgent = "User LaunchAgent"
    case globalLaunchAgent = "Global LaunchAgent"
    case launchDaemon = "LaunchDaemon"
}

enum StartupClassification: String {
    case apple = "Apple"
    case knownThirdParty = "Known Third-Party"
    case userInstalled = "User-Installed"
    case unknown = "Unknown"
}

struct StartupItem: Identifiable {
    var id: String { plistPath }
    let label: String
    let plistPath: String
    let programPath: String?
    let type: StartupItemType
    let runAtLoad: Bool
    let isLoaded: Bool
    let classification: StartupClassification
}

enum MacStartupMonitor {
    private static let userAgentsDir = ("~/Library/LaunchAgents" as NSString).expandingTildeInPath
    private static let globalAgentsDir = "/Library/LaunchAgents"
    private static let daemonsDir = "/Library/LaunchDaemons"

    static func scan() -> [StartupItem] {
        var items: [StartupItem] = []
        items += scanDirectory(userAgentsDir, type: .userLaunchAgent)
        items += scanDirectory(globalAgentsDir, type: .globalLaunchAgent)
        items += scanDirectory(daemonsDir, type: .launchDaemon)
        return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private static func scanDirectory(_ path: String, type: StartupItemType) -> [StartupItem] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }

        return files.filter { $0.hasSuffix(".plist") }.compactMap { file -> StartupItem? in
            let fullPath = (path as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: fullPath),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            else { return nil }

            let label = plist["Label"] as? String ?? (file as NSString).deletingPathExtension
            let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
            let runAtLoad = plist["RunAtLoad"] as? Bool ?? false

            return StartupItem(
                label: label,
                plistPath: fullPath,
                programPath: program,
                type: type,
                runAtLoad: runAtLoad,
                isLoaded: isLoaded(label: label, type: type),
                classification: classify(label: label, program: program)
            )
        }
    }

    /// Queries the domain-specific target directly via `launchctl print`
    /// rather than grepping a single blanket `launchctl list`, which
    /// only reliably reflects the calling user's GUI domain — it can
    /// under- or over-report LaunchDaemons (system domain) and even some
    /// global LaunchAgents. `launchctl print <domain>/<label>` exits 0
    /// only if that exact service is actually loaded in that domain.
    private static func isLoaded(label: String, type: StartupItemType) -> Bool {
        let domain = domainTarget(type: type)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "\(domain)/\(label)"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private static func domainTarget(type: StartupItemType) -> String {
        switch type {
        case .userLaunchAgent, .globalLaunchAgent: return "gui/\(getuid())"
        case .launchDaemon: return "system"
        }
    }

    private static func classify(label: String, program: String?) -> StartupClassification {
        let lower = label.lowercased()
        if lower.hasPrefix("com.apple.") { return .apple }

        let knownVendors = ["com.google.", "com.microsoft.", "com.dropbox.", "com.adobe.", "com.spotify.", "com.docker.", "com.jetbrains.", "com.1password.", "com.slack.", "com.zoom.", "com.github."]
        if knownVendors.contains(where: { lower.hasPrefix($0) }) { return .knownThirdParty }

        if program != nil { return .userInstalled }
        return .unknown
    }

    /// Unloads (does not delete) a LaunchAgent/Daemon via the standard
    /// `launchctl bootout` command. Reversible with `enable`.
    static func disable(_ item: StartupItem) -> Bool {
        runLaunchctl(["bootout", "\(domainTarget(type: item.type))/\(item.label)"])
    }

    /// Reloads a LaunchAgent/Daemon via `launchctl bootstrap`, pointing at
    /// its existing plist on disk — nothing is written or deleted.
    static func enable(_ item: StartupItem) -> Bool {
        runLaunchctl(["bootstrap", domainTarget(type: item.type), item.plistPath])
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}

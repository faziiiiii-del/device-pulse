//
//  MacCrashReportMonitor.swift
//  DevicePulseMac
//
//  Reads the crash / panic / hang / resource reports macOS writes to the
//  standard DiagnosticReports folders. Everything here is a plain file
//  in a documented location — no private API. The per-user folder
//  (~/Library/Logs/DiagnosticReports) is always readable by this app;
//  the system-wide one (/Library/Logs/DiagnosticReports) needs Full Disk
//  Access for its file *contents* on modern macOS, so a failed read is
//  reported honestly with an FDA hint rather than shown as empty.
//
//  Nothing is parsed speculatively: the list is built from filenames
//  (process + timestamp + type), and a report's body is only read when
//  you open it.
//

import Foundation

enum CrashReportCategory: String, CaseIterable {
    case appCrash = "App Crashes"
    case kernelPanic = "Kernel Panics"
    case unresponsive = "Hangs & Spins"
    case resource = "CPU & Energy"
    case stall = "Shutdown & Startup Stalls"
    case other = "Other Diagnostics"

    var symbol: String {
        switch self {
        case .appCrash: return "xmark.octagon"
        case .kernelPanic: return "exclamationmark.triangle"
        case .unresponsive: return "hourglass"
        case .resource: return "bolt.badge.clock"
        case .stall: return "power"
        case .other: return "doc.text.magnifyingglass"
        }
    }

    /// Rough ordering for display — most alarming first.
    var sortRank: Int {
        switch self {
        case .kernelPanic: return 0
        case .appCrash: return 1
        case .unresponsive: return 2
        case .stall: return 3
        case .resource: return 4
        case .other: return 5
        }
    }
}

struct CrashReport: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let fileName: String
    let processName: String
    let category: CrashReportCategory
    let date: Date
    /// True for /Library/Logs/… (may need Full Disk Access to read/delete).
    let isSystemLocation: Bool
    /// True for the "Retired" archive subfolder.
    let isRetired: Bool
}

enum MacCrashReportMonitor {
    private static let userDir = ("~/Library/Logs/DiagnosticReports" as NSString).expandingTildeInPath
    private static let systemDir = "/Library/Logs/DiagnosticReports"

    /// Hard cap so a machine with thousands of stale reports can't make
    /// the scan or the list view pathological.
    private static let maxReports = 600

    struct ScanResult {
        var reports: [CrashReport]
        var truncated: Bool
        /// Set when at least one system-location file couldn't be read
        /// during a contents fetch — surfaced as an FDA hint in the UI.
        var systemLocationUnreadable: Bool
    }

    static func scan() -> ScanResult {
        var all: [CrashReport] = []
        all += scanDirectory(userDir, isSystem: false, isRetired: false)
        all += scanDirectory(userDir + "/Retired", isSystem: false, isRetired: true)
        all += scanDirectory(systemDir, isSystem: true, isRetired: false)
        all += scanDirectory(systemDir + "/Retired", isSystem: true, isRetired: true)

        all.sort { $0.date > $1.date }
        let truncated = all.count > maxReports
        if truncated { all = Array(all.prefix(maxReports)) }
        return ScanResult(reports: all, truncated: truncated, systemLocationUnreadable: false)
    }

    private static func scanDirectory(_ path: String, isSystem: Bool, isRetired: Bool) -> [CrashReport] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [] }

        return entries.compactMap { name -> CrashReport? in
            guard let category = categorize(fileName: name) else { return nil }
            let fullPath = (path as NSString).appendingPathComponent(name)

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { return nil }

            let attributes = try? fm.attributesOfItem(atPath: fullPath)
            let fileDate = (attributes?[.modificationDate] as? Date)
                ?? (attributes?[.creationDate] as? Date)
                ?? dateFromFileName(name)
                ?? .distantPast

            return CrashReport(
                path: fullPath,
                fileName: name,
                processName: processFromFileName(name),
                category: category,
                date: fileDate,
                isSystemLocation: isSystem,
                isRetired: isRetired
            )
        }
    }

    /// Returns nil for files that aren't diagnostic reports (dot-files,
    /// stray folders) so they're skipped entirely.
    private static func categorize(fileName: String) -> CrashReportCategory? {
        let lower = fileName.lowercased()
        if lower == ".ds_store" { return nil }

        if lower.hasSuffix(".panic") || lower.hasSuffix(".contents.panic") { return .kernelPanic }
        if lower.hasSuffix(".ips") || lower.hasSuffix(".crash") { return .appCrash }
        if lower.hasSuffix(".hang") || lower.hasSuffix(".spin") || lower.hasSuffix(".stackshot") { return .unresponsive }
        if lower.hasSuffix(".shutdownstall") || lower.hasSuffix(".startupstall") { return .stall }
        if lower.contains("_resource.diag") || lower.hasSuffix(".cpu_resource.diag") || lower.hasSuffix(".wakeups_resource.diag") {
            return .resource
        }
        if lower.hasSuffix(".diag") || lower.hasSuffix(".spindump.txt") { return .other }
        return nil
    }

    /// Filenames look like `Process_2026-09-10-215505_Host.diag` or
    /// `Process-2026-09-10-215505.ips`; take everything before the first
    /// date-looking segment.
    private static func processFromFileName(_ name: String) -> String {
        if let range = name.range(of: #"[_-]\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) {
            let candidate = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty { return candidate }
        }
        // Fall back to the name minus its extension.
        return (name as NSString).deletingPathExtension
    }

    private static func dateFromFileName(_ name: String) -> Date? {
        guard let range = name.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: String(name[range]))
    }

    static func counts(for reports: [CrashReport]) -> [(CrashReportCategory, Int)] {
        CrashReportCategory.allCases
            .map { category in (category, reports.filter { $0.category == category }.count) }
            .filter { $0.1 > 0 }
            .sorted { $0.0.sortRank < $1.0.sortRank }
    }

    /// Reads a report body. `.ips` files begin with a one-line JSON
    /// header followed by a JSON document — returned as-is (pretty
    /// enough to read); other formats are plain text already.
    static func contents(of report: CrashReport) -> (text: String?, permissionDenied: Bool) {
        let url = URL(fileURLWithPath: report.path)
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            return (prettifyIfIPS(raw, fileName: report.fileName), false)
        } catch {
            let nsError = error as NSError
            let denied = nsError.domain == NSCocoaErrorDomain &&
                (nsError.code == NSFileReadNoPermissionError || nsError.code == 257)
            return (nil, denied)
        }
    }

    private static func prettifyIfIPS(_ raw: String, fileName: String) -> String {
        guard fileName.lowercased().hasSuffix(".ips") else { return raw }
        let lines = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count == 2,
              let bodyData = lines[1].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bodyData),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let prettyString = String(data: pretty, encoding: .utf8)
        else { return raw }
        return "\(lines[0])\n\n\(prettyString)"
    }

    /// Moves a report to the Trash (reversible). Returns false without
    /// side effects if the OS refuses — typically a system-location file
    /// without Full Disk Access / privileges.
    @discardableResult
    static func moveToTrash(_ report: CrashReport) -> Bool {
        let url = URL(fileURLWithPath: report.path)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }
}

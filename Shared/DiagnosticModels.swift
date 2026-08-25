//
//  DiagnosticModels.swift
//  Shared (macOS target only for now)
//
//  There is deliberately no single blended "health score" anywhere in
//  Device Pulse. Every check reports PASS / WARNING / INFO / UNAVAILABLE
//  with the exact threshold that produced it, and UNAVAILABLE is used
//  whenever a metric genuinely cannot be read — never a fabricated 0.
//

import Foundation

enum DiagnosticStatus: String {
    case pass = "Normal"
    case warning = "Warning"
    case info = "Information"
    case unavailable = "Unavailable"
}

struct DiagnosticCheck: Identifiable {
    let id = UUID()
    let name: String
    let status: DiagnosticStatus
    let detail: String
}

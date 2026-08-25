//
//  StatusUI.swift
//  Shared (macOS target only for now)
//

import SwiftUI

enum StatusLevel {
    case good, warning, bad, neutral

    var color: Color {
        switch self {
        case .good: return .green
        case .warning: return .yellow
        case .bad: return .red
        case .neutral: return .secondary
        }
    }

    init(diagnostic status: DiagnosticStatus) {
        switch status {
        case .pass: self = .good
        case .warning: self = .warning
        case .info, .unavailable: self = .neutral
        }
    }
}

struct StatusDot: View {
    let level: StatusLevel

    @State private var pulse = false

    private var isAttentionLevel: Bool { level == .bad || level == .warning }

    var body: some View {
        Circle()
            .fill(level.color)
            .frame(width: 9, height: 9)
            .shadow(color: level.color.opacity(isAttentionLevel && pulse ? 0.7 : 0), radius: pulse ? 5 : 0)
            .scaleEffect(isAttentionLevel && pulse ? 1.25 : 1)
            .onAppear {
                guard isAttentionLevel else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

struct StatusBadge: View {
    let status: DiagnosticStatus

    private var color: Color { StatusLevel(diagnostic: status).color }

    @State private var appeared = false

    var body: some View {
        Text(status.rawValue.uppercased())
            .font(.caption2).bold()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .scaleEffect(appeared ? 1 : 0.85)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { appeared = true }
            }
    }
}

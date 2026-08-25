//
//  Components.swift
//  DevicePulse
//
//  Shared card/gauge/label views used across the tabs.
//

import SwiftUI

struct StatCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct UsageBar: View {
    let usedLabel: String
    let totalLabel: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.tertiarySystemFill))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tint)
                        .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 12)

            HStack {
                Text(usedLabel).font(.caption).bold()
                Text(totalLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RingGauge: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.tertiarySystemFill), lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct MiniStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline).bold()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
}

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
        case .info: self = .neutral
        case .unavailable: self = .neutral
        }
    }
}

struct StatusDot: View {
    let level: StatusLevel

    var body: some View {
        Circle()
            .fill(level.color)
            .frame(width: 10, height: 10)
    }
}

struct StatusBadge: View {
    let status: DiagnosticStatus

    private var color: Color { StatusLevel(diagnostic: status).color }

    var body: some View {
        Text(status.rawValue.uppercased())
            .font(.caption2).bold()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

/// Tappable overview card used on the Home dashboard. Shows a title, a
/// headline value, a colored status dot, and a chevron implying navigation.
struct OverviewCard: View {
    let title: String
    let systemImage: String
    let value: String
    let subtitle: String
    let level: StatusLevel
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.subheadline).foregroundStyle(.secondary)
                        StatusDot(level: level)
                    }
                    Text(value).font(.title3).bold()
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

/// Simple, dependency-free line sparkline for a series of Doubles in 0...1.
struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                Path { path in
                    let stepX = geo.size.width / CGFloat(values.count - 1)
                    for (index, value) in values.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = geo.size.height * (1 - CGFloat(min(max(value, 0), 1)))
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            } else {
                Text("Not enough data yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DisclaimerCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What this app can't do, and why")
                .font(.caption).bold()
            Text("iOS sandboxes every app. No App Store app — including this one — can read battery health/cycle count, see Wi-Fi signal strength, list what other apps are using memory or storage, or clear caches outside its own container. Apps that claim otherwise on a non-jailbroken iPhone are not doing what they say.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

//
//  MacComponents.swift
//  DevicePulseMac
//

import SwiftUI

/// Subtle lift + tinted glow on hover, used by cards throughout the app.
struct MacHoverLift: ViewModifier {
    var tint: Color
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovering ? 1.012 : 1)
            .shadow(color: tint.opacity(isHovering ? 0.22 : 0), radius: isHovering ? 14 : 0, y: isHovering ? 6 : 0)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    func macHoverLift(tint: Color) -> some View { modifier(MacHoverLift(tint: tint)) }
}

/// Scales down slightly on press, used by tappable cards/buttons.
struct MacPressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

struct MacCard<Content: View>: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    @ViewBuilder var content: Content

    private var theme = ThemeReader()
    private var isFrosted: Bool { theme.current == .frosted }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MacIconTile(systemImage: systemImage, tint: tint, size: 26)
                Text(title).font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderColor, lineWidth: 1))
        .macHoverLift(tint: tint)
    }

    @ViewBuilder private var cardBackground: some View {
        if isFrosted {
            Rectangle().fill(.ultraThinMaterial)
        } else {
            Color(nsColor: .controlBackgroundColor)
        }
    }

    private var borderColor: Color {
        isFrosted ? Color.white.opacity(0.12) : Color(nsColor: .separatorColor)
    }
}

struct MacUsageBar: View {
    let usedLabel: String
    let totalLabel: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
                        .animation(.easeInOut(duration: 0.5), value: fraction)
                }
            }
            .frame(height: 10)

            HStack {
                Text(usedLabel).font(.caption).bold()
                Text(totalLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Compact ring for a single tier-based (not continuously-numeric) stat
/// — e.g. connection up/down, a status level — where a sparkline would
/// have nothing meaningful to plot. No center label, sized for sitting
/// inside a small stat card alongside a text value.
struct MacMiniRing: View {
    let fraction: Double
    let tint: Color
    var size: CGFloat = 30
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: fraction)
        }
        .frame(width: size, height: size)
    }
}

struct MacMiniStat: View {
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

struct MacInfoRow: View {
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

private struct MacSparkShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let stepX = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let x = CGFloat(index) * stepX
            let y = rect.height * (1 - CGFloat(min(max(value, 0), 1)))
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

struct MacSparkline: View {
    let values: [Double]
    let tint: Color

    @State private var didAppear = false

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                MacSparkShape(values: values)
                    .trim(from: 0, to: didAppear ? 1 : 0)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.7)) { didAppear = true }
                    }
            } else {
                Text("Collecting data…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MacOverviewCard: View {
    let title: String
    let systemImage: String
    let value: String
    let subtitle: String
    let level: StatusLevel
    var tint: Color = .accentColor
    var action: () -> Void

    private var theme = ThemeReader()
    private var isFrosted: Bool { theme.current == .frosted }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                MacIconTile(systemImage: systemImage, tint: tint, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.subheadline).foregroundStyle(.secondary)
                        StatusDot(level: level)
                    }
                    Text(value).font(.title3).bold()
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor, lineWidth: 1))
            .macHoverLift(tint: tint)
        }
        .buttonStyle(MacPressableButtonStyle())
    }

    @ViewBuilder private var cardBackground: some View {
        if isFrosted {
            Rectangle().fill(.ultraThinMaterial)
        } else {
            Color(nsColor: .controlBackgroundColor)
        }
    }

    private var borderColor: Color {
        isFrosted ? Color.white.opacity(0.12) : Color(nsColor: .separatorColor)
    }
}

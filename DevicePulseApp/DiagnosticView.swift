//
//  DiagnosticView.swift
//  DevicePulse
//

import SwiftUI

struct DiagnosticView: View {
    @State private var includeSpeedTest = false
    @State private var isRunning = false
    @State private var checks: [DiagnosticCheck] = []
    @State private var hasRun = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StatCard(title: "Full Diagnostic", systemImage: "stethoscope") {
                    Toggle("Include speed test (uses several MB of data)", isOn: $includeSpeedTest)
                        .font(.subheadline)

                    Button {
                        run()
                    } label: {
                        if isRunning {
                            HStack {
                                ProgressView()
                                Text("Running…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label(hasRun ? "Run Again" : "Run Diagnostic", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)
                }

                if hasRun {
                    ForEach(checks) { check in
                        StatCard(title: check.name, systemImage: iconFor(check.status)) {
                            HStack {
                                StatusBadge(status: check.status)
                                Spacer()
                            }
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Diagnostic")
    }

    private func run() {
        isRunning = true
        Task {
            let results = await DiagnosticsEngine.fullDiagnostic(includeSpeedTest: includeSpeedTest)
            await MainActor.run {
                checks = results
                isRunning = false
                hasRun = true
            }
        }
    }

    private func iconFor(_ status: DiagnosticStatus) -> String {
        switch status {
        case .pass: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .info: return "info.circle"
        case .unavailable: return "questionmark.circle"
        }
    }
}

#Preview {
    NavigationStack { DiagnosticView() }
}

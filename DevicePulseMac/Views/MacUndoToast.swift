//
//  MacUndoToast.swift
//  DevicePulseMac
//

import SwiftUI

struct MacUndoToast: View {
    let message: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.subheadline)
            Spacer()
            Button("Undo", action: onUndo)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 8, y: 2)
        .padding()
        .frame(maxWidth: 420)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Holds the most recent trash operation for a screen and auto-dismisses
/// its undo toast after a few seconds.
final class UndoToastState: ObservableObject {
    @Published var records: [TrashRecord] = []
    @Published var message: String = ""
    private var dismissWorkItem: DispatchWorkItem?
    private var onUndo: (() -> Void)?

    func show(records: [TrashRecord], message: String, onUndo: (() -> Void)? = nil) {
        guard !records.isEmpty else { return }
        self.records = records
        self.message = message
        self.onUndo = onUndo
        scheduleDismiss()
    }

    func undo() {
        MacTrashUndo.restore(records)
        onUndo?()
        dismiss()
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        records = []
    }

    private func scheduleDismiss() {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.records = [] }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}

extension View {
    func undoToast(_ state: UndoToastState) -> some View {
        overlay(alignment: .bottom) {
            if !state.records.isEmpty {
                MacUndoToast(message: state.message, onUndo: state.undo, onDismiss: state.dismiss)
                    .animation(.easeInOut(duration: 0.2), value: state.records.count)
            }
        }
    }
}

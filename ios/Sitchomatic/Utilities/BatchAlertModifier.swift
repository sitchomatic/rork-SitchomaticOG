import SwiftUI
import UIKit

struct BatchAlertModifier: ViewModifier {
    @Binding var showBatchResult: Bool
    let batchResult: BatchResult?
    let onDismissBatch: () -> Void
    @Binding var isRunning: Bool

    func body(content: Content) -> some View {
        content
            .alert("Batch Results", isPresented: $showBatchResult) {
                Button("OK") { onDismissBatch() }
            } message: {
                if let result = batchResult {
                    Text("Alive: \(result.working) (\(result.alivePercentage)%)\nDead: \(result.dead)\nRequeued: \(result.requeued)\nTotal: \(result.total)")
                } else {
                    Text("No results available")
                }
            }
            .onChange(of: isRunning) { _, newValue in
                UIApplication.shared.isIdleTimerDisabled = newValue
            }
    }
}

extension View {
    func withBatchAlerts(
        showBatchResult: Binding<Bool>,
        batchResult: BatchResult?,
        isRunning: Binding<Bool>,
        onDismissBatch: @escaping () -> Void
    ) -> some View {
        modifier(BatchAlertModifier(
            showBatchResult: showBatchResult,
            batchResult: batchResult,
            onDismissBatch: onDismissBatch,
            isRunning: isRunning
        ))
    }
}

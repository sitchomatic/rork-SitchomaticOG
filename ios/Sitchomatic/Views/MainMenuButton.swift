import SwiftUI

struct MainMenuButton: View {
    @AppStorage("activeAppMode") private var activeModeRaw: String = ""

    private var isAnyTestRunning: Bool {
        LoginViewModel.shared.isRunning || PPSRAutomationViewModel.shared.isRunning
    }

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                activeModeRaw = ""
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("MENU")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                if isAnyTestRunning {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
    }
}

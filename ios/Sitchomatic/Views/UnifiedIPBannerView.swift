import SwiftUI

struct UnifiedIPBannerView: View {
    private let deviceProxy = DeviceProxyService.shared
    @State private var tick: Int = 0
    @State private var tickTimer: Timer?

    var body: some View {
        if deviceProxy.ipRoutingMode == .appWideUnited && deviceProxy.isActive {
            HStack(spacing: 8) {
                Circle()
                    .fill(bannerColor)
                    .frame(width: 6, height: 6)

                Image(systemName: "shield.checkered")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(bannerColor)

                Text("United IP")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(bannerColor)

                if let label = deviceProxy.activeEndpointLabel {
                    Text(label)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer()

                if deviceProxy.rotationInterval != .everyBatch {
                    let _ = tick
                    HStack(spacing: 3) {
                        Image(systemName: "timer")
                            .font(.system(size: 8, weight: .bold))
                        Text(deviceProxy.rotationCountdownLabel)
                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    }
                    .foregroundStyle(.orange)
                } else {
                    Text("BATCH")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.8))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(bannerColor.opacity(0.08))
            .background(.ultraThinMaterial)
            .onAppear {
                tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                    Task { @MainActor in tick += 1 }
                }
            }
            .onDisappear { tickTimer?.invalidate() }
        }
    }

    private var bannerColor: Color {
        if deviceProxy.isRotating { return .yellow }
        if deviceProxy.isActive { return .cyan }
        return .red
    }
}

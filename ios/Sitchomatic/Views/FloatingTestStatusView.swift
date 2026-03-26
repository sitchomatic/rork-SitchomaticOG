import SwiftUI

struct FloatingTestStatusView: View {
    @State private var loginVM = LoginViewModel.shared
    @State private var ppsrVM = PPSRAutomationViewModel.shared
    @State private var isExpanded: Bool = false
    @State private var counterPulse: Bool = false
    @State private var lastCompletedCount: Int = 0

    private var isLoginRunning: Bool { loginVM.isRunning }
    private var isPPSRRunning: Bool { ppsrVM.isRunning }
    private var isAnyRunning: Bool { isLoginRunning || isPPSRRunning }

    private var statusColor: Color {
        if loginVM.isStopping { return .red }
        if loginVM.isPaused { return .orange }
        return .green
    }

    private var siteIcon: String {
        if isLoginRunning {
            switch loginVM.siteMode {
            case .joe: return "suit.spade.fill"
            case .double: return "arrow.triangle.branch"
            case .ignition: return "flame.fill"
            }
        }
        return "bolt.shield.fill"
    }

    private var siteColor: Color {
        if isLoginRunning {
            switch loginVM.siteMode {
            case .joe: return .green
            case .double: return .cyan
            case .ignition: return .orange
            }
        }
        return .teal
    }

    private var completedCount: Int {
        isLoginRunning ? loginVM.batchCompletedCount : ppsrVM.batchCompletedCount
    }

    private var totalCount: Int {
        isLoginRunning ? loginVM.batchTotalCount : ppsrVM.batchTotalCount
    }

    private var workingCount: Int {
        guard isLoginRunning else { return 0 }
        return loginVM.attempts.filter { $0.status.isTerminal && $0.credential.status == .working }.count
    }

    private var noAccCount: Int {
        guard isLoginRunning else { return 0 }
        return loginVM.attempts.filter { $0.status.isTerminal && $0.credential.status == .noAcc }.count
    }

    private var tempDisCount: Int {
        guard isLoginRunning else { return 0 }
        return loginVM.attempts.filter { $0.status.isTerminal && $0.credential.status == .tempDisabled }.count
    }

    private var permDisCount: Int {
        guard isLoginRunning else { return 0 }
        return loginVM.attempts.filter { $0.status.isTerminal && $0.credential.status == .permDisabled }.count
    }

    private var elapsedString: String {
        guard let start = loginVM.batchStartTime else { return "--" }
        let elapsed = Date().timeIntervalSince(start)
        let mins = Int(elapsed) / 60
        let secs = Int(elapsed) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private var etaString: String {
        guard let start = loginVM.batchStartTime, completedCount > 0 else { return "--" }
        let elapsed = Date().timeIntervalSince(start)
        let rate = elapsed / Double(completedCount)
        let remaining = rate * Double(max(0, totalCount - completedCount))
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        return String(format: "~%d:%02d", mins, secs)
    }

    var body: some View {
        if isAnyRunning {
            VStack(alignment: .trailing, spacing: 0) {
                if isExpanded {
                    expandedCard
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity),
                            removal: .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity)
                        ))
                }

                pillView
            }
            .padding(.trailing, 12)
            .padding(.top, 4)
            .onChange(of: completedCount) { oldVal, newVal in
                if newVal > oldVal {
                    withAnimation(.spring(duration: 0.2)) {
                        counterPulse = true
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        await MainActor.run {
                            withAnimation(.spring(duration: 0.2)) {
                                counterPulse = false
                            }
                        }
                    }
                }
            }
        }
    }

    private var pillView: some View {
        Button {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.6), radius: 4)

                Image(systemName: siteIcon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(siteColor)

                Text("\(completedCount)/\(totalCount)")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                    .scaleEffect(counterPulse ? 1.15 : 1.0)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .background(siteColor.opacity(0.15))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(siteColor.opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: isExpanded)
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: siteIcon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(siteColor)
                Text(isLoginRunning ? loginVM.batchSiteLabel : "PPSR")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                statusBadge
            }

            HStack(spacing: 8) {
                statColumn(value: "\(workingCount)", label: "WORK", color: .green)
                statColumn(value: "\(noAccCount)", label: "NO ACC", color: .red)
                statColumn(value: "\(tempDisCount)", label: "TEMP", color: .orange)
                statColumn(value: "\(permDisCount)", label: "PERM", color: .purple)
            }

            HStack(spacing: 12) {
                statColumn(value: elapsedString, label: "TIME", color: .white)
                statColumn(value: etaString, label: "ETA", color: .white.opacity(0.7))
            }

            ProgressView(value: Double(completedCount), total: max(1, Double(totalCount)))
                .tint(siteColor)

            Button {
                navigateToSession()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 9, weight: .bold))
                    Text("VIEW SESSIONS")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(siteColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(siteColor.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 200)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.3))
        .clipShape(.rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(siteColor.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .padding(.bottom, 4)
    }

    private var statusBadge: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
            Text(loginVM.isStopping ? "STOPPING" : (loginVM.isPaused ? "PAUSED" : "LIVE"))
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusColor.opacity(0.12))
        .clipShape(Capsule())
    }

    private func statColumn(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func navigateToSession() {
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
            isExpanded = false
        }
        if isLoginRunning {
            UserDefaults.standard.set(ActiveAppMode.unifiedSession.rawValue, forKey: "activeAppMode")
        } else if isPPSRRunning {
            UserDefaults.standard.set(ActiveAppMode.ppsr.rawValue, forKey: "activeAppMode")
        }
    }
}

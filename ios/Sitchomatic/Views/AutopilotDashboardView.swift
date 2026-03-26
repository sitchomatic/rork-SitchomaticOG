import SwiftUI
import Combine

struct AutopilotDashboardView: View {
    private let autopilot = AISessionAutopilotEngine.shared

    @State private var refreshTrigger: Int = 0
    @State private var selectedMode: AutopilotMode = AISessionAutopilotEngine.shared.mode
    @State private var showResetConfirmation: Bool = false

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                autopilotStatusCard
                modeSelector
                threatGauge
                liveSessionsSection
                globalStatsSection
                reflexPerformanceSection
                actionBreakdownSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("AI Autopilot")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showResetConfirmation = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.subheadline)
                }
            }
        }
        .confirmationDialog("Reset Autopilot Stats", isPresented: $showResetConfirmation) {
            Button("Reset All Stats", role: .destructive) {
                autopilot.resetStats()
                refreshTrigger += 1
            }
            Button("Cancel", role: .cancel) {}
        }
        .onReceive(timer) { _ in
            refreshTrigger += 1
            selectedMode = autopilot.mode
        }
    }

    private var autopilotStatusCard: some View {
        let _ = refreshTrigger
        let isActive = autopilot.isEnabled
        let sessions = autopilot.activeSessionCount
        let threat = autopilot.globalThreatLevel

        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(isActive ? statusColor(threat: threat).opacity(0.15) : Color(.tertiarySystemFill))
                    .frame(width: 56, height: 56)
                Image(systemName: isActive ? "brain.head.profile.fill" : "brain.head.profile")
                    .font(.title2)
                    .foregroundStyle(isActive ? statusColor(threat: threat) : .secondary)
                    .symbolEffect(.pulse, isActive: isActive && sessions > 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(isActive ? "Autopilot Active" : "Autopilot Off")
                    .font(.headline)
                    .foregroundStyle(isActive ? .primary : .secondary)

                if isActive {
                    Text("\(sessions) live session\(sessions == 1 ? "" : "s") \u{2022} Threat: \(String(format: "%.0f%%", threat * 100))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Enable to activate real-time AI copilot")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if isActive && sessions > 0 {
                VStack(spacing: 2) {
                    Text("\(autopilot.globalStats.totalInterventions)")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(statusColor(threat: threat))
                    Text("actions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Autopilot Mode")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach([AutopilotMode.off, .passive, .active, .aggressive], id: \.rawValue) { mode in
                    Button {
                        selectedMode = mode
                        autopilot.setMode(mode)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: modeIcon(mode))
                                .font(.callout)
                            Text(mode.rawValue.capitalized)
                                .font(.caption2.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selectedMode == mode ? modeColor(mode).opacity(0.15) : Color(.tertiarySystemFill))
                        .foregroundStyle(selectedMode == mode ? modeColor(mode) : .secondary)
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(selectedMode == mode ? modeColor(mode).opacity(0.4) : .clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(modeDescription(selectedMode))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private var threatGauge: some View {
        let _ = refreshTrigger
        let threat = autopilot.globalThreatLevel
        let stats = autopilot.globalStats

        return VStack(spacing: 12) {
            HStack {
                Text("Threat Level")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(threatLabel(threat))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusColor(threat: threat))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor(threat: threat).opacity(0.12))
                    .clipShape(Capsule())
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.quaternarySystemFill))
                        .frame(height: 8)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.green, .yellow, .orange, .red],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * threat, height: 8)
                        .animation(.spring(duration: 0.5), value: threat)
                }
            }
            .frame(height: 8)

            HStack(spacing: 0) {
                statPill(label: "Signals", value: "\(stats.totalSignalsProcessed)", icon: "antenna.radiowaves.left.and.right")
                Spacer()
                statPill(label: "Decisions", value: "\(stats.totalDecisionsMade)", icon: "brain")
                Spacer()
                statPill(label: "Preemptive", value: "\(stats.totalPreemptiveActions)", icon: "bolt.shield.fill")
                Spacer()
                statPill(label: "Avg Latency", value: "\(Int(stats.avgDecisionLatencyMs))ms", icon: "timer")
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private var liveSessionsSection: some View {
        let _ = refreshTrigger
        let sessions = autopilot.allActiveSessions()

        return Group {
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundStyle(.cyan)
                        Text("Live Sessions")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(sessions.count)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ForEach(sessions.prefix(8), id: \.sessionId) { session in
                        liveSessionRow(session)
                    }
                }
                .padding(16)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 16))
            }
        }
    }

    private func liveSessionRow(_ session: AutopilotSessionState) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor(threat: session.threatLevel))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.host)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(session.signalHistory.count) signals")
                    Text("\u{2022}")
                    Text("\(session.totalInterventions) actions")
                    Text("\u{2022}")
                    Text("\(session.sessionDurationMs / 1000)s")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Text("\(Int(session.threatLevel * 100))%")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(statusColor(threat: session.threatLevel))
        }
    }

    private var globalStatsSection: some View {
        let _ = refreshTrigger
        let stats = autopilot.globalStats
        let successRate = stats.totalInterventions > 0
            ? Double(stats.successfulInterventions) / Double(stats.successfulInterventions + stats.failedInterventions)
            : 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.xaxis.ascending")
                    .foregroundStyle(.purple)
                Text("Global Performance")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                metricCard(title: "Sessions Monitored", value: "\(stats.totalSessionsMonitored)", icon: "eye.fill", color: .blue)
                metricCard(title: "Intervention Rate", value: String(format: "%.1f%%", stats.totalDecisionsMade > 0 ? Double(stats.totalInterventions) / Double(stats.totalDecisionsMade) * 100 : 0), icon: "hand.raised.fill", color: .orange)
                metricCard(title: "Success Rate", value: String(format: "%.0f%%", successRate * 100), icon: "checkmark.circle.fill", color: .green)
                metricCard(title: "Avg Decision", value: "\(Int(stats.avgDecisionLatencyMs))ms", icon: "bolt.fill", color: .yellow)
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private var reflexPerformanceSection: some View {
        let _ = refreshTrigger
        let reflexStats = autopilot.reflexSystem.reflexStats()

        return Group {
            if !reflexStats.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                            .foregroundStyle(.red)
                        Text("Reflex Performance")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }

                    ForEach(reflexStats.prefix(6), id: \.action) { stat in
                        HStack {
                            Text(stat.action.replacingOccurrences(of: "preemptive", with: "pre."))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)

                            Spacer()

                            Text("\(stat.totalFirings)x")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)

                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color(.quaternarySystemFill))
                                    .frame(width: 50, height: 6)
                                Capsule()
                                    .fill(stat.successRate > 0.7 ? .green : stat.successRate > 0.4 ? .orange : .red)
                                    .frame(width: 50 * stat.successRate, height: 6)
                            }

                            Text("\(Int(stat.successRate * 100))%")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(stat.successRate > 0.7 ? .green : stat.successRate > 0.4 ? .orange : .red)
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                }
                .padding(16)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 16))
            }
        }
    }

    private var actionBreakdownSection: some View {
        let _ = refreshTrigger
        let stats = autopilot.globalStats
        let topActions = stats.actionTypeFrequency.sorted { $0.value > $1.value }.prefix(8)

        return Group {
            if !topActions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "list.bullet.circle.fill")
                            .foregroundStyle(.mint)
                        Text("Action Breakdown")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }

                    let maxCount = topActions.first?.value ?? 1
                    ForEach(Array(topActions), id: \.key) { action, count in
                        HStack(spacing: 10) {
                            Image(systemName: actionIcon(action))
                                .font(.caption)
                                .foregroundStyle(actionColor(action))
                                .frame(width: 20)

                            Text(formatActionName(action))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)

                            Spacer()

                            GeometryReader { proxy in
                                Capsule()
                                    .fill(actionColor(action).opacity(0.3))
                                    .frame(width: proxy.size.width * Double(count) / Double(maxCount))
                            }
                            .frame(width: 60, height: 6)

                            Text("\(count)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                }
                .padding(16)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 16))
            }
        }
    }

    private func statPill(label: String, value: String, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func metricCard(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.06))
        .clipShape(.rect(cornerRadius: 10))
    }

    private func statusColor(threat: Double) -> Color {
        if threat < 0.25 { return .green }
        if threat < 0.5 { return .yellow }
        if threat < 0.75 { return .orange }
        return .red
    }

    private func threatLabel(_ threat: Double) -> String {
        if threat < 0.15 { return "CLEAR" }
        if threat < 0.35 { return "LOW" }
        if threat < 0.55 { return "MODERATE" }
        if threat < 0.75 { return "HIGH" }
        return "CRITICAL"
    }

    private func modeIcon(_ mode: AutopilotMode) -> String {
        switch mode {
        case .off: return "moon.fill"
        case .passive: return "eye.fill"
        case .active: return "brain.fill"
        case .aggressive: return "bolt.circle.fill"
        }
    }

    private func modeColor(_ mode: AutopilotMode) -> Color {
        switch mode {
        case .off: return .secondary
        case .passive: return .blue
        case .active: return .purple
        case .aggressive: return .red
        }
    }

    private func modeDescription(_ mode: AutopilotMode) -> String {
        switch mode {
        case .off: return "Autopilot disabled. Sessions run without AI copilot."
        case .passive: return "Monitors signals and adjusts typing/timing only. No proxy or identity changes."
        case .active: return "Full real-time copilot. Preemptive proxy/fingerprint rotation when threats detected."
        case .aggressive: return "Maximum intervention. Will abort sessions and reset identities to prevent detection."
        }
    }

    private func actionIcon(_ action: String) -> String {
        if action.contains("Proxy") || action.contains("IP") { return "network" }
        if action.contains("Fingerprint") || action.contains("Counter") { return "fingerprint" }
        if action.contains("Typing") || action.contains("SlowDown") || action.contains("SpeedUp") { return "keyboard" }
        if action.contains("DNS") { return "lock.shield.fill" }
        if action.contains("Throttle") || action.contains("Pause") { return "pause.circle.fill" }
        if action.contains("Cookie") { return "trash.fill" }
        if action.contains("Session") { return "arrow.clockwise" }
        if action.contains("Abort") { return "xmark.octagon.fill" }
        if action.contains("URL") { return "arrow.triangle.2.circlepath" }
        if action.contains("Pattern") { return "shuffle" }
        if action.contains("AI") { return "brain" }
        return "gearshape.fill"
    }

    private func actionColor(_ action: String) -> Color {
        if action.contains("Proxy") || action.contains("IP") { return .orange }
        if action.contains("Fingerprint") || action.contains("Counter") { return .pink }
        if action.contains("Typing") || action.contains("SlowDown") { return .blue }
        if action.contains("DNS") { return .indigo }
        if action.contains("Throttle") { return .yellow }
        if action.contains("Abort") { return .red }
        if action.contains("Cookie") { return .brown }
        return .purple
    }

    private func formatActionName(_ action: String) -> String {
        var name = action
        name = name.replacingOccurrences(of: "preemptive", with: "Pre.")
        let result = name.unicodeScalars.reduce("") { acc, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar) && !acc.isEmpty {
                return acc + " " + String(scalar)
            }
            return acc + String(scalar)
        }
        return result.prefix(1).uppercased() + result.dropFirst()
    }
}

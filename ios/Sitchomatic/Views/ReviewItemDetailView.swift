import SwiftUI

struct ReviewItemDetailView: View {
    let item: ReviewItem
    let vm: ReviewQueueViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            confidenceSection
            signalBreakdownSection
            networkSection
            screenshotSection
            logsSection
            replaySection

            if !item.isResolved {
                actionButtons
            }
        }
    }

    private var confidenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("CONFIDENCE ANALYSIS")

            HStack(spacing: 0) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 8)
                        Capsule()
                            .fill(confidenceGradient)
                            .frame(width: geo.size.width * item.confidence, height: 8)
                    }
                }
                .frame(height: 8)

                Text("\(Int(item.confidence * 100))%")
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .foregroundStyle(confidenceColor)
                    .frame(width: 44, alignment: .trailing)
            }

            Text(item.reasoning)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(3)
        }
    }

    private var confidenceGradient: LinearGradient {
        if item.confidence < 0.4 {
            return LinearGradient(colors: [.red, .red.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
        }
        if item.confidence < 0.6 {
            return LinearGradient(colors: [.orange, .yellow.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
        }
        return LinearGradient(colors: [.yellow, .green.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
    }

    private var confidenceColor: Color {
        if item.confidence < 0.4 { return .red }
        if item.confidence < 0.6 { return .orange }
        return .yellow
    }

    private var signalBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("SIGNAL BREAKDOWN (\(item.signalBreakdown.count))")

            ForEach(Array(item.signalBreakdown.enumerated()), id: \.offset) { _, signal in
                HStack(spacing: 8) {
                    signalIcon(signal.source)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(signal.source)
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(signal.detail)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(String(format: "%.2f", signal.weightedScore))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(signalScoreColor(signal.weightedScore))
                        Text("w:\(String(format: "%.0f%%", signal.weight * 100))")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
                .padding(6)
                .background(Color.white.opacity(0.03))
                .clipShape(.rect(cornerRadius: 6))
            }
        }
    }

    private func signalIcon(_ source: String) -> some View {
        let icon: String
        let color: Color
        if source.contains("SUCCESS") {
            icon = "checkmark.circle.fill"; color = .green
        } else if source.contains("INCORRECT") || source.contains("DISABLED") {
            icon = "xmark.circle.fill"; color = .red
        } else if source.contains("OCR") {
            icon = "eye.fill"; color = .cyan
        } else if source.contains("URL") {
            icon = "link"; color = .blue
        } else if source.contains("AI") {
            icon = "brain.head.profile"; color = .purple
        } else if source.contains("TIMING") {
            icon = "clock"; color = .orange
        } else if source.contains("HTTP") {
            icon = "network"; color = .teal
        } else if source.contains("DOM") {
            icon = "doc.text"; color = .indigo
        } else if source.contains("TEMP") {
            icon = "clock.badge.exclamationmark"; color = .orange
        } else if source.contains("SMS") {
            icon = "message.fill"; color = .cyan
        } else {
            icon = "questionmark.circle"; color = .gray
        }

        return Image(systemName: icon)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .frame(width: 16)
    }

    private func signalScoreColor(_ score: Double) -> Color {
        if score > 0.15 { return .green }
        if score > 0.05 { return .yellow }
        return .white.opacity(0.4)
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("NETWORK & URL")

            HStack(spacing: 12) {
                infoPill(label: "MODE", value: item.networkMode)
                if let server = item.vpnServer {
                    infoPill(label: "SERVER", value: server)
                }
                if let ip = item.vpnIP {
                    infoPill(label: "IP", value: ip)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                Text(item.testedURL)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
    }

    private func infoPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.25))
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private var screenshotSection: some View {
        Group {
            if !item.screenshotIds.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("SCREENSHOTS (\(item.screenshotIds.count))")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(item.screenshotIds, id: \.self) { ssId in
                                if let image = vm.screenshot(for: ssId) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 120, height: 80)
                                        .clipShape(.rect(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                                        )
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.white.opacity(0.05))
                                        .frame(width: 120, height: 80)
                                        .overlay {
                                            Image(systemName: "photo")
                                                .font(.system(size: 16))
                                                .foregroundStyle(.white.opacity(0.2))
                                        }
                                }
                            }
                        }
                    }
                    .contentMargins(.horizontal, 0)
                }
            }
        }
    }

    private var logsSection: some View {
        Group {
            if !item.logs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("LOGS (\(item.logs.count))")

                    ForEach(item.logs.prefix(8)) { log in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(logLevelColor(log.level))
                                .frame(width: 4, height: 4)
                            Text(log.message)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }

                    if item.logs.count > 8 {
                        Text("+ \(item.logs.count - 8) more entries")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
            }
        }
    }

    private func logLevelColor(_ level: PPSRLogEntry.Level) -> Color {
        switch level {
        case .error: .red
        case .warning: .orange
        case .success: .green
        case .info: .blue
        }
    }

    private var replaySection: some View {
        Group {
            if let replay = item.replayLog {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("SESSION REPLAY")

                    HStack(spacing: 12) {
                        infoPill(label: "DURATION", value: "\(replay.totalDurationMs)ms")
                        infoPill(label: "EVENTS", value: "\(replay.events.count)")
                        infoPill(label: "OUTCOME", value: replay.outcome)
                    }

                    if !replay.events.isEmpty {
                        ForEach(Array(replay.events.suffix(5).enumerated()), id: \.offset) { _, event in
                            HStack(spacing: 6) {
                                Text("+\(event.elapsedMs)ms")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.25))
                                    .frame(width: 55, alignment: .trailing)
                                Text(event.action)
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.cyan.opacity(0.7))
                                Text(event.detail)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.35))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    vm.approve(item)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("APPROVE")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.green.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                vm.selectedItem = item
                vm.showOverridePicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("OVERRIDE")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: item.isResolved)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .heavy, design: .monospaced))
            .foregroundStyle(.white.opacity(0.25))
    }
}

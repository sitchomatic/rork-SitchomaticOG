import SwiftUI

struct EvidenceBundleDetailView: View {
    let bundle: EvidenceBundle
    let vm: EvidenceBundleViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                credentialSection
                resultSection
                confidenceSection
                signalBreakdownSection
                networkSection
                timelineSection
                screenshotSection
                logsSection
                replaySection
                exportActions
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .navigationTitle("Evidence")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Export JSON", systemImage: "doc.text.fill") {
                        vm.exportJSON(bundle)
                    }
                    Button("Export Text", systemImage: "doc.plaintext") {
                        vm.exportText(bundle)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        }
    }

    private var credentialSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(icon: "person.text.rectangle", title: "CREDENTIAL")
            VStack(alignment: .leading, spacing: 6) {
                infoRow(label: "USERNAME", value: bundle.username, mono: true)
                infoRow(label: "PASSWORD", value: bundle.password, mono: true)
                infoRow(label: "ID", value: String(bundle.credentialId.prefix(12)), mono: true)
            }
            .sectionCard()
        }
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(icon: "checkmark.seal", title: "RESULT")
            HStack(spacing: 12) {
                resultPill(label: bundle.resultStatus.rawValue, color: statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confidence")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("\(Int(bundle.confidence * 100))%")
                        .font(.system(size: 22, weight: .heavy, design: .monospaced))
                        .foregroundStyle(confidenceColor)
                }
                Spacer()
                if bundle.isExported {
                    VStack(spacing: 2) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.cyan)
                        Text("EXPORTED")
                            .font(.system(size: 7, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.7))
                    }
                }
            }
            .sectionCard()
        }
    }

    private var confidenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(icon: "brain.head.profile", title: "AI REASONING")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                                .frame(height: 8)
                            Capsule()
                                .fill(confidenceGradient)
                                .frame(width: geo.size.width * bundle.confidence, height: 8)
                        }
                    }
                    .frame(height: 8)
                    Text("\(Int(bundle.confidence * 100))%")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .foregroundStyle(confidenceColor)
                        .frame(width: 44, alignment: .trailing)
                }
                Text(bundle.reasoning)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .sectionCard()
        }
    }

    private var signalBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(icon: "waveform.path.ecg", title: "SIGNAL BREAKDOWN (\(bundle.signalBreakdown.count))")
            VStack(spacing: 4) {
                ForEach(Array(bundle.signalBreakdown.enumerated()), id: \.offset) { _, signal in
                    HStack(spacing: 8) {
                        signalIcon(signal.source)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(signal.source)
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                            Text(signal.detail)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.35))
                                .lineLimit(2)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(String(format: "%.3f", signal.weightedScore))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(signalScoreColor(signal.weightedScore))
                            Text("w:\(String(format: "%.0f%%", signal.weight * 100))")
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.03))
                    .clipShape(.rect(cornerRadius: 6))
                }
            }
            .sectionCard()
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(icon: "network", title: "NETWORK PATH")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    infoPill(label: "MODE", value: bundle.networkMode)
                    if let server = bundle.vpnServer {
                        infoPill(label: "SERVER", value: server)
                    }
                    if let ip = bundle.vpnIP {
                        infoPill(label: "IP", value: ip)
                    }
                    if let country = bundle.vpnCountry {
                        infoPill(label: "COUNTRY", value: country)
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                    Text(bundle.testedURL)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                }
            }
            .sectionCard()
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(icon: "clock.arrow.circlepath", title: "TIMELINE")
            HStack(spacing: 16) {
                infoPill(label: "STARTED", value: timeString(bundle.startedAt))
                infoPill(label: "ENDED", value: timeString(bundle.completedAt))
                infoPill(label: "DURATION", value: bundle.durationFormatted)
                infoPill(label: "RETRIES", value: "\(bundle.retryCount)")
            }
            .sectionCard()
        }
    }

    private var screenshotSection: some View {
        Group {
            if !bundle.screenshotIds.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(icon: "camera.fill", title: "SCREENSHOTS (\(bundle.screenshotIds.count))")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(bundle.screenshotIds, id: \.self) { ssId in
                                if let image = vm.screenshot(for: ssId) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 160, height: 100)
                                        .clipShape(.rect(cornerRadius: 10))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                                        )
                                } else {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.white.opacity(0.05))
                                        .frame(width: 160, height: 100)
                                        .overlay {
                                            Image(systemName: "photo")
                                                .font(.system(size: 18))
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
            if !bundle.logs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(icon: "doc.text", title: "LOGS (\(bundle.logs.count))")
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(bundle.logs.prefix(20)) { log in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(logColor(log.level))
                                    .frame(width: 4, height: 4)
                                Text(log.formattedTime)
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.25))
                                Text(log.message)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                        if bundle.logs.count > 20 {
                            Text("+ \(bundle.logs.count - 20) more entries")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                    }
                    .sectionCard()
                }
            }
        }
    }

    private var replaySection: some View {
        Group {
            if let replay = bundle.replayLog {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(icon: "play.rectangle", title: "SESSION REPLAY (\(replay.events.count) events)")
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 16) {
                            infoPill(label: "DURATION", value: "\(replay.totalDurationMs)ms")
                            infoPill(label: "EVENTS", value: "\(replay.events.count)")
                            infoPill(label: "OUTCOME", value: replay.outcome)
                        }
                        ForEach(Array(replay.events.enumerated()), id: \.offset) { _, event in
                            HStack(spacing: 6) {
                                Text("+\(event.elapsedMs)ms")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.25))
                                    .frame(width: 60, alignment: .trailing)
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
                    .sectionCard()
                }
            }
        }
    }

    private var exportActions: some View {
        HStack(spacing: 10) {
            Button {
                vm.exportJSON(bundle)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("EXPORT JSON")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(.cyan)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.cyan.opacity(0.1))
                .clipShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Button {
                vm.exportText(bundle)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.plaintext")
                        .font(.system(size: 11, weight: .bold))
                    Text("EXPORT TEXT")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.blue.opacity(0.1))
                .clipShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.cyan.opacity(0.6))
            Text(title)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func infoRow(label: String, value: String, mono: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: mono ? .bold : .medium, design: mono ? .monospaced : .default))
                .foregroundStyle(.white)
                .lineLimit(1)
                .textSelection(.enabled)
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

    private func resultPill(label: String, color: Color) -> some View {
        Text(label.uppercased())
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func signalIcon(_ source: String) -> some View {
        let icon: String
        let color: Color
        if source.contains("SUCCESS") { icon = "checkmark.circle.fill"; color = .green }
        else if source.contains("INCORRECT") || source.contains("DISABLED") { icon = "xmark.circle.fill"; color = .red }
        else if source.contains("OCR") { icon = "eye.fill"; color = .cyan }
        else if source.contains("URL") { icon = "link"; color = .blue }
        else if source.contains("AI") { icon = "brain.head.profile"; color = .purple }
        else if source.contains("TIMING") { icon = "clock"; color = .orange }
        else if source.contains("HTTP") { icon = "network"; color = .teal }
        else if source.contains("DOM") { icon = "doc.text"; color = .indigo }
        else { icon = "questionmark.circle"; color = .gray }

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

    private func logColor(_ level: PPSRLogEntry.Level) -> Color {
        switch level {
        case .error: .red
        case .warning: .orange
        case .success: .green
        case .info: .blue
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private var statusColor: Color {
        switch bundle.resultStatus {
        case .working: .green
        case .noAcc: .red
        case .tempDisabled: .orange
        case .permDisabled: .purple
        case .unsure: .yellow
        case .untested: .gray
        case .testing: .blue
        }
    }

    private var confidenceColor: Color {
        if bundle.confidence < 0.4 { return .red }
        if bundle.confidence < 0.7 { return .orange }
        return .green
    }

    private var confidenceGradient: LinearGradient {
        if bundle.confidence < 0.4 {
            return LinearGradient(colors: [.red, .red.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
        }
        if bundle.confidence < 0.7 {
            return LinearGradient(colors: [.orange, .yellow.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
        }
        return LinearGradient(colors: [.green, .cyan.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
    }
}

private extension View {
    func sectionCard() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04))
            .clipShape(.rect(cornerRadius: 10))
    }
}

import SwiftUI

struct SuperTestView: View {
    @State private var service = SuperTestService.shared
    @State private var showReport: Bool = false
    @State private var selectedPhase: SuperTestPhase?
    @State private var showLogs: Bool = false
    @State private var showConnectionPicker: Bool = false
    @State private var showNetworkModePrompt: Bool = false
    private let proxyService = ProxyRotationService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                if service.isRunning {
                    liveProgressCard
                }
                if service.isRunning || !service.results.isEmpty {
                    phaseGrid
                }
                if let report = service.lastReport, !service.isRunning {
                    reportSummaryCard(report)
                    if !report.diagnostics.isEmpty {
                        diagnosticsSection(report.diagnostics)
                    }
                }
                if !service.results.isEmpty {
                    resultsList
                }
                if showLogs && !service.logs.isEmpty {
                    logsSection
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Super Test")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    DebugLogView()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.subheadline)
                }

                Button {
                    showLogs.toggle()
                } label: {
                    Image(systemName: showLogs ? "terminal.fill" : "terminal")
                        .font(.subheadline)
                }
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            service.isRunning
                            ? Color.purple.opacity(0.15)
                            : (service.lastReport != nil ? Color.green.opacity(0.15) : Color.blue.opacity(0.15))
                        )
                        .frame(width: 56, height: 56)

                    Image(systemName: service.isRunning ? "bolt.horizontal.circle.fill" : (service.lastReport != nil ? "checkmark.seal.fill" : "testtube.2"))
                        .font(.system(size: 26))
                        .foregroundStyle(service.isRunning ? .purple : (service.lastReport != nil ? .green : .blue))
                        .symbolEffect(.pulse, isActive: service.isRunning)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Comprehensive Infrastructure Test")
                        .font(.subheadline.bold())
                    Text("URLs · DNS · Proxies · VPN · WireGuard · Fingerprint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if service.isRunning {
                        Text(service.currentPhase.rawValue)
                            .font(.system(.caption2, design: .monospaced, weight: .semibold))
                            .foregroundStyle(.purple)
                    }
                }

                Spacer()
            }

            if service.isRunning {
                Button {
                    service.stopSuperTest()
                } label: {
                    Label("Stop Test", systemImage: "stop.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.15))
                        .foregroundStyle(.red)
                        .clipShape(.rect(cornerRadius: 12))
                }
            } else {
                connectionTypeSelector

                networkModeBanner

                Button {
                    showNetworkModePrompt = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.horizontal.fill")
                            .font(.subheadline)
                        Text("Run Super Test")
                            .font(.subheadline.bold())
                        if service.selectedConnectionTypes.count < SuperTestConnectionType.allCases.count {
                            Text("(\(service.selectedConnectionTypes.count)/\(SuperTestConnectionType.allCases.count))")
                                .font(.caption2)
                                .opacity(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: service.selectedConnectionTypes.isEmpty ? [.gray, .gray] : [.purple, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundStyle(.white)
                    .clipShape(.rect(cornerRadius: 14))
                }
                .disabled(service.selectedConnectionTypes.isEmpty)
                .sensoryFeedback(.impact(weight: .heavy), trigger: service.isRunning)
                .confirmationDialog("Select Network Mode", isPresented: $showNetworkModePrompt, titleVisibility: .visible) {
                    ForEach(ConnectionMode.allCases, id: \.self) { mode in
                        Button {
                            proxyService.setUnifiedConnectionMode(mode)
                            service.startSuperTest()
                        } label: {
                            Label(mode.label, systemImage: mode.icon)
                        }
                    }
                    Button("Use Current (\(proxyService.unifiedConnectionMode.label))") {
                        service.startSuperTest()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Choose which network mode to use for this Super Test run. Current: \(proxyService.unifiedConnectionMode.label)")
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 16))
    }

    // MARK: - Network Mode Banner

    private var networkModeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: proxyService.unifiedConnectionMode.icon)
                .font(.caption)
                .foregroundStyle(networkModeColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Network Mode").font(.caption.bold())
                Text(proxyService.unifiedConnectionMode.label)
                    .font(.system(.caption2, design: .monospaced, weight: .semibold))
                    .foregroundStyle(networkModeColor)
            }
            Spacer()
            Text(proxyService.networkRegion.rawValue)
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(proxyService.networkRegion == .usa ? .blue : .orange)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background((proxyService.networkRegion == .usa ? Color.blue : .orange).opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(10)
        .background(networkModeColor.opacity(0.08))
        .clipShape(.rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(networkModeColor.opacity(0.2), lineWidth: 1)
        )
    }

    private var networkModeColor: Color {
        switch proxyService.unifiedConnectionMode {
        case .direct: .green
        case .proxy: .blue
        case .openvpn: .indigo
        case .wireguard: .purple
        case .dns: .cyan
        case .nodeMaven: .teal
        case .hybrid: .mint
        }
    }

    // MARK: - Connection Type Selector

    private var connectionTypeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    showConnectionPicker.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text("Test Phases")
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(service.selectedConnectionTypes.count)/\(SuperTestConnectionType.allCases.count)")
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: showConnectionPicker ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if showConnectionPicker {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Button {
                            withAnimation(.spring(duration: 0.2)) {
                                service.selectedConnectionTypes = Set(SuperTestConnectionType.allCases)
                            }
                        } label: {
                            Text("All")
                                .font(.caption2.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(service.selectedConnectionTypes.count == SuperTestConnectionType.allCases.count ? Color.blue.opacity(0.15) : Color(.tertiarySystemGroupedBackground))
                                .foregroundStyle(service.selectedConnectionTypes.count == SuperTestConnectionType.allCases.count ? .blue : .secondary)
                                .clipShape(Capsule())
                        }

                        Button {
                            withAnimation(.spring(duration: 0.2)) {
                                service.selectedConnectionTypes.removeAll()
                            }
                        } label: {
                            Text("None")
                                .font(.caption2.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(service.selectedConnectionTypes.isEmpty ? Color.red.opacity(0.15) : Color(.tertiarySystemGroupedBackground))
                                .foregroundStyle(service.selectedConnectionTypes.isEmpty ? .red : .secondary)
                                .clipShape(Capsule())
                        }

                        Spacer()
                    }
                    .padding(.bottom, 8)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(SuperTestConnectionType.allCases) { type in
                            connectionTypeToggle(type)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func connectionTypeToggle(_ type: SuperTestConnectionType) -> some View {
        let isSelected = service.selectedConnectionTypes.contains(type)
        return Button {
            withAnimation(.spring(duration: 0.2)) {
                if isSelected {
                    service.selectedConnectionTypes.remove(type)
                } else {
                    service.selectedConnectionTypes.insert(type)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: type.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? type.color : .secondary)
                    .frame(width: 16)
                Text(type.rawValue)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? type.color : Color(.tertiaryLabel))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? type.color.opacity(0.1) : Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? type.color.opacity(0.3) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
    }

    // MARK: - Live Progress

    private var liveProgressCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.currentPhase.rawValue)
                        .font(.subheadline.bold())
                        .foregroundStyle(.purple)
                    if !service.currentItem.isEmpty {
                        Text(service.currentItem)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(String(format: "%.0f%%", service.progress * 100))
                    .font(.system(.title3, design: .monospaced, weight: .bold))
                    .foregroundStyle(.purple)
            }

            ProgressView(value: service.progress)
                .tint(.purple)

            if let phaseInfo = service.phaseProgress[service.currentPhase] {
                HStack {
                    Text("\(phaseInfo.done)/\(phaseInfo.total) items")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(service.results.count) results so far")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color.purple.opacity(0.06))
        .clipShape(.rect(cornerRadius: 14))
    }

    // MARK: - Phase Grid

    private var phaseGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
        ], spacing: 8) {
            ForEach(service.phaseSummary, id: \.phase) { item in
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        selectedPhase = selectedPhase == item.phase ? nil : item.phase
                    }
                } label: {
                    phaseCell(item.phase, passed: item.passed, failed: item.failed)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func phaseCell(_ phase: SuperTestPhase, passed: Int, failed: Int) -> some View {
        let total = passed + failed
        let isSelected = selectedPhase == phase
        let isActive = service.currentPhase == phase && service.isRunning

        return HStack(spacing: 8) {
            Image(systemName: phase.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(phaseColor(phase))
                .symbolEffect(.pulse, isActive: isActive)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(phaseName(phase))
                    .font(.system(.caption, weight: .semibold))
                    .lineLimit(1)
                if total > 0 {
                    HStack(spacing: 4) {
                        Text("\(passed)")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.green)
                        Text("/")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\(total)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else if isActive {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text("—")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(isSelected ? phaseColor(phase).opacity(0.12) : Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? phaseColor(phase).opacity(0.4) : .clear, lineWidth: 1.5)
        )
    }

    private func phaseName(_ phase: SuperTestPhase) -> String {
        switch phase {
        case .fingerprint: "Fingerprint"
        case .joeURLs: "Joe URLs"
        case .ignitionURLs: "Ignition URLs"
        case .ppsrConnection: "PPSR"
        case .dnsServers: "DNS"
        case .socks5Proxies: "Proxies"
        case .openvpnProfiles: "VPN"
        case .wireguardProfiles: "WireGuard"
        default: phase.rawValue
        }
    }

    private func phaseColor(_ phase: SuperTestPhase) -> Color {
        switch phase {
        case .fingerprint: .purple
        case .joeURLs: .green
        case .ignitionURLs: .orange
        case .ppsrConnection: .cyan
        case .dnsServers: .blue
        case .socks5Proxies: .red
        case .openvpnProfiles: .indigo
        case .wireguardProfiles: .purple
        default: .secondary
        }
    }

    // MARK: - Report Summary

    private func reportSummaryCard(_ report: SuperTestReport) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(report.passRate > 0.7 ? Color.green.opacity(0.15) : (report.passRate > 0.4 ? Color.orange.opacity(0.15) : Color.red.opacity(0.15)))
                        .frame(width: 50, height: 50)
                    Text(report.formattedPassRate)
                        .font(.system(.subheadline, design: .monospaced, weight: .black))
                        .foregroundStyle(report.passRate > 0.7 ? .green : (report.passRate > 0.4 ? .orange : .red))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Test Complete")
                        .font(.subheadline.bold())
                    Text("\(report.formattedDuration) · \(report.totalTested) items tested")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let fpScore = report.fingerprintScore {
                    VStack(spacing: 2) {
                        Image(systemName: "fingerprint")
                            .font(.caption)
                            .foregroundStyle(report.fingerprintPassed ? .green : .red)
                        Text("\(fpScore)")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(report.fingerprintPassed ? .green : .red)
                    }
                    .padding(8)
                    .background((report.fingerprintPassed ? Color.green : Color.red).opacity(0.1))
                    .clipShape(.rect(cornerRadius: 8))
                }
            }

            HStack(spacing: 0) {
                reportStat(value: "\(report.totalPassed)", label: "Passed", color: .green, icon: "checkmark.circle.fill")
                reportStat(value: "\(report.totalFailed)", label: "Failed", color: .red, icon: "xmark.circle.fill")
                reportStat(value: "\(report.totalDisabled)", label: "Disabled", color: .orange, icon: "minus.circle.fill")
                reportStat(value: "\(report.totalEnabled)", label: "Enabled", color: .blue, icon: "plus.circle.fill")
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func reportStat(value: String, label: String, color: Color, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.subheadline, design: .monospaced, weight: .bold))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Results List

    private var resultsList: some View {
        let filtered: [SuperTestItemResult]
        if let phase = selectedPhase {
            filtered = service.results.filter { $0.category == phase }
        } else {
            filtered = service.results
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(selectedPhase.map { "\(phaseName($0)) Results" } ?? "All Results")
                    .font(.headline)
                Spacer()
                Text("\(filtered.count)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                    .foregroundStyle(.secondary)

                if selectedPhase != nil {
                    Button {
                        withAnimation { selectedPhase = nil }
                    } label: {
                        Text("Show All")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                    }
                }
            }

            ForEach(filtered) { result in
                resultRow(result)
            }
        }
    }

    private func resultRow(_ result: SuperTestItemResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(result.passed ? .green : .red)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(.caption, weight: .semibold))
                    .lineLimit(1)
                Text(result.detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if let ms = result.latencyMs, result.category != .fingerprint {
                Text("\(ms)ms")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 8))
    }

    // MARK: - Logs

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Console")
                    .font(.headline)
                Spacer()
                Text("\(service.logs.count)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 1) {
                ForEach(service.logs.prefix(50)) { log in
                    HStack(spacing: 6) {
                        Text(log.formattedTime)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 65, alignment: .leading)
                        Circle()
                            .fill(logColor(log.level))
                            .frame(width: 5, height: 5)
                        Text(log.message)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(logColor(log.level))
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                }
            }
            .padding(8)
            .background(Color.black.opacity(0.85))
            .clipShape(.rect(cornerRadius: 10))
        }
    }

    private func logColor(_ level: PPSRLogEntry.Level) -> Color {
        switch level {
        case .info: .white.opacity(0.7)
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    // MARK: - Diagnostics & Auto-Repair

    private func diagnosticsSection(_ findings: [DiagnosticFinding]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope")
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                Text("Diagnostics")
                    .font(.headline)
                Spacer()

                let autoFixCount = findings.filter { $0.autoFixAvailable }.count
                if autoFixCount > 0 && !service.isAutoRepairing {
                    Button {
                        service.runAutoRepair()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.caption2)
                            Text("Auto-Repair (\(autoFixCount))")
                                .font(.caption.bold())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                    }
                    .sensoryFeedback(.impact(weight: .medium), trigger: service.isAutoRepairing)
                }

                if service.isAutoRepairing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Repairing...")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                    }
                }
            }

            ForEach(findings) { finding in
                diagnosticCard(finding)
            }

            if !service.autoRepairLog.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Repair Log")
                            .font(.caption.bold())
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(service.autoRepairLog.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(entry.contains("\u{2713}") ? .green : (entry.contains("\u{2717}") ? .red : .secondary))
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.85))
                    .clipShape(.rect(cornerRadius: 8))
                }
            }
        }
    }

    private func diagnosticCard(_ finding: DiagnosticFinding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: diagnosticIcon(finding.severity))
                    .font(.subheadline)
                    .foregroundStyle(diagnosticColor(finding.severity))

                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title)
                        .font(.system(.caption, weight: .bold))
                    if finding.autoFixAvailable {
                        HStack(spacing: 3) {
                            Image(systemName: "wrench.fill")
                                .font(.system(size: 8))
                            Text("Auto-fixable")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.blue)
                    }
                }

                Spacer()

                Text(finding.severity.rawValue.uppercased())
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(diagnosticColor(finding.severity))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(diagnosticColor(finding.severity).opacity(0.12))
                    .clipShape(Capsule())
            }

            Text(finding.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let fix = finding.fixAction {
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                    Text(fix)
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.08))
                .clipShape(.rect(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(diagnosticColor(finding.severity).opacity(0.04))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(diagnosticColor(finding.severity).opacity(0.2), lineWidth: 1)
        )
    }

    private func diagnosticIcon(_ severity: DiagnosticSeverity) -> String {
        switch severity {
        case .critical: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .info: "info.circle.fill"
        case .success: "checkmark.seal.fill"
        }
    }

    private func diagnosticColor(_ severity: DiagnosticSeverity) -> Color {
        switch severity {
        case .critical: .red
        case .warning: .orange
        case .info: .blue
        case .success: .green
        }
    }
}

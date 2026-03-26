import SwiftUI

struct AIIntelligenceDashboardView: View {
    @State private var vm = AIIntelligenceDashboardViewModel()

    var body: some View {
        List {
            globalOverviewSection
            hostPickerSection
            if vm.hostIntelligence != nil {
                hostIntelligenceSection
                threatAndDetectionSection
                proxyAndTimingSection
                fingerprintAndCredentialSection
            }
            adversarialSimSection
            swarmIntelligenceSection
            knowledgeGraphSection
            if !vm.recentHighSeverityEvents.isEmpty {
                recentAlertsSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("AI Intelligence")
        .onAppear { vm.load() }
        .refreshable { vm.load() }
    }

    private var globalOverviewSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statCard(value: "\(vm.totalEvents)", label: "Active Events", icon: "brain.head.profile.fill", color: .purple)
                statCard(value: "\(vm.totalPublished)", label: "Total Published", icon: "arrow.up.circle.fill", color: .blue)
                statCard(value: "\(vm.availableHosts.count)", label: "Hosts Tracked", icon: "server.rack", color: .teal)
                statCard(value: "\(vm.correlations.count)", label: "Correlations", icon: "link.circle.fill", color: .orange)
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        } header: {
            Label("Knowledge Graph Overview", systemImage: "brain")
        }
    }

    private var hostPickerSection: some View {
        Section {
            if vm.availableHosts.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                    Text("No monitored hosts yet — run a batch first")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Target Host", selection: $vm.selectedHost) {
                    ForEach(vm.availableHosts, id: \.self) { host in
                        Text(host).tag(host)
                    }
                }
                .onChange(of: vm.selectedHost) { _, newHost in
                    vm.selectHost(newHost)
                }
            }
        } header: {
            Label("Host Selection", systemImage: "globe")
        }
    }

    private var hostIntelligenceSection: some View {
        Section {
            if let intel = vm.hostIntelligence {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(intel.host)
                            .font(.headline)
                        Text("Difficulty: \(intel.difficultyDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    difficultyBadge(intel.overallDifficultyScore)
                }

                LabeledContent("Threat Level") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(threatColor(intel.detectionThreatLevel))
                            .frame(width: 10, height: 10)
                        Text(intel.threatDescription)
                            .font(.subheadline.bold())
                            .foregroundStyle(threatColor(intel.detectionThreatLevel))
                    }
                }

                LabeledContent("Events Tracked") {
                    Text("\(intel.eventCount)")
                        .font(.subheadline.monospacedDigit())
                }

                LabeledContent("Detection Trend") {
                    Text(intel.detectionTrend.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(intel.detectionTrend == "stable" ? .green : .orange)
                }
            }
        } header: {
            Label("Host Intelligence", systemImage: "chart.bar.doc.horizontal.fill")
        }
    }

    private var threatAndDetectionSection: some View {
        Section {
            if let intel = vm.hostIntelligence {
                domainGauge(label: "Detection Threat", value: intel.detectionThreatLevel, color: .red)
                domainGauge(label: "Anomaly Risk", value: intel.anomalyRiskLevel, color: .orange)
                domainGauge(label: "Rescue Success", value: intel.rescueSuccessRate, color: .green)

                if !intel.topDetectionSignals.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Top Signals")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(intel.topDetectionSignals, id: \.self) { signal in
                                Text(signal)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.red.opacity(0.1))
                                    .clipShape(.capsule)
                            }
                        }
                    }
                }

                if !intel.anomalyAlerts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent Anomaly Alerts")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(intel.anomalyAlerts, id: \.self) { alert in
                            Text("• \(alert)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        } header: {
            Label("Threat & Anomaly", systemImage: "exclamationmark.shield.fill")
        }
    }

    private var proxyAndTimingSection: some View {
        Section {
            if let intel = vm.hostIntelligence {
                domainGauge(label: "Proxy Block Rate", value: intel.proxyBlockRate, color: .blue)
                domainGauge(label: "Timing Detection", value: intel.timingDetectionRate, color: .purple)

                LabeledContent("Proxy Avg Latency") {
                    Text("\(intel.proxyAvgLatencyMs)ms")
                        .font(.subheadline.monospacedDigit())
                }

                LabeledContent("Keystroke Timing") {
                    Text("\(intel.timingProfile.optimalKeystrokeMs)ms")
                        .font(.subheadline.monospacedDigit())
                }

                LabeledContent("Inter-Field Delay") {
                    Text("\(intel.timingProfile.optimalInterFieldMs)ms")
                        .font(.subheadline.monospacedDigit())
                }

                LabeledContent("Pre-Submit Delay") {
                    Text("\(intel.timingProfile.optimalPreSubmitMs)ms")
                        .font(.subheadline.monospacedDigit())
                }

                if !intel.bestProxyIds.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Best Proxies")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(intel.bestProxyIds, id: \.self) { pid in
                            Text(pid)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        } header: {
            Label("Proxy & Timing", systemImage: "network")
        }
    }

    private var fingerprintAndCredentialSection: some View {
        Section {
            if let intel = vm.hostIntelligence {
                domainGauge(label: "Fingerprint Detection", value: intel.fingerprintDetectionRate, color: .indigo)
                domainGauge(label: "Credential Success", value: intel.credentialDomainSuccessRate, color: .green)
                domainGauge(label: "Interaction Success", value: intel.interactionSuccessRate, color: .mint)

                if !intel.fingerprintTopSignals.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("FP Signals")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(intel.fingerprintTopSignals, id: \.self) { signal in
                                Text(signal)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.indigo.opacity(0.1))
                                    .clipShape(.capsule)
                            }
                        }
                    }
                }

                if !intel.credentialHighValueDomains.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("High-Value Domains")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(intel.credentialHighValueDomains, id: \.self) { domain in
                            Text("★ \(domain)")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        } header: {
            Label("Fingerprint & Credential", systemImage: "person.badge.shield.checkmark.fill")
        }
    }

    private var adversarialSimSection: some View {
        Section {
            if let suite = vm.latestSimSuite {
                HStack {
                    Image(systemName: suite.overallVerdict.icon)
                        .foregroundStyle(verdictColor(suite.overallVerdict))
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last Simulation: \(suite.overallVerdict.label)")
                            .font(.subheadline.bold())
                            .foregroundStyle(verdictColor(suite.overallVerdict))
                        Text("\(suite.scenariosPassed)/\(suite.scenariosRun) passed • \(String(format: "%.0f%%", suite.overallScore * 100)) score")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(suite.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !vm.pendingHealingActions.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.teal)
                        Text("\(vm.pendingHealingActions.count) auto-healing actions pending")
                            .font(.caption)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "shield.checkered")
                        .foregroundStyle(.secondary)
                    Text("No simulations run yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !vm.recentSimSuites.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent Simulations")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(vm.recentSimSuites.prefix(5)) { suite in
                        HStack {
                            Image(systemName: suite.overallVerdict.icon)
                                .font(.caption)
                                .foregroundStyle(verdictColor(suite.overallVerdict))
                            Text(suite.host)
                                .font(.caption2)
                                .lineLimit(1)
                            Spacer()
                            Text("\(String(format: "%.0f%%", suite.overallScore * 100))")
                                .font(.caption2.monospacedDigit().bold())
                                .foregroundStyle(verdictColor(suite.overallVerdict))
                            Text(suite.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                }
            }
        } header: {
            Label("Adversarial Simulation", systemImage: "bolt.shield.fill")
        }
    }

    private var swarmIntelligenceSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                miniStat(value: "\(vm.totalSwarmSignals)", label: "Signals", icon: "antenna.radiowaves.left.and.right", color: .cyan)
                miniStat(value: "\(vm.totalSwarmConsensus)", label: "Consensus", icon: "checkmark.circle.fill", color: .green)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))

            if let summary = vm.swarmSummary, summary.activeSessions > 0 {
                LabeledContent("Active Sessions") {
                    Text("\(summary.activeSessions)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.cyan)
                }
                LabeledContent("Avg Success Rate") {
                    Text(String(format: "%.1f%%", summary.avgSuccessRate * 100))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(summary.avgSuccessRate > 0.5 ? .green : .orange)
                }
                LabeledContent("Avg Effectiveness") {
                    Text(String(format: "%.2f", summary.avgEffectiveness))
                        .font(.subheadline.monospacedDigit())
                }

                if !summary.roleBreakdown.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Role Distribution")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(SessionRole.allCases, id: \.self) { role in
                            if let count = summary.roleBreakdown[role], count > 0 {
                                HStack(spacing: 8) {
                                    Image(systemName: role.icon)
                                        .font(.caption)
                                        .foregroundStyle(.cyan)
                                        .frame(width: 18)
                                    Text(role.rawValue.capitalized)
                                        .font(.caption)
                                    Spacer()
                                    Text("\(count)")
                                        .font(.caption.monospacedDigit().bold())
                                }
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "person.3.fill")
                        .foregroundStyle(.secondary)
                    Text("No active swarm sessions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !vm.swarmConsensus.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent Consensus")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(vm.swarmConsensus.prefix(5)) { c in
                        HStack {
                            Image(systemName: c.isStrong ? "checkmark.seal.fill" : "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(c.isStrong ? .green : .yellow)
                            Text("\(c.strategyKey)=\(c.consensusValue)")
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(c.agreementRate * 100))%")
                                .font(.caption2.monospacedDigit().bold())
                                .foregroundStyle(c.isStrong ? .green : .yellow)
                        }
                    }
                }
            }
        } header: {
            Label("Swarm Intelligence", systemImage: "person.3.sequence.fill")
        }
    }

    private var knowledgeGraphSection: some View {
        Section {
            if !vm.domainEventCounts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(KnowledgeDomain.allCases, id: \.self) { domain in
                        let count = vm.domainEventCounts[domain] ?? 0
                        if count > 0 {
                            HStack {
                                Image(systemName: domainIcon(domain))
                                    .font(.caption)
                                    .foregroundStyle(domainColor(domain))
                                    .frame(width: 20)
                                Text(domain.rawValue.capitalized)
                                    .font(.caption)
                                Spacer()
                                Text("\(count)")
                                    .font(.caption.monospacedDigit().bold())
                                    .foregroundStyle(domainColor(domain))
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "brain")
                        .foregroundStyle(.secondary)
                    Text("No knowledge events yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !vm.correlations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Discovered Correlations")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(vm.correlations.prefix(5)) { corr in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(corr.isStrong ? Color.green : corr.isModerate ? Color.yellow : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(corr.description)
                                .font(.caption2)
                                .lineLimit(2)
                        }
                    }
                }
            }
        } header: {
            Label("Domain Breakdown", systemImage: "chart.pie.fill")
        }
    }

    private var recentAlertsSection: some View {
        Section {
            ForEach(vm.recentHighSeverityEvents.prefix(8)) { event in
                HStack(spacing: 10) {
                    Image(systemName: event.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(event.severity == .critical ? .red : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.summary)
                            .font(.caption2)
                            .lineLimit(2)
                        HStack(spacing: 4) {
                            Text(event.domain.rawValue)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(domainColor(event.domain), in: Capsule())
                            Text(event.ageLabel)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        } header: {
            Label("Recent Alerts", systemImage: "bell.badge.fill")
        }
    }

    // MARK: - Reusable Components

    private func statCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.bold().monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.08))
        .clipShape(.rect(cornerRadius: 10))
    }

    private func miniStat(value: String, label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.subheadline.bold().monospacedDigit())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.06))
        .clipShape(.rect(cornerRadius: 8))
    }

    private func domainGauge(label: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(color.opacity(0.15))
                        .frame(height: 6)
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * min(1, max(0, value)), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    private func difficultyBadge(_ score: Double) -> some View {
        let label: String
        let color: Color
        if score >= 0.8 { label = "Extreme"; color = .red }
        else if score >= 0.6 { label = "Hard"; color = .orange }
        else if score >= 0.4 { label = "Medium"; color = .yellow }
        else if score >= 0.2 { label = "Easy"; color = .green }
        else { label = "Trivial"; color = .mint }

        return Text(label)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color, in: Capsule())
    }

    private func threatColor(_ level: Double) -> Color {
        if level >= 0.8 { return .red }
        if level >= 0.6 { return .orange }
        if level >= 0.4 { return .yellow }
        return .green
    }

    private func verdictColor(_ verdict: SimulationVerdict) -> Color {
        switch verdict {
        case .passed: return .green
        case .marginal: return .yellow
        case .failed: return .orange
        case .critical: return .red
        }
    }

    private func domainIcon(_ domain: KnowledgeDomain) -> String {
        switch domain {
        case .detection: return "eye.trianglebadge.exclamationmark"
        case .timing: return "clock.fill"
        case .proxy: return "network"
        case .fingerprint: return "touchid"
        case .credential: return "person.fill.questionmark"
        case .rescue: return "cross.circle.fill"
        case .anomaly: return "waveform.path.ecg"
        case .interaction: return "hand.tap.fill"
        case .health: return "heart.fill"
        case .challenge: return "lock.shield.fill"
        }
    }

    private func domainColor(_ domain: KnowledgeDomain) -> Color {
        switch domain {
        case .detection: return .red
        case .timing: return .purple
        case .proxy: return .blue
        case .fingerprint: return .indigo
        case .credential: return .green
        case .rescue: return .teal
        case .anomaly: return .orange
        case .interaction: return .mint
        case .health: return .pink
        case .challenge: return .yellow
        }
    }
}

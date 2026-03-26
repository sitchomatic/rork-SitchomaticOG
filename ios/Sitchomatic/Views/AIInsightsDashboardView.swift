import SwiftUI

struct AIInsightsDashboardView: View {
    @State private var vm = AIInsightsViewModel()
    @State private var snapshot: AIInsightsViewModel.SystemHealthSnapshot?
    @State private var showResetConfirmation: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                if let snapshot {
                    systemHealthCard(snapshot)
                    adaptiveModeCard(snapshot)
                    if !snapshot.hostHealthItems.isEmpty {
                        hostHealthSection(snapshot)
                    }
                    if !snapshot.topURLs.isEmpty {
                        urlPerformanceSection(snapshot)
                    }
                    if !snapshot.fingerprintStats.isEmpty {
                        fingerprintSection(snapshot)
                    }
                    if !snapshot.topDomains.isEmpty {
                        credentialInsightsSection(snapshot)
                    }
                    if !snapshot.detectionPatterns.isEmpty {
                        detectionPatternsSection(snapshot)
                    }
                    if !snapshot.topDetectionSignals.isEmpty {
                        signalsSection(snapshot)
                    }
                }
                aiSummarySection
                resetSection
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
        .navigationTitle("AI Insights")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { refreshSnapshot() }
        .refreshable { refreshSnapshot() }
        .alert("Reset All AI Data?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                vm.resetAllAIData()
                refreshSnapshot()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear all learned AI data across all 9 services. This cannot be undone.")
        }
    }

    private func refreshSnapshot() {
        snapshot = vm.buildSnapshot()
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "brain.head.profile.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.teal)
                Text("AI Intelligence Center")
                    .font(.title2.bold())
                Spacer()
                Button {
                    refreshSnapshot()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.bold())
                }
            }
            if let lastRefreshed = vm.lastRefreshed {
                HStack {
                    Text("Last AI analysis: \(lastRefreshed, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func systemHealthCard(_ snapshot: AIInsightsViewModel.SystemHealthSnapshot) -> some View {
        VStack(spacing: 12) {
            HStack {
                Label("System Health", systemImage: "heart.text.clipboard")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.0f%%", snapshot.globalHealth * 100))
                    .font(.title.bold())
                    .foregroundStyle(healthColor(snapshot.globalHealth))
            }

            ProgressView(value: snapshot.globalHealth)
                .tint(healthColor(snapshot.globalHealth))

            HStack(spacing: 16) {
                statPill("Detection", value: String(format: "%.0f%%", snapshot.globalDetectionRate * 100), color: snapshot.globalDetectionRate > 0.3 ? .red : .green)
                statPill("Hosts", value: "\(snapshot.hostHealthItems.count)", color: .blue)
                statPill("URLs", value: "\(snapshot.topURLs.count)", color: .purple)
                statPill("FP Profiles", value: "\(snapshot.fingerprintStats.count)", color: .orange)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private func adaptiveModeCard(_ snapshot: AIInsightsViewModel.SystemHealthSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: adaptiveModeIcon(snapshot.adaptiveMode))
                .font(.title2)
                .foregroundStyle(adaptiveModeColor(snapshot.adaptiveMode))
                .frame(width: 44, height: 44)
                .background(adaptiveModeColor(snapshot.adaptiveMode).opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Adaptive Mode")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(snapshot.adaptiveMode.capitalized)
                    .font(.headline.bold())
                    .foregroundStyle(adaptiveModeColor(snapshot.adaptiveMode))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Active Patterns")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(snapshot.detectionPatterns.count)")
                    .font(.title3.bold())
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private func hostHealthSection(_ snapshot: AIInsightsViewModel.SystemHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Host Health", systemImage: "server.rack")
                .font(.headline)

            ForEach(Array(snapshot.hostHealthItems.prefix(6).enumerated()), id: \.offset) { _, item in
                HStack(spacing: 10) {
                    Circle()
                        .fill(riskColor(item.risk))
                        .frame(width: 10, height: 10)

                    Text(item.host)
                        .font(.caption.monospaced())
                        .lineLimit(1)

                    Spacer()

                    Text("\(Int(item.health * 100))%")
                        .font(.caption.bold())
                        .foregroundStyle(healthColor(item.health))

                    Text("\(item.sessions) tests")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if item.streak > 0 {
                        Text("\(item.streak)x fail")
                            .font(.caption2.bold())
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private func urlPerformanceSection(_ snapshot: AIInsightsViewModel.SystemHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Top URLs by AI Score", systemImage: "link")
                .font(.headline)

            ForEach(Array(snapshot.topURLs.prefix(5).enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Text(shortenURL(item.url))
                        .font(.caption.monospaced())
                        .lineLimit(1)

                    Spacer()

                    Text("\(item.successRate)%")
                        .font(.caption.bold())
                        .foregroundStyle(item.successRate > 60 ? .green : item.successRate > 30 ? .orange : .red)

                    Text("\(item.attempts)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if item.blocked > 0 {
                        Image(systemName: "shield.slash")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private func fingerprintSection(_ snapshot: AIInsightsViewModel.SystemHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Fingerprint Profiles", systemImage: "touchid")
                .font(.headline)

            let topProfiles = snapshot.fingerprintStats.prefix(5)
            ForEach(Array(topProfiles.enumerated()), id: \.offset) { _, stat in
                HStack(spacing: 8) {
                    Text("Profile \(stat.profileIndex)")
                        .font(.caption.bold())

                    Spacer()

                    Text("\(Int(stat.detectionRate * 100))% det")
                        .font(.caption)
                        .foregroundStyle(stat.detectionRate > 0.3 ? .red : .green)

                    Text("\(Int(stat.successRate * 100))% success")
                        .font(.caption)
                        .foregroundStyle(stat.successRate > 0.5 ? .green : .orange)

                    Text("\(stat.useCount) uses")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private func credentialInsightsSection(_ snapshot: AIInsightsViewModel.SystemHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Credential Insights", systemImage: "person.crop.rectangle.stack")
                .font(.headline)

            HStack(spacing: 16) {
                statPill("Tested", value: "\(snapshot.credentialSummary.tested)", color: .blue)
                statPill("Untested", value: "\(snapshot.credentialSummary.untested)", color: .gray)
                statPill("High Priority", value: "\(snapshot.credentialSummary.highPriority)", color: .green)
            }

            if !snapshot.topDomains.isEmpty {
                Text("Top Email Domains")
                    .font(.subheadline.bold())
                    .padding(.top, 4)

                ForEach(Array(snapshot.topDomains.prefix(5).enumerated()), id: \.offset) { _, domain in
                    HStack {
                        Text("@\(domain.domain)")
                            .font(.caption.monospaced())
                        Spacer()
                        Text("\(domain.accountRate)% accounts")
                            .font(.caption.bold())
                            .foregroundStyle(domain.accountRate > 30 ? .green : .orange)
                        Text("(\(domain.total))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private func detectionPatternsSection(_ snapshot: AIInsightsViewModel.SystemHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Detection Patterns", systemImage: "exclamationmark.triangle")
                .font(.headline)

            ForEach(Array(snapshot.detectionPatterns.prefix(5).enumerated()), id: \.offset) { _, pattern in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(pattern.signals.prefix(2).joined(separator: ", "))
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text("\(pattern.occurrenceCount)x")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        if pattern.isNew {
                            Text("NEW")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.red)
                                .clipShape(.capsule)
                        }
                    }
                    Text("\(pattern.affectedHosts) hosts affected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private func signalsSection(_ snapshot: AIInsightsViewModel.SystemHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Top Detection Signals", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)

            ForEach(Array(snapshot.topDetectionSignals.prefix(6).enumerated()), id: \.offset) { _, signal in
                HStack {
                    Text(signal.signal)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text("\(signal.count)x")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private var aiSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Analysis", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await vm.requestAISummary() }
                } label: {
                    if vm.isLoadingInsights {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Analyze", systemImage: "wand.and.stars")
                            .font(.subheadline.bold())
                    }
                }
                .disabled(vm.isLoadingInsights)
            }

            if let summary = vm.aiSummary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
            } else {
                Text("Tap \"Analyze\" to generate an AI-powered summary of your automation performance and optimization recommendations.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private var resetSection: some View {
        Button(role: .destructive) {
            showResetConfirmation = true
        } label: {
            Label("Reset All AI Data", systemImage: "trash")
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    private func statPill(_ label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func healthColor(_ value: Double) -> Color {
        if value > 0.7 { return .green }
        if value > 0.4 { return .orange }
        return .red
    }

    private func riskColor(_ risk: SessionHealthRisk) -> Color {
        switch risk {
        case .low: return .green
        case .moderate: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }

    private func adaptiveModeIcon(_ mode: String) -> String {
        switch mode {
        case "defensive": return "shield.lefthalf.filled.trianglebadge.exclamationmark"
        case "cautious": return "exclamationmark.shield"
        default: return "checkmark.shield"
        }
    }

    private func adaptiveModeColor(_ mode: String) -> Color {
        switch mode {
        case "defensive": return .red
        case "cautious": return .orange
        default: return .green
        }
    }

    private func shortenURL(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return url }
        return parsed.host ?? url
    }
}

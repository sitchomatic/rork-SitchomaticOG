import SwiftUI

struct AIPatternDiscoveryDashboardView: View {
    @State private var vm = AIPatternDiscoveryViewModel()
    @State private var selectedTab: DashboardTab = .combos
    @State private var hostCombos: [AIPatternDiscoveryViewModel.HostComboProfile] = []
    @State private var heatmap: [AIPatternDiscoveryViewModel.HourBucket] = []
    @State private var proxyTrends: [AIPatternDiscoveryViewModel.ProxyTrendPoint] = []
    @State private var convergenceItems: [AIPatternDiscoveryViewModel.ConvergenceItem] = []
    @State private var patternItems: [AIPatternDiscoveryViewModel.PatternLearningItem] = []

    nonisolated enum DashboardTab: String, CaseIterable, Sendable {
        case combos = "Combos"
        case heatmap = "Time"
        case proxy = "Proxy"
        case convergence = "Brain"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                dashboardHeader
                    .padding(.horizontal)
                    .padding(.bottom, 12)

                tabPicker
                    .padding(.horizontal)
                    .padding(.bottom, 16)

                switch selectedTab {
                case .combos:
                    bestSettingCombosSection
                case .heatmap:
                    timeOfDayHeatmapSection
                case .proxy:
                    proxyTrendsSection
                case .convergence:
                    convergenceSection
                }

                aiInsightSection
                    .padding(.horizontal)
                    .padding(.top, 20)
            }
            .padding(.bottom, 40)
        }
        .navigationTitle("Pattern Discovery")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { refreshAll() }
        .refreshable { refreshAll() }
    }

    private func refreshAll() {
        hostCombos = vm.buildHostCombos()
        heatmap = vm.buildTimeOfDayHeatmap()
        proxyTrends = vm.buildProxyTrends()
        convergenceItems = vm.buildConvergenceItems()
        patternItems = vm.buildPatternLearningItems()
    }

    // MARK: - Header

    private var dashboardHeader: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "brain")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(
                                .linearGradient(colors: [.purple, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                        Text("AI Brain")
                            .font(.title2.bold())
                    }
                    Text("What the AI has learned across all services")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.bold())
                        .foregroundStyle(.purple)
                }
            }

            HStack(spacing: 0) {
                summaryStatBadge(
                    value: "\(hostCombos.count)",
                    label: "Hosts",
                    color: .blue
                )
                summaryStatBadge(
                    value: "\(convergenceItems.filter(\.converged).count)",
                    label: "Converged",
                    color: .green
                )
                summaryStatBadge(
                    value: "\(hostCombos.filter(\.aiOptimized).count)",
                    label: "AI Tuned",
                    color: .purple
                )
                summaryStatBadge(
                    value: "\(proxyTrends.count)",
                    label: "Proxy Pairs",
                    color: .orange
                )
            }
        }
    }

    private func summaryStatBadge(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(DashboardTab.allCases, id: \.rawValue) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tabIcon(tab))
                            .font(.caption2.bold())
                        Text(tab.rawValue)
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(selectedTab == tab ? tabColor(tab).opacity(0.15) : Color.clear)
                    .foregroundStyle(selectedTab == tab ? tabColor(tab) : .secondary)
                    .clipShape(.capsule)
                }
                .sensoryFeedback(.selection, trigger: selectedTab)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .clipShape(.capsule)
    }

    private func tabIcon(_ tab: DashboardTab) -> String {
        switch tab {
        case .combos: "slider.horizontal.3"
        case .heatmap: "clock.fill"
        case .proxy: "network"
        case .convergence: "brain.head.profile.fill"
        }
    }

    private func tabColor(_ tab: DashboardTab) -> Color {
        switch tab {
        case .combos: .blue
        case .heatmap: .orange
        case .proxy: .teal
        case .convergence: .purple
        }
    }

    // MARK: - Best Setting Combos

    private var bestSettingCombosSection: some View {
        VStack(spacing: 12) {
            if hostCombos.isEmpty {
                emptyState(icon: "slider.horizontal.3", message: "No host data yet. Run sessions to start collecting pattern data.")
            } else {
                ForEach(Array(hostCombos.prefix(10).enumerated()), id: \.offset) { index, combo in
                    hostComboCard(combo, rank: index + 1)
                }
            }

            if !patternItems.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.bar.fill")
                            .foregroundStyle(.indigo)
                        Text("Pattern Scores")
                            .font(.subheadline.bold())
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    ForEach(Array(patternItems.prefix(8).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Text(item.host)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(item.pattern)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.indigo.opacity(0.12))
                                .foregroundStyle(.indigo)
                                .clipShape(.capsule)

                            Text(String(format: "%.0f", item.score))
                                .font(.caption.bold())
                                .foregroundStyle(item.score > 0 ? .green : .red)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(.rect(cornerRadius: 16))
                .padding(.horizontal)
            }
        }
    }

    private func hostComboCard(_ combo: AIPatternDiscoveryViewModel.HostComboProfile, rank: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(rankGradient(rank))
                        .frame(width: 32, height: 32)
                    Text("\(rank)")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(combo.host)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let pattern = combo.bestPattern {
                            Text(pattern)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12))
                                .foregroundStyle(.blue)
                                .clipShape(.capsule)
                        }
                        Text("\(combo.dataPoints) pts")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f%%", combo.convergenceConfidence * 100))
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(confidenceColor(combo.convergenceConfidence))

                    HStack(spacing: 4) {
                        if combo.aiOptimized {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                                .foregroundStyle(.purple)
                        }
                        if combo.detectionRate > 0.3 {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            if let timing = combo.timingProfile, timing.totalSamples > 0 {
                Divider()
                    .padding(.vertical, 6)

                HStack(spacing: 0) {
                    timingMini("Key", bounds: timing.keystroke)
                    timingMini("Field", bounds: timing.interField)
                    timingMini("Submit", bounds: timing.preSubmit)
                    timingMini("DOM", bounds: timing.postDOM)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func timingMini(_ label: String, bounds: TimingBounds) -> some View {
        VStack(spacing: 2) {
            Text("\(bounds.minMs)-\(bounds.maxMs)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Time of Day Heatmap

    private var timeOfDayHeatmapSection: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .foregroundStyle(.orange)
                    Text("Success Rate by Hour")
                        .font(.subheadline.bold())
                    Spacer()
                }

                let activeBuckets = heatmap.filter { $0.totalCount > 0 }
                if activeBuckets.isEmpty {
                    emptyState(icon: "clock.badge.questionmark", message: "No time-of-day data yet. Complete some batches to see patterns.")
                } else {
                    heatmapGrid
                    heatmapLegend
                    bestWorstHours(activeBuckets)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(.rect(cornerRadius: 16))
            .padding(.horizontal)
        }
    }

    private var heatmapGrid: some View {
        VStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<6, id: \.self) { col in
                        let hour = row * 6 + col
                        let bucket = heatmap[hour]
                        heatmapCell(hour: hour, bucket: bucket)
                    }
                }
            }
        }
    }

    private func heatmapCell(hour: Int, bucket: AIPatternDiscoveryViewModel.HourBucket) -> some View {
        VStack(spacing: 1) {
            Text(hourLabel(hour))
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 4)
                .fill(heatmapColor(bucket))
                .frame(height: 28)
                .overlay {
                    if bucket.totalCount > 0 {
                        VStack(spacing: 0) {
                            Text("\(Int(bucket.successRate * 100))%")
                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                            Text("\(bucket.totalCount)")
                                .font(.system(size: 6, weight: .medium))
                        }
                        .foregroundStyle(.white)
                    }
                }
        }
        .frame(maxWidth: .infinity)
    }

    private func hourLabel(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let suffix = hour < 12 ? "a" : "p"
        return "\(h)\(suffix)"
    }

    private func heatmapColor(_ bucket: AIPatternDiscoveryViewModel.HourBucket) -> Color {
        guard bucket.totalCount > 0 else { return Color(.tertiarySystemFill) }
        let rate = bucket.successRate
        if rate >= 0.7 { return .green.opacity(0.6 + rate * 0.4) }
        if rate >= 0.4 { return .orange.opacity(0.5 + rate * 0.3) }
        if rate > 0 { return .red.opacity(0.4 + rate * 0.3) }
        return Color(.tertiarySystemFill)
    }

    private func legendColor(for rate: Double) -> Color {
        if rate >= 0.7 { return .green.opacity(0.6 + rate * 0.4) }
        if rate >= 0.4 { return .orange.opacity(0.5 + rate * 0.3) }
        return .red.opacity(0.4 + rate * 0.3)
    }

    private var heatmapLegend: some View {
        HStack(spacing: 4) {
            Text("Low")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach([0.1, 0.3, 0.5, 0.7, 0.9], id: \.self) { rate in
                RoundedRectangle(cornerRadius: 2)
                    .fill(legendColor(for: rate))
                    .frame(width: 16, height: 8)
            }
            Text("High")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func bestWorstHours(_ buckets: [AIPatternDiscoveryViewModel.HourBucket]) -> some View {
        let sorted = buckets.sorted { $0.successRate > $1.successRate }
        let best = sorted.first
        let worst = sorted.last

        return HStack(spacing: 12) {
            if let best {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Best: \(hourLabel(best.hour)) (\(Int(best.successRate * 100))%)")
                        .font(.caption2.bold())
                }
            }
            Spacer()
            if let worst, worst.hour != best?.hour {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text("Worst: \(hourLabel(worst.hour)) (\(Int(worst.successRate * 100))%)")
                        .font(.caption2.bold())
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Proxy Trends

    private var proxyTrendsSection: some View {
        VStack(spacing: 12) {
            if proxyTrends.isEmpty {
                emptyState(icon: "network.slash", message: "No proxy performance data yet. Use proxy connections to start tracking quality trends.")
                    .padding(.horizontal)
            } else {
                let grouped = Dictionary(grouping: proxyTrends) { $0.host }
                ForEach(Array(grouped.keys.sorted().prefix(6)), id: \.self) { host in
                    proxyHostCard(host: host, trends: grouped[host] ?? [])
                }
            }
        }
    }

    private func proxyHostCard(host: String, trends: [AIPatternDiscoveryViewModel.ProxyTrendPoint]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(.teal)
                    .font(.caption)
                Text(host)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                Text("\(trends.count) proxies")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(trends.prefix(4).enumerated()), id: \.offset) { _, trend in
                HStack(spacing: 8) {
                    Text(trend.proxyIdShort)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .frame(width: 60, alignment: .leading)

                    GeometryReader { geo in
                        let width = geo.size.width
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(.tertiarySystemFill))
                                .frame(height: 8)
                            Capsule()
                                .fill(proxyScoreGradient(trend.compositeScore))
                                .frame(width: max(4, width * trend.compositeScore), height: 8)
                        }
                    }
                    .frame(height: 8)

                    Text(String(format: "%.0f", trend.compositeScore * 100))
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(scoreColor(trend.compositeScore))
                        .frame(width: 28, alignment: .trailing)

                    if trend.hasAIWeight {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8))
                            .foregroundStyle(.purple)
                    }

                    if trend.isCoolingDown {
                        Image(systemName: "snowflake")
                            .font(.system(size: 8))
                            .foregroundStyle(.cyan)
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func proxyScoreGradient(_ score: Double) -> LinearGradient {
        if score > 0.7 {
            return LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing)
        } else if score > 0.4 {
            return LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing)
        }
        return LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)
    }

    // MARK: - Convergence

    private var convergenceSection: some View {
        VStack(spacing: 12) {
            if convergenceItems.isEmpty {
                emptyState(icon: "brain.head.profile.fill", message: "No convergence data yet. The AI needs more interaction sequences to identify patterns.")
                    .padding(.horizontal)
            } else {
                convergenceSummaryCard

                ForEach(Array(convergenceItems.prefix(8).enumerated()), id: \.offset) { _, item in
                    convergenceItemCard(item)
                }
            }
        }
    }

    private var convergenceSummaryCard: some View {
        HStack(spacing: 0) {
            let converged = convergenceItems.filter(\.converged).count
            let total = convergenceItems.count
            let aiOptimized = convergenceItems.filter(\.aiOptimized).count

            VStack(spacing: 2) {
                ZStack {
                    Circle()
                        .stroke(Color(.tertiarySystemFill), lineWidth: 4)
                        .frame(width: 48, height: 48)
                    Circle()
                        .trim(from: 0, to: total > 0 ? Double(converged) / Double(total) : 0)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 48, height: 48)
                        .rotationEffect(.degrees(-90))
                    Text("\(converged)/\(total)")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                }
                Text("Converged")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Text("\(aiOptimized)")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(.purple)
                Text("AI Optimized")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                let avgConf = convergenceItems.isEmpty ? 0.0 : convergenceItems.map(\.confidence).reduce(0, +) / Double(convergenceItems.count)
                Text(String(format: "%.0f%%", avgConf * 100))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(confidenceColor(avgConf))
                Text("Avg Confidence")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
        .padding(.horizontal)
    }

    private func convergenceItemCard(_ item: AIPatternDiscoveryViewModel.ConvergenceItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.converged ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(item.converged ? .green : .orange)
                    .font(.subheadline)

                Text(item.host)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                Spacer()

                Text(String(format: "%.0f%%", item.confidence * 100))
                    .font(.system(.caption, design: .rounded, weight: .heavy))
                    .foregroundStyle(confidenceColor(item.confidence))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(confidenceColor(item.confidence).opacity(0.12))
                    .clipShape(.capsule)
            }

            HStack(spacing: 12) {
                Label("\(item.dataPoints) pts", systemImage: "chart.dots.scatter")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let pattern = item.topPattern {
                    Text(pattern)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(.capsule)
                }

                if item.recipeActions > 0 {
                    Label("\(item.recipeActions) actions", systemImage: "list.bullet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if item.aiOptimized {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                        Text("AI")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.12))
                    .clipShape(.capsule)
                }
            }

            if let reasoning = item.aiReasoning {
                Text(reasoning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 14))
        .padding(.horizontal)
    }

    // MARK: - AI Insight

    private var aiInsightSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Pattern Insight", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await vm.requestAIPatternInsight() }
                } label: {
                    if vm.isGeneratingInsight {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Analyze", systemImage: "wand.and.stars")
                            .font(.subheadline.bold())
                    }
                }
                .disabled(vm.isGeneratingInsight)
            }

            if let insight = vm.aiInsight {
                Text(insight)
                    .font(.callout)
                    .foregroundStyle(.primary)
            } else {
                Text("Tap \"Analyze\" for AI-powered insights on what patterns the system is converging on, best time windows, and proxy quality trends.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    // MARK: - Helpers

    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func confidenceColor(_ value: Double) -> Color {
        if value > 0.7 { return .green }
        if value > 0.4 { return .orange }
        return .red
    }

    private func scoreColor(_ value: Double) -> Color {
        if value > 0.7 { return .green }
        if value > 0.4 { return .orange }
        return .red
    }

    private func rankGradient(_ rank: Int) -> LinearGradient {
        switch rank {
        case 1: LinearGradient(colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        case 2: LinearGradient(colors: [.gray, .white.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case 3: LinearGradient(colors: [.brown, .orange.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
        default: LinearGradient(colors: [.blue.opacity(0.6), .blue.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

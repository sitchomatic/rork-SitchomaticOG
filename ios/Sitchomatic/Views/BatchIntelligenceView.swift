import SwiftUI
import Combine

struct BatchIntelligenceView: View {
    private let preOptimizer = AIPredictiveBatchPreOptimizer.shared
    private let credentialTriage = AICredentialTriageService.shared

    @State private var selectedTab: Int = 0
    @State private var refreshTrigger: Int = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                tabSelector

                switch selectedTab {
                case 0: preOptimizerSection
                case 1: timeHeatmapSection
                case 2: credentialTriageSection
                case 3: domainIntelligenceSection
                default: EmptyView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Batch Intelligence")
        .navigationBarTitleDisplayMode(.large)
    }

    private var tabSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(["Pre-Optimizer", "Time Heatmap", "Credential Triage", "Domain Intel"].enumerated()), id: \.offset) { idx, title in
                    Button {
                        withAnimation(.spring(duration: 0.3)) { selectedTab = idx }
                    } label: {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selectedTab == idx ? Color.blue.opacity(0.15) : Color(.tertiarySystemFill))
                            .foregroundStyle(selectedTab == idx ? Color.blue : .secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .contentMargins(.horizontal, 0)
    }

    private var preOptimizerSection: some View {
        VStack(spacing: 16) {
            if let report = preOptimizer.lastReport {
                readinessCard(report: report)
                recommendedConfigCard(report: report)
                healthMetricsCard(report: report)
                urlRankingsCard(report: report)
                strategicRecsCard(report: report)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No Pre-Optimization Report Yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("A report will be generated automatically before your next batch run.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 16))
            }

            statsCard
        }
    }

    private func readinessCard(report: BatchPreOptimizationReport) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(readinessColor(report.overallReadiness).opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: readinessIcon(report.overallReadiness))
                    .font(.title3)
                    .foregroundStyle(readinessColor(report.overallReadiness))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(report.overallReadiness.rawValue.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(readinessColor(report.overallReadiness))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(readinessColor(report.overallReadiness).opacity(0.12))
                        .clipShape(Capsule())

                    Text("\(Int(report.readinessScore * 100))%")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text("Est. \(String(format: "%.0f%%", report.estimatedSuccessRate * 100)) success \u{2022} ~\(String(format: "%.0f", report.estimatedDurationMinutes))min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 2) {
                Text("\(report.credentialCount)")
                    .font(.title3.bold().monospacedDigit())
                Text("creds")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private func recommendedConfigCard(report: BatchPreOptimizationReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.blue)
                Text("Recommended Configuration")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                configPill(title: "Concurrency", value: "\(report.recommendedConcurrency)", icon: "arrow.triangle.branch", color: .purple)
                configPill(title: "Timeout", value: "\(Int(report.recommendedTimeout))s", icon: "timer", color: .orange)
                configPill(title: "Stealth", value: report.recommendedStealthEnabled ? "ON" : "OFF", icon: "eye.slash.fill", color: report.recommendedStealthEnabled ? .green : .secondary)
                configPill(title: "Retry", value: report.recommendedRetryOnFail ? "ON" : "OFF", icon: "arrow.clockwise", color: report.recommendedRetryOnFail ? .blue : .secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private func healthMetricsCard(report: BatchPreOptimizationReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "heart.text.clipboard")
                    .foregroundStyle(.red)
                Text("Health Assessment")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            VStack(spacing: 8) {
                healthBar(label: "Proxy Pool", value: report.proxyPoolHealth, color: .orange)
                healthBar(label: "URL Pool", value: report.urlPoolHealth, color: .blue)
                healthBar(label: "Credential Quality", value: report.credentialQualityScore, color: .purple)
                healthBar(label: "Time of Day", value: report.timeOfDayScore, color: .green)
                healthBar(label: "Memory", value: report.memoryPressureScore, color: .yellow)
            }

            if !report.proxyWarnings.isEmpty {
                ForEach(report.proxyWarnings, id: \.self) { warning in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private func urlRankingsCard(report: BatchPreOptimizationReport) -> some View {
        Group {
            if !report.urlRankings.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "link.badge.plus")
                            .foregroundStyle(.cyan)
                        Text("URL Rankings")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }

                    ForEach(report.urlRankings.prefix(6), id: \.url) { ranking in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(ranking.score > 0.6 ? Color.green : ranking.score > 0.3 ? .orange : .red)
                                .frame(width: 8, height: 8)
                            Text(ranking.url)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(ranking.score * 100))%")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(ranking.score > 0.6 ? .green : ranking.score > 0.3 ? .orange : .red)
                        }
                    }
                }
                .padding(16)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 16))
            }
        }
    }

    private func strategicRecsCard(report: BatchPreOptimizationReport) -> some View {
        Group {
            if !report.strategicRecommendations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(.yellow)
                        Text("Strategic Recommendations")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }

                    ForEach(Array(report.strategicRecommendations.prefix(6).enumerated()), id: \.offset) { _, rec in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                                .padding(.top, 1)
                            Text(rec)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 16))
            }
        }
    }

    private var statsCard: some View {
        let triageSummary = credentialTriage.triageSummary()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.xaxis.ascending")
                    .foregroundStyle(.mint)
                Text("Lifetime Stats")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                miniStat(label: "Batches Analyzed", value: "\(preOptimizer.store.totalBatchesAnalyzed)")
                miniStat(label: "AI Analyses", value: "\(preOptimizer.store.totalAIAnalyses)")
                miniStat(label: "Total Triages", value: "\(triageSummary.totalTriages)")
                miniStat(label: "Mid-Batch Reorders", value: "\(triageSummary.midBatchReorders)")
                miniStat(label: "Domains Tracked", value: "\(triageSummary.domainsTracked)")
                miniStat(label: "Exhausted Domains", value: "\(triageSummary.exhaustedDomains)")
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private var timeHeatmapSection: some View {
        let heatmap = preOptimizer.timeOfDayHeatmap()

        return VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "clock.fill")
                        .foregroundStyle(.orange)
                    Text("Success Rate by Hour")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                    ForEach(heatmap, id: \.hour) { entry in
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(heatmapColor(successRate: entry.successRate, hasBatches: entry.batchCount > 0))
                                .frame(height: 32)
                                .overlay {
                                    if entry.batchCount > 0 {
                                        Text("\(Int(entry.successRate * 100))")
                                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                                            .foregroundStyle(.white)
                                    }
                                }
                            Text("\(entry.hour)")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                HStack(spacing: 12) {
                    legendDot(color: .green.opacity(0.7), label: ">70%")
                    legendDot(color: .yellow.opacity(0.7), label: "40-70%")
                    legendDot(color: .red.opacity(0.7), label: "<40%")
                    legendDot(color: Color(.quaternarySystemFill), label: "No data")
                }
                .font(.caption2)

                let currentHour = Calendar.current.component(.hour, from: Date())
                let current = heatmap.first { $0.hour == currentHour }
                if let current, current.batchCount >= 2 {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                        Text("Current hour (\(currentHour):00) has \(Int(current.successRate * 100))% success rate over \(current.batchCount) batches")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .background(.regularMaterial)
            .clipShape(.rect(cornerRadius: 16))

            hostRankingsCard
        }
    }

    private var hostRankingsCard: some View {
        let rankings = preOptimizer.hostPerformanceRankings()

        return Group {
            if !rankings.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.indigo)
                        Text("Host Performance")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }

                    ForEach(rankings.prefix(8), id: \.host) { entry in
                        HStack(spacing: 10) {
                            Text(entry.host)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(entry.latency)ms")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text("\(Int(entry.score * 100))%")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(entry.score > 0.6 ? .green : entry.score > 0.3 ? .orange : .red)
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

    private var credentialTriageSection: some View {
        let summary = credentialTriage.triageSummary()

        return VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(.purple)
                    Text("Credential Triage Engine")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }

                Text("The triage engine intelligently orders credentials before each batch using domain spreading, similarity detection, and priority tiering.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    triageStat(title: "Total Triages", value: "\(summary.totalTriages)", icon: "arrow.up.arrow.down", color: .purple)
                    triageStat(title: "Mid-Batch Reorders", value: "\(summary.midBatchReorders)", icon: "arrow.triangle.swap", color: .blue)
                    triageStat(title: "Domains Tracked", value: "\(summary.domainsTracked)", icon: "globe", color: .green)
                    triageStat(title: "Exhausted Domains", value: "\(summary.exhaustedDomains)", icon: "xmark.circle.fill", color: .red)
                }
            }
            .padding(16)
            .background(.regularMaterial)
            .clipShape(.rect(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "brain.fill")
                        .foregroundStyle(.pink)
                    Text("How It Works")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }

                triageStep(num: 1, title: "Priority Tiering", desc: "Credentials sorted into high-value, untested, retest, low-priority, and exhausted tiers")
                triageStep(num: 2, title: "Domain Spreading", desc: "Same-domain credentials are spread apart to avoid pattern detection")
                triageStep(num: 3, title: "Similarity Detection", desc: "Similar usernames (john1@, john2@) are separated using Levenshtein distance")
                triageStep(num: 4, title: "Mid-Batch Reordering", desc: "As results come in, remaining credentials are dynamically reordered based on which domains are producing hits")
            }
            .padding(16)
            .background(.regularMaterial)
            .clipShape(.rect(cornerRadius: 16))
        }
    }

    private var domainIntelligenceSection: some View {
        let domains = credentialTriage.domainRankings()
        let topDomains = AICredentialPriorityScoringService.shared.topDomains(limit: 10)

        return VStack(spacing: 16) {
            if !domains.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "globe.americas.fill")
                            .foregroundStyle(.green)
                        Text("Domain Rankings (Triage)")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }

                    ForEach(domains.prefix(12), id: \.domain) { entry in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(entry.exhausted ? .red : entry.accountRate > 30 ? .green : entry.accountRate > 10 ? .orange : .secondary)
                                .frame(width: 8, height: 8)
                            Text(entry.domain)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            if entry.exhausted {
                                Text("EXHAUSTED")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.red.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                            Text("\(entry.tested) tested")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text("\(entry.accountRate)%")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(entry.accountRate > 30 ? .green : entry.accountRate > 10 ? .orange : .secondary)
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                }
                .padding(16)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 16))
            }

            if !topDomains.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                        Text("Top Domains by Account Discovery")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }

                    ForEach(topDomains.prefix(8), id: \.domain) { entry in
                        HStack(spacing: 10) {
                            Text(entry.domain)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(entry.total) creds")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text("\(entry.accountRate)%")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.yellow)
                        }
                    }
                }
                .padding(16)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 16))
            }

            if domains.isEmpty && topDomains.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No Domain Data Yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Domain intelligence builds as you run batches.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(40)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 16))
            }
        }
    }

    private func configPill(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.caption.weight(.bold))
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(8)
        .background(color.opacity(0.06))
        .clipShape(.rect(cornerRadius: 8))
    }

    private func healthBar(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.quaternarySystemFill))
                    Capsule()
                        .fill(value > 0.6 ? Color.green : value > 0.3 ? .orange : .red)
                        .frame(width: proxy.size.width * value)
                }
            }
            .frame(height: 6)

            Text("\(Int(value * 100))%")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(value > 0.6 ? .green : value > 0.3 ? .orange : .red)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(6)
    }

    private func triageStat(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.caption.weight(.bold).monospacedDigit())
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(8)
        .background(color.opacity(0.06))
        .clipShape(.rect(cornerRadius: 8))
    }

    private func triageStep(num: Int, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(num)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.purple)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.tertiary)
        }
    }

    private func heatmapColor(successRate: Double, hasBatches: Bool) -> Color {
        guard hasBatches else { return Color(.quaternarySystemFill) }
        if successRate > 0.7 { return .green.opacity(0.7) }
        if successRate > 0.4 { return .yellow.opacity(0.7) }
        return .red.opacity(0.7)
    }

    private func readinessColor(_ readiness: BatchReadiness) -> Color {
        switch readiness {
        case .optimal: return .green
        case .good: return .blue
        case .acceptable: return .yellow
        case .degraded: return .orange
        case .risky: return .red
        }
    }

    private func readinessIcon(_ readiness: BatchReadiness) -> String {
        switch readiness {
        case .optimal: return "checkmark.shield.fill"
        case .good: return "hand.thumbsup.fill"
        case .acceptable: return "minus.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .risky: return "xmark.octagon.fill"
        }
    }
}

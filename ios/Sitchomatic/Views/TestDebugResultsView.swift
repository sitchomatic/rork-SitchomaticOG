import SwiftUI
import UIKit

struct TestDebugResultsView: View {
    @Bindable var vm: TestDebugViewModel
    @State private var selectedTab: ResultsTab = .grid
    @State private var showShareSheet: Bool = false
    @State private var showCompareSheet: Bool = false
    @State private var exportText: String = ""

    nonisolated enum ResultsTab: String, CaseIterable, Sendable {
        case grid = "Grid"
        case ranked = "Ranked"
        case heatmap = "Heatmap"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                tabPicker

                switch selectedTab {
                case .grid:
                    screenshotGrid
                case .ranked:
                    rankedList
                case .heatmap:
                    heatmapView
                }
            }
            .background(Color(.systemGroupedBackground))

            if vm.showAppliedToast {
                appliedToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(duration: 0.35), value: vm.showAppliedToast)
            }
        }
        .navigationTitle("Results")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        exportText = vm.generateExportText()
                        showShareSheet = true
                    } label: {
                        Label("Share Results", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        UIPasteboard.general.string = vm.generateExportText()
                    } label: {
                        Label("Copy to Clipboard", systemImage: "doc.on.doc")
                    }

                    if vm.savedRunSummaries.count >= 2 {
                        Divider()
                        Button {
                            showCompareSheet = true
                        } label: {
                            Label("Compare Runs (\(vm.savedRunSummaries.count))", systemImage: "arrow.left.arrow.right")
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    vm.reset()
                } label: {
                    Label("New Test", systemImage: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheetView(items: [exportText])
        }
        .sheet(isPresented: $vm.showSessionLogSheet) {
            if let session = vm.selectedSessionForLog {
                TestDebugSessionLogSheet(session: session)
            }
        }
        .sheet(isPresented: $showCompareSheet) {
            TestDebugCompareView(runs: vm.savedRunSummaries)
        }
    }

    private var appliedToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
            Text("Settings Applied")
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            LinearGradient(colors: [.green, .green.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
        )
        .clipShape(Capsule())
        .shadow(color: .green.opacity(0.3), radius: 10, y: 4)
        .padding(.bottom, 20)
    }

    private var tabPicker: some View {
        VStack(spacing: 12) {
            summaryBar

            if vm.retryableSessionCount > 0 && !vm.isRunning {
                retryButton
            }

            HStack(spacing: 0) {
                ForEach(ResultsTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.spring(duration: 0.25)) {
                            selectedTab = tab
                        }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(selectedTab == tab ? .white : .secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                Group {
                                    if selectedTab == tab {
                                        Capsule()
                                            .fill(LinearGradient(colors: [.purple, .indigo], startPoint: .leading, endPoint: .trailing))
                                    }
                                }
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(Capsule())
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var retryButton: some View {
        Button {
            vm.retryFailedSessions()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                Text("RETRY FAILED (\(vm.retryableSessionCount))")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                LinearGradient(colors: [.orange, .red.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(.rect(cornerRadius: 10))
        }
        .padding(.horizontal, 16)
        .sensoryFeedback(.impact(weight: .medium), trigger: vm.isRetryingFailed)
    }

    private var summaryBar: some View {
        HStack(spacing: 16) {
            summaryPill(value: "\(vm.sessions.count)", label: "Total", color: .primary)
            summaryPill(value: "\(vm.successCount)", label: "Success", color: .green)
            summaryPill(value: "\(vm.failedCount)", label: "Failed", color: .red)
            summaryPill(value: "\(vm.unsureCount)", label: "Unsure", color: .yellow)
        }
        .padding(.horizontal, 16)
    }

    private func summaryPill(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .black, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var screenshotGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 14) {
                ForEach(vm.sessions) { session in
                    Button {
                        vm.showSessionLog(session)
                    } label: {
                        screenshotCard(session)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func screenshotCard(_ session: TestDebugSession) -> some View {
        VStack(spacing: 0) {
            Color(.tertiarySystemGroupedBackground)
                .frame(height: 140)
                .overlay {
                    if let img = session.finalScreenshot {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .allowsHitTesting(false)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: session.status.icon)
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(statusColor(session.status))
                            Text(session.status.rawValue)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Text("#\(session.index)")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.6))
                        .clipShape(.rect(cornerRadius: 6))
                        .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(statusColor(session.status))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                        .padding(8)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.differentiator)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Text(session.status.rawValue)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(session.status))
                    Spacer()
                    Text(session.formattedDuration)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var rankedList: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let winner = vm.winningSession {
                    winnerCard(winner)
                }

                ForEach(vm.rankedSessions) { session in
                    Button {
                        vm.showSessionLog(session)
                    } label: {
                        rankedRow(session)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func winnerCard(_ session: TestDebugSession) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.yellow)
                Text("OPTIMAL SETTINGS")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(session.formattedDuration)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Text(session.differentiator)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                vm.applyWinnerSettings()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 13, weight: .bold))
                    Text("APPLY THESE SETTINGS")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    LinearGradient(colors: [.purple, .indigo], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(.rect(cornerRadius: 10))
            }
            .sensoryFeedback(.success, trigger: vm.showAppliedToast)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color(red: 0.6, green: 0.5, blue: 0.1), Color(red: 0.4, green: 0.3, blue: 0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(.rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.yellow.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .yellow.opacity(0.15), radius: 12, y: 4)
    }

    private func rankedRow(_ session: TestDebugSession) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor(session.status).opacity(0.15))
                    .frame(width: 36, height: 36)
                Text("\(session.index)")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(statusColor(session.status))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(session.differentiator)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Image(systemName: session.status.icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(statusColor(session.status))
                    Text(session.status.rawValue)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(session.status))

                    if let err = session.errorMessage {
                        Text(err)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(session.formattedDuration)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var heatmapView: some View {
        ScrollView {
            let data = vm.buildHeatmapData()

            if data.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("No data yet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else {
                VStack(spacing: 16) {
                    heatmapLegend

                    ForEach(data) { dimension in
                        heatmapDimensionCard(dimension)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    private var heatmapLegend: some View {
        HStack(spacing: 4) {
            Text("0%")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            ForEach(0..<10, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(heatColor(Double(i) / 9.0))
                    .frame(height: 8)
            }

            Text("100%")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func heatmapDimensionCard(_ dimension: HeatmapDimension) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(dimension.name.uppercased())
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.secondary)

            ForEach(dimension.cells) { cell in
                HStack(spacing: 10) {
                    Text(cell.label)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 100, alignment: .leading)
                        .lineLimit(1)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(.tertiarySystemGroupedBackground))

                            RoundedRectangle(cornerRadius: 6)
                                .fill(heatColor(cell.rate))
                                .frame(width: max(0, geo.size.width * cell.rate))
                        }
                    }
                    .frame(height: 26)

                    Text("\(cell.successes)/\(cell.total)")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(heatColor(cell.rate))
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func heatColor(_ rate: Double) -> Color {
        if rate >= 0.75 {
            return .green
        } else if rate >= 0.5 {
            return .yellow
        } else if rate >= 0.25 {
            return .orange
        } else {
            return .red
        }
    }

    private func statusColor(_ status: TestDebugSessionStatus) -> Color {
        switch status {
        case .queued: .secondary
        case .running: .blue
        case .success: .green
        case .failed, .connectionFailure: .red
        case .unsure: .yellow
        case .timeout: .orange
        }
    }
}

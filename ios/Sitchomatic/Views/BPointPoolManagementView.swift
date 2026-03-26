import SwiftUI

struct BPointPoolManagementView: View {
    @State private var pool = BPointBillerPoolService.shared
    @State private var showResetConfirmation: Bool = false
    @State private var searchText: String = ""

    private var filteredBlacklist: [BillerBlacklistEntry] {
        if searchText.isEmpty { return pool.blacklistedBillers }
        let query = searchText.lowercased()
        return pool.blacklistedBillers.filter {
            $0.billerCode.contains(query) || $0.reason.lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            poolStatsSection
            actionsSection
            if !pool.blacklistedBillers.isEmpty {
                blacklistSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("BPoint Biller Pool")
        .searchable(text: $searchText, prompt: "Search blacklisted billers")
        .alert("Reset Biller Pool", isPresented: $showResetConfirmation) {
            Button("Reset All", role: .destructive) { pool.resetPool() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will restore all \(pool.blacklistedCount) blacklisted billers back to the active pool. This cannot be undone.")
        }
    }

    private var poolStatsSection: some View {
        Section {
            HStack(spacing: 0) {
                statCell(value: pool.activeBillerCount, label: "Active", color: .green)
                Divider().frame(height: 36)
                statCell(value: pool.blacklistedCount, label: "Blocked", color: .red)
                Divider().frame(height: 36)
                statCell(value: pool.totalBillerCount, label: "Total", color: .secondary)
            }
            .padding(.vertical, 4)

            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(poolHealthColor)
                    .font(.caption)
                Text("Pool Health")
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.1f%%", pool.poolHealthPercentage))
                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                    .foregroundStyle(poolHealthColor)
            }

            if pool.poolExhausted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Pool exhausted — all billers blacklisted. Reset to continue.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Label("Pool Status", systemImage: "chart.bar.fill")
        }
    }

    private var poolHealthColor: Color {
        let pct = pool.poolHealthPercentage
        if pct > 75 { return .green }
        if pct > 40 { return .yellow }
        if pct > 10 { return .orange }
        return .red
    }

    private func statCell(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var actionsSection: some View {
        Section {
            if pool.blacklistedCount > 0 {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset Pool — Restore All \(pool.blacklistedCount) Billers")
                    }
                }
            }

            if pool.blacklistedCount > 0 {
                ShareLink(
                    item: pool.exportBlacklist(),
                    subject: Text("BPoint Biller Blacklist"),
                    message: Text("Exported \(pool.blacklistedCount) blacklisted billers")
                ) {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export Blacklist")
                    }
                }
            }
        } header: {
            Label("Actions", systemImage: "gearshape.fill")
        }
    }

    private var blacklistSection: some View {
        Section {
            ForEach(filteredBlacklist) { entry in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.billerCode)
                            .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        Text(entry.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Text(entry.formattedDate)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        pool.restoreBiller(entry)
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.green)
                }
            }
        } header: {
            Label("Blacklisted Billers (\(filteredBlacklist.count))", systemImage: "xmark.circle.fill")
        } footer: {
            Text("Swipe left on a biller to restore it to the active pool.")
        }
    }
}

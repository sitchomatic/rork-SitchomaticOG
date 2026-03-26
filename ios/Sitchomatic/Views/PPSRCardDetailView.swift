import SwiftUI
import UIKit

struct PPSRCardDetailView: View {
    let card: PPSRCard
    let vm: PPSRAutomationViewModel
    @State private var showCopiedToast: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                cardHeader
                binDataSection
                statsSection
                actionsSection
                if !card.testResults.isEmpty { testHistorySection }
                infoSection
            }
            .listStyle(.insetGrouped)

            if showCopiedToast {
                Text("Copied to clipboard")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.green.gradient, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
            }
        }
        .navigationTitle(card.number)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if card.binData == nil { await card.loadBINData() }
        }
    }

    private var cardHeader: some View {
        Section {
            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(colors: [brandColor, brandColor.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 180)

                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Image(systemName: card.brand.iconName)
                                .font(.title)
                                .foregroundStyle(.white)
                            Spacer()
                            HStack(spacing: 4) {
                                Circle().fill(statusColor).frame(width: 6, height: 6)
                                Text(card.status.rawValue).font(.caption2.bold())
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                        }

                        Text(formattedCardNumber)
                            .font(.system(.title3, design: .monospaced, weight: .semibold))
                            .foregroundStyle(.white)
                            .tracking(2)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("EXPIRES").font(.system(.caption2, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                                Text(card.formattedExpiry).font(.system(.subheadline, design: .monospaced, weight: .medium)).foregroundStyle(.white)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("CVV").font(.system(.caption2, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                                Text(card.cvv).font(.system(.subheadline, design: .monospaced, weight: .medium)).foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        }
    }

    private var statusColor: Color {
        switch card.status {
        case .working: .green
        case .dead: .red
        case .testing: .orange
        case .untested: .secondary
        }
    }

    @ViewBuilder
    private var binDataSection: some View {
        if let binData = card.binData, binData.isLoaded {
            Section("BIN Information") {
                LabeledContent("BIN") { Text(card.binPrefix).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                if !binData.scheme.isEmpty { LabeledContent("Scheme", value: binData.scheme) }
                if !binData.type.isEmpty { LabeledContent("Type", value: binData.type.capitalized) }
                if !binData.category.isEmpty { LabeledContent("Category", value: binData.category.capitalized) }
                if !binData.issuer.isEmpty { LabeledContent("Issuer", value: binData.issuer) }
                if !binData.country.isEmpty {
                    LabeledContent("Country") {
                        HStack(spacing: 4) {
                            if !binData.countryCode.isEmpty { Text(flagEmoji(for: binData.countryCode)) }
                            Text(binData.country)
                        }
                    }
                }
            }
        } else {
            Section("BIN Information") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading BIN data...").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statsSection: some View {
        Section("Performance") {
            HStack {
                StatItem(value: "\(card.totalTests)", label: "Total Tests", color: .blue)
                StatItem(value: "\(card.successCount)", label: "Passed", color: .green)
                StatItem(value: "\(card.failureCount)", label: "Failed", color: .red)
            }
            if card.totalTests > 0 {
                LabeledContent("Success Rate") {
                    Text(String(format: "%.0f%%", card.successRate * 100))
                        .font(.system(.body, design: .monospaced, weight: .bold))
                        .foregroundStyle(card.successRate >= 0.5 ? .green : .red)
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                vm.testSingleCard(card)
            } label: {
                HStack {
                    Spacer()
                    Label("Run PPSR Test", systemImage: "play.fill").font(.headline)
                    Spacer()
                }
            }
            .disabled(card.status == .testing)
            .listRowBackground(card.status == .testing ? Color.teal.opacity(0.3) : Color.teal)
            .foregroundStyle(.white)

            Button {
                UIPasteboard.general.string = card.pipeFormat
                withAnimation(.spring(duration: 0.3)) { showCopiedToast = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation { showCopiedToast = false }
                }
            } label: {
                Label("Copy Card", systemImage: "doc.on.doc")
            }

            if card.status == .dead {
                Button { vm.restoreCard(card) } label: { Label("Restore Card", systemImage: "arrow.counterclockwise") }
                Button(role: .destructive) { vm.deleteCard(card) } label: { Label("Delete Permanently", systemImage: "trash") }
            }
        }
    }

    private var testHistorySection: some View {
        Section("Test History") {
            ForEach(card.testResults) { result in
                HStack(spacing: 10) {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.success ? .green : .red)
                        .font(.subheadline)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(result.success ? "Passed" : "Failed").font(.subheadline.bold()).foregroundStyle(result.success ? .green : .red)
                            Text(result.formattedDuration).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Text(result.formattedDate).font(.caption).foregroundStyle(.tertiary)
                        if let err = result.errorMessage {
                            Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var infoSection: some View {
        Section("Card Info") {
            LabeledContent("Brand", value: card.brand.rawValue)
            LabeledContent("Number") { Text(card.number).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
            LabeledContent("Expiry", value: card.formattedExpiry)
            LabeledContent("CVV", value: card.cvv)
            LabeledContent("Pipe Format") { Text(card.pipeFormat).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary) }
            LabeledContent("Added") { Text(card.addedAt, style: .date) }
            if let lastTest = card.lastTestedAt {
                LabeledContent("Last Tested") { Text(lastTest, style: .relative).foregroundStyle(.secondary) }
            }
        }
    }

    private var brandColor: Color {
        switch card.brand {
        case .visa: .blue
        case .mastercard: .orange
        case .amex: .green
        case .jcb: .red
        case .discover: .purple
        case .dinersClub: .indigo
        case .unionPay: .teal
        case .unknown: .gray
        }
    }

    private var formattedCardNumber: String {
        let num = card.number
        var groups: [String] = []
        var index = num.startIndex
        let groupSize = card.brand == .amex ? [4, 6, 5] : [4, 4, 4, 4]
        for size in groupSize {
            let end = num.index(index, offsetBy: min(size, num.distance(from: index, to: num.endIndex)))
            groups.append(String(num[index..<end]))
            index = end
            if index >= num.endIndex { break }
        }
        return groups.joined(separator: " ")
    }

    private func flagEmoji(for countryCode: String) -> String {
        let base: UInt32 = 127397
        return countryCode.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(base + $0.value).map { String($0) }
        }.joined()
    }
}

struct StatItem: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.system(.title2, design: .monospaced, weight: .bold)).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

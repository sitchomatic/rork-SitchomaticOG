import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct WorkingLoginsView: View {
    let vm: PPSRAutomationViewModel
    @State private var showCopiedToast: Bool = false
    @State private var showFileExporter: Bool = false
    @State private var exportDocument: CardExportDocument?
    @State private var viewMode: ViewMode = .list
    @State private var binFilter: String = ""
    @State private var showBINFilter: Bool = false

    private var filteredWorkingCards: [PPSRCard] {
        let cards = vm.workingCards
        if binFilter.isEmpty { return cards }
        return cards.filter { $0.binPrefix.hasPrefix(binFilter) }
    }

    private var availableBINs: [String] {
        let bins = Set(vm.workingCards.map(\.binPrefix))
        return bins.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            if filteredWorkingCards.isEmpty && binFilter.isEmpty && vm.workingCards.isEmpty {
                EmptyStateView(
                    icon: "checkmark.shield.fill",
                    title: "No Working Cards",
                    subtitle: "Cards that pass PPSR tests will appear here.",
                    accentColor: .green,
                    tips: [
                        EmptyStateTip(icon: "play.fill", text: "Run tests from the Dashboard to start validating cards"),
                        EmptyStateTip(icon: "doc.on.doc", text: "Working cards can be copied or exported as .txt")
                    ]
                )
            } else {
                exportBar
                if showBINFilter { binFilterSection }
                if filteredWorkingCards.isEmpty {
                    ContentUnavailableView("No Matches", systemImage: "magnifyingglass", description: Text("No working cards match BIN \(binFilter)"))
                } else if viewMode == .tile {
                    workingTileGrid
                } else {
                    cardsList
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Working Cards")
        .refreshable {
            vm.syncFromiCloud()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation(.snappy) { showBINFilter.toggle() } } label: {
                    Image(systemName: showBINFilter ? "number.circle.fill" : "number.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ViewModeToggle(mode: $viewMode, accentColor: .teal)
            }
            if !vm.workingCards.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { copyAllCards() } label: { Label("Copy All Cards", systemImage: "doc.on.doc") }
                        Button { exportAsTxt() } label: { Label("Export as .txt", systemImage: "square.and.arrow.up") }
                    } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                Text("Copied to clipboard")
                    .font(.subheadline.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(.green.gradient, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
            }
        }
        .sensoryFeedback(.success, trigger: copyHapticTrigger)
        .fileExporter(isPresented: $showFileExporter, document: exportDocument, contentType: .plainText, defaultFilename: "working_cards_\(dateStamp()).txt") { result in
            switch result {
            case .success: vm.log("Exported \(vm.workingCards.count) working cards to file", level: .success)
            case .failure(let error): vm.log("Export failed: \(error.localizedDescription)", level: .error)
            }
        }
    }

    private var exportBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(filteredWorkingCards.count) working cards").font(.subheadline.bold())
                if !binFilter.isEmpty {
                    Text("BIN: \(binFilter)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { copyAllCards() } label: {
                Label("Copy All", systemImage: "doc.on.doc")
                    .font(.caption.bold())
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.green.opacity(0.15)).foregroundStyle(.green).clipShape(Capsule())
            }
        }
        .padding(.horizontal).padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var binFilterSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "number").foregroundStyle(.teal)
                TextField("Filter by BIN (e.g. 411111)", text: $binFilter)
                    .font(.system(.body, design: .monospaced))
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                if !binFilter.isEmpty {
                    Button { withAnimation(.snappy) { binFilter = "" } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 10))

            if !availableBINs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChipSmall(title: "All", isSelected: binFilter.isEmpty) {
                            withAnimation(.snappy) { binFilter = "" }
                        }
                        ForEach(availableBINs, id: \.self) { bin in
                            FilterChipSmall(title: bin, isSelected: binFilter == bin) {
                                withAnimation(.snappy) { binFilter = bin }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal).padding(.bottom, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var cardsList: some View {
        List {
            ForEach(filteredWorkingCards) { card in
                let latestScreenshot = vm.screenshotsForCard(card.id).first?.image
                WorkingCardRow(card: card, onCopy: { copyCard(card) }, screenshot: latestScreenshot)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { copyCard(card) } label: { Label("Copy", systemImage: "doc.on.doc") }.tint(.green)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button { vm.retestCard(card) } label: { Label("Retest", systemImage: "arrow.clockwise") }.tint(.teal)
                    }
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
        }
        .listStyle(.insetGrouped)
    }

    private var workingTileGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(filteredWorkingCards) { card in
                    let latestScreenshot = vm.screenshotsForCard(card.id).first?.image
                    Button { copyCard(card) } label: {
                        ScreenshotTileView(
                            screenshot: latestScreenshot,
                            title: "\(card.brand.rawValue) \(card.number.suffix(4))",
                            subtitle: card.formattedExpiry,
                            statusColor: .green,
                            statusText: "Working",
                            badge: card.totalTests > 0 ? "\(card.successCount)/\(card.totalTests)" : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { copyCard(card) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button { vm.retestCard(card) } label: { Label("Retest", systemImage: "arrow.clockwise") }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    @State private var copyHapticTrigger: Int = 0

    private func copyCard(_ card: PPSRCard) {
        UIPasteboard.general.string = card.pipeFormat
        copyHapticTrigger += 1
        withAnimation(.spring(duration: 0.3)) { showCopiedToast = true }
        Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { showCopiedToast = false } }
    }

    private func copyAllCards() {
        let text = filteredWorkingCards.map(\.pipeFormat).joined(separator: "\n")
        UIPasteboard.general.string = text
        vm.log("Copied \(filteredWorkingCards.count) working cards to clipboard", level: .success)
        withAnimation(.spring(duration: 0.3)) { showCopiedToast = true }
        Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { showCopiedToast = false } }
    }

    private func exportAsTxt() {
        let text = vm.exportWorkingCards()
        exportDocument = CardExportDocument(text: text)
        showFileExporter = true
    }

    private func dateStamp() -> String {
        DateFormatters.fileStamp.string(from: Date())
    }
}

struct WorkingCardRow: View {
    let card: PPSRCard
    let onCopy: () -> Void
    var screenshot: UIImage? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let screenshot {
                Color.clear.frame(width: 40, height: 40)
                    .overlay { Image(uiImage: screenshot).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false) }
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(brandColor.opacity(0.12)).frame(width: 40, height: 40)
                    Image(systemName: card.brand.iconName).font(.title3.bold()).foregroundStyle(brandColor)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(card.brand.rawValue).font(.subheadline.bold())
                    Text(card.number).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(card.formattedExpiry).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                    Text("CVV \(card.cvv)").font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                    if card.totalTests > 0 {
                        Text("\(card.successCount)/\(card.totalTests)").font(.caption2.bold()).foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            Button { onCopy() } label: {
                Image(systemName: "doc.on.doc").font(.subheadline).foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private var brandColor: Color {
        switch card.brand {
        case .visa: .blue; case .mastercard: .orange; case .amex: .green; case .jcb: .red
        case .discover: .purple; case .dinersClub: .indigo; case .unionPay: .teal; case .unknown: .secondary
        }
    }
}

nonisolated struct CardExportDocument: FileDocument, Sendable {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws { text = "" }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SavedCredentialsView: View {
    let vm: PPSRAutomationViewModel
    @State private var showImportSheet: Bool = false
    @State private var importText: String = ""
    @State private var searchText: String = ""

    @State private var filterBrand: CardBrand? = nil
    @State private var filterStatus: CardStatus? = nil
    @State private var filterCountry: String? = nil
    @State private var filterBIN: String? = nil
    @State private var showFilters: Bool = false
    @State private var viewMode: ViewMode = .list
    @State private var showFileImporter: Bool = false
    @State private var fileImportResult: String? = nil
    @State private var selectedCSVMapping: PPSRCard.CSVColumnMapping = .auto
    @State private var isSelecting: Bool = false
    @State private var selectedCardIds: Set<String> = []
    @State private var showRemoveSelectedConfirm: Bool = false

    private var filteredCards: [PPSRCard] {
        var result = vm.cards.filter { $0.status != .dead }
        if !searchText.isEmpty {
            result = result.filter {
                $0.number.localizedStandardContains(searchText) ||
                $0.brand.rawValue.localizedStandardContains(searchText) ||
                $0.binPrefix.localizedStandardContains(searchText) ||
                ($0.binData?.country ?? "").localizedStandardContains(searchText) ||
                ($0.binData?.issuer ?? "").localizedStandardContains(searchText)
            }
        }
        if let brand = filterBrand { result = result.filter { $0.brand == brand } }
        if let status = filterStatus { result = result.filter { $0.status == status } }
        if let country = filterCountry, !country.isEmpty { result = result.filter { $0.binData?.country == country } }
        if let bin = filterBIN, !bin.isEmpty { result = result.filter { $0.binPrefix == bin } }
        return vm.applySortOrder(result)
    }

    private var availableCountries: [String] {
        Set(vm.cards.compactMap { $0.binData?.country }.filter { !$0.isEmpty }).sorted()
    }

    private var availableBINs: [String] {
        Set(vm.cards.filter { $0.status != .dead }.map(\.binPrefix)).sorted()
    }

    private var availableBrands: [CardBrand] {
        Set(vm.cards.map(\.brand)).sorted { $0.rawValue < $1.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            sortFilterBar
            if showFilters { filterSection }
            if isSelecting { selectionBar }
            if viewMode == .tile {
                cardsTileGrid
            } else {
                cardsList
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(isSelecting ? "\(selectedCardIds.count) Selected" : "Saved Cards")
        .searchable(text: $searchText, prompt: "Search cards, BIN, bank, country...")
        .refreshable {
            vm.syncFromiCloud()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button("Cancel") {
                        withAnimation(.snappy) { isSelecting = false; selectedCardIds.removeAll() }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy) {
                        isSelecting.toggle()
                        if !isSelecting { selectedCardIds.removeAll() }
                    }
                } label: {
                    Image(systemName: isSelecting ? "xmark.circle.fill" : "checkmark.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ViewModeToggle(mode: $viewMode, accentColor: .teal)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImportSheet = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation(.snappy) { showFilters.toggle() } } label: {
                    Image(systemName: showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showImportSheet) { importSheet }
        .alert("Remove \(selectedCardIds.count) Card\(selectedCardIds.count == 1 ? "" : "s")?", isPresented: $showRemoveSelectedConfirm) {
            Button("Remove", role: .destructive) {
                vm.deleteCards(withIds: selectedCardIds)
                withAnimation(.snappy) { isSelecting = false; selectedCardIds.removeAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the selected cards. This cannot be undone.")
        }
    }

    private var selectionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.snappy) {
                        if selectedCardIds.count == filteredCards.count {
                            selectedCardIds.removeAll()
                        } else {
                            selectedCardIds = Set(filteredCards.map(\.id))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: selectedCardIds.count == filteredCards.count ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                        Text(selectedCardIds.count == filteredCards.count ? "Deselect All" : "Select All")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.teal.opacity(0.15))
                    .foregroundStyle(.teal)
                    .clipShape(Capsule())
                }

                Spacer()

                if !selectedCardIds.isEmpty {
                    Button {
                        showRemoveSelectedConfirm = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash.fill").font(.caption)
                            Text("Remove \(selectedCardIds.count)")
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.red)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    .sensoryFeedback(.warning, trigger: showRemoveSelectedConfirm)

                    Button {
                        let cards = vm.cards.filter { selectedCardIds.contains($0.id) }
                        vm.testSelectedCards(cards)
                        withAnimation(.snappy) { isSelecting = false; selectedCardIds.removeAll() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.caption)
                            Text("Test \(selectedCardIds.count)")
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.teal)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    .disabled(vm.isRunning)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var sortFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(PPSRAutomationViewModel.CardSortOption.allCases) { option in
                        Button {
                            withAnimation(.snappy) {
                                if vm.cardSortOption == option { vm.cardSortAscending.toggle() }
                                else { vm.cardSortOption = option; vm.cardSortAscending = false }
                            }
                        } label: {
                            HStack {
                                Text(option.rawValue)
                                if vm.cardSortOption == option { Image(systemName: vm.cardSortAscending ? "chevron.up" : "chevron.down") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down").font(.caption2)
                        Text(vm.cardSortOption.rawValue).font(.subheadline.weight(.medium))
                        Image(systemName: vm.cardSortAscending ? "chevron.up" : "chevron.down").font(.caption2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.teal.opacity(0.15))
                    .foregroundStyle(.teal)
                    .clipShape(Capsule())
                }

                Text("\(filteredCards.count) cards")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill)).clipShape(Capsule())

                if filterBrand != nil || filterStatus != nil || filterCountry != nil || filterBIN != nil {
                    Button {
                        withAnimation(.snappy) { filterBrand = nil; filterStatus = nil; filterCountry = nil; filterBIN = nil }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark").font(.caption2)
                            Text("Clear").font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.red.opacity(0.12)).foregroundStyle(.red).clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
        }
    }

    private var filterSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("Brand").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChipSmall(title: "All", isSelected: filterBrand == nil) { withAnimation(.snappy) { filterBrand = nil } }
                        ForEach(availableBrands, id: \.self) { brand in
                            FilterChipSmall(title: brand.rawValue, isSelected: filterBrand == brand) { withAnimation(.snappy) { filterBrand = brand } }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text("Status").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChipSmall(title: "All", isSelected: filterStatus == nil) { withAnimation(.snappy) { filterStatus = nil } }
                        FilterChipSmall(title: "Working", isSelected: filterStatus == .working) { withAnimation(.snappy) { filterStatus = .working } }
                        FilterChipSmall(title: "Untested", isSelected: filterStatus == .untested) { withAnimation(.snappy) { filterStatus = .untested } }
                    }
                }
            }
            if !availableCountries.isEmpty {
                HStack(spacing: 8) {
                    Text("Country").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            FilterChipSmall(title: "All", isSelected: filterCountry == nil) { withAnimation(.snappy) { filterCountry = nil } }
                            ForEach(availableCountries, id: \.self) { country in
                                FilterChipSmall(title: country, isSelected: filterCountry == country) { withAnimation(.snappy) { filterCountry = country } }
                            }
                        }
                    }
                }
            }
            if availableBINs.count > 1 {
                HStack(spacing: 8) {
                    Text("BIN").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            FilterChipSmall(title: "All", isSelected: filterBIN == nil) { withAnimation(.snappy) { filterBIN = nil } }
                            ForEach(availableBINs, id: \.self) { bin in
                                FilterChipSmall(title: bin, isSelected: filterBIN == bin) { withAnimation(.snappy) { filterBIN = bin } }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal).padding(.bottom, 10)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var cardsList: some View {
        Group {
            if filteredCards.isEmpty {
                if vm.cards.isEmpty {
                    EmptyStateView(
                        icon: "creditcard.fill",
                        title: "No Cards",
                        subtitle: "Import cards to get started.",
                        accentColor: .teal,
                        actionTitle: "Import Cards",
                        action: { showImportSheet = true },
                        tips: [
                            EmptyStateTip(icon: "doc.on.clipboard", text: "Paste cards from clipboard in pipe, colon, or comma format"),
                            EmptyStateTip(icon: "doc.badge.plus", text: "Import CSV/TSV files via the file browser"),
                            EmptyStateTip(icon: "arrow.triangle.2.circlepath", text: "Duplicates are automatically excluded")
                        ]
                    )
                } else {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No Matches",
                        subtitle: "Try adjusting your filters or search terms.",
                        accentColor: .secondary
                    )
                }
            } else {
                List {
                    ForEach(filteredCards) { card in
                        if isSelecting {
                            Button {
                                withAnimation(.snappy) {
                                    if selectedCardIds.contains(card.id) {
                                        selectedCardIds.remove(card.id)
                                    } else {
                                        selectedCardIds.insert(card.id)
                                    }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedCardIds.contains(card.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(selectedCardIds.contains(card.id) ? .teal : .secondary)
                                    SavedCardRow(card: card)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(selectedCardIds.contains(card.id) ? Color.teal.opacity(0.08) : Color(.secondarySystemGroupedBackground))
                        } else {
                            NavigationLink(value: card.id) {
                                SavedCardRow(card: card)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { vm.deleteCard(card) } label: { Label("Delete", systemImage: "trash") }
                                Button { vm.testSingleCard(card) } label: { Label("Test", systemImage: "play.fill") }.tint(.teal)
                            }
                            .listRowBackground(Color(.secondarySystemGroupedBackground))
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var cardsTileGrid: some View {
        Group {
            if filteredCards.isEmpty {
                if vm.cards.isEmpty {
                    EmptyStateView(
                        icon: "creditcard.fill",
                        title: "No Cards",
                        subtitle: "Import cards to get started.",
                        accentColor: .teal,
                        actionTitle: "Import Cards",
                        action: { showImportSheet = true },
                        tips: [
                            EmptyStateTip(icon: "doc.on.clipboard", text: "Paste cards from clipboard in pipe, colon, or comma format"),
                            EmptyStateTip(icon: "doc.badge.plus", text: "Import CSV/TSV files via the file browser"),
                            EmptyStateTip(icon: "arrow.triangle.2.circlepath", text: "Duplicates are automatically excluded")
                        ]
                    )
                } else {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No Matches",
                        subtitle: "Try adjusting your filters or search terms.",
                        accentColor: .secondary
                    )
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(filteredCards) { card in
                            NavigationLink(value: card.id) {
                                let screenshot = vm.screenshotsForCard(card.id).first?.image
                                ScreenshotTileView(
                                    screenshot: screenshot,
                                    title: "\(card.brand.rawValue) \(card.number.suffix(4))",
                                    subtitle: card.formattedExpiry,
                                    statusColor: cardTileStatusColor(card.status),
                                    statusText: card.status.rawValue,
                                    badge: card.totalTests > 0 ? "\(card.successCount)/\(card.totalTests)" : nil
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 32)
                }
            }
        }
    }

    private func cardTileStatusColor(_ status: CardStatus) -> Color {
        switch status {
        case .working: .green
        case .dead: .red
        case .testing: .teal
        case .untested: .secondary
        }
    }

    @State private var showFormatHelp: Bool = false

    private var importSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        HStack(spacing: 14) {
                            Image(systemName: "doc.badge.plus")
                                .font(.title2)
                                .foregroundStyle(.teal)
                                .frame(width: 44, height: 44)
                                .background(.teal.opacity(0.12))
                                .clipShape(.rect(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Import from File")
                                    .font(.headline)
                                Text("CSV, TSV, or XLSX")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                showFileImporter = true
                            } label: {
                                Text("Browse")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16).padding(.vertical, 8)
                                    .background(.teal)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            }
                        }

                        Picker("Column Mapping", selection: $selectedCSVMapping) {
                            Text("Auto Detect").tag(PPSRCard.CSVColumnMapping.auto)
                            Text("Columns A, B, C").tag(PPSRCard.CSVColumnMapping.columnsABC)
                            Text("Columns C, E, F").tag(PPSRCard.CSVColumnMapping.columnsCEF)
                        }
                        .pickerStyle(.segmented)
                        .font(.caption)
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Paste Cards", systemImage: "doc.on.doc")
                                .font(.headline)
                            Spacer()
                            Button {
                                showFormatHelp = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "questionmark.circle")
                                    Text("Formats")
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.teal)
                            }
                        }

                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $importText)
                                .font(.system(.body, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(12)
                                .frame(minHeight: 220)

                            if importText.isEmpty {
                                Text("Paste cards in any format...")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.quaternary)
                                    .padding(.horizontal, 16).padding(.vertical, 20)
                                    .allowsHitTesting(false)
                            }
                        }
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 12))

                        HStack(spacing: 8) {
                            Button {
                                if let clip = UIPasteboard.general.string { importText = clip }
                            } label: {
                                Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                                    .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .tint(.teal)
                            .controlSize(.small)

                            Spacer()

                            let lineCount = importText.components(separatedBy: .newlines).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count
                            if lineCount > 0 {
                                Text("\(lineCount) lines")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color(.tertiarySystemFill))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 14))

                    if let result = fileImportResult {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.green)
                            Text(result)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                            Spacer()
                        }
                        .padding(14)
                        .background(Color.green.opacity(0.1))
                        .clipShape(.rect(cornerRadius: 12))
                    }

                    Button {
                        vm.smartImportCards(importText)
                        importText = ""
                        showImportSheet = false
                        fileImportResult = nil
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.down.fill")
                            Text("Import Cards")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.teal.opacity(0.4) : Color.teal)
                        .foregroundStyle(.white)
                        .clipShape(.rect(cornerRadius: 14))
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Import Cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showImportSheet = false
                        importText = ""
                        fileImportResult = nil
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, UTType(filenameExtension: "xlsx") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    guard url.startAccessingSecurityScopedResource() else {
                        vm.log("File access denied", level: .error)
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }

                    let ext = url.pathExtension.lowercased()
                    if ext == "xlsx" {
                        if let csvText = parseXLSXasCSV(url: url) {
                            let r = vm.importFromCSV(csvText, mapping: selectedCSVMapping)
                            fileImportResult = "\(r.added) added, \(r.duplicates) duplicates skipped"
                        } else {
                            vm.log("Could not parse XLSX file — try exporting as CSV", level: .error)
                            fileImportResult = "XLSX parse failed — export as CSV instead"
                        }
                    } else {
                        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                            let r = vm.importFromCSV(text, mapping: selectedCSVMapping)
                            fileImportResult = "\(r.added) added, \(r.duplicates) duplicates skipped"
                        } else {
                            vm.log("Could not read file", level: .error)
                        }
                    }
                case .failure(let error):
                    vm.log("File import error: \(error.localizedDescription)", level: .error)
                }
            }
            .sheet(isPresented: $showFormatHelp) {
                formatHelpSheet
            }
        }
    }

    private var formatHelpSheet: some View {
        NavigationStack {
            List {
                Section("Delimiter Formats") {
                    VStack(alignment: .leading, spacing: 6) {
                        formatExampleRow(label: "Pipe", example: "4111111111111111|12|28|123")
                        formatExampleRow(label: "Colon", example: "4111111111111111:12:28:123")
                        formatExampleRow(label: "Comma", example: "4111111111111111,12,28,123")
                    }
                }

                Section("Rich Text (Order Format)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Single line:")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        Text("CCNUM: 5473541007693740 CVV: 054 EXP DATE: 12/27")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.teal)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Multi-line block:")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        Text("CCNUM: 5483227225881915\nCVV: 680\nEXP DATE: 01/29")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.teal)
                    }
                }

                Section("CSV / File Import") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Columns A, B, C → Card Number, Expiry, CVV")
                            .font(.caption)
                        Text("Columns C, E, F → Card Number, Expiry, CVV")
                            .font(.caption)
                        Text("Auto detect tries C,E,F first then A,B,C.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.teal)
                        Text("Duplicates are always excluded automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Supported Formats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showFormatHelp = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func formatExampleRow(label: String, example: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            Text(example)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.teal)
        }
    }

    private func parseXLSXasCSV(url: URL) -> String? {
        if let csvText = XLSXParserService.parseToCSV(url: url) {
            return csvText
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else { return nil }
        if content.contains(",") || content.contains("\t") {
            return content
        }
        return nil
    }
}

struct SavedCardRow: View {
    let card: PPSRCard

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(brandColor.opacity(0.12)).frame(width: 40, height: 40)
                Image(systemName: card.brand.iconName).font(.title3.bold()).foregroundStyle(brandColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(card.brand.rawValue).font(.subheadline.bold())
                    Text(card.number).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(card.formattedExpiry).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                    if let binData = card.binData, binData.isLoaded {
                        if !binData.country.isEmpty {
                            Text(binData.country).font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color(.tertiarySystemFill)).clipShape(Capsule())
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("BIN \(card.binPrefix)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                    if card.totalTests > 0 {
                        Text("\(card.successCount)/\(card.totalTests)").font(.caption2.bold())
                            .foregroundStyle(card.lastTestSuccess == true ? .green : .red)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 3) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(card.status.rawValue).font(.system(.caption2, design: .monospaced)).foregroundStyle(statusColor)
                }
                if card.status == .testing { ProgressView().controlSize(.small).tint(.teal) }
            }
        }
        .padding(.vertical, 4)
        .task { if card.binData == nil { await card.loadBINData() } }
    }

    private var brandColor: Color {
        switch card.brand {
        case .visa: .blue; case .mastercard: .orange; case .amex: .green; case .jcb: .red
        case .discover: .purple; case .dinersClub: .indigo; case .unionPay: .teal; case .unknown: .secondary
        }
    }

    private var statusColor: Color {
        switch card.status {
        case .working: .green; case .dead: .red; case .testing: .teal; case .untested: .secondary
        }
    }
}

struct FilterChipSmall: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(isSelected ? Color.teal : Color(.tertiarySystemFill))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

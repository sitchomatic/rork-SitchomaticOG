import SwiftUI
import UIKit

struct EvidenceBundleListView: View {
    @State private var vm = EvidenceBundleViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            filterBar

            if vm.filteredBundles.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(vm.filteredBundles) { bundle in
                        NavigationLink(value: bundle.id) {
                            EvidenceBundleRowView(bundle: bundle)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .swipeActions(edge: .trailing) {
                            Button {
                                vm.exportJSON(bundle)
                            } label: {
                                Label("JSON", systemImage: "doc.text.fill")
                            }
                            .tint(.cyan)

                            Button {
                                vm.exportText(bundle)
                            } label: {
                                Label("Text", systemImage: "doc.plaintext")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .searchable(text: $vm.searchText, prompt: "Search credentials, URLs...")
        .navigationTitle("Evidence Bundles")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: UUID.self) { bundleId in
            if let bundle = vm.filteredBundles.first(where: { $0.id == bundleId }) ?? EvidenceBundleService.shared.bundles.first(where: { $0.id == bundleId }) {
                EvidenceBundleDetailView(bundle: bundle, vm: vm)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Button("Export All (JSON)", systemImage: "square.and.arrow.up") {
                            vm.exportAllJSON()
                        }
                        Button("Export Unexported (JSON)", systemImage: "square.and.arrow.up.on.square") {
                            vm.exportBatchJSON()
                        }
                    }
                    Section {
                        Button("Clear Exported", systemImage: "trash") {
                            vm.clearExported()
                        }
                        Button("Clear All", systemImage: "trash.fill", role: .destructive) {
                            vm.clearAll()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .semibold))
                }
            }

            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 6) {
                    Text("\(vm.totalCount)")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("bundles")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                    if vm.exportedCount > 0 {
                        Text("·")
                            .foregroundStyle(.white.opacity(0.2))
                        Text("\(vm.exportedCount)")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.green)
                        Text("exported")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green.opacity(0.6))
                    }
                }
            }
        }
        .sheet(isPresented: $vm.showShareSheet) {
            if !vm.shareItems.isEmpty {
                ActivityViewWrapper(activityItems: vm.shareItems)
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(EvidenceBundleViewModel.BundleFilter.allCases, id: \.self) { filter in
                    filterChip(filter)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func filterChip(_ filter: EvidenceBundleViewModel.BundleFilter) -> some View {
        let count = vm.countFor(filter)
        return Button {
            withAnimation(.spring(duration: 0.2)) {
                vm.selectedFilter = filter
            }
        } label: {
            HStack(spacing: 4) {
                Text(filter.rawValue)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(vm.selectedFilter == filter ? Color.white.opacity(0.2) : Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(vm.selectedFilter == filter ? .white : .white.opacity(0.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(vm.selectedFilter == filter ? filterColor(filter).opacity(0.2) : Color.white.opacity(0.05))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    vm.selectedFilter == filter ? filterColor(filter).opacity(0.4) : Color.white.opacity(0.1),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
    }

    private func filterColor(_ filter: EvidenceBundleViewModel.BundleFilter) -> Color {
        switch filter {
        case .all: .blue
        case .working: .green
        case .noAcc: .red
        case .tempDis: .orange
        case .permDis: .purple
        case .unsure: .yellow
        case .exported: .cyan
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "archivebox")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.15))
            Text("No Evidence Bundles")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            Text("Forensic bundles are created automatically\nfor each completed run with full audit trail.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct EvidenceBundleRowView: View {
    let bundle: EvidenceBundle

    var body: some View {
        HStack(spacing: 10) {
            confidenceRing

            VStack(alignment: .leading, spacing: 3) {
                Text(bundle.username)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    statusBadge
                    if bundle.isExported {
                        exportedBadge
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(bundle.durationFormatted)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Text(bundle.createdAt, style: .relative)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(12)
        .background(cardBackground)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
    }

    private var confidenceRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 3)
                .frame(width: 36, height: 36)
            Circle()
                .trim(from: 0, to: bundle.confidence)
                .stroke(confidenceColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 36, height: 36)
                .rotationEffect(.degrees(-90))
            Text("\(Int(bundle.confidence * 100))")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(confidenceColor)
        }
    }

    private var confidenceColor: Color {
        if bundle.confidence < 0.4 { return .red }
        if bundle.confidence < 0.7 { return .orange }
        return .green
    }

    private var statusBadge: some View {
        Text(bundle.outcomeLabel.uppercased())
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private var exportedBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 7))
            Text("EXPORTED")
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
        }
        .foregroundStyle(.cyan)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.cyan.opacity(0.1))
        .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch bundle.resultStatus {
        case .working: .green
        case .noAcc: .red
        case .tempDisabled: .orange
        case .permDisabled: .purple
        case .unsure: .yellow
        case .untested: .gray
        case .testing: .blue
        }
    }

    private var cardBackground: Color {
        bundle.isExported ? Color.white.opacity(0.03) : Color.white.opacity(0.05)
    }

    private var borderColor: Color {
        bundle.isExported ? .cyan.opacity(0.15) : statusColor.opacity(0.2)
    }
}

struct ActivityViewWrapper: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

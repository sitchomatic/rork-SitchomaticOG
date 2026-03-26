import SwiftUI

struct ReviewQueueView: View {
    @State private var vm = ReviewQueueViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            
            if vm.filteredItems.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(vm.filteredItems) { item in
                        ReviewItemCardView(item: item, vm: vm)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if !item.isResolved {
                                    Button {
                                        vm.selectedItem = item
                                        vm.showOverridePicker = true
                                    } label: {
                                        Label("Override", systemImage: "pencil.circle.fill")
                                    }
                                    .tint(.orange)
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if !item.isResolved {
                                    Button {
                                        withAnimation(.spring(duration: 0.3)) {
                                            vm.approve(item)
                                        }
                                    } label: {
                                        Label("Approve", systemImage: "checkmark.circle.fill")
                                    }
                                    .tint(.green)
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .searchable(text: $vm.searchText, prompt: "Search credentials, URLs...")
        .navigationTitle("Review Queue")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    EvidenceBundleListView()
                } label: {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Expire Old Items", systemImage: "clock.badge.xmark") {
                        vm.expireOld()
                    }
                    Button("Clear Resolved", systemImage: "trash") {
                        vm.clearResolved()
                    }
                    Divider()
                    Button("Clear All", systemImage: "trash.fill", role: .destructive) {
                        vm.clearAll()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .sheet(isPresented: $vm.showOverridePicker) {
            if let item = vm.selectedItem {
                OverridePickerSheet(item: item, vm: vm)
                    .presentationDetents([.height(320)])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ReviewQueueViewModel.ReviewFilter.allCases, id: \.self) { filter in
                    filterChip(filter)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func filterChip(_ filter: ReviewQueueViewModel.ReviewFilter) -> some View {
        let count: Int = {
            switch filter {
            case .pending: vm.pendingCount
            case .resolved: vm.resolvedCount
            case .expired: vm.expiredCount
            case .all: vm.totalCount
            }
        }()

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
            .background(vm.selectedFilter == filter ? Color.yellow.opacity(0.2) : Color.white.opacity(0.05))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    vm.selectedFilter == filter ? Color.yellow.opacity(0.4) : Color.white.opacity(0.1),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green.opacity(0.4))
            Text("No Items to Review")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            Text("Uncertain outcomes will appear here\nfor manual review when confidence is below 70%.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct ReviewItemCardView: View {
    let item: ReviewItem
    let vm: ReviewQueueViewModel
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow
            
            if isExpanded {
                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.vertical, 8)
                ReviewItemDetailView(item: item, vm: vm)
            }
        }
        .padding(12)
        .background(cardBackground)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                isExpanded.toggle()
            }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 10) {
            confidenceRing

            VStack(alignment: .leading, spacing: 3) {
                Text(item.username)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    outcomeBadge
                    if item.isResolved, let resolved = item.resolvedOutcome {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.3))
                        resolvedBadge(resolved)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(item.createdAt, style: .relative)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private var confidenceRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 3)
                .frame(width: 36, height: 36)
            Circle()
                .trim(from: 0, to: item.confidence)
                .stroke(confidenceColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 36, height: 36)
                .rotationEffect(.degrees(-90))
            Text("\(Int(item.confidence * 100))")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(confidenceColor)
        }
    }

    private var confidenceColor: Color {
        if item.confidence < 0.4 { return .red }
        if item.confidence < 0.6 { return .orange }
        return .yellow
    }

    private var outcomeBadge: some View {
        Text(item.suggestedStatusLabel.uppercased())
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundStyle(outcomeColor(item.suggestedOutcome))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(outcomeColor(item.suggestedOutcome).opacity(0.12))
            .clipShape(Capsule())
    }

    private func resolvedBadge(_ status: CredentialStatus) -> some View {
        Text(status.rawValue.uppercased())
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor(status).opacity(0.12))
            .clipShape(Capsule())
    }

    private var cardBackground: Color {
        if item.isResolved { return Color.white.opacity(0.03) }
        if item.isExpired { return Color.red.opacity(0.04) }
        return Color.white.opacity(0.05)
    }

    private var borderColor: Color {
        if item.isResolved { return .green.opacity(0.2) }
        if item.isExpired { return .red.opacity(0.2) }
        return confidenceColor.opacity(0.2)
    }

    private func outcomeColor(_ outcome: LoginOutcome) -> Color {
        switch outcome {
        case .success: .green
        case .noAcc: .red
        case .tempDisabled: .orange
        case .permDisabled: .purple
        case .unsure: .yellow
        case .connectionFailure: .gray
        case .timeout: .gray
        case .redBannerError: .red
        case .smsDetected: .cyan
        }
    }

    private func statusColor(_ status: CredentialStatus) -> Color {
        switch status {
        case .working: .green
        case .noAcc: .red
        case .tempDisabled: .orange
        case .permDisabled: .purple
        case .unsure: .yellow
        case .untested: .gray
        case .testing: .blue
        }
    }
}

struct OverridePickerSheet: View {
    let item: ReviewItem
    let vm: ReviewQueueViewModel

    @Environment(\.dismiss) private var dismiss

    private let options: [(CredentialStatus, String, String, Color)] = [
        (.working, "checkmark.circle.fill", "Working", .green),
        (.noAcc, "xmark.circle.fill", "No Account", .red),
        (.tempDisabled, "clock.badge.exclamationmark", "Temp Disabled", .orange),
        (.permDisabled, "lock.fill", "Perm Disabled", .purple),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text(item.username)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("@ \(Int(item.confidence * 100))%")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.top, 8)

                ForEach(options, id: \.0) { status, icon, label, color in
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            vm.override(item, as: status)
                        }
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon)
                                .font(.system(size: 18))
                                .foregroundStyle(color)
                                .frame(width: 28)
                            Text(label)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.2))
                        }
                        .padding(12)
                        .background(color.opacity(0.08))
                        .clipShape(.rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.impact(weight: .medium), trigger: item.isResolved)
                }
            }
            .padding(.horizontal, 16)
            .navigationTitle("Override Outcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

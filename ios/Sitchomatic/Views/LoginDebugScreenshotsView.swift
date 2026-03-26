import SwiftUI
import UIKit

struct LoginDebugScreenshotsView: View {
    @Bindable var vm: LoginViewModel
    @State private var selectedScreenshot: PPSRDebugScreenshot?
    @State private var selectedAlbum: LoginScreenshotAlbum?
    @State private var selectedCategory: ScreenshotCategory = .all
    @State private var showFlipbook: Bool = false
    @State private var flipbookStartIndex: Int = 0
    @State private var showEvidenceBundles: Bool = false
    @State private var showReviewQueue: Bool = false
    @State private var showSpeedStatus: Bool = false

    private enum ScreenshotCategory: String, CaseIterable {
        case all = "All"
        case working = "Working"
        case noAcc = "No Acc"
        case permDisabled = "Perm Dis"
        case tempDisabled = "Temp Dis"
        case unsure = "Unsure"
        case overridden = "Overridden"
        case aiDetected = "AI Detected"

        var icon: String {
            switch self {
            case .all: "photo.stack"
            case .working: "checkmark.seal.fill"
            case .noAcc: "xmark.seal.fill"
            case .permDisabled: "lock.slash.fill"
            case .tempDisabled: "clock.badge.exclamationmark.fill"
            case .unsure: "questionmark.diamond.fill"
            case .overridden: "hand.point.up.left.fill"
            case .aiDetected: "cpu"
            }
        }

        var color: Color {
            switch self {
            case .all: .blue
            case .working: .green
            case .noAcc: .red
            case .permDisabled: .purple
            case .tempDisabled: .orange
            case .unsure: .yellow
            case .overridden: .cyan
            case .aiDetected: .indigo
            }
        }
    }

    private var albums: [LoginScreenshotAlbum] {
        let filtered = filteredScreenshots
        let grouped = Dictionary(grouping: filtered) { $0.albumKey }
        return grouped.map { key, shots in
            let credId = shots.first?.cardId ?? ""
            let credential = vm.credentials.first(where: { $0.id == credId })
            return LoginScreenshotAlbum(
                id: key,
                credentialUsername: shots.first?.cardDisplayNumber ?? "",
                credentialId: credId,
                credentialStatus: credential?.status,
                screenshots: shots.sorted { $0.timestamp > $1.timestamp }
            )
        }.sorted { $0.latestTimestamp > $1.latestTimestamp }
    }

    private var filteredScreenshots: [PPSRDebugScreenshot] {
        switch selectedCategory {
        case .all:
            return vm.debugScreenshots
        case .working:
            return vm.debugScreenshots.filter { matchesCredentialStatus($0, .working) }
        case .noAcc:
            return vm.debugScreenshots.filter { matchesCredentialStatus($0, .noAcc) }
        case .permDisabled:
            return vm.debugScreenshots.filter { matchesCredentialStatus($0, .permDisabled) }
        case .tempDisabled:
            return vm.debugScreenshots.filter { matchesCredentialStatus($0, .tempDisabled) }
        case .unsure:
            return vm.debugScreenshots.filter { matchesCredentialStatus($0, .unsure) }
        case .overridden:
            return vm.debugScreenshots.filter { $0.hasUserOverride }
        case .aiDetected:
            return vm.debugScreenshots.filter { $0.autoDetectedResult != .unknown }
        }
    }

    private func matchesCredentialStatus(_ screenshot: PPSRDebugScreenshot, _ status: CredentialStatus) -> Bool {
        guard let cred = vm.credentials.first(where: { $0.id == screenshot.cardId }) else { return false }
        return cred.status == status
    }

    private func countForCategory(_ category: ScreenshotCategory) -> Int {
        switch category {
        case .all: return vm.debugScreenshots.count
        case .working: return vm.debugScreenshots.filter { matchesCredentialStatus($0, .working) }.count
        case .noAcc: return vm.debugScreenshots.filter { matchesCredentialStatus($0, .noAcc) }.count
        case .permDisabled: return vm.debugScreenshots.filter { matchesCredentialStatus($0, .permDisabled) }.count
        case .tempDisabled: return vm.debugScreenshots.filter { matchesCredentialStatus($0, .tempDisabled) }.count
        case .unsure: return vm.debugScreenshots.filter { matchesCredentialStatus($0, .unsure) }.count
        case .overridden: return vm.debugScreenshots.filter { $0.hasUserOverride }.count
        case .aiDetected: return vm.debugScreenshots.filter { $0.autoDetectedResult != .unknown }.count
        }
    }

    var body: some View {
        Group {
            if vm.debugScreenshots.isEmpty {
                ContentUnavailableView("No Screenshots", systemImage: "photo.stack", description: Text("Enable Debug Mode and run a test to capture screenshots."))
            } else {
                VStack(spacing: 0) {
                    categoryFilterBar
                    speedAdaptationBanner
                    albumsList
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("Debug Screenshots")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Actions") {
                        Button {
                            showReviewQueue = true
                        } label: {
                            Label("Review Queue", systemImage: "checklist")
                        }
                        Button {
                            showEvidenceBundles = true
                        } label: {
                            Label("Evidence Bundles", systemImage: "archivebox.fill")
                        }
                    }
                    Section("Speed") {
                        Button {
                            showSpeedStatus.toggle()
                        } label: {
                            Label("Speed Status", systemImage: "gauge.with.dots.needle.67percent")
                        }
                        Button {
                            LiveSpeedAdaptationService.shared.reset()
                        } label: {
                            Label("Reset Speed Adaptation", systemImage: "arrow.counterclockwise")
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            vm.clearDebugScreenshots()
                        } label: {
                            Label("Clear All Screenshots", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $selectedScreenshot) { screenshot in
            LoginScreenshotCorrectionSheet(screenshot: screenshot, vm: vm)
        }
        .sheet(item: $selectedAlbum) { album in
            LoginAlbumDetailSheet(album: album, vm: vm)
        }
        .sheet(isPresented: $showEvidenceBundles) {
            NavigationStack {
                EvidenceBundleListView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showEvidenceBundles = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showReviewQueue) {
            NavigationStack {
                ReviewQueueView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showReviewQueue = false }
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $showFlipbook) {
            ScreenshotFlipbookView(screenshots: filteredScreenshots, startIndex: flipbookStartIndex)
        }
    }

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ScreenshotCategory.allCases, id: \.self) { category in
                    categoryChip(category)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func categoryChip(_ category: ScreenshotCategory) -> some View {
        let count = countForCategory(category)
        let isSelected = selectedCategory == category
        return Button {
            withAnimation(.spring(duration: 0.25)) {
                selectedCategory = category
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: category.icon)
                    .font(.system(size: 10, weight: .bold))
                Text(category.rawValue)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(isSelected ? .white.opacity(0.2) : .primary.opacity(0.08))
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(isSelected ? .white : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(isSelected ? category.color.opacity(0.7) : Color(.tertiarySystemGroupedBackground))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selectedCategory)
    }

    private var speedAdaptationBanner: some View {
        Group {
            if showSpeedStatus {
                let liveSpeed = LiveSpeedAdaptationService.shared
                HStack(spacing: 8) {
                    Image(systemName: liveSpeed.currentSpeedMultiplier < 1.0 ? "hare.fill" : (liveSpeed.currentSpeedMultiplier > 1.0 ? "tortoise.fill" : "gauge.with.dots.needle.50percent"))
                        .font(.caption)
                        .foregroundStyle(liveSpeed.currentSpeedMultiplier < 1.0 ? .green : (liveSpeed.currentSpeedMultiplier > 1.0 ? .orange : .blue))
                    Text(liveSpeed.statusSummary())
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        withAnimation(.snappy) { showSpeedStatus = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color(.secondarySystemGroupedBackground))
            }
        }
    }

    private var albumsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(albums) { album in
                    Button { selectedAlbum = album } label: {
                        LoginAlbumCard(album: album, vm: vm)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let credId = album.credentialId.nilIfEmpty, let cred = vm.credentials.first(where: { $0.id == credId }) {
                            Section("Credential: \(cred.username.prefix(20))") {
                                Label("Status: \(cred.displayStatus)", systemImage: statusIcon(for: cred.status))
                            }
                            Section("Quick Actions") {
                                Button {
                                    if let shot = album.screenshots.first {
                                        vm.correctResult(for: shot, override: .success)
                                    }
                                } label: {
                                    Label("Mark Success", systemImage: "checkmark.circle.fill")
                                }
                                Button {
                                    if let shot = album.screenshots.first {
                                        vm.correctResult(for: shot, override: .noAcc)
                                    }
                                } label: {
                                    Label("Mark No Acc", systemImage: "xmark.circle.fill")
                                }
                                Button {
                                    if let shot = album.screenshots.first {
                                        vm.correctResult(for: shot, override: .permDisabled)
                                    }
                                } label: {
                                    Label("Mark Perm Disabled", systemImage: "lock.slash.fill")
                                }
                                Button {
                                    if let shot = album.screenshots.first {
                                        vm.correctResult(for: shot, override: .tempDisabled)
                                    }
                                } label: {
                                    Label("Mark Temp Disabled", systemImage: "clock.badge.exclamationmark")
                                }
                                Button {
                                    if let shot = album.screenshots.first {
                                        vm.requeueCredentialFromScreenshot(shot)
                                    }
                                } label: {
                                    Label("Retest Credential", systemImage: "arrow.clockwise")
                                }
                            }
                        }
                    }
                }

                if filteredScreenshots.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: selectedCategory.icon)
                            .font(.system(size: 36))
                            .foregroundStyle(selectedCategory.color.opacity(0.4))
                        Text("No \(selectedCategory.rawValue) Screenshots")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }
            }
            .padding(.horizontal).padding(.vertical, 12)
        }
    }

    private func statusIcon(for status: CredentialStatus) -> String {
        switch status {
        case .untested: "circle.dashed"
        case .testing: "arrow.triangle.2.circlepath"
        case .working: "checkmark.seal.fill"
        case .noAcc: "xmark.seal.fill"
        case .permDisabled: "lock.slash.fill"
        case .tempDisabled: "clock.badge.exclamationmark.fill"
        case .unsure: "questionmark.diamond.fill"
        }
    }
}

struct LoginScreenshotAlbum: Identifiable {
    let id: String
    let credentialUsername: String
    let credentialId: String
    let credentialStatus: CredentialStatus?
    let screenshots: [PPSRDebugScreenshot]

    var title: String { credentialUsername.isEmpty ? "Unknown" : credentialUsername }
    var latestTimestamp: Date { screenshots.first?.timestamp ?? .distantPast }
    var successCount: Int { screenshots.filter { $0.effectiveResult == .success }.count }
    var noAccCount: Int { screenshots.filter { $0.effectiveResult == .noAcc }.count }
    var permDisabledCount: Int { screenshots.filter { $0.effectiveResult == .permDisabled }.count }
    var tempDisabledCount: Int { screenshots.filter { $0.effectiveResult == .tempDisabled }.count }
    var unsureCount: Int { screenshots.filter { $0.effectiveResult == .unsure || $0.effectiveResult == .none }.count }
    var overrideCount: Int { screenshots.filter { $0.hasUserOverride }.count }
    var aiDetectedCount: Int { screenshots.filter { $0.autoDetectedResult != .unknown }.count }

    var joeScreenshots: [PPSRDebugScreenshot] { screenshots.filter { $0.isJoe } }
    var ignitionScreenshots: [PPSRDebugScreenshot] { screenshots.filter { $0.isIgnition } }

    var joeResult: UserResultOverride {
        let terminal = joeScreenshots.first(where: { $0.effectiveResult != .none })
        return terminal?.effectiveResult ?? .none
    }

    var ignitionResult: UserResultOverride {
        let terminal = ignitionScreenshots.first(where: { $0.effectiveResult != .none })
        return terminal?.effectiveResult ?? .none
    }

    var pairedResultLabel: String {
        let joe = joeResult
        let ign = ignitionResult
        if joe == .none && ign == .none { return "Pending" }
        if joe == ign { return joe.displayLabel }
        if joe == .none { return ign.displayLabel }
        if ign == .none { return joe.displayLabel }
        return "\(joe.displayLabel) / \(ign.displayLabel)"
    }

    var pairedResultColors: (Color, Color) {
        (joeResult == .none ? .gray : joeResult.color, ignitionResult == .none ? .gray : ignitionResult.color)
    }

    var hasBothSites: Bool {
        !joeScreenshots.isEmpty && !ignitionScreenshots.isEmpty
    }

    var statusColor: Color {
        guard let status = credentialStatus else { return .gray }
        switch status {
        case .working: return .green
        case .noAcc: return .red
        case .permDisabled: return .purple
        case .tempDisabled: return .orange
        case .unsure: return .yellow
        case .untested: return .gray
        case .testing: return .blue
        }
    }

    var statusLabel: String {
        credentialStatus?.rawValue ?? "Unknown"
    }
}

struct LoginAlbumCard: View {
    let album: LoginScreenshotAlbum
    let vm: LoginViewModel

    private var evidenceBundle: EvidenceBundle? {
        EvidenceBundleService.shared.bundles.first(where: { $0.credentialId == album.credentialId })
    }

    var body: some View {
        VStack(spacing: 0) {
            if album.hasBothSites {
                HStack(spacing: 1) {
                    sitePreviewTile(screenshots: album.joeScreenshots, label: "JOE", icon: "suit.spade.fill", color: .green)
                    sitePreviewTile(screenshots: album.ignitionScreenshots, label: "IGN", icon: "flame.fill", color: .orange)
                }
                .frame(height: 130)
                .clipShape(.rect(cornerRadii: .init(topLeading: 12, topTrailing: 12)))
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 6) {
                        Text("\(album.screenshots.count)")
                            .font(.system(.caption2, design: .monospaced, weight: .heavy))
                            .foregroundStyle(.white)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.6)).clipShape(Capsule()).padding(8)
                }
                .overlay(alignment: .topLeading) {
                    credentialStatusBadge.padding(8)
                }
            } else if let firstShot = album.screenshots.first {
                Color.clear.frame(height: 130)
                    .overlay { Image(uiImage: firstShot.image).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false) }
                    .clipShape(.rect(cornerRadii: .init(topLeading: 12, topTrailing: 12)))
                    .overlay(alignment: .bottomLeading) {
                        HStack(spacing: 6) {
                            Text("\(album.screenshots.count)")
                                .font(.system(.caption2, design: .monospaced, weight: .heavy))
                                .foregroundStyle(.white)
                            Image(systemName: "camera.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.6)).clipShape(Capsule()).padding(8)
                    }
                    .overlay(alignment: .topLeading) {
                        credentialStatusBadge.padding(8)
                    }
                    .overlay(alignment: .topTrailing) {
                        resultBadge(for: firstShot).padding(8)
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(album.title)
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if let bundle = evidenceBundle {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(confidenceColor(bundle.confidence))
                                .frame(width: 6, height: 6)
                            Text("\(Int(bundle.confidence * 100))%")
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                .foregroundStyle(confidenceColor(bundle.confidence))
                        }
                    }
                }

                if album.hasBothSites {
                    pairedResultBar
                } else {
                    singleSiteStats
                }
            }
            .padding(12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(album.statusColor.opacity(0.25), lineWidth: 1)
        )
    }

    private func sitePreviewTile(screenshots: [PPSRDebugScreenshot], label: String, icon: String, color: Color) -> some View {
        GeometryReader { geo in
            if let shot = screenshots.first {
                Color.clear
                    .overlay { Image(uiImage: shot.displayImage).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false) }
                    .clipped()
                    .overlay(alignment: .top) {
                        HStack(spacing: 3) {
                            Image(systemName: icon).font(.system(size: 7, weight: .bold))
                            Text(label).font(.system(size: 8, weight: .heavy, design: .monospaced))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(color.opacity(0.85)).clipShape(Capsule())
                        .padding(.top, 6)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        let result = screenshots.first(where: { $0.effectiveResult != .none })?.effectiveResult ?? .none
                        if result != .none {
                            Text(result.displayLabel.uppercased())
                                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(result.color.opacity(0.85)).clipShape(Capsule())
                                .padding(6)
                        }
                    }
            } else {
                Color(.tertiarySystemGroupedBackground)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: icon).font(.caption).foregroundStyle(color.opacity(0.4))
                            Text(label).font(.system(size: 8, weight: .heavy, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
            }
        }
    }

    private var pairedResultBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "suit.spade.fill").font(.system(size: 8)).foregroundStyle(.green)
                Text(album.joeResult == .none ? "PENDING" : album.joeResult.displayLabel.uppercased())
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(album.joeResult == .none ? .gray : album.joeResult.color)
            }
            Spacer()
            Text("/")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.quaternary)
            Spacer()
            HStack(spacing: 4) {
                Text(album.ignitionResult == .none ? "PENDING" : album.ignitionResult.displayLabel.uppercased())
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(album.ignitionResult == .none ? .gray : album.ignitionResult.color)
                Image(systemName: "flame.fill").font(.system(size: 8)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 8))
    }

    private var singleSiteStats: some View {
        HStack(spacing: 6) {
            if album.successCount > 0 {
                miniStat(icon: "checkmark.circle.fill", count: album.successCount, color: .green)
            }
            if album.noAccCount > 0 {
                miniStat(icon: "xmark.circle.fill", count: album.noAccCount, color: .secondary)
            }
            if album.permDisabledCount > 0 {
                miniStat(icon: "lock.slash.fill", count: album.permDisabledCount, color: .red)
            }
            if album.tempDisabledCount > 0 {
                miniStat(icon: "clock.badge.exclamationmark", count: album.tempDisabledCount, color: .orange)
            }
            if album.unsureCount > 0 {
                miniStat(icon: "questionmark.diamond.fill", count: album.unsureCount, color: .yellow)
            }
            Spacer()
            if evidenceBundle != nil {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.cyan.opacity(0.6))
            }
        }
    }

    private var credentialStatusBadge: some View {
        Text(album.statusLabel.uppercased())
            .font(.system(size: 8, weight: .heavy, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(album.statusColor.opacity(0.85))
            .clipShape(Capsule())
    }

    private func miniStat(icon: String, count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8)).foregroundStyle(color)
            Text("\(count)").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(color)
        }
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence < 0.4 { return .red }
        if confidence < 0.7 { return .orange }
        return .green
    }

    private func resultBadge(for screenshot: PPSRDebugScreenshot) -> some View {
        let result = screenshot.effectiveResult
        return Image(systemName: result.icon)
            .font(.title3).foregroundStyle(result.color)
            .padding(4).background(.ultraThinMaterial).clipShape(Circle())
    }
}

struct LoginScreenshotCard: View {
    let screenshot: PPSRDebugScreenshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 180)
                .overlay { Image(uiImage: screenshot.displayImage).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false) }
                .clipShape(.rect(cornerRadii: .init(topLeading: 12, topTrailing: 12)))
                .overlay(alignment: .topTrailing) {
                    resultIndicator.padding(8)
                }
                .overlay(alignment: .topLeading) {
                    if !screenshot.site.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: screenshot.siteIcon).font(.system(size: 7, weight: .bold))
                            Text(screenshot.siteLabel.uppercased()).font(.system(size: 8, weight: .heavy, design: .monospaced))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(screenshot.siteColor.opacity(0.85)).clipShape(Capsule())
                        .padding(8)
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(screenshot.stepName.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.green).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.green.opacity(0.12)).clipShape(Capsule())
                    Spacer()
                    Text(screenshot.formattedTime).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                }

                if !screenshot.note.isEmpty {
                    Text(screenshot.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }

                HStack(spacing: 12) {
                    if screenshot.hasUserOverride {
                        Text(screenshot.overrideLabel)
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(screenshot.userOverride.color)
                    }
                    if screenshot.autoDetectedResult != .unknown {
                        HStack(spacing: 2) {
                            Image(systemName: "cpu").font(.system(size: 8))
                            Text("AI:\(screenshot.autoDetectedResult.displayLabel.uppercased())")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                        }
                        .foregroundStyle(screenshot.autoDetectedResult.toOverride.color)
                    }
                }
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .padding(12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var resultIndicator: some View {
        let result = screenshot.effectiveResult
        return Image(systemName: result.icon)
            .font(.title3).foregroundStyle(result.color)
            .padding(4).background(.ultraThinMaterial).clipShape(Circle())
    }
}

struct LoginAlbumDetailSheet: View {
    let album: LoginScreenshotAlbum
    let vm: LoginViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedScreenshot: PPSRDebugScreenshot?
    @State private var showFlipbook: Bool = false
    @State private var flipbookStartIndex: Int = 0

    private var credential: LoginCredential? {
        vm.credentials.first(where: { $0.id == album.credentialId })
    }

    private var evidenceBundle: EvidenceBundle? {
        EvidenceBundleService.shared.bundles.first(where: { $0.credentialId == album.credentialId })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    credentialInfoCard
                    if let bundle = evidenceBundle {
                        evidenceCard(bundle)
                    }
                    screenshotsList
                }
                .padding(.horizontal).padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Album").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $selectedScreenshot) { screenshot in LoginScreenshotCorrectionSheet(screenshot: screenshot, vm: vm) }
            .fullScreenCover(isPresented: $showFlipbook) {
                ScreenshotFlipbookView(screenshots: album.screenshots, startIndex: flipbookStartIndex)
            }
        }
        .presentationDetents([.large])
    }

    private var credentialInfoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "photo.stack.fill").foregroundStyle(album.statusColor)
                Text("Login Session").font(.headline)
                Spacer()
                Text(album.statusLabel.uppercased())
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(album.statusColor).clipShape(Capsule())
            }
            HStack(spacing: 6) {
                Image(systemName: "person.fill").font(.caption).foregroundStyle(.secondary)
                Text(album.title).font(.system(.caption, design: .monospaced, weight: .semibold))
            }

            if album.hasBothSites {
                pairedResultsHeader
            }

            HStack(spacing: 12) {
                Text("\(album.screenshots.count) screenshots").font(.caption).foregroundStyle(.tertiary)
                if album.hasBothSites {
                    Text("\(album.joeScreenshots.count) Joe · \(album.ignitionScreenshots.count) Ign")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if album.overrideCount > 0 {
                    Label("\(album.overrideCount) overridden", systemImage: "hand.point.up.left.fill")
                        .font(.caption2).foregroundStyle(.cyan)
                }
            }

            if let cred = credential {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(UserResultOverride.overrideable, id: \.self) { result in
                            Button {
                                if let shot = album.screenshots.first {
                                    vm.correctResult(for: shot, override: result)
                                }
                            } label: {
                                Label(result.displayLabel, systemImage: result.icon)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .background(cred.status.rawValue == result.displayLabel ? result.color : result.color.opacity(0.12))
                                    .foregroundStyle(cred.status.rawValue == result.displayLabel ? .white : result.color)
                                    .clipShape(Capsule())
                            }
                        }
                        Button {
                            if let shot = album.screenshots.first {
                                vm.requeueCredentialFromScreenshot(shot)
                            }
                        } label: {
                            Label("Retest", systemImage: "arrow.clockwise")
                                .font(.caption.bold())
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(Color.orange.opacity(0.12))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))
    }

    private var pairedResultsHeader: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "suit.spade.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
                    Text("JOE FORTUNE").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(.secondary)
                }
                Text(album.joeResult == .none ? "PENDING" : album.joeResult.displayLabel.uppercased())
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .foregroundStyle(album.joeResult == .none ? .gray : album.joeResult.color)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(album.joeResult == .none ? Color.clear : album.joeResult.color.opacity(0.06))

            Rectangle().fill(.quaternary).frame(width: 1)

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                    Text("IGNITION").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(.secondary)
                }
                Text(album.ignitionResult == .none ? "PENDING" : album.ignitionResult.displayLabel.uppercased())
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .foregroundStyle(album.ignitionResult == .none ? .gray : album.ignitionResult.color)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(album.ignitionResult == .none ? Color.clear : album.ignitionResult.color.opacity(0.06))
        }
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private func evidenceCard(_ bundle: EvidenceBundle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "archivebox.fill").foregroundStyle(.cyan)
                Text("Evidence Bundle").font(.headline)
                Spacer()
                confidenceIndicator(bundle.confidence)
            }

            HStack(spacing: 12) {
                Label(bundle.outcomeLabel, systemImage: "flag.fill")
                    .font(.caption.bold())
                    .foregroundStyle(outcomeColor(bundle.outcome))
                Label(bundle.durationFormatted, systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
                Label(bundle.networkMode, systemImage: "network")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !bundle.reasoning.isEmpty {
                Text(bundle.reasoning)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if !bundle.signalBreakdown.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(bundle.signalBreakdown.prefix(5), id: \.source) { signal in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(signal.weightedScore > 0.3 ? Color.green : (signal.weightedScore > 0.15 ? Color.orange : Color.red))
                                .frame(width: 4, height: 4)
                            Text(signal.source)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f%%", signal.weightedScore * 100))
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 8))
            }
        }
        .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))
    }

    private func confidenceIndicator(_ confidence: Double) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(confidence < 0.4 ? Color.red : (confidence < 0.7 ? Color.orange : Color.green))
                .frame(width: 8, height: 8)
            Text("\(Int(confidence * 100))%")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(confidence < 0.4 ? .red : (confidence < 0.7 ? .orange : .green))
        }
    }

    private func outcomeColor(_ outcome: LoginOutcome) -> Color {
        switch outcome {
        case .success: .green
        case .noAcc: .red
        case .permDisabled: .purple
        case .tempDisabled: .orange
        case .unsure: .yellow
        case .connectionFailure, .timeout: .gray
        case .redBannerError: .red
        case .smsDetected: .orange
        }
    }

    private var screenshotsList: some View {
        LazyVStack(spacing: 12) {
            ForEach(Array(album.screenshots.enumerated()), id: \.element.id) { index, screenshot in
                Button { selectedScreenshot = screenshot } label: { LoginScreenshotCard(screenshot: screenshot) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            flipbookStartIndex = index
                            showFlipbook = true
                        } label: {
                            Label("Flipbook View", systemImage: "book.pages")
                        }
                        Section("Override Result") {
                            ForEach(UserResultOverride.overrideable, id: \.self) { result in
                                Button { vm.correctResult(for: screenshot, override: result) } label: {
                                    Label(result.displayLabel, systemImage: result.icon)
                                }
                            }
                            if screenshot.hasUserOverride {
                                Button { vm.resetScreenshotOverride(screenshot) } label: {
                                    Label("Reset Override", systemImage: "arrow.uturn.backward")
                                }
                            }
                        }
                        Button { vm.requeueCredentialFromScreenshot(screenshot) } label: {
                            Label("Retest Credential", systemImage: "arrow.clockwise")
                        }
                    }
            }
        }
    }
}

struct LoginScreenshotCorrectionSheet: View {
    @Bindable var screenshot: PPSRDebugScreenshot
    let vm: LoginViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingNote: String = ""
    @State private var showConfirmCorrection: Bool = false
    @State private var showRetestConfirmation: Bool = false
    @State private var pendingOverride: UserResultOverride = .none
    @State private var showFullPage: Bool = false
    @State private var isCropMode: Bool = false
    @State private var cropStart: CGPoint = .zero
    @State private var cropEnd: CGPoint = .zero
    @State private var isDragging: Bool = false
    @State private var bannerScanResult: String?

    private var credential: LoginCredential? {
        vm.credentials.first(where: { $0.id == screenshot.cardId })
    }

    private var evidenceBundle: EvidenceBundle? {
        EvidenceBundleService.shared.bundles.first(where: { $0.credentialId == screenshot.cardId })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    siteBadgeHeader
                    credentialStatusCard
                    screenshotSection
                    greenBannerScanSection
                    autoDetectionInfo
                    if let bundle = evidenceBundle {
                        evidenceSummaryCard(bundle)
                    }
                    correctionSection
                    aiFeedbackSection
                    noteSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Review Screenshot").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear { editingNote = screenshot.userNote }
            .alert("Correct Result", isPresented: $showConfirmCorrection) {
                Button("Confirm") { vm.correctResult(for: screenshot, override: pendingOverride) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Mark this credential as \(pendingOverride.displayLabel)? This will update the credential status and apply to ALL screenshots for this credential.")
            }
            .alert("Retest Credential", isPresented: $showRetestConfirmation) {
                Button("Add to Queue") { vm.requeueCredentialFromScreenshot(screenshot); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Add \(screenshot.cardDisplayNumber) back to the untested queue?")
            }
        }
        .presentationDetents([.large])
    }

    private var credentialStatusCard: some View {
        Group {
            if let cred = credential {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cred.username)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(cred.displayStatus.uppercased())
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(statusColor(cred.status))
                                .clipShape(Capsule())
                            if cred.totalTests > 0 {
                                Text("\(cred.totalTests) tests")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Spacer()
                    if let bundle = evidenceBundle {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(bundle.confidence * 100))%")
                                .font(.system(size: 16, weight: .heavy, design: .monospaced))
                                .foregroundStyle(bundle.confidence < 0.4 ? .red : (bundle.confidence < 0.7 ? .orange : .green))
                            Text("confidence")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(statusColor(cred.status).opacity(0.3), lineWidth: 1)
                )
            }
        }
    }

    private func statusColor(_ status: CredentialStatus) -> Color {
        switch status {
        case .working: .green
        case .noAcc: .red
        case .permDisabled: .purple
        case .tempDisabled: .orange
        case .unsure: .yellow
        case .untested: .gray
        case .testing: .blue
        }
    }

    private func evidenceSummaryCard(_ bundle: EvidenceBundle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "archivebox.fill").foregroundStyle(.cyan)
                Text("Evidence Bundle").font(.headline)
                Spacer()
                Text(bundle.outcomeLabel.uppercased())
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(bundle.outcome == .success ? .green : .red)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((bundle.outcome == .success ? Color.green : Color.red).opacity(0.12))
                    .clipShape(Capsule())
            }
            HStack(spacing: 12) {
                Label(bundle.durationFormatted, systemImage: "clock").font(.caption)
                Label(bundle.networkMode, systemImage: "network").font(.caption)
                if bundle.retryCount > 0 {
                    Label("\(bundle.retryCount) retries", systemImage: "arrow.clockwise").font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            if !bundle.reasoning.isEmpty {
                Text(bundle.reasoning)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))
    }

    private var screenshotSection: some View {
        VStack(spacing: 8) {
            HStack {
                if screenshot.croppedImage != nil {
                    Picker("View", selection: $showFullPage) {
                        Text("Focus Crop").tag(false)
                        Text("Full Page").tag(true)
                    }.pickerStyle(.segmented)
                }
                Spacer()
                Button {
                    withAnimation(.snappy) { isCropMode.toggle() }
                    if !isCropMode {
                        cropStart = .zero
                        cropEnd = .zero
                    }
                } label: {
                    Label(isCropMode ? "Done Crop" : "Crop Region", systemImage: isCropMode ? "checkmark.circle.fill" : "crop")
                        .font(.caption.bold())
                        .foregroundStyle(isCropMode ? .white : .blue)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(isCropMode ? Color.blue : Color.blue.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            GeometryReader { geo in
                let displayImage = showFullPage ? screenshot.image : screenshot.displayImage
                Image(uiImage: displayImage)
                    .resizable().aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    .overlay {
                        if isCropMode {
                            cropOverlay(in: geo.size)
                        }
                    }
                    .gesture(isCropMode ? cropGesture(in: geo.size) : nil)
            }
            .aspectRatio(CGFloat(screenshot.image.size.width) / CGFloat(screenshot.image.size.height), contentMode: .fit)

            if isCropMode {
                HStack(spacing: 8) {
                    Image(systemName: "hand.draw.fill").font(.caption).foregroundStyle(.blue)
                    Text("Drag to select the region where the green banner appears")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(Color.blue.opacity(0.06))
                .clipShape(.rect(cornerRadius: 8))

                if cropStart != .zero && cropEnd != .zero {
                    HStack(spacing: 8) {
                        Button {
                            applyCrop()
                        } label: {
                            Label("Save Crop Region", systemImage: "crop")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color.blue).foregroundStyle(.white).clipShape(.rect(cornerRadius: 10))
                        }
                        Button {
                            scanCropForBanner()
                        } label: {
                            Label("Scan Region", systemImage: "viewfinder")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color.green.opacity(0.15)).foregroundStyle(.green).clipShape(.rect(cornerRadius: 10))
                        }
                    }
                }
            }
        }
    }

    private func cropOverlay(in size: CGSize) -> some View {
        ZStack {
            if cropStart != .zero && cropEnd != .zero {
                let rect = normalizedCropRect(in: size)
                Rectangle()
                    .fill(.black.opacity(0.3))
                    .reverseMask {
                        Rectangle()
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
                    }

                Rectangle()
                    .stroke(Color.green, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    private func cropGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                let start = CGPoint(
                    x: max(0, min(value.startLocation.x, size.width)),
                    y: max(0, min(value.startLocation.y, size.height))
                )
                let end = CGPoint(
                    x: max(0, min(value.location.x, size.width)),
                    y: max(0, min(value.location.y, size.height))
                )
                cropStart = start
                cropEnd = end
                isDragging = true
            }
            .onEnded { _ in
                isDragging = false
            }
    }

    private func normalizedCropRect(in size: CGSize) -> CGRect {
        let x = min(cropStart.x, cropEnd.x)
        let y = min(cropStart.y, cropEnd.y)
        let w = abs(cropEnd.x - cropStart.x)
        let h = abs(cropEnd.y - cropStart.y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func applyCrop() {
        guard cropStart != .zero, cropEnd != .zero else { return }
        let imageSize = screenshot.image.size
        let displayAspect = imageSize.width / imageSize.height

        let viewWidth = UIScreen.main.bounds.width - 32
        let viewHeight = viewWidth / displayAspect
        let viewSize = CGSize(width: viewWidth, height: viewHeight)

        let rect = normalizedCropRect(in: viewSize)

        let scaleX = imageSize.width / viewSize.width
        let scaleY = imageSize.height / viewSize.height

        let pixelRect = CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )

        if let cgImage = screenshot.image.cgImage,
           let cropped = cgImage.cropping(to: pixelRect) {
            screenshot.croppedImage = UIImage(cgImage: cropped, scale: screenshot.image.scale, orientation: screenshot.image.imageOrientation)
            withAnimation(.snappy) {
                isCropMode = false
                showFullPage = false
            }
        }
    }

    private func scanCropForBanner() {
        guard cropStart != .zero, cropEnd != .zero else { return }
        let imageSize = screenshot.image.size
        let displayAspect = imageSize.width / imageSize.height

        let viewWidth = UIScreen.main.bounds.width - 32
        let viewHeight = viewWidth / displayAspect
        let viewSize = CGSize(width: viewWidth, height: viewHeight)

        let rect = normalizedCropRect(in: viewSize)

        let normalizedRect = CGRect(
            x: rect.origin.x / viewSize.width,
            y: rect.origin.y / viewSize.height,
            width: rect.width / viewSize.width,
            height: rect.height / viewSize.height
        )

        let result = GreenBannerDetector.detectInCropRegion(image: screenshot.image, cropRect: normalizedRect)
        withAnimation(.snappy) {
            if result.detected {
                bannerScanResult = "GREEN BANNER DETECTED (confidence: \(String(format: "%.0f%%", result.confidence * 100)))"
            } else {
                bannerScanResult = "No green banner found in selected region"
            }
        }
    }

    private var greenBannerScanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "viewfinder.rectangular").foregroundStyle(.green)
                Text("Green Banner Detection").font(.headline)
                Spacer()
                Button {
                    let result = GreenBannerDetector.detect(in: screenshot.image)
                    withAnimation(.snappy) {
                        if result.detected {
                            bannerScanResult = "GREEN BANNER DETECTED (confidence: \(String(format: "%.0f%%", result.confidence * 100)), rows: \(String(format: "%.1f%%", result.greenRowPercentage)))"
                        } else {
                            bannerScanResult = "No green banner found in full screenshot"
                        }
                    }
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.green.opacity(0.12)).foregroundStyle(.green).clipShape(Capsule())
                }
            }

            if let scanResult = bannerScanResult {
                HStack(spacing: 6) {
                    Image(systemName: scanResult.contains("DETECTED") ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(scanResult.contains("DETECTED") ? .green : .red)
                    Text(scanResult)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(scanResult.contains("DETECTED") ? .green : .red)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((scanResult.contains("DETECTED") ? Color.green : Color.red).opacity(0.06))
                .clipShape(.rect(cornerRadius: 8))
            }

            Text("Only a green banner confirms a successful login. Use Crop Region to mark the detection area.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))
    }

    private var siteBadgeHeader: some View {
        Group {
            if !screenshot.site.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: screenshot.siteIcon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(screenshot.siteColor)
                    Text(screenshot.siteLabel)
                        .font(.system(.subheadline, design: .monospaced, weight: .heavy))
                        .foregroundStyle(screenshot.siteColor)
                    Spacer()
                    Text(screenshot.effectiveResult.displayLabel.uppercased())
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(screenshot.effectiveResult.color.opacity(0.85))
                        .clipShape(Capsule())
                }
                .padding(12)
                .background(screenshot.siteColor.opacity(0.06))
                .clipShape(.rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(screenshot.siteColor.opacity(0.2), lineWidth: 1))
            }
        }
    }

    private var autoDetectionInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "cpu").foregroundStyle(.blue)
                Text("AI Detection").font(.headline)
                Spacer()
                autoDetectionBadge
            }

            if !screenshot.note.isEmpty {
                Text(screenshot.note)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            if screenshot.autoDetectedResult != .unknown {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Detection reasoning:")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(detectionReasoningSummary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
                .padding(8)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 8))
            }
        }
        .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))
    }

    private var detectionReasoningSummary: String {
        let note = screenshot.note.lowercased()
        var reasons: [String] = []
        if note.contains("has been disabled") { reasons.append("Detected 'has been disabled' → Perm Disabled") }
        if note.contains("temporarily disabled") { reasons.append("Detected 'temporarily disabled' → Temp Disabled") }
        if note.contains("incorrect") { reasons.append("Detected 'incorrect' → No Account") }
        if note.contains("welcome") || note.contains("lobby") || note.contains("dashboard") { reasons.append("Detected success indicators → Success") }
        if note.contains("green banner") { reasons.append("Green banner detected → Success") }
        if note.contains("no response") || note.contains("timeout") { reasons.append("No response / timeout → Unsure") }
        if reasons.isEmpty { reasons.append("AI: \(screenshot.autoDetectedResult.displayLabel) (based on page content analysis)") }
        return reasons.joined(separator: "\n")
    }

    private var autoDetectionBadge: some View {
        let result = screenshot.autoDetectedResult
        let override = result.toOverride
        return Label(result.displayLabel.uppercased(), systemImage: override.icon)
            .font(.caption.bold()).foregroundStyle(override.color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(override.color.opacity(0.12)).clipShape(Capsule())
    }

    private var correctionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "hand.point.up.left.fill").foregroundStyle(.orange); Text("Correct Result").font(.headline) }

            if screenshot.hasUserOverride {
                HStack(spacing: 8) {
                    Image(systemName: screenshot.userOverride.icon)
                        .foregroundStyle(screenshot.userOverride.color)
                    Text("You marked this as: \(screenshot.overrideLabel)").font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Reset") { vm.resetScreenshotOverride(screenshot) }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(12).background(Color(.tertiarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 10))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(UserResultOverride.overrideable, id: \.self) { result in
                    Button { pendingOverride = result; showConfirmCorrection = true } label: {
                        Label(result.displayLabel, systemImage: result.icon).font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(screenshot.userOverride == result ? result.color : result.color.opacity(0.15))
                            .foregroundStyle(screenshot.userOverride == result ? .white : result.color)
                            .clipShape(.rect(cornerRadius: 10))
                    }
                }
                Button { showRetestConfirmation = true } label: {
                    Label("Retest", systemImage: "arrow.clockwise.circle.fill").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.orange.opacity(0.15)).foregroundStyle(.orange).clipShape(.rect(cornerRadius: 10))
                }
            }
        }
        .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))
    }

    private var aiFeedbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "brain.head.profile").foregroundStyle(.purple)
                Text("Teach AI").font(.headline)
                Spacer()
                if !screenshot.correctionReason.isEmpty {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
            }

            Text("If the AI detected this incorrectly, explain why so it learns from the mistake.")
                .font(.caption2).foregroundStyle(.tertiary)

            if screenshot.hasUserOverride && screenshot.autoDetectedResult.toOverride != screenshot.userOverride {
                HStack(spacing: 8) {
                    VStack(spacing: 2) {
                        Text("AI SAID").font(.system(size: 8, weight: .heavy, design: .monospaced)).foregroundStyle(.tertiary)
                        Text(screenshot.autoDetectedResult.displayLabel.uppercased())
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .foregroundStyle(screenshot.autoDetectedResult.toOverride.color)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(screenshot.autoDetectedResult.toOverride.color.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 8))

                    Image(systemName: "arrow.right").font(.caption.bold()).foregroundStyle(.tertiary)

                    VStack(spacing: 2) {
                        Text("CORRECT").font(.system(size: 8, weight: .heavy, design: .monospaced)).foregroundStyle(.tertiary)
                        Text(screenshot.userOverride.displayLabel.uppercased())
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .foregroundStyle(screenshot.userOverride.color)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(screenshot.userOverride.color.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 8))
                }

                TextField("Why was the AI wrong? (e.g. 'The page showed incorrect password not disabled')", text: Binding(
                    get: { screenshot.correctionReason },
                    set: { screenshot.correctionReason = $0 }
                ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2...4)
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 8))

                if !screenshot.correctionReason.isEmpty {
                    Button {
                        submitAIFeedback()
                    } label: {
                        Label("Submit AI Feedback", systemImage: "paperplane.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.purple).foregroundStyle(.white)
                            .clipShape(.rect(cornerRadius: 10))
                    }
                }
            } else if !screenshot.hasUserOverride {
                Text("Override the result above first, then explain the correction here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("AI and override agree: \(screenshot.userOverride.displayLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.06))
                .clipShape(.rect(cornerRadius: 8))
            }
        }
        .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))
    }

    private func submitAIFeedback() {
        let host = screenshot.isJoe ? "joefortunepokies.win" : "ignitioncasino.eu"
        UserInterventionLearningService.shared.recordCorrection(
            host: host,
            pageContent: "\(screenshot.note) | Reason: \(screenshot.correctionReason)",
            currentURL: "",
            originalClassification: screenshot.autoDetectedResult.rawValue,
            userCorrectedOutcome: screenshot.userOverride.rawValue,
            actionTaken: "manual_ai_feedback_with_reason"
        )
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: "pencil.line").foregroundStyle(.orange); Text("Your Note").font(.headline) }

            TextField("Add a note...", text: $editingNote, axis: .vertical)
                .textFieldStyle(.plain).font(.system(.subheadline, design: .monospaced)).lineLimit(3...6)
                .padding(12).background(Color(.tertiarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 10))

            if editingNote != screenshot.userNote {
                Button {
                    screenshot.userNote = editingNote
                } label: {
                    Text("Save Note").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.accentColor).foregroundStyle(.white).clipShape(.rect(cornerRadius: 10))
                }
            }
        }
        .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))
    }
}

extension View {
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask(
            Rectangle()
                .overlay(alignment: .center) {
                    mask().blendMode(.destinationOut)
                }
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

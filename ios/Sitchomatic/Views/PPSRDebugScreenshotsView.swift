import SwiftUI

struct ScreenshotAlbum: Identifiable {
    let id: String
    let cardDisplayNumber: String
    let cardId: String
    let screenshots: [PPSRDebugScreenshot]

    var title: String { cardDisplayNumber.isEmpty ? "Unknown Card" : cardDisplayNumber }
    var latestTimestamp: Date { screenshots.first?.timestamp ?? .distantPast }
    var passCount: Int { screenshots.filter { $0.effectiveResult == .markedPass }.count }
    var failCount: Int { screenshots.filter { $0.effectiveResult == .markedFail }.count }

    var overallResult: UserResultOverride {
        let finals = screenshots.filter { $0.stepName.contains("final") || $0.stepName.contains("response") }
        if let last = finals.last { return last.effectiveResult }
        return .none
    }
}

struct PPSRDebugScreenshotsView: View {
    @Bindable var vm: PPSRAutomationViewModel
    @State private var selectedScreenshot: PPSRDebugScreenshot?
    @State private var selectedAlbum: ScreenshotAlbum?
    @State private var viewMode: ViewMode = .albums
    @State private var showFlipbook: Bool = false
    @State private var flipbookStartIndex: Int = 0

    private enum ViewMode: String, CaseIterable {
        case albums = "Albums"
        case all = "All"
    }

    private var albums: [ScreenshotAlbum] {
        let grouped = Dictionary(grouping: vm.debugScreenshots) { $0.albumKey }
        return grouped.map { key, shots in
            ScreenshotAlbum(id: key, cardDisplayNumber: shots.first?.cardDisplayNumber ?? "", cardId: shots.first?.cardId ?? "", screenshots: shots.sorted { $0.timestamp > $1.timestamp })
        }.sorted { $0.latestTimestamp > $1.latestTimestamp }
    }

    var body: some View {
        Group {
            if vm.debugScreenshots.isEmpty {
                ContentUnavailableView("No Screenshots", systemImage: "photo.stack", description: Text("Enable Debug Mode and run a test."))
            } else {
                VStack(spacing: 0) {
                    Picker("View", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)

                    switch viewMode {
                    case .albums:
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(albums) { album in
                                    Button { selectedAlbum = album } label: { AlbumCard(album: album) }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal).padding(.vertical, 12)
                        }
                    case .all:
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(Array(vm.debugScreenshots.enumerated()), id: \.element.id) { index, screenshot in
                                    Button { selectedScreenshot = screenshot } label: { ScreenshotCard(screenshot: screenshot) }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button {
                                                flipbookStartIndex = index
                                                showFlipbook = true
                                            } label: {
                                                Label("Flipbook View", systemImage: "book.pages")
                                            }
                                        }
                                }
                            }.padding(.horizontal).padding(.vertical, 12)
                        }
                    }
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("Debug Mode")
        .sheet(item: $selectedScreenshot) { screenshot in
            ScreenshotCorrectionSheet(screenshot: screenshot, vm: vm)
        }
        .sheet(item: $selectedAlbum) { album in
            AlbumDetailSheet(album: album, vm: vm)
        }
        .fullScreenCover(isPresented: $showFlipbook) {
            ScreenshotFlipbookView(screenshots: vm.debugScreenshots, startIndex: flipbookStartIndex)
        }
    }
}

struct AlbumCard: View {
    let album: ScreenshotAlbum

    var body: some View {
        VStack(spacing: 0) {
            if let firstShot = album.screenshots.first {
                Color.clear.frame(height: 140)
                    .overlay { Image(uiImage: firstShot.image).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false) }
                    .clipShape(.rect(cornerRadii: .init(topLeading: 12, topTrailing: 12)))
                    .overlay(alignment: .bottomLeading) {
                        Text("\(album.screenshots.count) screenshots")
                            .font(.system(.caption2, design: .monospaced, weight: .medium))
                            .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.6)).clipShape(Capsule()).padding(8)
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(album.title).font(.system(.subheadline, design: .monospaced, weight: .semibold)).lineLimit(1)
                HStack(spacing: 12) {
                    Label("\(album.screenshots.count) tests", systemImage: "doc.text")
                    Spacer()
                    if album.passCount > 0 {
                        HStack(spacing: 2) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text("\(album.passCount)") }
                    }
                    if album.failCount > 0 {
                        HStack(spacing: 2) { Image(systemName: "xmark.circle.fill").foregroundStyle(.red); Text("\(album.failCount)") }
                    }
                }
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }
}

struct AlbumDetailSheet: View {
    let album: ScreenshotAlbum
    let vm: PPSRAutomationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedScreenshot: PPSRDebugScreenshot?
    @State private var showFlipbook: Bool = false
    @State private var flipbookStartIndex: Int = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "photo.stack.fill").foregroundStyle(.blue)
                            Text("Test Session").font(.headline)
                            Spacer()
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "creditcard.fill").font(.caption).foregroundStyle(.secondary)
                            Text(album.title).font(.system(.caption, design: .monospaced, weight: .semibold))
                        }
                        Text("\(album.screenshots.count) screenshots captured").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))

                    LazyVStack(spacing: 12) {
                        ForEach(Array(album.screenshots.enumerated()), id: \.element.id) { index, screenshot in
                            Button { selectedScreenshot = screenshot } label: { ScreenshotCard(screenshot: screenshot) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        flipbookStartIndex = index
                                        showFlipbook = true
                                    } label: {
                                        Label("Flipbook View", systemImage: "book.pages")
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal).padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Album").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $selectedScreenshot) { screenshot in ScreenshotCorrectionSheet(screenshot: screenshot, vm: vm) }
            .fullScreenCover(isPresented: $showFlipbook) {
                ScreenshotFlipbookView(screenshots: album.screenshots, startIndex: flipbookStartIndex)
            }
        }
        .presentationDetents([.large])
    }
}

struct ScreenshotCard: View {
    let screenshot: PPSRDebugScreenshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 180)
                .overlay { Image(uiImage: screenshot.displayImage).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false) }
                .clipShape(.rect(cornerRadii: .init(topLeading: 12, topTrailing: 12)))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(screenshot.stepName.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.blue).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.blue.opacity(0.12)).clipShape(Capsule())
                    Spacer()
                    Text(screenshot.formattedTime).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                }

                if !screenshot.note.isEmpty {
                    Text(screenshot.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }

                HStack(spacing: 12) {
                    Label(screenshot.cardDisplayNumber, systemImage: "creditcard")
                    if !screenshot.vin.isEmpty {
                        Label(String(screenshot.vin.prefix(8)) + "…", systemImage: "car")
                    }
                    if screenshot.hasUserOverride {
                        Text(screenshot.overrideLabel)
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(screenshot.userOverride == .markedPass ? .green : .red)
                    }
                }
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .padding(12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }
}

struct ScreenshotCorrectionSheet: View {
    @Bindable var screenshot: PPSRDebugScreenshot
    let vm: PPSRAutomationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingNote: String = ""
    @State private var showConfirmCorrection: Bool = false
    @State private var showRetestConfirmation: Bool = false
    @State private var pendingOverride: UserResultOverride = .none
    @State private var showFullPage: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        if screenshot.croppedImage != nil {
                            Picker("View", selection: $showFullPage) {
                                Text("Focus Crop").tag(false)
                                Text("Full Page").tag(true)
                            }.pickerStyle(.segmented)
                        }
                        Image(uiImage: showFullPage ? screenshot.image : screenshot.displayImage)
                            .resizable().aspectRatio(contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    }

                    correctionSection
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
                let label = pendingOverride == .markedPass ? "PASS" : "FAIL"
                Text("Mark this as \(label)?")
            }
            .alert("Retest Card", isPresented: $showRetestConfirmation) {
                Button("Add to Queue") { vm.requeueCardFromScreenshot(screenshot); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Add \(screenshot.cardDisplayNumber) back to the untested queue?")
            }
        }
        .presentationDetents([.large])
    }

    private var correctionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "hand.point.up.left.fill").foregroundStyle(.orange); Text("Correct Result").font(.headline) }

            if screenshot.hasUserOverride {
                HStack(spacing: 8) {
                    Image(systemName: screenshot.userOverride == .markedPass ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(screenshot.userOverride == .markedPass ? .green : .red)
                    Text("You marked this as: \(screenshot.overrideLabel)").font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Reset") { vm.resetScreenshotOverride(screenshot) }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(12).background(Color(.tertiarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 10))
            }

            HStack(spacing: 8) {
                Button { pendingOverride = .markedPass; showConfirmCorrection = true } label: {
                    Label("Pass", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(screenshot.userOverride == .markedPass ? Color.green : Color.green.opacity(0.15))
                        .foregroundStyle(screenshot.userOverride == .markedPass ? .white : .green)
                        .clipShape(.rect(cornerRadius: 10))
                }
                Button { pendingOverride = .markedFail; showConfirmCorrection = true } label: {
                    Label("Fail", systemImage: "xmark.circle.fill").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(screenshot.userOverride == .markedFail ? Color.red : Color.red.opacity(0.15))
                        .foregroundStyle(screenshot.userOverride == .markedFail ? .white : .red)
                        .clipShape(.rect(cornerRadius: 10))
                }
                Button { showRetestConfirmation = true } label: {
                    Label("Retest", systemImage: "arrow.clockwise.circle.fill").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.orange.opacity(0.15)).foregroundStyle(.orange).clipShape(.rect(cornerRadius: 10))
                }
            }
        }
        .padding().background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 12))
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

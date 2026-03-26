import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LoginWorkingListView: View {
    let vm: LoginViewModel
    @State private var showCopiedToast: Bool = false
    @State private var showFileExporter: Bool = false
    @State private var exportDocument: CardExportDocument?
    @State private var viewMode: ViewMode = .list
    @State private var selectedCredential: LoginCredential?
    @State private var showReviewQueue: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if vm.workingCredentials.isEmpty {
                EmptyStateView(
                    icon: "checkmark.shield.fill",
                    title: "No Working Logins",
                    subtitle: "Credentials that pass login tests will appear here.",
                    accentColor: .green,
                    tips: [
                        EmptyStateTip(icon: "play.fill", text: "Run tests from the Dashboard to start validating credentials"),
                        EmptyStateTip(icon: "doc.on.doc", text: "Working logins can be copied or exported as .txt")
                    ]
                )
            } else {
                exportBar
                if viewMode == .tile {
                    workingTileGrid
                } else {
                    credentialsList
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Working Logins")
        .refreshable {
            vm.persistCredentialsNow()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showReviewQueue = true } label: {
                    let count = ReviewQueueService.shared.pendingCount
                    Image(systemName: count > 0 ? "tray.full.fill" : "tray.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(count > 0 ? .orange : .secondary)
                        .overlay(alignment: .topTrailing) {
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.orange, in: Capsule())
                                    .offset(x: 8, y: -8)
                            }
                        }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ViewModeToggle(mode: $viewMode, accentColor: .green)
            }
            if !vm.workingCredentials.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { copyAllCredentials() } label: { Label("Copy All", systemImage: "doc.on.doc") }
                        Button { exportAsTxt() } label: { Label("Export as .txt", systemImage: "square.and.arrow.up") }
                    } label: { Image(systemName: "square.and.arrow.up") }
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
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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
        .fileExporter(isPresented: $showFileExporter, document: exportDocument, contentType: .plainText, defaultFilename: "working_logins_\(dateStamp()).txt") { result in
            switch result {
            case .success: vm.log("Exported \(vm.workingCredentials.count) working credentials to file", level: .success)
            case .failure(let error): vm.log("Export failed: \(error.localizedDescription)", level: .error)
            }
        }
        .sheet(item: $selectedCredential) { cred in
            NavigationStack {
                LoginCredentialDetailView(credential: cred, vm: vm)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var exportBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
            Text("\(vm.workingCredentials.count) working logins").font(.subheadline.bold())
            Spacer()
            Button { copyAllCredentials() } label: {
                Label("Copy All", systemImage: "doc.on.doc")
                    .font(.caption.bold())
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.green.opacity(0.15)).foregroundStyle(.green).clipShape(Capsule())
            }
        }
        .padding(.horizontal).padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var credentialsList: some View {
        List {
            ForEach(vm.workingCredentials) { cred in
                let latestScreenshot = vm.screenshotsForCredential(cred.id).first?.image
                LoginWorkingRow(credential: cred, onCopy: { copyCredential(cred) }, screenshot: latestScreenshot)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { copyCredential(cred) } label: { Label("Copy", systemImage: "doc.on.doc") }.tint(.green)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button { vm.retestCredential(cred) } label: { Label("Retest", systemImage: "arrow.clockwise") }.tint(.blue)
                    }
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
        }
        .listStyle(.insetGrouped)
    }

    private var workingTileGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(vm.workingCredentials) { cred in
                    let latestScreenshot = vm.screenshotsForCredential(cred.id).first?.image
                    Button { selectedCredential = cred } label: {
                        ScreenshotTileView(
                            screenshot: latestScreenshot,
                            title: cred.username,
                            subtitle: cred.maskedPassword,
                            statusColor: .green,
                            statusText: "Working",
                            badge: cred.totalTests > 0 ? "\(cred.successCount)/\(cred.totalTests)" : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { copyCredential(cred) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button { vm.retestCredential(cred) } label: { Label("Retest", systemImage: "arrow.clockwise") }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    @State private var copyHapticTrigger: Int = 0

    private func copyCredential(_ cred: LoginCredential) {
        UIPasteboard.general.string = cred.exportFormat
        copyHapticTrigger += 1
        withAnimation(.spring(duration: 0.3)) { showCopiedToast = true }
        Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { showCopiedToast = false } }
    }

    private func copyAllCredentials() {
        let text = vm.exportWorkingCredentials()
        UIPasteboard.general.string = text
        vm.log("Copied \(vm.workingCredentials.count) working credentials to clipboard", level: .success)
        withAnimation(.spring(duration: 0.3)) { showCopiedToast = true }
        Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { showCopiedToast = false } }
    }

    private func exportAsTxt() {
        let text = vm.exportWorkingCredentials()
        exportDocument = CardExportDocument(text: text)
        showFileExporter = true
    }

    private func dateStamp() -> String {
        DateFormatters.fileStamp.string(from: Date())
    }
}

struct LoginWorkingRow: View {
    let credential: LoginCredential
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
                    RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)).frame(width: 40, height: 40)
                    Image(systemName: "person.fill.checkmark").font(.title3.bold()).foregroundStyle(.green)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(credential.username)
                    .font(.system(.subheadline, design: .monospaced, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(credential.maskedPassword)
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                    if credential.totalTests > 0 {
                        Text("\(credential.successCount)/\(credential.totalTests)")
                            .font(.caption2.bold()).foregroundStyle(.green)
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
}

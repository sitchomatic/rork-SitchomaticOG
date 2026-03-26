import SwiftUI
import UIKit

struct LoginCredentialDetailView: View {
    let credential: LoginCredential
    let vm: LoginViewModel
    @State private var showCopiedToast: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                credentialHeader
                statsSection
                actionsSection
                if !credential.testResults.isEmpty { testHistorySection }
                infoSection
            }
            .listStyle(.insetGrouped)

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
        .navigationTitle(credential.username).navigationBarTitleDisplayMode(.inline)
    }

    private var credentialHeader: some View {
        Section {
            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(colors: [statusGradientColor, statusGradientColor.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 160)

                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "person.badge.key.fill").font(.title).foregroundStyle(.white)
                            Spacer()
                            HStack(spacing: 4) {
                                Circle().fill(statusBadgeColor).frame(width: 6, height: 6)
                                Text(credential.status.rawValue).font(.caption2.bold())
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial).clipShape(Capsule())
                        }

                        Text(credential.username)
                            .font(.system(.title3, design: .monospaced, weight: .semibold))
                            .foregroundStyle(.white).lineLimit(1)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("PASSWORD").font(.system(.caption2, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                                Text(credential.maskedPassword)
                                    .font(.system(.subheadline, design: .monospaced, weight: .medium)).foregroundStyle(.white)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("TESTS").font(.system(.caption2, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                                Text("\(credential.totalTests)")
                                    .font(.system(.subheadline, design: .monospaced, weight: .medium)).foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        }
    }

    private var statusGradientColor: Color {
        switch credential.status {
        case .working: .green
        case .noAcc: .red
        case .permDisabled: .red.opacity(0.7)
        case .tempDisabled: .orange
        case .unsure: .yellow
        case .testing: .teal
        case .untested: .gray
        }
    }

    private var statusBadgeColor: Color {
        switch credential.status {
        case .working: .green
        case .noAcc: .red
        case .permDisabled: .red.opacity(0.7)
        case .tempDisabled: .orange
        case .unsure: .yellow
        case .testing: .green
        case .untested: .secondary
        }
    }

    private var statsSection: some View {
        Section("Performance") {
            HStack {
                StatItem(value: "\(credential.totalTests)", label: "Total Tests", color: .blue)
                StatItem(value: "\(credential.successCount)", label: "Passed", color: .green)
                StatItem(value: "\(credential.failureCount)", label: "Failed", color: .red)
            }
            if credential.totalTests > 0 {
                LabeledContent("Success Rate") {
                    Text(String(format: "%.0f%%", credential.successRate * 100))
                        .font(.system(.body, design: .monospaced, weight: .bold))
                        .foregroundStyle(credential.successRate >= 0.5 ? .green : .red)
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                vm.testSingleCredential(credential)
            } label: {
                HStack { Spacer(); Label("Run Login Test", systemImage: "play.fill").font(.headline); Spacer() }
            }
            .disabled(credential.status == .testing)
            .listRowBackground(credential.status == .testing ? Color.green.opacity(0.3) : Color.green)
            .foregroundStyle(.white)

            Button {
                UIPasteboard.general.string = credential.exportFormat
                withAnimation(.spring(duration: 0.3)) { showCopiedToast = true }
                Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { showCopiedToast = false } }
            } label: { Label("Copy Credential", systemImage: "doc.on.doc") }

            if credential.status == .noAcc || credential.status == .permDisabled || credential.status == .tempDisabled || credential.status == .unsure {
                Button { vm.restoreCredential(credential) } label: { Label("Restore to Untested", systemImage: "arrow.counterclockwise") }
                Button(role: .destructive) { vm.deleteCredential(credential) } label: { Label("Delete Permanently", systemImage: "trash") }
            }
        }
    }

    private var testHistorySection: some View {
        Section("Test History") {
            ForEach(credential.testResults) { result in
                HStack(spacing: 10) {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.success ? .green : .red).font(.subheadline)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(result.success ? "Success" : "Failed").font(.subheadline.bold()).foregroundStyle(result.success ? .green : .red)
                            Text(result.formattedDuration).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Text(result.formattedDate).font(.caption).foregroundStyle(.tertiary)
                        if let err = result.errorMessage {
                            Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
                        }
                        if let detail = result.responseDetail {
                            Text(detail).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var infoSection: some View {
        Section("Credential Info") {
            LabeledContent("Username") { Text(credential.username).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
            LabeledContent("Password") { Text(credential.password).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
            LabeledContent("Export Format") { Text(credential.exportFormat).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary) }
            LabeledContent("Added") { Text(credential.addedAt, style: .date) }
            if let lastTest = credential.lastTestedAt {
                LabeledContent("Last Tested") { Text(lastTest, style: .relative).foregroundStyle(.secondary) }
            }
        }
    }
}

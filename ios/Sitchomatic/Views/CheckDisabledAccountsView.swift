import SwiftUI

struct CheckDisabledAccountsView: View {
    let vm: LoginViewModel
    @State private var selectedEmails: Set<String> = []
    @State private var selectAll: Bool = false
    @State private var showResults: Bool = false
    @State private var showRemovePrompt: Bool = false

    private var allCredentials: [LoginCredential] {
        vm.credentials
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.disabledCheckService.isRunning {
                runningBanner
            }

            if showResults && !vm.disabledCheckService.results.isEmpty {
                resultsSection
            } else {
                selectionSection
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Check Disabled")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if showResults {
                    Button("Back to Selection") {
                        withAnimation(.snappy) { showResults = false }
                    }
                }
            }
        }
        .alert("Remove Disabled Accounts?", isPresented: $showRemovePrompt) {
            Button("Remove & Blacklist", role: .destructive) {
                vm.applyDisabledCheckResults()
                vm.addDisabledToBlacklist()
            }
            Button("Remove Only") {
                vm.applyDisabledCheckResults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Found \(vm.disabledCheckService.disabledResults.count) permanently disabled accounts. Remove them from credentials and optionally add to blacklist?")
        }
    }

    private var runningBanner: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().tint(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Checking Disabled Status").font(.subheadline.bold()).foregroundStyle(.orange)
                    if !vm.disabledCheckService.currentEmail.isEmpty {
                        Text(vm.disabledCheckService.currentEmail)
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { vm.disabledCheckService.stopCheck() } label: {
                    Text("Stop").font(.caption.bold()).foregroundStyle(.red)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.red.opacity(0.12)).clipShape(Capsule())
                }
            }
            ProgressView(value: vm.disabledCheckService.progress)
                .tint(.orange)
        }
        .padding()
        .background(Color.orange.opacity(0.06))
    }

    private var selectionSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass.circle.fill").foregroundStyle(.orange).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check Account Status").font(.headline)
                        Text("Uses forgot-password page to detect disabled accounts — 3x faster than login testing")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button {
                        withAnimation(.snappy) {
                            if selectAll {
                                selectedEmails.removeAll()
                            } else {
                                selectedEmails = Set(allCredentials.map(\.username))
                            }
                            selectAll.toggle()
                        }
                    } label: {
                        Label(selectAll ? "Deselect All" : "Select All (\(allCredentials.count))", systemImage: selectAll ? "checkmark.circle.fill" : "circle")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(selectAll ? Color.orange : Color(.tertiarySystemFill))
                            .foregroundStyle(selectAll ? .white : .primary)
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Text("\(selectedEmails.count) selected")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.secondary)
                }

                if !selectedEmails.isEmpty {
                    Button {
                        let emails = Array(selectedEmails)
                        vm.runDisabledCheck(emails: emails)
                        withAnimation(.snappy) { showResults = true }
                    } label: {
                        Label("Run Disabled Check (\(selectedEmails.count))", systemImage: "play.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.orange).foregroundStyle(.white).clipShape(.rect(cornerRadius: 12))
                    }
                    .disabled(vm.disabledCheckService.isRunning)
                }
            }
            .padding()

            List {
                ForEach(allCredentials) { cred in
                    Button {
                        withAnimation(.snappy) {
                            if selectedEmails.contains(cred.username) {
                                selectedEmails.remove(cred.username)
                            } else {
                                selectedEmails.insert(cred.username)
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedEmails.contains(cred.username) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedEmails.contains(cred.username) ? .orange : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(cred.username)
                                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                                    .foregroundStyle(.primary).lineLimit(1)
                                HStack(spacing: 6) {
                                    statusBadge(cred.status)
                                }
                            }
                            Spacer()
                        }
                    }
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func statusBadge(_ status: CredentialStatus) -> some View {
        HStack(spacing: 3) {
            Circle().fill(statusColor(status)).frame(width: 5, height: 5)
            Text(status.rawValue)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(statusColor(status))
        }
    }

    private func statusColor(_ status: CredentialStatus) -> Color {
        switch status {
        case .working: .green
        case .noAcc: .red
        case .permDisabled: .red.opacity(0.7)
        case .tempDisabled: .orange
        case .unsure: .yellow
        case .testing: .green
        case .untested: .secondary
        }
    }

    private var resultsSection: some View {
        VStack(spacing: 0) {
            if !vm.disabledCheckService.results.isEmpty {
                VStack(spacing: 10) {
                    HStack(spacing: 16) {
                        VStack(spacing: 4) {
                            Text("\(vm.disabledCheckService.disabledResults.count)")
                                .font(.system(.title2, design: .monospaced, weight: .bold)).foregroundStyle(.red)
                            Text("Disabled").font(.caption2).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 4) {
                            Text("\(vm.disabledCheckService.activeResults.count)")
                                .font(.system(.title2, design: .monospaced, weight: .bold)).foregroundStyle(.green)
                            Text("Active/No Acc").font(.caption2).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 4) {
                            Text("\(vm.disabledCheckService.results.count)")
                                .font(.system(.title2, design: .monospaced, weight: .bold)).foregroundStyle(.blue)
                            Text("Total").font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    if !vm.disabledCheckService.disabledResults.isEmpty {
                        Button {
                            showRemovePrompt = true
                        } label: {
                            Label("Remove Disabled & Add to Blacklist", systemImage: "trash.fill")
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.red.opacity(0.15)).foregroundStyle(.red).clipShape(.rect(cornerRadius: 10))
                        }
                    }
                }
                .padding()
            }

            List {
                if !vm.disabledCheckService.disabledResults.isEmpty {
                    Section("Permanently Disabled") {
                        ForEach(vm.disabledCheckService.disabledResults) { result in
                            HStack(spacing: 10) {
                                Image(systemName: "lock.slash.fill").foregroundStyle(.red).font(.caption)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.email).font(.system(.subheadline, design: .monospaced, weight: .medium)).lineLimit(1)
                                    Text(result.responseText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                    }
                }

                if !vm.disabledCheckService.activeResults.isEmpty {
                    Section("Active / No Account") {
                        ForEach(vm.disabledCheckService.activeResults) { result in
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.email).font(.system(.subheadline, design: .monospaced, weight: .medium)).lineLimit(1)
                                    Text(result.responseText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                    }
                }

                if !vm.disabledCheckService.logs.isEmpty {
                    Section("Log") {
                        ForEach(vm.disabledCheckService.logs.prefix(30)) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.formattedTime)
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                                    .frame(width: 70, alignment: .leading)
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

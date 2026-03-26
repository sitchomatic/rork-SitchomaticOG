import SwiftUI
import UIKit

struct TempDisabledAccountsView: View {
    let vm: LoginViewModel
    @State private var selectedCred: LoginCredential?
    @State private var passwordInput: String = ""
    @State private var showPasswordSheet: Bool = false
    @State private var globalPasswordInput: String = ""
    @State private var showGlobalPasswordSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if vm.tempDisabledCredentials.isEmpty {
                ContentUnavailableView("No Temp Disabled Accounts", systemImage: "clock.badge.exclamationmark", description: Text("Accounts that are temporarily locked will appear here.\nAssign passwords to test them on a schedule."))
            } else {
                backgroundToggleBar
                statusBar
                accountsList
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Temp Disabled")
        .toolbar {
            if !vm.tempDisabledCredentials.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showGlobalPasswordSheet = true } label: {
                            Label("Assign Passwords to All", systemImage: "key.fill")
                        }
                        Button {
                            vm.runTempDisabledPasswordCheck()
                        } label: {
                            Label("Run Password Check Now", systemImage: "play.fill")
                        }
                        .disabled(vm.tempDisabledService.isRunning)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showPasswordSheet) {
            if let cred = selectedCred {
                passwordAssignSheet(for: cred)
            }
        }
        .sheet(isPresented: $showGlobalPasswordSheet) {
            globalPasswordAssignSheet
        }
    }

    private var backgroundToggleBar: some View {
        VStack(spacing: 10) {
            Toggle(isOn: Bindable(vm.tempDisabledService).backgroundCheckEnabled) {
                HStack(spacing: 10) {
                    Image(systemName: "moon.fill").foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check Temp Disabled in Background").font(.subheadline.bold())
                        Text("Tests 3 passwords per account every hour").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.purple)

            if vm.tempDisabledService.backgroundCheckEnabled {
                HStack(spacing: 6) {
                    Image(systemName: "battery.75percent").font(.caption2).foregroundStyle(.orange)
                    Text("Background checks use additional battery power")
                        .font(.caption2).foregroundStyle(.orange)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.06)).clipShape(.rect(cornerRadius: 8))
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                Text("\(vm.tempDisabledCredentials.count) accounts").font(.subheadline.bold())
            }
            Spacer()
            if vm.tempDisabledService.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking...").font(.caption.bold()).foregroundStyle(.orange)
                }
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Last check: \(vm.tempDisabledService.timeSinceLastRun)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground).opacity(0.5))
    }

    private var accountsList: some View {
        List {
            ForEach(vm.tempDisabledCredentials) { cred in
                TempDisabledCredRow(credential: cred, onAssignPasswords: {
                    selectedCred = cred
                    passwordInput = cred.assignedPasswords.joined(separator: "\n")
                    showPasswordSheet = true
                })
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { vm.restoreCredential(cred) } label: { Label("Restore", systemImage: "arrow.counterclockwise") }.tint(.blue)
                    Button(role: .destructive) { vm.deleteCredential(cred) } label: { Label("Delete", systemImage: "trash") }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }

            if !vm.tempDisabledService.checkLogs.isEmpty {
                Section("Recent Check Log") {
                    ForEach(vm.tempDisabledService.checkLogs.prefix(20)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.formattedTime)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 60, alignment: .leading)
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func passwordAssignSheet(for cred: LoginCredential) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.fill").foregroundStyle(.orange)
                        Text(cred.username)
                            .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                    }
                    Text("Enter passwords to try, one per line. 3 passwords will be tested per hourly check.")
                        .font(.caption).foregroundStyle(.secondary)

                    if !cred.assignedPasswords.isEmpty {
                        HStack(spacing: 12) {
                            Text("\(cred.assignedPasswords.count) total")
                                .font(.caption.bold()).foregroundStyle(.blue)
                            Text("\(cred.untestedPasswordCount) remaining")
                                .font(.caption.bold()).foregroundStyle(.orange)
                            if cred.nextPasswordIndex > 0 {
                                Text("\(cred.nextPasswordIndex) tested")
                                    .font(.caption.bold()).foregroundStyle(.green)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $passwordInput)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 10)).frame(minHeight: 200)
                    .overlay(alignment: .topLeading) {
                        if passwordInput.isEmpty {
                            Text("One password per line...\npassword123\nMyP@ssw0rd\nqwerty2024")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.quaternary)
                                .padding(.horizontal, 14).padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    let lineCount = passwordInput.components(separatedBy: .newlines)
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                    if lineCount > 0 {
                        Text("\(lineCount) password\(lineCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty {
                            passwordInput = clipboard
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard").font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered).tint(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Assign Passwords").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPasswordSheet = false; passwordInput = "" }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let passwords = passwordInput.components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        vm.assignPasswordsToTempDisabled(cred, passwords: passwords)
                        showPasswordSheet = false
                        passwordInput = ""
                    }
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private var globalPasswordAssignSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Assign passwords to all \(vm.tempDisabledCredentials.count) temp disabled accounts")
                        .font(.subheadline.bold())
                    Text("These passwords will be tested 3 at a time per hourly check for each account.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $globalPasswordInput)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 10)).frame(minHeight: 200)
                    .overlay(alignment: .topLeading) {
                        if globalPasswordInput.isEmpty {
                            Text("One password per line...\nCommon passwords to try on all accounts")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.quaternary)
                                .padding(.horizontal, 14).padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    let lineCount = globalPasswordInput.components(separatedBy: .newlines)
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                    if lineCount > 0 {
                        Text("\(lineCount) password\(lineCount == 1 ? "" : "s") × \(vm.tempDisabledCredentials.count) accounts")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty {
                            globalPasswordInput = clipboard
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard").font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered).tint(.secondary)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Global Password Assign").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showGlobalPasswordSheet = false; globalPasswordInput = "" }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Assign to All") {
                        let passwords = globalPasswordInput.components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        for cred in vm.tempDisabledCredentials {
                            vm.assignPasswordsToTempDisabled(cred, passwords: passwords)
                        }
                        showGlobalPasswordSheet = false
                        globalPasswordInput = ""
                    }
                    .disabled(globalPasswordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }
}

struct TempDisabledCredRow: View {
    let credential: LoginCredential
    let onAssignPasswords: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)).frame(width: 40, height: 40)
                    Image(systemName: "clock.badge.exclamationmark").font(.title3).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(credential.username)
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(credential.maskedPassword)
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                        if !credential.assignedPasswords.isEmpty {
                            Text("\(credential.untestedPasswordCount)/\(credential.assignedPasswords.count) left")
                                .font(.caption2.bold()).foregroundStyle(.orange)
                        }
                    }
                }
                Spacer()
                Button { onAssignPasswords() } label: {
                    Label(credential.assignedPasswords.isEmpty ? "Assign" : "Edit", systemImage: "key.fill")
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.orange.opacity(0.12))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
            }

            if !credential.assignedPasswords.isEmpty {
                HStack(spacing: 8) {
                    ProgressView(value: Double(credential.nextPasswordIndex), total: Double(max(credential.assignedPasswords.count, 1)))
                        .tint(.orange)
                    Text("\(credential.nextPasswordIndex)/\(credential.assignedPasswords.count)")
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

import SwiftUI

struct DualFindSetupView: View {
    @Bindable var vm: DualFindViewModel
    let onStart: () -> Void
    let onResume: () -> Void

    @FocusState private var focusedField: PasswordField?

    private enum PasswordField: Hashable {
        case pw1, pw2, pw3
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if vm.hasResumePoint {
                    resumeBanner
                }

                sessionPicker

                emailSection

                passwordSection

                startButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Dual Find")
        .navigationBarTitleDisplayMode(.large)
    }

    private var resumeBanner: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Previous Run Available")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Resume from where you left off")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                Button {
                    onResume()
                } label: {
                    Text("Resume")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.purple)
                        .clipShape(Capsule())
                }
            }

            HStack {
                Button(role: .destructive) {
                    vm.clearResumePoint()
                } label: {
                    Text("Discard")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red.opacity(0.8))
                }

                Spacer()
            }
        }
        .padding(14)
        .background(.purple.opacity(0.12))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var sessionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Session Count", systemImage: "rectangle.stack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("Sessions", selection: $vm.sessionCount) {
                ForEach(DualFindSessionCount.allCases, id: \.rawValue) { count in
                    Text(count.label).tag(count)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var emailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Email List", systemImage: "envelope.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if vm.parsedEmailCount > 0 {
                    Text("\(vm.parsedEmailCount)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.purple)
                        .clipShape(Capsule())
                }
            }

            TextEditor(text: $vm.emailInputText)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if vm.emailInputText.isEmpty {
                        Text("Paste emails here, one per line...")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Passwords (3)", systemImage: "key.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            passwordField(index: 0, label: "Password 1", field: .pw1)
            passwordField(index: 1, label: "Password 2", field: .pw2)
            passwordField(index: 2, label: "Password 3", field: .pw3)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func passwordField(index: Int, label: String, field: PasswordField) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.purple)
                .frame(width: 20)

            SecureField(label, text: $vm.passwords[index])
                .font(.system(size: 14, design: .monospaced))
                .textContentType(.password)
                .focused($focusedField, equals: field)
                .onSubmit {
                    switch field {
                    case .pw1: focusedField = .pw2
                    case .pw2: focusedField = .pw3
                    case .pw3: focusedField = nil
                    }
                }

            if !vm.passwords[index].isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 8))
    }

    private var startButton: some View {
        Button {
            onStart()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .bold))
                Text("Start Dual Find")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(vm.canStart ? .purple : .gray.opacity(0.4))
            .clipShape(.rect(cornerRadius: 14))
        }
        .disabled(!vm.canStart)
        .sensoryFeedback(.impact(weight: .heavy), trigger: vm.isRunning)
        .padding(.bottom, 20)
    }
}

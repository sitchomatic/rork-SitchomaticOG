import SwiftUI

struct TestDebugProgressView: View {
    @Bindable var vm: TestDebugViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                waveHeader
                progressBar
                etaLabel
                statsRow
                controlButtons
                sessionGrid
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(vm.isRetryingFailed ? "Retrying Failed" : "Running Test")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $vm.showSessionLogSheet) {
            if let session = vm.selectedSessionForLog {
                TestDebugSessionLogSheet(session: session)
            }
        }
    }

    private var waveHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.purple)
                    .symbolEffect(.pulse, options: .repeating.speed(0.6))
                Text("WAVE \(vm.currentWave) OF \(vm.totalWaves)")
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            Text("\(vm.completedCount) of \(vm.sessions.count) sessions complete")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var progressBar: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.tertiarySystemGroupedBackground))
                        .frame(height: 10)

                    Capsule()
                        .fill(LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, geo.size.width * vm.progress), height: 10)
                        .animation(.spring(duration: 0.4), value: vm.progress)
                }
            }
            .frame(height: 10)

            Text("\(Int(vm.progress * 100))%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var etaLabel: some View {
        if let eta = vm.estimatedTimeRemaining {
            HStack(spacing: 6) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.purple.opacity(0.7))
                Text(eta)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.purple.opacity(0.08))
            .clipShape(.rect(cornerRadius: 10))
        }
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            statPill(label: "Success", value: "\(vm.successCount)", color: .green, icon: "checkmark.circle.fill")
            statPill(label: "Failed", value: "\(vm.failedCount)", color: .red, icon: "xmark.circle.fill")
            statPill(label: "Unsure", value: "\(vm.unsureCount)", color: .yellow, icon: "questionmark.circle.fill")
            statPill(label: "Queued", value: "\(vm.sessions.count - vm.completedCount)", color: .secondary, icon: "circle.dashed")
        }
        .padding(6)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func statPill(label: String, value: String, color: Color, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 18, weight: .black, design: .monospaced))
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var controlButtons: some View {
        HStack(spacing: 12) {
            if vm.isPaused {
                Button {
                    vm.resumeTest()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(.rect(cornerRadius: 12))
                }
            } else {
                Button {
                    vm.pauseTest()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(.rect(cornerRadius: 12))
                }
            }

            Button {
                vm.stopTest()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.red.opacity(0.15))
                    .foregroundStyle(.red)
                    .clipShape(.rect(cornerRadius: 12))
            }
        }
    }

    private var sessionGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SESSIONS")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Tap for logs")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(vm.sessions) { session in
                    Button {
                        vm.showSessionLog(session)
                    } label: {
                        sessionTile(session)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sessionTile(_ session: TestDebugSession) -> some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tileColor(session.status).opacity(0.15))
                    .frame(height: 44)

                if session.status == .running {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: session.status.icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(tileColor(session.status))
                }
            }

            Text("#\(session.index)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func tileColor(_ status: TestDebugSessionStatus) -> Color {
        switch status {
        case .queued: .secondary
        case .running: .blue
        case .success: .green
        case .failed, .connectionFailure: .red
        case .unsure: .yellow
        case .timeout: .orange
        }
    }
}

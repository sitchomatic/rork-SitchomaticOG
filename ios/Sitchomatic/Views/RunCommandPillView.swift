import SwiftUI

struct RunCommandPillView: View {
    @State private var vm = RunCommandViewModel.shared
    @State private var counterPulse: Bool = false
    @State private var lastCompleted: Int = 0

    var body: some View {
        if vm.isAnyRunning {
            VStack(alignment: .trailing, spacing: 0) {
                if vm.isExpanded {
                    RunCommandExpandedView()
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity),
                            removal: .scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity)
                        ))
                        .padding(.bottom, 4)
                }

                Button {
                    withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                        vm.isExpanded.toggle()
                    }
                } label: {
                    pillContent
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .light), trigger: vm.isExpanded)
            }
            .padding(.trailing, 12)
            .padding(.top, 4)
            .onChange(of: vm.completedCount) { old, new in
                guard new > old else { return }
                withAnimation(.spring(duration: 0.2)) { counterPulse = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    withAnimation(.spring(duration: 0.2)) { counterPulse = false }
                }
            }
            .sheet(isPresented: $vm.showFullSheet) {
                RunCommandSheetView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.ultraThinMaterial)
                    .presentationContentInteraction(.scrolls)
                    .preferredColorScheme(.dark)
            }
        }
    }

    private var pillContent: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(vm.statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: vm.statusColor.opacity(0.7), radius: 4)

            Image(systemName: vm.siteIcon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(vm.siteColor)

            Text("\(vm.completedCount)/\(vm.totalCount)")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .scaleEffect(counterPulse ? 1.15 : 1.0)

            Image(systemName: vm.isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .background(vm.siteColor.opacity(0.15))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(vm.siteColor.opacity(0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }
}

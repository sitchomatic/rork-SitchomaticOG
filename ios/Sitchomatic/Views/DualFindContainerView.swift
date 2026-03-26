import SwiftUI

struct DualFindContainerView: View {
    @State private var vm = DualFindViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.isRunning {
                    DualFindRunningView(vm: vm)
                } else {
                    DualFindSetupView(
                        vm: vm,
                        onStart: { vm.startRun() },
                        onResume: { vm.resumeRun() }
                    )
                }
            }
        }
        .withMainMenuButton()
        .preferredColorScheme(.dark)
        .tint(.purple)
    }
}

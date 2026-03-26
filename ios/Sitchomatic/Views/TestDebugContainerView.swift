import SwiftUI

struct TestDebugContainerView: View {
    @State private var vm = TestDebugViewModel()

    var body: some View {
        NavigationStack {
            Group {
                switch vm.phase {
                case .setup:
                    TestDebugSetupView(vm: vm)
                case .running:
                    TestDebugProgressView(vm: vm)
                case .results:
                    TestDebugResultsView(vm: vm)
                }
            }
        }
        .withMainMenuButton()
        .preferredColorScheme(.dark)
    }
}

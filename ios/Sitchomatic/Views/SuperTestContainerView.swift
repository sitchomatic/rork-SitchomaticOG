import SwiftUI

struct SuperTestContainerView: View {
    var body: some View {
        NavigationStack {
            SuperTestView()
        }
        .withMainMenuButton()
        .preferredColorScheme(.dark)
    }
}

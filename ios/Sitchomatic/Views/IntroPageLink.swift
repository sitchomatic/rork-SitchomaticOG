import SwiftUI

struct IntroPageLink: View {
    @AppStorage("hasSelectedMode") private var hasSelectedMode: Bool = false

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    withAnimation(.spring(duration: 0.4)) {
                        hasSelectedMode = false
                    }
                } label: {
                    Text("intro")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 2)
                .padding(.bottom, 2)
            }
        }
        .allowsHitTesting(true)
    }
}

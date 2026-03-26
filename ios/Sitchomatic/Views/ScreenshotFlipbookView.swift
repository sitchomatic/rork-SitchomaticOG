import SwiftUI
import UIKit

struct ScreenshotFlipbookView: View {
    let screenshots: [PPSRDebugScreenshot]
    let startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0
    @State private var isZoomed: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                TabView(selection: $currentIndex) {
                    ForEach(Array(screenshots.enumerated()), id: \.element.id) { index, screenshot in
                        FlipbookPage(screenshot: screenshot, isZoomed: $isZoomed)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                VStack {
                    Spacer()
                    flipbookFooter
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("\(currentIndex + 1) / \(screenshots.count)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.ultraThinMaterial.opacity(0.6))
                        .clipShape(Capsule())
                }
                ToolbarItem(placement: .topBarTrailing) {
                    shareButton
                }
            }
            .onAppear { currentIndex = startIndex }
            .sensoryFeedback(.selection, trigger: currentIndex)
        }
    }

    private var flipbookFooter: some View {
        VStack(spacing: 8) {
            if currentIndex < screenshots.count {
                let screenshot = screenshots[currentIndex]
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Text(screenshot.stepName.replacingOccurrences(of: "_", with: " ").uppercased())
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.white.opacity(0.15))
                            .clipShape(Capsule())

                        Spacer()

                        resultBadge(for: screenshot)
                    }

                    HStack(spacing: 8) {
                        if !screenshot.cardDisplayNumber.isEmpty {
                            Label(screenshot.cardDisplayNumber, systemImage: "person.fill")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                        Text(screenshot.formattedTime)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    if !screenshot.note.isEmpty {
                        Text(screenshot.note)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            scrubber
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.7), .black.opacity(0.9)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    private var scrubber: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(screenshots.enumerated()), id: \.element.id) { index, screenshot in
                        Button {
                            withAnimation(.snappy) { currentIndex = index }
                        } label: {
                            Color.clear
                                .frame(width: 44, height: 32)
                                .overlay {
                                    Image(uiImage: screenshot.displayImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .allowsHitTesting(false)
                                }
                                .clipShape(.rect(cornerRadius: 4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(index == currentIndex ? Color.white : Color.clear, lineWidth: 2)
                                )
                                .opacity(index == currentIndex ? 1.0 : 0.5)
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 4)
            }
            .contentMargins(.horizontal, 0)
            .frame(height: 36)
            .onChange(of: currentIndex) { _, newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func resultBadge(for screenshot: PPSRDebugScreenshot) -> some View {
        switch screenshot.effectiveResult {
        case .markedPass:
            Label("PASS", systemImage: "checkmark.circle.fill")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(.green)
        case .markedFail:
            Label("FAIL", systemImage: "xmark.circle.fill")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(.red)
        case .none:
            Label("UNSURE", systemImage: "questionmark.circle.fill")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        if currentIndex < screenshots.count {
            let screenshot = screenshots[currentIndex]
            ShareLink(item: Image(uiImage: screenshot.image), preview: SharePreview(screenshot.stepName, image: Image(uiImage: screenshot.image))) {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
        }
    }
}

struct FlipbookPage: View {
    let screenshot: PPSRDebugScreenshot
    @Binding var isZoomed: Bool
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let imageAspect = screenshot.image.size.width / screenshot.image.size.height
            let fitWidth = geo.size.width
            let fitHeight = fitWidth / imageAspect

            Image(uiImage: screenshot.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let newScale = lastScale * value.magnification
                            scale = min(max(newScale, 1.0), 5.0)
                            isZoomed = scale > 1.05
                        }
                        .onEnded { _ in
                            if scale < 1.1 {
                                withAnimation(.spring(duration: 0.3)) {
                                    scale = 1.0
                                    offset = .zero
                                    isZoomed = false
                                }
                                lastScale = 1.0
                                lastOffset = .zero
                            } else {
                                lastScale = scale
                            }
                        }
                        .simultaneously(with:
                            DragGesture()
                                .onChanged { value in
                                    guard scale > 1.05 else { return }
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                }
                        )
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(duration: 0.3)) {
                        if scale > 1.1 {
                            scale = 1.0
                            offset = .zero
                            lastScale = 1.0
                            lastOffset = .zero
                            isZoomed = false
                        } else {
                            scale = 2.5
                            lastScale = 2.5
                            isZoomed = true
                        }
                    }
                }
        }
    }
}

struct ImageFlipbookView: View {
    let images: [UIImage]
    let startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                TabView(selection: $currentIndex) {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("\(currentIndex + 1) / \(images.count)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.ultraThinMaterial.opacity(0.6))
                        .clipShape(Capsule())
                }
            }
            .onAppear { currentIndex = startIndex }
            .sensoryFeedback(.selection, trigger: currentIndex)
        }
    }
}

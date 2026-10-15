import SwiftUI

/// An image from Gravity Lens, fetched with the device token.
struct LensImageView: View {
    @Environment(LensStore.self) private var lens
    let source: LensStore.ImageSource
    var thumb = true
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("Unavailable").font(.caption2)
                }
                .foregroundStyle(Color.secondaryText)
            } else {
                ProgressView()
            }
        }
        .task(id: source) {
            do { image = try await lens.image(source, thumb: thumb) } catch { failed = true }
        }
    }
}

/// A row of thumbnails; tapping one opens the viewer on it.
struct ImageStrip: View {
    let botId: String
    let refs: [LensImageRef]
    var size: CGFloat = 88
    @State private var opened: Int?

    private var shown: [LensImageRef] { refs.filter { $0.exists != false } }

    var body: some View {
        if !shown.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, ref in
                        Button { opened = index } label: {
                            LensImageView(source: .bot(botId, ref))
                                .frame(width: size * 1.4, height: size)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Image \(ref.name)")
                    }
                }
                .padding(.vertical, 2)
            }
            .fullScreenCover(item: Binding(get: { opened.map(ViewerStart.init) }, set: { opened = $0?.index })) { start in
                ImageViewer(sources: shown.map { .bot(botId, $0) }, index: start.index)
            }
        }
    }
}

private struct ViewerStart: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Full screen, swipe between images, pinch or double-tap to zoom.
struct ImageViewer: View {
    let sources: [LensStore.ImageSource]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(sources.enumerated()), id: \.offset) { offset, source in
                    ZoomableImage(source: source).tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: sources.count > 1 ? .automatic : .never))
            .preferredColorScheme(.dark)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(sources.indices.contains(index) ? sources[index].title : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(index + 1) of \(sources.count)").font(.caption).foregroundStyle(Color.secondaryText)
                }
            }
        }
    }
}

private struct ZoomableImage: View {
    let source: LensStore.ImageSource
    @State private var scale: CGFloat = 1
    @State private var settled: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragged: CGSize = .zero

    var body: some View {
        LensImageView(source: source, thumb: false, contentMode: .fit)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(MagnifyGesture()
                .onChanged { scale = max(1, settled * $0.magnification) }
                .onEnded { _ in
                    settled = scale
                    if scale == 1 { offset = .zero; dragged = .zero }
                })
            .simultaneousGesture(scale > 1 ? DragGesture()
                .onChanged { offset = CGSize(width: dragged.width + $0.translation.width,
                                             height: dragged.height + $0.translation.height) }
                .onEnded { _ in dragged = offset } : nil)
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    scale = scale > 1 ? 1 : 2.5
                    settled = scale
                    offset = .zero
                    dragged = .zero
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

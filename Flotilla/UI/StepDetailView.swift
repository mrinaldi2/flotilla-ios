import SwiftUI

/// Everything about one step: the command and its output, or the file diff.
struct StepDetailView: View {
    @Environment(LensStore.self) private var lens
    let botId: String
    let event: LensEvent
    @State private var detail: LensEventDetail?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(event.title, systemImage: StepRow.symbol(event.tool)).font(.headline)
                    if let path = event.path {
                        Text(path).font(.caption.monospaced()).foregroundStyle(Color.secondaryText).textSelection(.enabled)
                    }
                    if event.error == true {
                        Label("This step failed", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(Color.warningText)
                    }
                }
                if let images = event.images?.filter({ $0.exists != false }), !images.isEmpty {
                    ImageGrid(botId: botId, refs: images)
                }
                if let detail {
                    if let command = detail.command, !command.isEmpty { CodeBlock(title: "Command", text: command) }
                    if let diff = detail.diff, !diff.isEmpty { DiffView(lines: diff) }
                    if let content = detail.content, !content.isEmpty { CodeBlock(title: "Content", text: content) }
                    if let output = detail.output, !output.isEmpty, detail.diff?.isEmpty ?? true {
                        CodeBlock(title: "Output", text: output)
                    }
                    if detail.command == nil, detail.diff?.isEmpty ?? true, let input = detail.input, !input.isEmpty {
                        CodeBlock(title: "Input", text: input)
                    }
                } else if let error {
                    Text(error).foregroundStyle(Color.secondaryText)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .navigationTitle(event.tool == "Bash" ? "Command" : "Step")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { detail = try await lens.detail(bot: botId, event: event.id) } catch { self.error = error.localizedDescription }
        }
    }
}

/// Images a step produced or looked at, large, two across.
private struct ImageGrid: View {
    let botId: String
    let refs: [LensImageRef]
    @State private var opened: Int?

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(Array(refs.enumerated()), id: \.element.id) { index, ref in
                Button { opened = index } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        LensImageView(source: .bot(botId, ref))
                            .frame(height: 120)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(ref.name).font(.caption2).foregroundStyle(Color.secondaryText).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .fullScreenCover(item: Binding(get: { opened.map { GridStart(index: $0) } }, set: { opened = $0?.index })) { start in
            ImageViewer(sources: refs.map { .bot(botId, $0) }, index: start.index)
        }
    }

    private struct GridStart: Identifiable {
        let index: Int
        var id: Int { index }
    }
}

struct CodeBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(Color.secondaryText)
                Spacer()
                Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
                    .font(.caption)
                    .accessibilityLabel("Copy \(title.lowercased())")
            }
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

struct DiffView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Changes").font(.caption.weight(.semibold)).foregroundStyle(Color.secondaryText)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("@@") ? .secondary : .primary)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(line))
                    }
                }
                .padding(.vertical, 6)
                .textSelection(.enabled)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func background(_ line: String) -> Color {
        if line.hasPrefix("+") { return .green.opacity(0.16) }
        if line.hasPrefix("-") { return .red.opacity(0.14) }
        return .clear
    }
}

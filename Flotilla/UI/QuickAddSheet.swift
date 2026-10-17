import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// New item (+, K7): a draft with a title, type, board, labels from the
/// board's groups (K8), description, files and links. Photos come from the library (screenshots included) or the
/// camera, files from Files. HEIC photos are sent as JPEG: the home takes
/// PNG, JPEG, WebP, GIF, PDF, Markdown, text and log files.
struct QuickAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var model: QuickAddModel
    let boards: [KanbanBoard]
    /// A board's label groups, to pick labels from.
    let groups: (String) -> [LabelGroupView]
    let saved: (QuickAddModel.Saved) -> Void
    @State private var photos: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    @State private var pickingFiles = false
    @State private var link = ""
    @State private var readFailure: String?
    @FocusState private var titleFocused: Bool

    private static let types: [(Flotilla_Board_V1_ItemType, String)] = [
        (.feature, "Feature"), (.bug, "Bug"), (.chore, "Chore"), (.spike, "Spike"), (.epic, "Epic"),
    ]
    private static let fileTypes: [UTType] = [.image, .pdf, .plainText, .text, UTType(filenameExtension: "md"),
                                               UTType(filenameExtension: "log")].compactMap { $0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $model.title, prompt: .placeholder("What needs doing"), axis: .vertical)
                        .lineLimit(1...3)
                        .focused($titleFocused)
                        .accessibilityIdentifier("quick-add-title")
                    Picker("Type", selection: $model.type) {
                        ForEach(Self.types, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    if boards.count > 1 {
                        Picker("Board", selection: $model.boardId) {
                            ForEach(boards, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    }
                } footer: {
                    Text("Saved as a draft: it reaches the board when you finalize it.").foregroundStyle(Color.secondaryText)
                }
                labels
                Section {
                    TextField("Description", text: $model.description, prompt: .placeholder("Left empty, the type’s template fills it"),
                              axis: .vertical)
                        .lineLimit(3...12)
                } header: {
                    SectionTitle("Description")
                }
                attachments
                links
                if let failure = model.failure ?? readFailure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.errorText)
                    }
                }
            }
            .navigationTitle("New item")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(model.progress != nil)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save draft") { save() }
                        .disabled(!model.canSave)
                        .accessibilityIdentifier("quick-add-save")
                }
            }
            .overlay {
                if let progress = model.progress {
                    ProgressView(progress)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .onAppear {
                titleFocused = true
                #if DEBUG
                // UI tests: the photo picker runs out of process, so -attachFixture <path> adds a file.
                if let path = UserDefaults.standard.string(forKey: "attachFixture"), model.files.isEmpty,
                   let data = FileManager.default.contents(atPath: path) {
                    model.add(name: (path as NSString).lastPathComponent, data: data)
                }
                #endif
            }
            .onChange(of: model.boardId) { _, board in model.keepLabels(offered: groups(board)) }
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                photos = []
                Task { await addPhotos(items) }
            }
            .fileImporter(isPresented: $pickingFiles, allowedContentTypes: Self.fileTypes, allowsMultipleSelection: true) { result in
                addFiles(result)
            }
            .fullScreenCover(isPresented: $takingPhoto) {
                CameraPicker { image in
                    if let data = image.jpegData(compressionQuality: 0.85) { model.add(name: Self.name("photo", "jpg"), data: data) }
                }
                .ignoresSafeArea()
            }
        }
        .interactiveDismissDisabled(model.progress != nil)
    }

    /// A row of chips per label group of the chosen board; none, no section.
    @ViewBuilder private var labels: some View {
        let groups = groups(model.boardId).filter { !$0.values.isEmpty }
        if !groups.isEmpty {
            Section {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.name).font(.caption.weight(.semibold)).foregroundStyle(Color.secondaryText)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(group.values, id: \.self) { value in labelChip(group, value) }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Label group \(group.name)")
                }
            } header: {
                SectionTitle("Labels", count: model.labels.isEmpty ? nil : model.labels.count)
            }
        }
    }

    private func labelChip(_ group: LabelGroupView, _ value: String) -> some View {
        let label = group.label(value)
        let on = model.labels.contains(label)
        return Button { model.toggle(label: label) } label: {
            Text(on ? "✓ \(value)" : value)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(on ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name): \(value)")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("quick-add-label-\(label)")
    }

    @ViewBuilder private var attachments: some View {
        Section {
            ForEach(model.files) { file in
                FileRow(file: file)
                    .swipeActions { Button("Remove", role: .destructive) { model.remove(file.id) } }
                    .accessibilityAction(named: "Remove") { model.remove(file.id) }
            }
            PhotosPicker(selection: $photos, maxSelectionCount: 10, matching: .images, photoLibrary: .shared()) {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { takingPhoto = true } label: { Label("Camera", systemImage: "camera") }
            }
            Button { pickingFiles = true } label: { Label("Files", systemImage: "folder") }
            if let total = model.totalProblem {
                Label(total, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.errorText)
            }
        } header: {
            SectionTitle("Attach", count: model.files.isEmpty ? nil : model.files.count)
        } footer: {
            Text("Screenshots are in your Photo Library. PNG, JPEG, WebP, GIF, PDF, Markdown, text or log; up to 10 MB an image and 25 MB a file.")
                .foregroundStyle(Color.secondaryText)
        }
    }

    @ViewBuilder private var links: some View {
        Section {
            ForEach(Array(model.links.enumerated()), id: \.offset) { index, url in
                Label(url, systemImage: "link")
                    .lineLimit(1)
                    .swipeActions { Button("Remove", role: .destructive) { model.links.remove(at: index) } }
            }
            HStack {
                TextField("Link", text: $link, prompt: .placeholder("https://…"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add") {
                    model.links.append(link.trimmed)
                    link = ""
                }
                .disabled(URL(string: link.trimmed)?.scheme?.hasPrefix("http") != true)
            }
        } header: {
            SectionTitle("Link a document")
        }
    }

    private func save() {
        Task {
            guard let result = await model.save() else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            saved(result)
        }
    }

    /// "photo-20261013-091233.jpg".
    private static func name(_ stem: String, _ ext: String, index: Int = 0) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = index > 0 ? "-\(index + 1)" : ""
        return "\(stem)-\(formatter.string(from: Date()))\(suffix).\(ext)"
    }

    /// Library images keep PNG (screenshots), GIF and WebP; the rest, HEIC
    /// above all, become JPEG.
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        readFailure = nil
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                readFailure = "Couldn’t read a photo from the library."
                continue
            }
            let type = item.supportedContentTypes.first
            if let type, let ext = [UTType.png: "png", .gif: "gif", .webP: "webp", .jpeg: "jpg"][type] {
                model.add(name: Self.name(type == .png ? "image" : "photo", ext, index: index), data: data)
            } else if let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) {
                model.add(name: Self.name("photo", "jpg", index: index), data: jpeg)
            } else {
                readFailure = "A photo couldn’t be turned into JPEG."
            }
        }
    }

    private func addFiles(_ result: Result<[URL], Error>) {
        readFailure = nil
        switch result {
        case .failure(let error):
            readFailure = error.localizedDescription
        case .success(let urls):
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    readFailure = "Couldn’t read \(url.lastPathComponent)."
                    continue
                }
                let ext = url.pathExtension.lowercased()
                if ext == "heic" || ext == "heif", let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) {
                    model.add(name: url.deletingPathExtension().lastPathComponent + ".jpg", data: jpeg)
                } else {
                    model.add(name: url.lastPathComponent, data: data)
                }
            }
        }
    }
}

/// A file about to be attached: a thumbnail or an icon, its name and size,
/// and why the home won't take it, said at once.
private struct FileRow: View {
    let file: QuickAddModel.File

    var body: some View {
        HStack(spacing: 12) {
            if file.isImage, let image = UIImage(data: file.data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                IconTile(systemImage: "doc", size: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(AttachmentRules.size(Int64(file.data.count))).font(.footnote).foregroundStyle(Color.secondaryText)
                if let problem = file.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.errorText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The camera, for a photo to attach.
struct CameraPicker: UIViewControllerRepresentable {
    let taken: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.taken(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

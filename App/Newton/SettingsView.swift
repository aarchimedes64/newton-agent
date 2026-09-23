import SwiftUI
import UniformTypeIdentifiers
import NewtonCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AppSettings()
    @State private var importing = false
    @State private var downloadURL = ""
    @State private var repository = ""
    @State private var hubFiles: [HuggingFaceFile] = []
    @State private var didLookup = false
    @State private var isLookingUp = false
    @State private var lookupTask: Task<Void, Never>?
    @State private var pendingDeletion: ModelFile?
    @State private var eraseConfirmation = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Inference") {
                    Picker("Provider", selection: $draft.provider) {
                        Text("OpenAI-compatible API").tag(AppSettings.Provider.compatible)
                        Text("On-device GGUF").tag(AppSettings.Provider.local)
                    }
                    if draft.provider == .compatible {
                        TextField("Base URL (including /v1)", text: $draft.baseURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Model ID", text: $draft.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("API key (optional for local servers)", text: $draft.apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("For a downloaded model served by llama.cpp, Ollama, or LM Studio on your computer, enter that computer’s LAN address and API base path. On iPhone, localhost means the iPhone. Use HTTPS; local-network HTTP may require server transport configuration.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $draft.localModelID) {
                            Text("Select a model").tag(nil as UUID?)
                            ForEach(model.models) { model in Text(model.name).tag(Optional(model.id)) }
                        }
                        Text("Import an instruction-tuned GGUF with a chat template. Start with a small quantized model that fits your device’s memory. Tool reliability depends on the model. Context: 4,096 tokens; output: 512 tokens.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                downloadedModels
                huggingFaceDownloads
                Section("Import a model") {
                    Button("Import GGUF from Files", systemImage: "square.and.arrow.down") { importing = true }
                    DisclosureGroup("Direct download URL") {
                        TextField("Direct HTTPS URL to a GGUF file", text: $downloadURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Download model") {
                            guard let url = URL(string: downloadURL), url.scheme == "https" else { failure = "Enter a direct HTTPS model URL."; return }
                            model.addModel(from: url, downloading: true)
                        }.disabled(downloadURL.isEmpty)
                    }
                    Text("Keep Newton open while downloading. Models can be several gigabytes; choose one that fits your device. Downloads are saved inside Newton and removed when you delete the app.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(model.isManagingModel)
                Section("Apple Notes bridge") {
                    TextField("Shortcut name", text: $draft.notesShortcut)
                    Text("In Shortcuts, create a shortcut with this exact name. Add the Create Note action and use Shortcut Input as its body. Choose your folder. Newton will open the shortcut after your approval; completion cannot be verified. Apple Notes reading, editing, and deleting are not exposed by this app.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Tools") {
                    Toggle("Enable tools", isOn: $draft.toolsEnabled)
                    Text("When off, Newton only chats. Models receive no tool definitions and cannot run actions. Applies to local models and APIs after you tap Save.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.makeTools(), id: \.definition.name) { tool in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(tool.definition.name).font(.subheadline.monospaced())
                            Text(tool.definition.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Data & privacy") {
                    Text("Chats, credentials, private notes, and model copies stay in Newton’s protected app container, excluded from backup. No iCloud sync, shared container, or Keychain storage is used. Audio is transcribed on device and is not saved.")
                    Text("Deleting the app removes its local data. Offloading keeps data. Sent messages, events in Calendar, notes exported to Apple Notes, and data retained by your API provider are outside Newton’s container. iOS manages its own speech resources.").font(.caption).foregroundStyle(.secondary)
                    Button("Erase all Newton data", role: .destructive) { eraseConfirmation = true }.disabled(model.isManagingModel)
                }
            }
            .disabled(model.isRunning || !model.storageReady)
            .safeAreaInset(edge: .bottom) {
                if model.isManagingModel {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.modelTransferStatus).font(.subheadline).lineLimit(2)
                            Spacer()
                            Button("Cancel", role: .cancel) { model.modelTask?.cancel() }
                        }
                        if let progress = model.modelTransferProgress {
                            ProgressView(value: progress)
                            Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption).foregroundStyle(.secondary)
                        } else { ProgressView() }
                    }.padding().frame(maxWidth: .infinity).background(.bar)
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try model.saveSettings(draft); dismiss() } catch { failure = error.localizedDescription }
                    }.disabled(model.isRunning || model.isManagingModel || !model.storageReady)
                }
            }
            .onAppear { draft = model.settings }
            .onChange(of: model.models) { old, new in
                if new.count > old.count { draft.localModelID = model.settings.localModelID }
                if let id = draft.localModelID, !new.contains(where: { $0.id == id }) { draft.localModelID = nil }
            }
            .onDisappear { lookupTask?.cancel() }
            .confirmationDialog("Delete downloaded model?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible, presenting: pendingDeletion) { file in
                Button("Delete model", role: .destructive) {
                    model.deleteModel(file)
                    if draft.localModelID == file.id, !model.models.contains(where: { $0.id == file.id }) { draft.localModelID = nil }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: { file in
                Text("Delete \(file.name) from this device and free \(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))? You'll need to download it again to use it. Your chats will stay.")
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                do { if let url = try result.get().first { model.addModel(from: url, downloading: false) } }
                catch { failure = error.localizedDescription }
            }
            .confirmationDialog("Erase chats, credentials, notes, and every imported model?", isPresented: $eraseConfirmation, titleVisibility: .visible) {
                Button("Erase all Newton data", role: .destructive) { model.eraseAllData(); draft = model.settings }
            } message: { Text("This cannot be undone. Exported data in other apps is unaffected.") }
            .alert("Settings", isPresented: Binding(get: { failure != nil || model.error != nil }, set: { if !$0 { failure = nil; model.error = nil } })) {
                Button("OK") { failure = nil; model.error = nil }
            } message: { Text(failure ?? model.error ?? "") }
        }
    }

    private var downloadedModels: some View {
        Section("Downloaded models (\(model.models.count))") {
            if model.models.isEmpty {
                Label("No models downloaded yet", systemImage: "internaldrive")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.models) { file in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(file.name).font(.subheadline.weight(.medium))
                        Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                        if draft.provider == .local && draft.localModelID == file.id {
                            Label("Selected for inference", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        } else {
                            Button("Use for inference") { draft.provider = .local; draft.localModelID = file.id }
                                .font(.caption).buttonStyle(.borderless)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) { pendingDeletion = file } label: {
                        Image(systemName: "trash.fill").foregroundStyle(.red).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless).accessibilityLabel("Delete \(file.name)")
                    .accessibilityHint("Asks for confirmation before removing the model from this device")
                }
            }
        }.disabled(model.isManagingModel)
    }
    private var huggingFaceDownloads: some View {
        Section("Download from Hugging Face") {
            TextField("Repository URL or owner/model-GGUF", text: $repository)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(isLookingUp)
                .onChange(of: repository) { _, _ in hubFiles = []; didLookup = false }
            Button("Find GGUF files", systemImage: "magnifyingglass") { findHubFiles() }
                .disabled(repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLookingUp)
            if isLookingUp { ProgressView("Looking up repository…") }
            if didLookup && hubFiles.isEmpty {
                Text("No supported single-file GGUF models found. Split models and vision projection files are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(hubFiles) { file in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(file.name).font(.subheadline)
                        Text(file.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size unavailable")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if model.models.contains(where: { $0.sourceURL == file.downloadURL }) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Downloaded")
                    } else {
                        Button { model.addModel(from: file.downloadURL, downloading: true, expectedBytes: file.byteCount) } label: {
                            Image(systemName: "arrow.down.circle").font(.title2).frame(width: 44, height: 44)
                        }.buttonStyle(.borderless).accessibilityLabel("Download \(file.name)")
                    }
                }
            }
            Text("Enter a public GGUF repository, choose a file to download, then select Use for inference and Save. Private and gated repositories require sign-in and aren't supported yet.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(model.isManagingModel)
    }
    private func findHubFiles() {
        lookupTask?.cancel()
        isLookingUp = true; didLookup = false; hubFiles = []
        let input = repository
        lookupTask = Task { @MainActor in
            defer { isLookingUp = false }
            do {
                let files = try await HuggingFaceHub().files(in: input)
                try Task.checkCancellation()
                hubFiles = files; didLookup = true
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }

}

struct NotesView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editor: StoredNote?
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.notes.sorted { $0.updatedAt > $1.updatedAt }) { note in
                        Button { editor = note } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(note.title).font(.headline).foregroundStyle(.primary)
                                Text(note.body).lineLimit(2).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                do { try model.saveNotes(model.notes.filter { $0.id != note.id }) } catch { failure = error.localizedDescription }
                            }
                        }
                    }
                } footer: { Text("These notes are stored inside Newton. Apple Notes is available through the separate Shortcut tool.") }
            }.disabled(model.isRunning || !model.storageReady)
            .overlay { if model.notes.isEmpty { ContentUnavailableView("Your own scratchpad", systemImage: "note.text", description: Text("Create a note here or ask Newton to remember something.")) } }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("New note", systemImage: "plus") { editor = StoredNote(title: "", body: "") }.disabled(model.isRunning || !model.storageReady) }
            }
            .sheet(item: $editor) { note in NoteEditor(model: model, note: note) }
            .alert("Notes", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
        }
    }
}

struct NoteEditor: View {
    let model: AppModel
    @State var note: StoredNote
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form { TextField("Title", text: $note.title); TextEditor(text: $note.body).frame(minHeight: 280) }
                .navigationTitle("Note").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            do {
                                note.updatedAt = Date()
                                try model.saveNotes([note] + model.notes.filter { $0.id != note.id }); dismiss()
                            } catch { failure = error.localizedDescription }
                        }.disabled(note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .alert("Could not save", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
        }
    }
}

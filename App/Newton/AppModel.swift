import SwiftUI
import NewtonCore
import NewtonLocal
import Observation
import MessageUI

struct ApprovalRequest: Identifiable {
    let id = UUID()
    let call: ToolCall
}
struct MessageDraft: Identifiable {
    let id = UUID()
    let recipient: String
    let body: String
}

@MainActor @Observable final class AppModel {
    var conversations: [Conversation] = []
    var notes: [StoredNote] = []
    var models: [ModelFile] = []
    var settings = AppSettings()
    var selection: UUID?
    var isRunning = false
    var isManagingModel = false
    var modelTransferProgress: Double?
    var modelTransferStatus = ""
    var error: String?
    var streamedText: String?
    var tokensPerSecond: Double?
    var approval: ApprovalRequest?
    var messageDraft: MessageDraft?
    var storageReady = false
    @ObservationIgnored private var storage: SandboxStore?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var pendingApprovalID: UUID?
    @ObservationIgnored private var approvalDecision = false
    @ObservationIgnored private var messageContinuation: CheckedContinuation<String, Never>?
    @ObservationIgnored private var pendingMessageID: UUID?
    @ObservationIgnored private var messageResult = "Composer dismissed. Delivery is not confirmed."
    @ObservationIgnored let calendar = CalendarTools()
    @ObservationIgnored var modelTask: Task<Void, Never>?
    @ObservationIgnored private var streamTokens = 0
    @ObservationIgnored private var streamStartedAt: Date?
    // Run-wide accumulators for the persisted GenerationRecord.
    @ObservationIgnored private var genTokens = 0
    @ObservationIgnored private var genSeconds = 0.0
    @ObservationIgnored private var genContextTokens = 0
    @ObservationIgnored private var genOccurred = false
    var selectedChat: Conversation? { conversations.first { $0.id == selection } }

    init() {
        do {
            let storage = try SandboxStore(); self.storage = storage
            settings = try storage.read(AppSettings.self, name: "settings", fallback: AppSettings())
            conversations = try storage.read([Conversation].self, name: "chats", fallback: [])
            notes = try storage.read([StoredNote].self, name: "notes", fallback: [])
            models = try storage.read([ModelFile].self, name: "models", fallback: [])
            // A terminated deletion must not leave a missing model selectable.
            models = models.filter { FileManager.default.fileExists(atPath: storage.modelURL($0.id).path) }
            if let id = settings.localModelID, !models.contains(where: { $0.id == id }) { settings.localModelID = nil }
            for index in conversations.indices { conversations[index].repairInterruptedCalls() }
            try storage.write(conversations, name: "chats")
            selection = conversations.first?.id; storageReady = true
        } catch { self.error = "Could not open local storage: \(error.localizedDescription). Existing files have been preserved." }
    }
    func newChat() {
        do {
            let chat = Conversation()
            try saveChats([chat] + conversations); selection = chat.id
        } catch { self.error = error.localizedDescription }
    }
    func deleteChat(_ id: UUID) {
        guard !isRunning else { return }
        do {
            try saveChats(conversations.filter { $0.id != id })
            if selection == id { selection = conversations.first?.id }
        } catch { self.error = error.localizedDescription }
    }
    func renameChat(_ id: UUID, title: String) {
        do {
            var updated = conversations
            guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
            updated[index].title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            if updated[index].title.isEmpty { return }
            try saveChats(updated)
        } catch { self.error = error.localizedDescription }
    }
    private func requireStorage() throws -> SandboxStore {
        guard storageReady, let storage else { throw HarnessError("Local storage is unavailable. Restart after resolving the storage error.") }
        return storage
    }
    private func saveChats(_ value: [Conversation]) throws {
        try requireStorage().write(value, name: "chats"); conversations = value
    }
    func saveSettings(_ value: AppSettings) throws {
        _ = try CompatibleInference.endpoint(value.baseURL)
        try requireStorage().write(value, name: "settings"); settings = value
    }
    func saveNotes(_ value: [StoredNote]) throws {
        try requireStorage().write(value, name: "notes"); notes = value
    }
    func send(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, !isManagingModel, storageReady else { return false }
        do {
            let inference: any ChatInference
            if settings.provider == .local {
                guard let id = settings.localModelID, models.contains(where: { $0.id == id }) else { throw HarnessError("Import and select a GGUF model in Settings.") }
                inference = LlamaInference(modelURL: try requireStorage().modelURL(id))
            } else {
                _ = try CompatibleInference.endpoint(settings.baseURL)
                guard !settings.model.isEmpty else { throw HarnessError("Set the inference model ID in Settings first.") }
                inference = CompatibleInference(settings: settings)
            }
            if selection == nil { newChat() }
            guard let id = selection, var chat = selectedChat else { return false }
            chat.repairInterruptedCalls()
            if chat.messages.isEmpty { chat.title = String(text.prefix(48)) }
            chat.messages.append(Message(role: "user", content: text)); chat.updatedAt = Date()
            try saveChats(conversations.map { $0.id == id ? chat : $0 })
            // Snapshot the context the generation will be asked to condition on, before the run mutates it.
            genContextTokens = chat.messages.reduce(0) { total, message in
                var bytes = (message.content ?? "").utf8.count
                for call in message.toolCalls ?? [] { bytes += call.function.name.utf8.count + call.function.arguments.utf8.count }
                return total + max(1, bytes / 4) // Same bytes-per-four estimate the live rate uses.
            }
            genTokens = 0; genSeconds = 0.0; genOccurred = false
            isRunning = true
            tokensPerSecond = nil // A new run starts with no rate; the last value persists after it ends.
            let runtime = AgentRuntime(tools: makeTools(), toolsEnabled: settings.toolsEnabled)
            runTask = Task {
                defer {
                    // Close the final round's rate window, then persist what this generation measured.
                    if let started = streamStartedAt { genSeconds += Date().timeIntervalSince(started); streamStartedAt = nil }
                    if genOccurred {
                        let rate = genTokens > 0 && genSeconds > 0.2 ? Double(genTokens) / genSeconds : 0
                        recordGeneration(chatID: id, contextSize: genContextTokens, averageTokensPerSecond: rate)
                    }
                    isRunning = false; runTask = nil; streamedText = nil
                }
                do {
                    try await runtime.run(messages: chat.messages, inference: inference,
                        approve: { [weak self] call in await self?.requestApproval(call) ?? false },
                        persist: { [weak self] messages in
                            guard let self else { throw CancellationError() }
                            var next = self.conversations
                            guard let i = next.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                            // The persisted transcript now renders the answer itself; drop the live echo.
                            // Keep tokensPerSecond: the readout stays up at its last value until the run ends.
                            if messages.last?.role == "assistant" { self.streamedText = nil; self.genOccurred = true }
                            next[i].messages = messages; next[i].updatedAt = Date()
                            try self.saveChats(next)
                        },
                        onGenerationStart: { [weak self] in
                            // End the previous round's rate window into the run totals, then reset the
                            // round's counters; the new round overwrites the readout as its deltas arrive.
                            if let self, let started = self.streamStartedAt {
                                self.genSeconds += Date().timeIntervalSince(started)
                            }
                            self?.streamedText = nil
                            self?.streamTokens = 0; self?.streamStartedAt = nil
                        },
                        onToken: { [weak self] piece in
                            guard let self else { return }
                            if self.streamStartedAt == nil { self.streamStartedAt = Date() }
                            self.streamTokens += max(1, piece.utf8.count / 4) // Deltas are not token-aligned; estimate bytes-per-four.
                            self.genTokens += max(1, piece.utf8.count / 4)
                            self.genOccurred = true
                            self.streamedText = (self.streamedText ?? "") + piece
                            if let started = self.streamStartedAt {
                                let elapsed = Date().timeIntervalSince(started)
                                if elapsed > 0.2 { self.tokensPerSecond = Double(self.streamTokens) / elapsed }
                            }
                        })
                } catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func cancel() {
        runTask?.cancel()
        resolveApproval(false)
        if let id = pendingApprovalID { approvalDidDismiss(id) }
        finishMessage("Message composer cancelled. Delivery is not confirmed.")
    }
    private func recordGeneration(chatID: UUID, contextSize: Int, averageTokensPerSecond: Double) {
        guard let index = conversations.firstIndex(where: { $0.id == chatID }) else { return }
        var next = conversations
        next[index].generations = (next[index].generations ?? []) + [GenerationRecord(contextSize: contextSize, averageTokensPerSecond: averageTokensPerSecond)]
        do { try saveChats(next) } catch { self.error = error.localizedDescription }
    }
    private func requestApproval(_ call: ToolCall) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await withCheckedContinuation { continuation in
            let request = ApprovalRequest(call: call)
            approvalDecision = false; pendingApprovalID = request.id
            approvalContinuation = continuation; approval = request
        }
    }
    func resolveApproval(_ allowed: Bool) {
        approvalDecision = allowed; approval = nil
        // Resume after the review sheet disappears, so a native composer or the
        // next approval is never presented during the previous dismissal.
    }
    func approvalDidDismiss(_ id: UUID) {
        guard pendingApprovalID == id else { return }
        let continuation = approvalContinuation
        approvalContinuation = nil; pendingApprovalID = nil
        continuation?.resume(returning: approvalDecision)
    }
    func composeMessage(recipient: String, body: String) async throws -> String {
        guard MFMessageComposeViewController.canSendText() else { throw HarnessError("Messages is unavailable on this device. Try a physical iPhone with messaging configured.") }
        return await withCheckedContinuation { continuation in
            let draft = MessageDraft(recipient: recipient, body: body)
            pendingMessageID = draft.id; messageResult = "Composer dismissed. Delivery is not confirmed."
            messageContinuation = continuation; messageDraft = draft
        }
    }
    func finishMessage(_ result: String, id: UUID? = nil) {
        if let id, pendingMessageID != id { return }
        messageResult = result; messageDraft = nil
        if id == nil, let pendingMessageID { messageDidDismiss(pendingMessageID) }
    }
    func messageDidDismiss(_ id: UUID) {
        guard pendingMessageID == id else { return }
        let continuation = messageContinuation
        messageContinuation = nil; pendingMessageID = nil
        continuation?.resume(returning: messageResult)
    }
    func addModel(from source: URL, downloading: Bool, expectedBytes: Int64? = nil) {
        guard !isRunning, !isManagingModel, let storage, storageReady else { return }
        if downloading, models.contains(where: { $0.sourceURL == source }) {
            error = "This model is already downloaded. Select it in the local model picker."; return
        }
        isManagingModel = true
        modelTransferProgress = nil
        modelTransferStatus = (downloading ? "Downloading " : "Importing ") + source.lastPathComponent
        modelTask = Task {
            defer { isManagingModel = false; modelTask = nil; modelTransferProgress = nil; modelTransferStatus = "" }
            let id = UUID(); let destination = storage.modelURL(id)
            do {
                let info = try await ModelImporter.importModel(from: source, to: destination, downloading: downloading, expectedBytes: expectedBytes) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.isManagingModel else { return }
                        self.modelTransferProgress = progress
                        if progress == 1 { self.modelTransferStatus = "Verifying and saving model…" }
                    }
                }
                try Task.checkCancellation()
                let model = ModelFile(id: id, name: source.lastPathComponent, byteCount: info, sourceURL: downloading ? source : nil)
                let next = models + [model]
                try storage.write(next, name: "models"); models = next
                var config = settings; config.localModelID = id
                try saveSettings(config)
            } catch {
                if !models.contains(where: { $0.id == id }) { try? FileManager.default.removeItem(at: destination) }
                if !Task.isCancelled && !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func deleteModel(_ model: ModelFile) {
        guard !isRunning, !isManagingModel else { return }
        do {
            let storage = try requireStorage()
            try storage.removeModelFile(model.id)
            // The cache must not outlive the file it maps; isRunning was gated above, so no
            // generation can be reading these weights right now.
            Task { await LlamaModelCache.shared.releaseAll() }
            let next = models.filter { $0.id != model.id }
            models = next
            if settings.localModelID == model.id { settings.localModelID = nil }
            try storage.write(next, name: "models")
            try storage.write(settings, name: "settings")
        } catch { self.error = error.localizedDescription }
    }
    func eraseAllData() {
        guard !isRunning, !isManagingModel else { return }
        do {
            try requireStorage().erase()
            Task { await LlamaModelCache.shared.releaseAll() }
            conversations = []; notes = []; models = []; settings = AppSettings(); selection = nil
        } catch { self.error = error.localizedDescription }
    }
}

actor ModelImporter {
    static func importModel(from source: URL, to destination: URL, downloading: Bool, expectedBytes: Int64? = nil,
                            progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws -> Int64 {
        let worker = ModelImporter()
        return try await worker.copy(source: source, destination: destination, downloading: downloading, expectedBytes: expectedBytes, progress: progress)
    }
    private func copy(source: URL, destination: URL, downloading: Bool, expectedBytes: Int64?, progress: @escaping @Sendable (Double?) -> Void) async throws -> Int64 {
        var local = source
        let scoped = !downloading && source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        if downloading {
            guard source.scheme == "https", source.host != nil, source.user == nil, source.password == nil else {
                throw HarnessError("Model downloads require an HTTPS URL without embedded credentials.")
            }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (file, response) = try await session.download(from: source, delegate: ModelDownloadProgress(progress: progress))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), response.url?.scheme == "https" else {
                try? FileManager.default.removeItem(at: file)
                throw HarnessError("Model download failed. Use a direct HTTPS link to a GGUF file.")
            }
            local = file
        }
        defer { if downloading { try? FileManager.default.removeItem(at: local) } }
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: local)
        let header = try handle.read(upToCount: 4); try handle.close()
        guard header == Data("GGUF".utf8) else { throw HarnessError("This is not a GGUF model file.") }
        let size = try local.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 4 else { throw HarnessError("The model file is incomplete.") }
        if let expectedBytes, expectedBytes != Int64(size) { throw HarnessError("The downloaded size does not match Hugging Face's file size. Please download the model again.") }
        let staging = destination.appendingPathExtension("partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        if downloading { try FileManager.default.moveItem(at: local, to: staging) }
        else { try FileManager.default.copyItem(at: local, to: staging) }
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: staging.path)
        try FileManager.default.moveItem(at: staging, to: destination)
        return Int64(size)
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double?) -> Void
    init(progress: @escaping @Sendable (Double?) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }
}

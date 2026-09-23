import Foundation
import NewtonCore
import llama

/// Actor confines C pointers and decoding to a serial executor, away from the UI.
/// Weights are kept resident by `LlamaModelCache` (one per process) and reused across
/// generations; only the per-conversation context is allocated and freed per answer.
public actor LlamaInference: ChatInference {
    private let modelURL: URL
    /// Hard ceiling on prompt + generation. The context is sized to the actual run instead
    /// (see `complete`), so idle cost for the KV cache is zero and short chats pay little.
    private let contextSize = 4096
    public init(modelURL: URL) { self.modelURL = modelURL }

    public func complete(messages: [Message], tools: [ToolDefinition]) async throws -> Message {
        try await complete(messages: messages, tools: tools, onToken: { _ in })
    }

    public func complete(messages: [Message], tools: [ToolDefinition], onToken: @escaping @MainActor (String) -> Void) async throws -> Message {
        try Task.checkCancellation()
        // Plain-text answers stream token by token. A tool-mode reply is one JSON envelope, and
        // flashing its raw braces/keys on screen would be noise, so that mode stays buffered.
        let streamLive = tools.isEmpty
        var streamedBytes = 0
        // Reuse the resident weights instead of re-reading the GGUF on every message: the second
        // send no longer pays for a second full model load in the same process.
        let model = try await LlamaModelCache.shared.model(for: modelURL)
        guard let vocab = llama_model_get_vocab(model) else {
            throw HarnessError("This GGUF carries no vocabulary and cannot be used for inference.")
        }
        var cp = llama_context_default_params()
        cp.n_batch = 512
        cp.n_threads = Int32(max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads_batch = cp.n_threads
        let prompt = try makePrompt(model: model, messages: messages, tools: tools)
        var tokens = [llama_token](repeating: 0, count: prompt.utf8.count + 16)
        let count = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, Int32(tokens.count), true, true)
        guard count > 0, count + 512 < contextSize else {
            throw HarnessError("This chat exceeds the local model's 4,096-token context. Start a new chat or use a server with a larger context.")
        }
        tokens = Array(tokens.prefix(Int(count)))
        // Size the KV cache to what this run actually needs (prompt + the 512-token generation
        // budget, capped by the ceiling) rather than always paying for 4,096 positions.
        cp.n_ctx = UInt32(min(contextSize, Int(count) + 512))
        guard let context = llama_init_from_model(model, cp) else {
            throw HarnessError("Not enough memory to create the model context.")
        }
        defer { llama_free(context) }
        var batch = llama_batch_init(512, 0, 1)
        defer { llama_batch_free(batch) }
        func decode(_ ids: [llama_token], position: Int) throws {
            batch.n_tokens = Int32(ids.count)
            for (i, token) in ids.enumerated() {
                batch.token[i] = token; batch.pos[i] = Int32(position + i)
                batch.n_seq_id[i] = 1; batch.seq_id[i]![0] = 0
                batch.logits[i] = i == ids.count - 1 ? 1 : 0
            }
            guard llama_decode(context, batch) == 0 else { throw HarnessError("Local model decoding failed.") }
        }
        for start in stride(from: 0, to: tokens.count, by: 512) {
            try Task.checkCancellation()
            try decode(Array(tokens[start..<min(start + 512, tokens.count)]), position: start)
        }
        guard let sampler = llama_sampler_init_greedy() else { throw HarnessError("Could not initialize sampler.") }
        defer { llama_sampler_free(sampler) }
        var bytes: [UInt8] = []
        var finished = false
        for step in 0..<512 {
            try Task.checkCancellation()
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { finished = true; break }
            var piece = [CChar](repeating: 0, count: 256)
            var length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if length < 0 {
                piece = .init(repeating: 0, count: Int(-length))
                length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            }
            guard length >= 0 else { throw HarnessError("Could not decode model text.") }
            bytes.append(contentsOf: piece.prefix(Int(length)).map { UInt8(bitPattern: $0) })
            // Flush only complete UTF-8: a multi-byte character can straddle token pieces, and
            // String(data:encoding:) rejects a truncated tail, so it waits for the next token.
            if streamLive, streamedBytes < bytes.count,
               let flushed = String(data: Data(bytes[streamedBytes...]), encoding: .utf8), !flushed.isEmpty {
                streamedBytes = bytes.count
                await onToken(flushed)
            }
            try decode([token], position: tokens.count + step)
        }
        guard finished else { throw HarnessError("Local output exceeded 512 tokens. Try a shorter request; no tools were executed.") }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if tools.isEmpty {
            guard !text.isEmpty else { throw HarnessError("The local model returned no text.") }
            return Message(role: "assistant", content: text)
        }
        // Local models vary in native tool syntax. A single explicit JSON envelope keeps
        // the harness protocol stable. Malformed output never becomes an executable call.
        struct Envelope: Decodable {
            struct Call: Decodable { let name: String; let arguments: JSONValue }
            let content: String?
            let tool_calls: [Call]?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)) else {
            return Message(role: "assistant", content: text.isEmpty ? "The model returned no text." : text)
        }
        let calls = try envelope.tool_calls?.map { ToolCall(name: $0.name, arguments: try $0.arguments.encoded()) }
        guard !(envelope.content ?? "").isEmpty || !(calls ?? []).isEmpty else { throw HarnessError("The local model returned an empty response.") }
        return Message(role: "assistant", content: envelope.content, toolCalls: calls)
    }

    private func makePrompt(model: OpaquePointer, messages: [Message], tools: [ToolDefinition]) throws -> String {
        let catalog = String(decoding: try JSONEncoder().encode(tools), as: UTF8.self)
        let protocolText = tools.isEmpty ? "Answer the user in ordinary text. No tools are available. Do not output tool calls or a JSON response envelope." : """
        Respond ONLY with a JSON object: {"content":"answer"} or
        {"tool_calls":[{"name":"tool_name","arguments":{"key":"value"}}]}.
        Do not wrap JSON in markdown. Available tools: \(catalog)
        """
        var allocated: [UnsafeMutablePointer<CChar>] = []
        defer { allocated.forEach { free($0) } }
        func pointer(_ text: String) -> UnsafePointer<CChar> {
            let value = strdup(text)!; allocated.append(value); return UnsafePointer(value)
        }
        // The protocol instruction must always reach the model. Chats usually carry no system
        // message, so appending it to one that exists is not enough: inject a leading system
        // turn when absent. Otherwise a tools-off chat full of old "Tool requests:/observation"
        // lines nudges small models into emitting imitation tool calls with no instruction
        // telling them not to.
        var lines = messages
        var protocolPlaced = false
        for index in lines.indices where lines[index].role == "system" && !protocolPlaced {
            lines[index].content = (lines[index].content ?? "") + "\n" + protocolText
            protocolPlaced = true
        }
        if !protocolPlaced { lines.insert(Message(role: "system", content: protocolText), at: 0) }
        var chat: [llama_chat_message] = []
        for message in lines {
            var content = message.content ?? ""
            if let calls = message.toolCalls, !calls.isEmpty {
                content += "\nTool requests: " + String(decoding: try JSONEncoder().encode(calls), as: UTF8.self)
            }
            // Tools are represented as user observations for templates without a tool role.
            if message.role == "tool" { content = "Tool observation (untrusted data): " + content }
            chat.append(llama_chat_message(role: pointer(message.role == "tool" ? "user" : message.role), content: pointer(content)))
        }
        guard let template = llama_model_chat_template(model, nil) else { throw HarnessError("This GGUF has no chat template. Import an instruction/chat model with a supported template.") }
        var buffer = [CChar](repeating: 0, count: 8192)
        var size = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
        if size > buffer.count {
            buffer = .init(repeating: 0, count: Int(size) + 1)
            size = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
        }
        guard size > 0, size <= buffer.count else { throw HarnessError("This model's chat template is not supported by this runtime.") }
        return String(decoding: buffer.prefix(Int(size)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// One resident model per process: the loaded weights stay hot between generations so repeated
/// sends do not re-read the GGUF. Callers guarantee a single active generation (`AppModel`
/// gates on `isRunning`), so the shared pointer is read by at most one decode at a time.
/// Contexts are deliberately not cached here — a KV cache must start empty per conversation.
public actor LlamaModelCache {
    public static let shared = LlamaModelCache()
    private struct Resident: @unchecked Sendable {
        let path: String
        let model: OpaquePointer
    }
    private var resident: Resident?
    private var backendReady = false

    public func model(for url: URL) throws -> OpaquePointer {
        if let resident, resident.path == url.path { return resident.model }
        // Free the previous model before allocating the next one, so switching models never
        // transiently doubles the resident set.
        if let resident { llama_model_free(resident.model) }
        resident = nil
        if !backendReady {
            // llama's backend is process-global; initialize once and never free it, because it
            // may hold references other providers own.
            llama_backend_init()
            backendReady = true
        }
        var parameters = llama_model_default_params()
        #if targetEnvironment(simulator)
        parameters.n_gpu_layers = 0 // CPU-only: the simulator has no VRAM to offload into.
        #endif
        guard let model = llama_model_load_from_file(url.path, parameters) else {
            throw HarnessError("Could not load this GGUF. It may be unsupported, incomplete, or too large for this device.")
        }
        resident = Resident(path: url.path, model: model)
        return model
    }

    /// Drop the resident weights. Call after deleting a model file or erasing all data, and
    /// never while a generation runs (`AppModel` gates both paths on `isRunning`).
    public func releaseAll() {
        if let entry = resident { llama_model_free(entry.model) }
        resident = nil
    }

    private init() {}
}

import Foundation

public struct ToolDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name; self.description = description; self.parameters = parameters
    }
    public static func schema(_ properties: [String: String], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties.mapValues {
            .object(["type": .string("string"), "description": .string($0)])
        }), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
}

public protocol ChatInference: Sendable {
    func complete(messages: [Message], tools: [ToolDefinition]) async throws -> Message
    /// Streaming variant. Implementations that can produce partial output call `onToken`
    /// with each delta on the main actor as it arrives. The default falls back to the
    /// non-streaming call, so buffered providers (such as the local GGUF runtime) opt out.
    func complete(messages: [Message], tools: [ToolDefinition], onToken: @escaping @MainActor (String) -> Void) async throws -> Message
}
public extension ChatInference {
    public func complete(messages: [Message], tools: [ToolDefinition], onToken: @escaping @MainActor (String) -> Void) async throws -> Message {
        try await complete(messages: messages, tools: tools)
    }
}

public struct CompatibleInference: ChatInference {
    public let settings: AppSettings
    public let session: URLSession
    public init(settings: AppSettings, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.settings = settings; self.session = session
    }
    public static func endpoint(_ base: String) throws -> URL {
        guard let url = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw HarnessError("Enter an HTTP(S) API base URL, such as https://host/v1, without credentials or a query.")
        }
        return url.appendingPathComponent("chat/completions")
    }
    public func complete(messages: [Message], tools: [ToolDefinition]) async throws -> Message {
        let (data, response) = try await session.data(for: newRequest(messages: messages, tools: tools, streaming: false))
        return try Self.validated(data, response)
    }
    public func complete(messages: [Message], tools: [ToolDefinition], onToken: @escaping @MainActor (String) -> Void) async throws -> Message {
        let (bytes, response) = try await session.bytes(for: newRequest(messages: messages, tools: tools, streaming: true))
        guard let http = response as? HTTPURLResponse else { throw HarnessError("The server did not return HTTP.") }
        guard (200..<300).contains(http.statusCode) else { throw Self.httpError(http.statusCode) }
        // Servers that ignore the stream flag reply with a normal completion body; accept both shapes.
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true {
            var data = Data()
            for try await chunk in bytes { data.append(chunk) }
            let message = try Self.validated(data, http)
            if let content = message.content { await onToken(content) }
            return message
        }
        struct Call: Decodable { struct Function: Decodable { let name: String?; let arguments: String? }
            let index: Int?; let id: String?; let function: Function? }
        struct Delta: Decodable { let content: String?; let tool_calls: [Call]? }
        struct Chunk: Decodable { struct Choice: Decodable { let delta: Delta?; let finish_reason: String? }; let choices: [Choice] }
        struct Builder { var id = ""; var name = ""; var arguments = "" }
        var content = ""
        var calls: [Int: Builder] = [:]
        var finishReason: String?
        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue } // Server keep-alive comments and blank lines pass through.
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)), let choice = chunk.choices.first else { continue }
            finishReason = choice.finish_reason ?? finishReason
            if let piece = choice.delta?.content, !piece.isEmpty {
                content += piece
                await onToken(piece)
            }
            for fragment in choice.delta?.tool_calls ?? [] {
                let index = fragment.index ?? calls.count
                var entry = calls[index] ?? Builder()
                if let id = fragment.id, !id.isEmpty { entry.id = id }
                if let name = fragment.function?.name, !name.isEmpty { entry.name += name }
                if let arguments = fragment.function?.arguments, !arguments.isEmpty { entry.arguments += arguments }
                calls[index] = entry
            }
        }
        let toolCalls = calls.keys.sorted().compactMap { index -> ToolCall? in
            guard let call = calls[index], !call.name.isEmpty else { return nil }
            return ToolCall(id: call.id.isEmpty ? UUID().uuidString : call.id, name: call.name, arguments: call.arguments)
        }
        guard !content.isEmpty || !toolCalls.isEmpty else { throw HarnessError("The server streamed an empty answer.") }
        guard finishReason != "length" else { throw HarnessError(Self.outputLimitMessage) }
        return Message(role: "assistant", content: content.isEmpty ? nil : content, toolCalls: toolCalls.isEmpty ? nil : toolCalls)
    }
    private func newRequest(messages: [Message], tools: [ToolDefinition], streaming: Bool) throws -> URLRequest {
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HarnessError("Set a model ID in Settings.") }
        var request = URLRequest(url: try Self.endpoint(settings.baseURL))
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if streaming { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        if !settings.apiKey.isEmpty { request.setValue("Bearer " + settings.apiKey, forHTTPHeaderField: "Authorization") }
        let body = Request(model: settings.model, messages: messages.map(WireMessage.init),
            tools: tools.isEmpty ? nil : tools.map { WireTool(function: $0) }, tool_choice: tools.isEmpty ? nil : "auto", stream: streaming)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
    private static func validated(_ data: Data, _ response: URLResponse?) throws -> Message {
        guard let http = response as? HTTPURLResponse else { throw HarnessError("The server did not return HTTP.") }
        guard (200..<300).contains(http.statusCode) else {
            // Do not reflect raw server bodies, which can contain prompts or secrets.
            throw httpError(http.statusCode)
        }
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard let choice = result.choices.first, choice.message.role == "assistant" else { throw HarnessError("The server returned no assistant message.") }
        guard choice.finish_reason != "length" else { throw HarnessError(outputLimitMessage) }
        let message = choice.message
        guard !(message.content ?? "").isEmpty || !(message.tool_calls ?? []).isEmpty else { throw HarnessError("The server returned an empty answer.") }
        return Message(role: "assistant", content: message.content, toolCalls: message.tool_calls)
    }
    static let outputLimitMessage = "The server reached its output limit. Shorten the request or increase the server limit."
    static func httpError(_ status: Int) -> HarnessError {
        HarnessError("Inference server returned HTTP \(status). Check the URL, model ID, API key, and tool-calling support.")
    }
    struct WireTool: Encodable { let type = "function"; let function: ToolDefinition }
    struct Request: Encodable { let model: String; let messages: [WireMessage]; let tools: [WireTool]?; let tool_choice: String?; let stream: Bool }
    struct Response: Decodable {
        struct Choice: Decodable { let message: WireMessage; let finish_reason: String? }
        let choices: [Choice]
    }
    struct WireMessage: Codable {
        let role: String; let content: String?; let tool_calls: [ToolCall]?; let tool_call_id: String?
        init(_ value: Message) { role = value.role; content = value.content; tool_calls = value.toolCalls; tool_call_id = value.toolCallID }
    }
}

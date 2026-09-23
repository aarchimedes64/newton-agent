import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public func encoded() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

public struct ToolCall: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var type = "function"
    public var function: Function
    public struct Function: Codable, Equatable, Sendable {
        public var name: String
        public var arguments: String
    }
    public init(id: String = UUID().uuidString, name: String, arguments: String) {
        self.id = id; function = Function(name: name, arguments: arguments)
    }
}

public struct Message: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var role: String
    public var content: String?
    public var toolCalls: [ToolCall]?
    public var toolCallID: String?
    public init(role: String, content: String? = nil, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role; self.content = content; self.toolCalls = toolCalls; self.toolCallID = toolCallID
    }
}

/// One assistant generation's measured performance, stored alongside the chat transcript.
/// contextSize is the estimated token count sent at the start of the generation (bytes/4);
/// averageTokensPerSecond is streamed tokens over streamed time for the whole run.
public struct GenerationRecord: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var startedAt = Date()
    public var contextSize = 0
    public var averageTokensPerSecond = 0.0
    public init(contextSize: Int, averageTokensPerSecond: Double, startedAt: Date = Date(), id: UUID = UUID()) {
        self.id = id; self.startedAt = startedAt; self.contextSize = contextSize; self.averageTokensPerSecond = averageTokensPerSecond
    }
}

public struct Conversation: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title = "New chat"
    public var updatedAt = Date()
    public var messages: [Message] = []
    // Optional (not defaulted) so transcripts saved before this field existed decode cleanly.
    public var generations: [GenerationRecord]?
    public init() {}
    /// Do not replay a side effect after a crash. Complete the wire protocol with an unknown outcome.
    public mutating func repairInterruptedCalls() {
        var repaired: [Message] = []
        var index = 0
        while index < messages.count {
            let message = messages[index]
            repaired.append(message); index += 1
            guard let calls = message.toolCalls, !calls.isEmpty else { continue }
            var results: [String: Message] = [:]
            while index < messages.count, messages[index].role == "tool" {
                if let id = messages[index].toolCallID { results[id] = messages[index] }
                index += 1
            }
            for call in calls {
                repaired.append(results[call.id] ?? Message(role: "tool",
                    content: "{\"error\":\"Interrupted. Outcome unknown; do not retry a write without checking with the user.\"}", toolCallID: call.id))
            }
        }
        messages = repaired
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Sendable { case compatible, local }
    public var provider: Provider = .compatible
    public var baseURL = "https://api.openai.com/v1"
    public var model = ""
    public var apiKey = ""
    public var localModelID: UUID?
    public var notesShortcut = "Newton — Create Note"
    public var toolsEnabled = true
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case provider, baseURL, model, apiKey, localModelID, notesShortcut, toolsEnabled
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decodeIfPresent(Provider.self, forKey: .provider) ?? .compatible
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        localModelID = try values.decodeIfPresent(UUID.self, forKey: .localModelID)
        notesShortcut = try values.decodeIfPresent(String.self, forKey: .notesShortcut) ?? "Newton — Create Note"
        toolsEnabled = try values.decodeIfPresent(Bool.self, forKey: .toolsEnabled) ?? true
    }
}

public struct StoredNote: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var body: String
    public var updatedAt = Date()
    public init(title: String, body: String) { self.title = title; self.body = body }
}

public struct ModelFile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var byteCount: Int64
    public var sourceURL: URL?
    public init(id: UUID, name: String, byteCount: Int64, sourceURL: URL? = nil) {
        self.id = id; self.name = name; self.byteCount = byteCount; self.sourceURL = sourceURL
    }
}

public struct HarnessError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

import XCTest
@testable import NewtonCore

actor ScriptedInference: ChatInference {
    var replies: [Message]
    var inputs: [[Message]] = []
    var catalogs: [[ToolDefinition]] = []
    init(_ replies: [Message]) { self.replies = replies }
    func complete(messages: [Message], tools: [ToolDefinition]) async throws -> Message {
        inputs.append(messages); catalogs.append(tools)
        guard !replies.isEmpty else { throw HarnessError("No scripted response") }
        return replies.removeFirst()
    }
}

final class HarnessTests: XCTestCase {
    func testToolsSettingDefaultsForExistingInstallsAndPersists() throws {
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).toolsEnabled)
        var settings = AppSettings(); settings.toolsEnabled = false
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).toolsEnabled)
    }
    @MainActor func testDisabledToolsAreOmittedAndCannotExecute() async throws {
        var executed = false
        var approved = false
        let tool = AgentTool(ToolDefinition(name: "write", description: "", parameters: ToolDefinition.schema([:], required: []))) { _ in executed = true; return "saved" }
        let call = ToolCall(name: "write", arguments: "{}")
        let inference = ScriptedInference([Message(role: "assistant", toolCalls: [call])])
        let history = [Message(role: "user", content: "Hello"), Message(role: "assistant", toolCalls: [call]), Message(role: "tool", content: "Old result", toolCallID: call.id)]
        do {
            try await AgentRuntime(tools: [tool], toolsEnabled: false).run(messages: history, inference: inference, approve: { _ in approved = true; return true }, persist: { _ in XCTFail("Invalid tool response should not be saved") })
            XCTFail("Expected disabled-tool rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("tools are disabled")) }
        XCTAssertFalse(executed); XCTAssertFalse(approved)
        let catalogs = await inference.catalogs
        XCTAssertTrue(catalogs[0].isEmpty)
        let inputs = await inference.inputs
        XCTAssertFalse(inputs[0].contains { $0.role == "tool" || $0.toolCalls != nil })
    }
    @MainActor func testApprovedToolResultIsFedBackToModel() async throws {
        let call = ToolCall(id: "call-1", name: "notes_create", arguments: "{\"title\":\"Hello\"}")
        let inference = ScriptedInference([Message(role: "assistant", toolCalls: [call]), Message(role: "assistant", content: "Saved")])
        var executions = 0
        var persisted: [Message] = []
        let tool = AgentTool(ToolDefinition(name: "notes_create", description: "", parameters: ToolDefinition.schema(["title": "Title"], required: ["title"]))) { args in
            executions += 1
            XCTAssertEqual(args["title"], .string("Hello"))
            XCTAssertEqual(persisted.last?.toolCalls?.first?.id, "call-1", "Intent must be durable before action")
            return "saved"
        }
        try await AgentRuntime(tools: [tool]).run(messages: [Message(role: "user", content: "Save a note")], inference: inference, approve: { _ in true }, persist: { persisted = $0 })
        XCTAssertEqual(executions, 1)
        XCTAssertEqual(persisted.map(\.role), ["user", "assistant", "tool", "assistant"])
        let inputs = await inference.inputs
        XCTAssertEqual(inputs[1].last?.toolCallID, "call-1")
    }
    @MainActor func testDenialAndBadArgumentsNeverExecute() async throws {
        for arguments in ["{\"title\":\"Hello\"}", "{\"title\":4}", "{}", "{\"title\":\"x\",\"extra\":\"y\"}"] {
            var executions = 0
            let call = ToolCall(name: "write", arguments: arguments)
            let tool = AgentTool(ToolDefinition(name: "write", description: "", parameters: ToolDefinition.schema(["title": "Title"], required: ["title"]))) { _ in executions += 1; return "written" }
            let inference = ScriptedInference([Message(role: "assistant", toolCalls: [call]), Message(role: "assistant", content: "Done")])
            var transcript: [Message] = []
            try await AgentRuntime(tools: [tool]).run(messages: [], inference: inference, approve: { _ in false }, persist: { transcript = $0 })
            XCTAssertEqual(executions, 0)
            XCTAssertTrue(transcript.first(where: { $0.role == "tool" })?.content?.contains("error") == true)
        }
    }
    @MainActor func testPersistenceFailurePreventsSideEffect() async {
        var executed = false
        let tool = AgentTool(ToolDefinition(name: "write", description: "", parameters: ToolDefinition.schema([:], required: []))) { _ in executed = true; return "ok" }
        let inference = ScriptedInference([Message(role: "assistant", toolCalls: [ToolCall(name: "write", arguments: "{}")])])
        do {
            try await AgentRuntime(tools: [tool]).run(messages: [], inference: inference, approve: { _ in true }, persist: { _ in throw HarnessError("disk full") })
            XCTFail("Expected persistence failure")
        } catch { XCTAssertFalse(executed) }
    }
    @MainActor func testCancellationBeforeRunDoesNotCallInference() async {
        let inference = ScriptedInference([Message(role: "assistant", content: "bad")])
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await AgentRuntime(tools: []).run(messages: [], inference: inference, approve: { _ in true }, persist: { _ in })
        }
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let inputs = await inference.inputs
        XCTAssertTrue(inputs.isEmpty)
    }
    @MainActor func testRoundLimitStopsToolLoop() async {
        let call = ToolCall(name: "missing", arguments: "{}")
        let inference = ScriptedInference([Message(role: "assistant", toolCalls: [call])])
        do {
            try await AgentRuntime(tools: [], maxRounds: 1).run(messages: [], inference: inference, approve: { _ in true }, persist: { _ in })
            XCTFail("Expected round limit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("1 tool rounds")) }
    }
    func testInterruptedToolCallsAreRepairedWithoutReplay() {
        var chat = Conversation()
        chat.messages = [Message(role: "assistant", toolCalls: [ToolCall(id: "a", name: "write", arguments: "{}"), ToolCall(id: "b", name: "write", arguments: "{}")]), Message(role: "tool", content: "saved", toolCallID: "a")]
        chat.repairInterruptedCalls()
        XCTAssertEqual(chat.messages.count, 3)
        XCTAssertEqual(chat.messages[1].content, "saved")
        XCTAssertEqual(chat.messages[2].toolCallID, "b")
        XCTAssertTrue(chat.messages[2].content!.contains("Outcome unknown"))
        let repaired = chat.messages; chat.repairInterruptedCalls(); XCTAssertEqual(chat.messages, repaired)
    }
    @MainActor func testStorageRoundTripCorruptionAndErase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try SandboxStore(root: root)
        var settings = AppSettings(); settings.apiKey = "test-key"
        try storage.write(settings, name: "settings")
        XCTAssertEqual(try storage.read(AppSettings.self, name: "settings", fallback: AppSettings()), settings)
        let model = storage.modelURL(UUID()); try Data("GGUFtest".utf8).write(to: model)
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try Data("broken".utf8).write(to: root.appendingPathComponent("chats.json"))
        XCTAssertThrowsError(try storage.read([Conversation].self, name: "chats", fallback: []))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("chats.json"), encoding: .utf8), "broken")
        try storage.erase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.json").path))
    }
    func testEndpointValidation() throws {
        XCTAssertEqual(try CompatibleInference.endpoint("http://192.168.1.3:8080/v1/").absoluteString, "http://192.168.1.3:8080/v1/chat/completions")
        for bad in ["file:///etc/passwd", "https://user:secret@host/v1", "https://host/v1?key=secret", "host/v1"] {
            XCTAssertThrowsError(try CompatibleInference.endpoint(bad))
        }
    }
    func testWirePayloadUsesOpenAIKeysAndOmitsPersistenceIDs() throws {
        let call = ToolCall(id: "call", name: "test", arguments: "{}")
        let message = CompatibleInference.WireMessage(Message(role: "assistant", toolCalls: [call]))
        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["tool_calls"]); XCTAssertNil(object["id"]); XCTAssertNil(object["toolCalls"])
    }
}

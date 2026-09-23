import XCTest
@testable import NewtonCore

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var contentType = "application/json"
    static var lastBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 2048)
            while case let read = stream.read(&buffer, maxLength: buffer.count), read > 0 {
                data.append(contentsOf: buffer[..<read])
            }
            body = data
        }
        Self.lastBody = body
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": Self.contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// Synchronous collector so the main-actor streaming callback can append without an async hop.
final class TokenCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ piece: String) { lock.withLock { storage.append(piece) } }
    var pieces: [String] { lock.withLock { storage } }
}

final class CompatibleInferenceTests: XCTestCase {
    private func inference() -> CompatibleInference {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        var settings = AppSettings(); settings.baseURL = "https://example.test/v1"; settings.model = "custom-model"; settings.apiKey = "test-secret"
        return CompatibleInference(settings: settings, session: URLSession(configuration: config))
    }
    func testHTTPTransportAndToolCallDecoding() async throws {
        StubURLProtocol.contentType = "application/json"
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
            return (200, Data(#"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"notes_search","arguments":"{}"}}]}}]}"#.utf8))
        }
        let result = try await inference().complete(messages: [Message(role: "user", content: "find notes")], tools: [])
        XCTAssertEqual(result.toolCalls?.first?.function.name, "notes_search")
        XCTAssertEqual(result.toolCalls?.first?.id, "c1")
    }
    func testHTTPErrorsDoNotExposeResponseSecrets() async {
        StubURLProtocol.handler = { _ in (401, Data("server echoed test-secret".utf8)) }
        do { _ = try await inference().complete(messages: [], tools: []); XCTFail("Expected HTTP error") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains("test-secret"))
        }
    }
    func testTruncatedResponseCannotExecuteTools() async {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"partial"}}]}"#.utf8))
        }
        do { _ = try await inference().complete(messages: [], tools: []); XCTFail("Expected output-limit error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("output limit")) }
    }
    func testEmptyResponseIsRejected() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"choices":[]}"#.utf8)) }
        do { _ = try await inference().complete(messages: [], tools: []); XCTFail("Expected empty response error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no assistant")) }
    }
    func testStreamDeltasAndToolCallFragments() async throws {
        StubURLProtocol.contentType = "text/event-stream"
        StubURLProtocol.lastBody = nil
        StubURLProtocol.handler = { request in
            let events = [
                #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"hel"}}]}"#,
                #"data: {"choices":[{"index":0,"delta":{"content":"lo"}}]}"#,
                #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"notes_","arguments":"{\"q\":"}}]}}]}"#,
                #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"search","arguments":"\"notes\"}"}}]}}]}"#,
                #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
                "data: [DONE]",
            ]
            return (200, Data((events.joined(separator: "\n\n") + "\n\n").utf8))
        }
        let collected = TokenCollector()
        let result = try await inference().complete(messages: [Message(role: "user", content: "find notes")], tools: []) { piece in
            collected.add(piece)
        }
        // The request body asks for streaming; the loader may deliver it as httpBody or as a stream.
        XCTAssertTrue(String(decoding: StubURLProtocol.lastBody ?? Data(), as: UTF8.self).contains(#""stream":true"#))
        XCTAssertEqual(collected.pieces, ["hel", "lo"])
        XCTAssertEqual(result.content, "hello")
        XCTAssertEqual(result.toolCalls?.count, 1)
        XCTAssertEqual(result.toolCalls?.first?.id, "c1")
        XCTAssertEqual(result.toolCalls?.first?.function.name, "notes_search")
        XCTAssertEqual(result.toolCalls?.first?.function.arguments, #"{"q":"notes"}"#)
    }
    func testStreamFallsBackWhenServerIgnoresStreamFlag() async throws {
        StubURLProtocol.contentType = "application/json"
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"ok"}}]}"#.utf8))
        }
        let collected = TokenCollector()
        let result = try await inference().complete(messages: [Message(role: "user", content: "hi")], tools: []) { piece in
            collected.add(piece)
        }
        XCTAssertEqual(result.content, "ok")
        XCTAssertEqual(collected.pieces.joined(), "ok")
    }
    func testEmptyStreamIsRejected() async throws {
        StubURLProtocol.contentType = "text/event-stream"
        StubURLProtocol.handler = { _ in (200, Data("data: [DONE]\n\n".utf8)) }
        do {
            _ = try await inference().complete(messages: [Message(role: "user", content: "hi")], tools: []) { _ in }
            XCTFail("Expected empty stream error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("empty")) }
    }
}

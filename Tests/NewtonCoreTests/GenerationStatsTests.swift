import XCTest
@testable import NewtonCore

final class GenerationStatsTests: XCTestCase {
    func testTranscriptsSavedBeforeGenerationRecordsExistedStillDecode() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","title":"Old chat","updatedAt":0,"messages":[]}"#
        let chat = try JSONDecoder().decode(Conversation.self, from: Data(legacy.utf8))
        XCTAssertNil(chat.generations, "Absent key must decode as nil, not fail")
        XCTAssertEqual(chat.title, "Old chat")
    }
    func testGenerationRecordsRoundTrip() throws {
        var chat = Conversation()
        chat.generations = [
            GenerationRecord(contextSize: 1204, averageTokensPerSecond: 23.5),
            GenerationRecord(contextSize: 4310, averageTokensPerSecond: 0),
        ]
        let decoded = try JSONDecoder().decode(Conversation.self, from: try JSONEncoder().encode(chat))
        XCTAssertEqual(decoded.generations?.count, 2)
        XCTAssertEqual(decoded.generations?.first?.contextSize, 1204)
        XCTAssertEqual(decoded.generations?.first?.averageTokensPerSecond ?? 0, 23.5, accuracy: 0.001)
        XCTAssertEqual(decoded.generations?[1].averageTokensPerSecond ?? 0, 0, accuracy: 0.001)
    }
}

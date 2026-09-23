import XCTest
@testable import NewtonCore

final class ModelLibraryTests: XCTestCase {
    func testHuggingFaceRepositoryInput() throws {
        XCTAssertEqual(try HuggingFaceHub.repositoryID(" owner/model-GGUF "), "owner/model-GGUF")
        XCTAssertEqual(try HuggingFaceHub.repositoryID("https://huggingface.co/owner/model-GGUF/"), "owner/model-GGUF")
        for input in ["https://other.example/owner/model", "owner/model/blob/main/file.gguf", "owner/..", "owner//model", "https://token@huggingface.co/owner/model", "http://huggingface.co/owner/model"] {
            XCTAssertThrowsError(try HuggingFaceHub.repositoryID(input))
        }
    }
    func testOnlyUsableGGUFFilesAreListedWithPinnedDownloadURLs() throws {
        let data = Data(#"{"sha":"abc123","siblings":[{"rfilename":"README.md"},{"rfilename":"model.safetensors"},{"rfilename":"model-00001-of-00002.gguf"},{"rfilename":"mmproj-model.gguf"},{"rfilename":"../bad.gguf"},{"rfilename":"quantized/model Q4.gguf","size":123456}]}"#.utf8)
        let files = try HuggingFaceHub.decodeFiles(data, repository: "owner/model")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].byteCount, 123456)
        XCTAssertEqual(files[0].downloadURL.absoluteString, "https://huggingface.co/owner/model/resolve/abc123/quantized/model%20Q4.gguf")
    }
    func testInvalidRevisionIsRejected() {
        XCTAssertThrowsError(try HuggingFaceHub.decodeFiles(Data(#"{"sha":"../main","siblings":[]}"#.utf8), repository: "owner/model"))
    }
    func testOldModelInventoryRemainsReadable() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"name\":\"old.gguf\",\"byteCount\":42}".utf8)
        let file = try JSONDecoder().decode(ModelFile.self, from: data)
        XCTAssertEqual(file.id, id)
        XCTAssertNil(file.sourceURL)
    }
    @MainActor func testRemovalDeletesOnlyTheSelectedModelBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SandboxStore(root: root)
        let removed = UUID(), kept = UUID()
        try Data("GGUFtest".utf8).write(to: store.modelURL(removed))
        try Data("GGUFkeep".utf8).write(to: store.modelURL(kept))
        try store.write(["chat"], name: "chats")
        try store.removeModelFile(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.modelURL(removed).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.modelURL(kept).path))
        XCTAssertEqual(try store.read([String].self, name: "chats", fallback: []), ["chat"])
        try store.removeModelFile(removed) // A missing file does not prevent removing stale metadata.
    }
}

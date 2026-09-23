import Foundation

/// Every owned byte lives below this directory. No Keychain, shared group, or cloud store.
@MainActor public final class SandboxStore {
    public let root: URL
    public var modelsDirectory: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public init(root: URL? = nil) throws {
        self.root = try root ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Newton", isDirectory: true)
        try prepare()
    }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: modelsDirectory.path)
        #endif
    }
    public func read<T: Decodable>(_ type: T.Type, name: String, fallback: T) throws -> T {
        let url = root.appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    public func write<T: Encodable>(_ value: T, name: String) throws {
        let data = try JSONEncoder().encode(value)
        #if os(iOS)
        try data.write(to: root.appendingPathComponent(name + ".json"), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: root.appendingPathComponent(name + ".json"), options: .atomic)
        #endif
    }
    public func modelURL(_ id: UUID) -> URL { modelsDirectory.appendingPathComponent(id.uuidString + ".gguf") }
    public func removeModelFile(_ id: UUID) throws {
        let url = modelURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func erase() throws {
        try FileManager.default.removeItem(at: root)
        try prepare()
    }
}

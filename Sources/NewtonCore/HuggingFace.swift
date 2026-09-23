import Foundation

public struct HuggingFaceFile: Identifiable, Equatable, Sendable {
    public var id: String { downloadURL.absoluteString }
    public let name: String
    public let byteCount: Int64?
    public let downloadURL: URL
}

/// Public, single-file GGUF repositories. Pin downloads to the revision we listed.
public struct HuggingFaceHub: Sendable {
    public init() {}
    public static func repositoryID(_ input: String) throws -> String {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if input.contains("://") {
            guard let url = URL(string: input), url.scheme == "https", url.host == "huggingface.co",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else {
                throw HarnessError("Enter a public Hugging Face repository URL or owner/model name.")
            }
            path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else { path = input }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw HarnessError("Use the repository's main page, such as https://huggingface.co/owner/model-GGUF, or owner/model-GGUF.")
        }
        return parts.joined(separator: "/")
    }
    public func files(in repository: String, session: URLSession = URLSession(configuration: .ephemeral)) async throws -> [HuggingFaceFile] {
        let id = try Self.repositoryID(repository)
        var components = URLComponents(string: "https://huggingface.co/api/models/" + id)!
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse else { throw HarnessError("Hugging Face did not return a valid response.") }
        guard (200..<300).contains(http.statusCode) else {
            if [401, 403, 404].contains(http.statusCode) {
                throw HarnessError("Repository not found or access is restricted. Use a public, ungated GGUF repository; sign-in downloads are not supported yet.")
            }
            throw HarnessError("Hugging Face returned HTTP \(http.statusCode). Try again later.")
        }
        return try Self.decodeFiles(data, repository: id)
    }
    public static func decodeFiles(_ data: Data, repository: String) throws -> [HuggingFaceFile] {
        struct Metadata: Decodable {
            struct File: Decodable { let rfilename: String; let size: Int64? }
            let sha: String
            let siblings: [File]
        }
        let id = try repositoryID(repository)
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard !metadata.sha.isEmpty, metadata.sha.allSatisfy(\.isHexDigit) else { throw HarnessError("Hugging Face returned an invalid revision.") }
        return metadata.siblings.compactMap { file in
            let name = file.rfilename
            let leaf = (name as NSString).lastPathComponent
            guard name.lowercased().hasSuffix(".gguf"), !leaf.lowercased().hasPrefix("mmproj"),
                  name.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: [.regularExpression, .caseInsensitive]) == nil,
                  !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
            var url = URL(string: "https://huggingface.co/" + id + "/resolve/" + metadata.sha)!
            for part in name.split(separator: "/") { url.appendPathComponent(String(part)) }
            return HuggingFaceFile(name: name, byteCount: file.size, downloadURL: url)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

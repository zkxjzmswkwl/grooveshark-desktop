import CryptoKit
import Darwin
import Foundation
import Network

struct SharedLibraryManifest: Codable, Sendable {
    let generatedAt: Date
    let tracks: [SharedLibraryTrack]
}

struct SharedLibraryTrack: Codable, Identifiable, Sendable {
    let id: String
    let relativePath: String
    let title: String
    let artist: String
    let album: String
    let genre: String
    let trackNumber: Int?
}

struct SharedLibraryDownloadResult: Sendable {
    let importedRoot: URL
    let downloadedTracks: Int
}

struct LibraryTransferQueueSnapshot: Sendable {
    let completed: [SharedLibraryTrack]
    let current: [SharedLibraryTrack]
    let upcoming: [SharedLibraryTrack]

    static let empty = LibraryTransferQueueSnapshot(completed: [], current: [], upcoming: [])
}

actor LibrarySharingService {
    private struct SharedFile {
        let track: SharedLibraryTrack
        let sourceURL: URL
    }

    private let queue = DispatchQueue(label: "grooveshark.library-sharing")
    private var listener: NWListener?
    private var port: UInt16?
    private var manifestData = Data()
    private var filesByID: [String: SharedFile] = [:]
    private var manifestTracks: [SharedLibraryTrack] = []
    private var currentlyUploadingIDs: Set<String> = []
    private var completedUploadIDs: Set<String> = []

    func start(port: UInt16, tracks: [Track], roots: [String]) async throws -> String {
        if listener != nil {
            stop()
        }

        let endpointPort = try NWEndpoint.Port(rawValue: port).unwrap(or: LibrarySharingError.invalidPort)
        rebuildSharedLibrary(tracks: tracks, roots: roots)

        let listener = try NWListener(using: .tcp, on: endpointPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleConnection(connection) }
        }
        listener.start(queue: queue)

        self.listener = listener
        self.port = port
        let host = Self.primaryLANAddress() ?? "localhost"
        return "http://\(host):\(port)"
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        currentlyUploadingIDs = []
        completedUploadIDs = []
    }

    func updateSharedLibrary(tracks: [Track], roots: [String]) {
        rebuildSharedLibrary(tracks: tracks, roots: roots)
    }

    func sharingTransferSnapshot() -> LibraryTransferQueueSnapshot {
        let completedSet = completedUploadIDs
        let currentSet = currentlyUploadingIDs
        let completed = manifestTracks.filter { completedSet.contains($0.id) && !currentSet.contains($0.id) }
        let current = manifestTracks.filter { currentSet.contains($0.id) }
        let upcoming = manifestTracks.filter { !completedSet.contains($0.id) && !currentSet.contains($0.id) }
        return LibraryTransferQueueSnapshot(completed: completed, current: current, upcoming: upcoming)
    }

    private func rebuildSharedLibrary(tracks: [Track], roots: [String]) {
        var files: [String: SharedFile] = [:]

        for track in tracks {
            let canonicalPath = FilePathNormalization.canonical(track.url.path)
            guard FileManager.default.fileExists(atPath: canonicalPath) else { continue }

            let relativePath = makeRelativePath(for: canonicalPath, roots: roots)
            let id = Self.makeTrackID(path: canonicalPath)
            let sharedTrack = SharedLibraryTrack(
                id: id,
                relativePath: relativePath,
                title: track.title,
                artist: track.artist,
                album: track.album,
                genre: track.genre,
                trackNumber: track.trackNumber
            )
            files[id] = SharedFile(track: sharedTrack, sourceURL: URL(fileURLWithPath: canonicalPath))
        }

        let manifest = SharedLibraryManifest(
            generatedAt: Date(),
            tracks: files.values.map(\.track).sorted {
                $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        manifestData = (try? encoder.encode(manifest)) ?? Data()
        filesByID = files
        manifestTracks = manifest.tracks
        let validIDs = Set(manifestTracks.map(\.id))
        completedUploadIDs = completedUploadIDs.intersection(validIDs)
        currentlyUploadingIDs = currentlyUploadingIDs.intersection(validIDs)
    }

    private func makeRelativePath(for canonicalPath: String, roots: [String]) -> String {
        let normalizedPath = FilePathNormalization.canonical(canonicalPath)
        for root in roots {
            let canonicalRoot = FilePathNormalization.canonical(root)
            guard FilePathNormalization.isUnderLibraryRoot(normalizedPath, libraryRoot: canonicalRoot) else {
                continue
            }

            let rootWithSlash = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
            if normalizedPath.hasPrefix(rootWithSlash) {
                return String(normalizedPath.dropFirst(rootWithSlash.count))
            }
            return (normalizedPath as NSString).lastPathComponent
        }
        return (normalizedPath as NSString).lastPathComponent
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            guard let data, !data.isEmpty else {
                connection.cancel()
                return
            }

            Task {
                let response = await self.response(for: data)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func response(for requestData: Data) -> Data {
        guard let request = parseRequest(requestData) else {
            return httpResponse(status: 400, reason: "Bad Request", contentType: "text/plain", body: Data("Bad request".utf8))
        }

        guard request.method == "GET" else {
            return httpResponse(status: 405, reason: "Method Not Allowed", contentType: "text/plain", body: Data("Method not allowed".utf8))
        }

        switch request.path {
        case "/", "":
            let body = """
            GrooveShark Library Sharing
            Tracks available: \(filesByID.count)
            Manifest: /library/index.json
            Health: /health
            """
            return httpResponse(status: 200, reason: "OK", contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
        case "/health":
            let body = #"{"status":"ok","tracks":\#(filesByID.count)}"#
            return httpResponse(status: 200, reason: "OK", contentType: "application/json", body: Data(body.utf8))
        case "/library/index.json":
            return httpResponse(status: 200, reason: "OK", contentType: "application/json", body: manifestData)
        case "/library/file":
            guard let id = request.queryItems["id"],
                  let sharedFile = filesByID[id],
                  filesByID[id] != nil
            else {
                return httpResponse(status: 404, reason: "Not Found", contentType: "text/plain", body: Data("File not found".utf8))
            }
            currentlyUploadingIDs.insert(id)
            guard let fileData = try? Data(contentsOf: sharedFile.sourceURL) else {
                currentlyUploadingIDs.remove(id)
                return httpResponse(status: 404, reason: "Not Found", contentType: "text/plain", body: Data("File not found".utf8))
            }
            currentlyUploadingIDs.remove(id)
            completedUploadIDs.insert(id)
            return httpResponse(status: 200, reason: "OK", contentType: "application/octet-stream", body: fileData)
        default:
            return httpResponse(status: 404, reason: "Not Found", contentType: "text/plain", body: Data("Not found".utf8))
        }
    }

    private func parseRequest(_ data: Data) -> ParsedRequest? {
        guard let text = String(data: data, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first
        else { return nil }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://localhost\(target)") else { return nil }

        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        return ParsedRequest(method: method, path: components.path, queryItems: queryItems)
    }

    private func httpResponse(status: Int, reason: String, contentType: String, body: Data) -> Data {
        var response = Data()
        let header =
            "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        response.append(Data(header.utf8))
        response.append(body)
        return response
    }

    private struct ParsedRequest {
        let method: String
        let path: String
        let queryItems: [String: String]
    }

    private static func makeTrackID(path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func primaryLANAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer = first
        while true {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp,
               !isLoopback,
               let addr = interface.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let count = hostname.firstIndex(of: 0) ?? hostname.count
                    let bytes = hostname.prefix(count).map { UInt8(bitPattern: $0) }
                    return String(decoding: bytes, as: UTF8.self)
                }
            }

            guard let next = interface.ifa_next else { break }
            pointer = next
        }

        return nil
    }
}

enum LibrarySharingError: LocalizedError {
    case invalidPort
    case invalidAddress
    case invalidResponse
    case requestFailed(status: Int)
    case emptyLibrary

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "Choose a port between 1024 and 65535."
        case .invalidAddress:
            return "Enter a valid address such as 192.168.1.20:43821."
        case .invalidResponse:
            return "The shared library response was invalid."
        case let .requestFailed(status):
            return "Request failed with status \(status)."
        case .emptyLibrary:
            return "The shared library has no tracks."
        }
    }
}

struct LibrarySharingClient {
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func downloadLibrary(
        from address: String,
        to destinationRoot: URL,
        progress: (@Sendable (LibraryTransferQueueSnapshot) async -> Void)? = nil
    ) async throws -> SharedLibraryDownloadResult {
        let baseURL = try normalizedBaseURL(from: address)
        let manifestURL = baseURL.appending(path: "library/index.json")
        let manifestData = try await request(url: manifestURL)
        let manifest = try decoder.decode(SharedLibraryManifest.self, from: manifestData)
        guard !manifest.tracks.isEmpty else { throw LibrarySharingError.emptyLibrary }

        await progress?(LibraryTransferQueueSnapshot(completed: [], current: [], upcoming: manifest.tracks))

        let importRoot = makeImportRoot(baseURL: baseURL, destinationRoot: destinationRoot)
        try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: true)

        var downloaded = 0
        var completed: [SharedLibraryTrack] = []
        for (index, track) in manifest.tracks.enumerated() {
            await progress?(LibraryTransferQueueSnapshot(
                completed: completed,
                current: [track],
                upcoming: Array(manifest.tracks.dropFirst(index + 1))
            ))

            var components = URLComponents(url: baseURL.appending(path: "library/file"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "id", value: track.id)]
            guard let fileURL = components?.url else { throw LibrarySharingError.invalidAddress }

            let data = try await request(url: fileURL)
            let relativePath = sanitizedRelativePath(track.relativePath, fallbackName: "track-\(track.id.prefix(8)).mp3")
            let targetURL = uniqueDestinationURL(base: importRoot, relativePath: relativePath)
            try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: targetURL, options: .atomic)
            completed.append(track)
            downloaded += 1

            await progress?(LibraryTransferQueueSnapshot(
                completed: completed,
                current: [],
                upcoming: Array(manifest.tracks.dropFirst(index + 1))
            ))
        }

        await progress?(LibraryTransferQueueSnapshot(completed: completed, current: [], upcoming: []))

        return SharedLibraryDownloadResult(importedRoot: importRoot, downloadedTracks: downloaded)
    }

    private func request(url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw LibrarySharingError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw LibrarySharingError.requestFailed(status: http.statusCode)
        }
        return data
    }

    private func normalizedBaseURL(from address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibrarySharingError.invalidAddress }

        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            candidate = "http://\(trimmed)"
        }

        guard var components = URLComponents(string: candidate),
              let host = components.host,
              !host.isEmpty
        else {
            throw LibrarySharingError.invalidAddress
        }
        if components.port == nil {
            components.port = 43821
        }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw LibrarySharingError.invalidAddress }
        return url
    }

    private func makeImportRoot(baseURL: URL, destinationRoot: URL) -> URL {
        let host = baseURL.host ?? "shared-library"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        return destinationRoot.appendingPathComponent("Shared-\(host)-\(stamp)", isDirectory: true)
    }

    private func sanitizedRelativePath(_ value: String, fallbackName: String) -> String {
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .map { part in
                let cleaned = part.trimmingCharacters(in: .whitespacesAndNewlines)
                let invalid = CharacterSet(charactersIn: "\\:*?\"<>|")
                let replaced = cleaned.components(separatedBy: invalid).joined(separator: "_")
                return replaced.replacingOccurrences(of: "..", with: "_")
            }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }

        if components.isEmpty {
            return fallbackName
        }
        return components.joined(separator: "/")
    }

    private func uniqueDestinationURL(base: URL, relativePath: String) -> URL {
        let initial = base.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: initial.path) else {
            return initial
        }

        let ext = initial.pathExtension
        let name = initial.deletingPathExtension().lastPathComponent
        let dir = initial.deletingLastPathComponent()
        var suffix = 2
        while true {
            let candidateName = ext.isEmpty ? "\(name)-\(suffix)" : "\(name)-\(suffix).\(ext)"
            let candidate = dir.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let value = self else { throw error() }
        return value
    }
}

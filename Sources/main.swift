import AppKit
import AVFoundation
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

@main
enum LiquidFLACPlayerLauncher {
    @MainActor
    private static let delegate = DesktopAppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
private final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    private let player = PlayerViewModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = PlayerView()
            .environmentObject(player)
            .frame(minWidth: 980, minHeight: 620)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Liquid FLAC Player"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct Track: Identifiable, Equatable, Hashable {
    var id: String { url.path }
    let url: URL
    let title: String
    let artist: String
    let album: String
    let genre: String
}

enum LibraryGrouping: String, CaseIterable, Identifiable {
    case all = "All"
    case artist = "Artist"
    case genre = "Genre"

    var id: String { rawValue }
}

enum LibrarySortOption: String, CaseIterable, Identifiable {
    case title = "Song"
    case artist = "Artist"
    case album = "Album"
    case genre = "Genre"

    var id: String { rawValue }
}

struct LibraryGroup: Identifiable {
    var id: String { name }
    let name: String
    let tracks: [Track]
}

struct MetadataEditSession: Identifiable {
    let id = UUID()
    let tracks: [Track]
}

struct FileMetadataUpdate: Sendable {
    let title: String?
    let artist: String?
    let album: String?
    let genre: String?
}

struct IndexedTrack: Codable {
    let path: String
    let title: String
    let artist: String
    let album: String
    let genre: String

    init(path: String, title: String, artist: String, album: String, genre: String) {
        self.path = path
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album) ?? "Unknown Album"
        genre = try container.decode(String.self, forKey: .genre)
    }
}

struct RootFingerprint: Codable, Equatable {
    let fileCount: Int
    let latestModificationTime: TimeInterval
}

struct LibraryRootIndex: Codable {
    let path: String
    let fingerprint: RootFingerprint
}

struct LibraryIndex: Codable {
    static let currentVersion = 3

    let version: Int
    var roots: [LibraryRootIndex]
    var tracks: [IndexedTrack]
    var updatedAt: Date
    var manualEdits: [String: IndexedTrack]

    init(
        version: Int,
        roots: [LibraryRootIndex],
        tracks: [IndexedTrack],
        updatedAt: Date,
        manualEdits: [String: IndexedTrack] = [:]
    ) {
        self.version = version
        self.roots = roots
        self.tracks = tracks
        self.updatedAt = updatedAt
        self.manualEdits = manualEdits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        roots = try container.decode([LibraryRootIndex].self, forKey: .roots)
        tracks = try container.decode([IndexedTrack].self, forKey: .tracks)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        manualEdits = try container.decodeIfPresent([String: IndexedTrack].self, forKey: .manualEdits) ?? [:]
    }

    mutating func applyManualEditsForExistingFiles() {
        manualEdits = manualEdits.filter { path, _ in
            FileManager.default.fileExists(atPath: path)
        }

        for (_, editedTrack) in manualEdits {
            tracks.removeAll { $0.path == editedTrack.path }
            tracks.append(editedTrack)
        }

        tracks.sort { lhs, rhs in
            lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
                || (lhs.artist == rhs.artist && lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending)
        }
    }
}

struct ITunesArtworkResponse: Decodable {
    let results: [ITunesArtworkResult]
}

struct ITunesArtworkResult: Decodable {
    let artworkUrl100: String?
}

struct AcoustIDResponse: Decodable {
    let results: [AcoustIDResult]?
}

struct AcoustIDResult: Decodable {
    let score: Double?
    let recordings: [AcoustIDRecording]?
}

struct AcoustIDRecording: Decodable {
    let artists: [AcoustIDArtist]?
    let releases: [AcoustIDRelease]?
}

struct AcoustIDArtist: Decodable {
    let name: String?
}

struct AcoustIDRelease: Decodable {
    let id: String?
    let title: String?
}

struct AudioFingerprint {
    let duration: Int
    let fingerprint: String
}

enum LibraryScanOutcome {
    case skippedUnchanged
    case rebuilt(newRootIndex: LibraryRootIndex, tracks: [IndexedTrack])
}

actor FileMetadataWriter {
    private let fileManager = FileManager.default

    func write(update: FileMetadataUpdate, to tracks: [Track]) async -> [String] {
        var failures: [String] = []

        for track in tracks {
            switch track.url.pathExtension.lowercased() {
            case "flac":
                if let error = writeFLAC(update: update, to: track.url) {
                    failures.append("\(track.url.lastPathComponent): \(error)")
                }
            default:
                failures.append("\(track.url.lastPathComponent): writing \(track.url.pathExtension.uppercased()) tags is not supported yet")
            }
        }

        return failures
    }

    private func writeFLAC(update: FileMetadataUpdate, to url: URL) -> String? {
        guard let metaflac = findExecutable(named: "metaflac") else {
            return "install metaflac with `brew install flac`"
        }

        var arguments: [String] = []
        appendVorbisComment("TITLE", update.title, to: &arguments)
        appendVorbisComment("ARTIST", update.artist, to: &arguments)
        appendVorbisComment("ALBUM", update.album, to: &arguments)
        appendVorbisComment("GENRE", update.genre, to: &arguments)

        guard !arguments.isEmpty else { return nil }
        arguments.append(url.path)

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: metaflac)
        process.arguments = arguments
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return message.isEmpty ? "metaflac exited with code \(process.terminationStatus)" : message
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func appendVorbisComment(_ key: String, _ value: String?, to arguments: inout [String]) {
        guard let value else { return }
        arguments.append("--remove-tag=\(key)")
        arguments.append("--set-tag=\(key)=\(value)")
    }

    private func findExecutable(named name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]

        if let match = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return match
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}

actor ArtworkProvider {
    private let fileManager = FileManager.default

    func artworkData(for track: Track) async -> Data? {
        let cacheURL = cacheURL(for: track)
        if let fingerprintedData = await fingerprintedArtworkData(for: track, cacheURL: cacheURL) {
            return fingerprintedData
        }

        if let cached = try? Data(contentsOf: cacheURL) {
            return cached
        }

        guard let artworkURL = await lookupITunesArtworkURL(for: track) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: artworkURL)
            try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            return data
        } catch {
            return nil
        }
    }

    func refreshArtworkData(for track: Track) async -> Data? {
        let cacheURL = cacheURL(for: track)
        let fingerprintCacheURL = cacheURL.deletingPathExtension().appendingPathExtension("fingerprint.jpg")
        try? fileManager.removeItem(at: cacheURL)
        try? fileManager.removeItem(at: fingerprintCacheURL)
        return await artworkData(for: track)
    }

    private func fingerprintedArtworkData(for track: Track, cacheURL: URL) async -> Data? {
        let fingerprintCacheURL = cacheURL.deletingPathExtension().appendingPathExtension("fingerprint.jpg")
        if let cached = try? Data(contentsOf: fingerprintCacheURL) {
            return cached
        }

        guard let artworkURL = await lookupFingerprintArtworkURL(for: track) else { return nil }

        do {
            var request = URLRequest(url: artworkURL)
            request.setValue("mplayer/0.1 (local macOS player)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return nil
            }
            try fileManager.createDirectory(at: fingerprintCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fingerprintCacheURL, options: .atomic)
            return data
        } catch {
            return nil
        }
    }

    private func lookupFingerprintArtworkURL(for track: Track) async -> URL? {
        guard let apiKey = ProcessInfo.processInfo.environment["ACOUSTID_API_KEY"],
              !apiKey.isEmpty,
              let fingerprint = audioFingerprint(for: track.url) else {
            return nil
        }

        var components = URLComponents(string: "https://api.acoustid.org/v2/lookup")
        components?.queryItems = [
            URLQueryItem(name: "client", value: apiKey),
            URLQueryItem(name: "duration", value: String(fingerprint.duration)),
            URLQueryItem(name: "fingerprint", value: fingerprint.fingerprint),
            URLQueryItem(name: "meta", value: "recordings releases releasegroups")
        ]

        guard let url = components?.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(AcoustIDResponse.self, from: data)
            guard let releaseID = bestReleaseID(from: response, matching: track) else { return nil }
            return URL(string: "https://coverartarchive.org/release/\(releaseID)/front-500")
        } catch {
            return nil
        }
    }

    private func audioFingerprint(for url: URL) -> AudioFingerprint? {
        guard let fpcalcPath = findExecutable(named: "fpcalc") else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: fpcalcPath)
        process.arguments = ["-json", url.path]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let duration = object["duration"] as? Double,
                  let fingerprint = object["fingerprint"] as? String else {
                return nil
            }
            return AudioFingerprint(duration: Int(duration.rounded()), fingerprint: fingerprint)
        } catch {
            return nil
        }
    }

    private func findExecutable(named name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]

        if let match = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return match
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    private func bestReleaseID(from response: AcoustIDResponse, matching track: Track) -> String? {
        var releases: [(release: AcoustIDRelease, artist: String, resultScore: Double)] = []

        for result in response.results ?? [] {
            let resultScore = result.score ?? 0
            guard resultScore >= 0.80 else { continue }

            for recording in result.recordings ?? [] {
                let artist = recording.artists?.first?.name ?? ""
                for release in recording.releases ?? [] {
                    releases.append((release, artist, resultScore))
                }
            }
        }

        let ranked = releases
            .compactMap { candidate -> (id: String, score: Int)? in
                guard let id = candidate.release.id else { return nil }
                let title = candidate.release.title ?? ""
                var score = 0
                if track.album != "Unknown Album", normalized(title) == normalized(track.album) { score += 6 }
                if normalized(candidate.artist) == normalized(track.artist) { score += 2 }
                if track.album != "Unknown Album", normalized(title).contains(normalized(track.album)) { score += 2 }
                if candidate.resultScore >= 0.95 { score += 1 }
                return (id, score)
            }
            .filter { candidate in
                track.album == "Unknown Album" ? candidate.score >= 3 : candidate.score >= 6
            }
            .sorted { $0.score > $1.score }

        return ranked.first?.id
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }

    private func lookupITunesArtworkURL(for track: Track) async -> URL? {
        let term = "\(track.artist) \(track.album == "Unknown Album" ? track.title : track.album)"
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1")
        ]

        guard let url = components?.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ITunesArtworkResponse.self, from: data)
            guard let rawURL = response.results.first?.artworkUrl100 else { return nil }
            return URL(string: rawURL.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
        } catch {
            return nil
        }
    }

    private func cacheURL(for track: Track) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let key = "\(track.artist)-\(track.album)-\(track.title)"
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return appSupport
            .appendingPathComponent("LiquidFLACPlayer/artwork", isDirectory: true)
            .appendingPathComponent(key.isEmpty ? "unknown.jpg" : "\(key).jpg")
    }
}

actor LibraryIndexer {
    private let fileManager = FileManager.default
    private let audioExtensions: Set<String> = [
        "flac", "mp3", "m4a", "aac", "aiff", "aif", "wav", "alac", "ogg", "opus"
    ]

    func loadIndex() -> LibraryIndex? {
        let url = indexURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LibraryIndex.self, from: data)
    }

    func saveIndex(_ index: LibraryIndex) {
        let url = indexURL()
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(index)
            try data.write(to: url, options: .atomic)
        } catch {
            // Silent failure keeps playback functional even if index persistence fails.
        }
    }

    func scan(rootPath: String, previousRoot: LibraryRootIndex?) async -> LibraryScanOutcome {
        let rootURL = URL(fileURLWithPath: rootPath)
        let fingerprint = buildFingerprint(for: rootURL)

        if let previousRoot, previousRoot.fingerprint == fingerprint {
            return .skippedUnchanged
        }

        let files = discoverAudioFiles(in: rootURL)
        var indexedTracks: [IndexedTrack] = []
        indexedTracks.reserveCapacity(files.count)

        for file in files {
            let metadata = await extractMetadata(for: file)
            indexedTracks.append(
                IndexedTrack(
                    path: file.path,
                    title: metadata.title,
                    artist: metadata.artist,
                    album: metadata.album,
                    genre: metadata.genre
                )
            )
        }

        return .rebuilt(
            newRootIndex: LibraryRootIndex(path: rootPath, fingerprint: fingerprint),
            tracks: indexedTracks
        )
    }

    private func indexURL() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("LiquidFLACPlayer", isDirectory: true)
            .appendingPathComponent("library-index.json", isDirectory: false)
    }

    private func discoverAudioFiles(in root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }
            urls.append(fileURL)
        }
        return urls
    }

    private func buildFingerprint(for root: URL) -> RootFingerprint {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return RootFingerprint(fileCount: 0, latestModificationTime: 0)
        }

        var fileCount = 0
        var latestDate = Date(timeIntervalSince1970: 0)

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }
            fileCount += 1
            if let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let modified = values.contentModificationDate,
               modified > latestDate {
                latestDate = modified
            }
        }

        return RootFingerprint(fileCount: fileCount, latestModificationTime: latestDate.timeIntervalSince1970)
    }

    private func extractMetadata(for url: URL) async -> (title: String, artist: String, album: String, genre: String) {
        let asset = AVURLAsset(url: url)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent

        let metadataItems = allMetadataItems(for: asset)
        let fallback = fallbackMetadata(from: fallbackTitle)
        let finderMetadata = spotlightMetadata(for: url)

        let title: String
        if let finderTitle = finderMetadata.title {
            title = finderTitle
        } else if let tagTitle = metadataValue(in: metadataItems, exactKeys: ["title", "tit2", "©nam", "name"], containsKeys: ["title"]) {
            title = tagTitle
        } else {
            title = fallback.title
        }

        let artist: String
        if let finderArtist = finderMetadata.artist {
            artist = finderArtist
        } else if let tagArtist = cleanArtistValue(metadataValue(in: metadataItems, exactKeys: ["artist", "albumartist", "album_artist", "tpe1", "©art"], containsKeys: ["artist", "performer"])) {
            artist = tagArtist
        } else {
            artist = fallback.artist
        }

        let album: String
        if let finderAlbum = finderMetadata.album {
            album = finderAlbum
        } else if let tagAlbum = metadataValue(in: metadataItems, exactKeys: ["album", "albumname", "talb", "©alb"], containsKeys: ["album"]) {
            album = tagAlbum
        } else {
            album = fallback.album
        }

        let genre: String
        if let finderGenre = finderMetadata.genre {
            genre = finderGenre
        } else if let tagGenre = metadataValue(in: metadataItems, exactKeys: ["genre", "tcon", "©gen"], containsKeys: ["genre"]) {
            genre = tagGenre
        } else {
            genre = fallback.genre
        }

        return (title, artist, album, genre)
    }

    private func spotlightMetadata(for url: URL) -> (title: String?, artist: String?, album: String?, genre: String?) {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) else {
            return (nil, nil, nil, nil)
        }

        let title = mdString(item, kMDItemTitle)
        let authors = mdString(item, kMDItemAuthors)
        let performers = mdString(item, kMDItemPerformers)
        let artist = cleanArtistValue(authors) ?? cleanArtistValue(performers)
        let album = mdString(item, kMDItemAlbum)
        let genre = mdString(item, kMDItemMusicalGenre)

        return (
            title: title,
            artist: artist,
            album: album,
            genre: genre
        )
    }

    private func mdString(_ item: MDItem, _ attribute: CFString) -> String? {
        guard let value = MDItemCopyAttribute(item, attribute) else { return nil }

        if let string = value as? String {
            return cleanMetadataString(string)
        }

        if let strings = value as? [String] {
            return cleanMetadataString(strings.joined(separator: ", "))
        }

        return nil
    }

    private func allMetadataItems(for asset: AVURLAsset) -> [AVMetadataItem] {
        var items = asset.commonMetadata

        for format in asset.availableMetadataFormats {
            items.append(contentsOf: asset.metadata(forFormat: format))
        }

        return items
    }

    private func metadataValue(in items: [AVMetadataItem], exactKeys: Set<String>, containsKeys: [String]) -> String? {
        for item in items {
            let keys = metadataKeys(for: item)
            guard keys.contains(where: { key in
                exactKeys.contains(key) || containsKeys.contains(where: { field in keyContains(key, field: field) })
            }) else {
                continue
            }
            guard !keys.contains(where: isTrackNumberKey),
                  let value = cleanMetadataString(item.stringValue) else {
                continue
            }
            return value
        }

        return nil
    }

    private func metadataKeys(for item: AVMetadataItem) -> [String] {
        var keys: [String] = []

        if let commonKey = item.commonKey?.rawValue {
            keys.append(commonKey)
        }

        if let identifier = item.identifier?.rawValue {
            keys.append(identifier)
        }

        if let stringKey = item.key as? String {
            keys.append(stringKey)
        } else if let numberKey = item.key as? NSNumber {
            keys.append(numberKey.stringValue)
        }

        return keys.map(normalizedMetadataKey)
    }

    private func normalizedMetadataKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "org.xiph.vorbis.", with: "")
            .replacingOccurrences(of: "com.apple.quicktime.", with: "")
            .replacingOccurrences(of: "id3.", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "")
    }

    private func keyContains(_ key: String, field: String) -> Bool {
        key.contains(field) && !isTrackNumberKey(key)
    }

    private func isTrackNumberKey(_ key: String) -> Bool {
        key.contains("tracknumber") || key.contains("tracknum") || key == "trck" || key == "track"
    }

    private func cleanMetadataString(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned
    }

    private func cleanArtistValue(_ value: String?) -> String? {
        guard let cleaned = cleanMetadataString(value) else { return nil }
        let numericCharacters = CharacterSet(charactersIn: "0123456789/.-_ ")
        if cleaned.unicodeScalars.allSatisfy({ numericCharacters.contains($0) }) {
            return nil
        }
        return cleaned
    }

    private func fallbackMetadata(from filename: String) -> (title: String, artist: String, album: String, genre: String) {
        if let separator = filename.range(of: " - ") {
            let artist = String(filename[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(filename[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !title.isEmpty {
                return (title, artist, "Unknown Album", "Unknown Genre")
            }
        }
        return (filename, "Unknown Artist", "Unknown Album", "Unknown Genre")
    }
}

@MainActor
final class PlayerViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playlist: [Track] = []
    @Published var currentIndex: Int?
    @Published var isPlaying = false
    @Published var duration: TimeInterval = 1
    @Published var currentTime: TimeInterval = 0
    @Published var volume: Float = 0.9 {
        didSet { audioPlayer?.volume = volume }
    }
    @Published var errorMessage: String?
    @Published var libraryRoots: [String] = []
    @Published var libraryGrouping: LibraryGrouping = .artist
    @Published var sortOption: LibrarySortOption = .artist {
        didSet { sortPlaylistPreservingCurrentTrack() }
    }
    @Published var indexStatus: String = "No library indexed yet"
    @Published var isReindexing = false
    @Published var artworkImage: NSImage?
    @Published var isRefreshingArtwork = false

    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private var reindexTimer: Timer?
    private var index = LibraryIndex(version: LibraryIndex.currentVersion, roots: [], tracks: [], updatedAt: .distantPast)
    private let indexer = LibraryIndexer()
    private let artworkProvider = ArtworkProvider()
    private let fileMetadataWriter = FileMetadataWriter()

    override init() {
        super.init()
        Task { await loadIndexOnLaunch() }
        startReindexScheduler()
    }

    var currentTrack: Track? {
        guard let currentIndex else { return nil }
        guard playlist.indices.contains(currentIndex) else { return nil }
        return playlist[currentIndex]
    }

    var groupedLibrary: [LibraryGroup] {
        switch libraryGrouping {
        case .all:
            return [LibraryGroup(name: "All Tracks", tracks: playlist)]
        case .artist:
            return groupsBy(\.artist)
        case .genre:
            return groupsBy(\.genre)
        }
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.title = "Choose audio files"

        guard panel.runModal() == .OK else { return }

        let tracks = panel.urls.map(trackFromURL)
        guard !tracks.isEmpty else {
            errorMessage = "No audio files were selected."
            return
        }

        if playlist.isEmpty {
            playlist = tracks
            sortPlaylistPreservingCurrentTrack()
            loadTrack(at: 0)
            play()
        } else {
            playlist.append(contentsOf: tracks)
            sortPlaylistPreservingCurrentTrack()
        }
    }

    func addLibraryFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.title = "Choose Library Folders"

        guard panel.runModal() == .OK else { return }

        var added = false
        for url in panel.urls {
            let path = url.path
            if !libraryRoots.contains(path) {
                libraryRoots.append(path)
                added = true
            }
        }

        if added {
            libraryRoots.sort()
            scheduleReindex(reason: "Scanning newly added folders")
        }
    }

    func removeLibraryRoot(_ path: String) {
        libraryRoots.removeAll { $0 == path }
        index.roots.removeAll { $0.path == path }
        index.tracks.removeAll { track in
            path == URL(fileURLWithPath: track.path).deletingLastPathComponent().path || track.path.hasPrefix(path + "/")
        }
        index.manualEdits = index.manualEdits.filter { _, track in
            !(path == URL(fileURLWithPath: track.path).deletingLastPathComponent().path || track.path.hasPrefix(path + "/"))
        }
        applyIndexedTracks(index.tracks)
        persistCurrentIndex()
    }

    func playPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let audioPlayer else {
            if !playlist.isEmpty, currentIndex == nil {
                loadTrack(at: 0)
                play()
            }
            return
        }
        audioPlayer.play()
        isPlaying = true
        startProgressTimer()
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func nextTrack() {
        guard let currentIndex else { return }
        let next = currentIndex + 1
        guard playlist.indices.contains(next) else {
            pause()
            return
        }
        loadTrack(at: next)
        play()
    }

    func previousTrack() {
        guard let currentIndex else { return }
        if currentTime > 2 {
            seek(to: 0)
            return
        }
        let previous = currentIndex - 1
        guard playlist.indices.contains(previous) else { return }
        loadTrack(at: previous)
        play()
    }

    func selectTrack(_ track: Track) {
        guard let idx = playlist.firstIndex(where: { $0.url == track.url }) else { return }
        loadTrack(at: idx)
        play()
    }

    func seek(to value: TimeInterval) {
        guard let audioPlayer else { return }
        audioPlayer.currentTime = max(0, min(value, audioPlayer.duration))
        currentTime = audioPlayer.currentTime
    }

    func forceRefreshArtwork() {
        guard let track = currentTrack else { return }
        artworkImage = nil
        isRefreshingArtwork = true

        Task { [artworkProvider] in
            let data = await artworkProvider.refreshArtworkData(for: track)
            let image = data.flatMap(NSImage.init(data:))

            await MainActor.run {
                if self.currentTrack?.url == track.url {
                    self.artworkImage = image
                }
                self.isRefreshingArtwork = false
            }
        }
    }

    func updateMetadata(for track: Track, title: String, artist: String, album: String, genre: String) {
        updateMetadata(for: [track], title: title, artist: artist, album: album, genre: genre)
    }

    func updateMetadata(for tracks: [Track], title: String?, artist: String?, album: String?, genre: String?) {
        let urls = Set(tracks.map(\.url))
        guard !urls.isEmpty else { return }
        let currentURL = currentTrack?.url
        var updatedCurrentTrack: Track?
        var updatedTracksForDisk: [Track] = []
        let fileUpdate = FileMetadataUpdate(title: title, artist: artist, album: album, genre: genre)

        for index in playlist.indices {
            let original = playlist[index]
            guard urls.contains(original.url) else { continue }

            let updatedTrack = Track(
                url: original.url,
                title: title.map { cleaned($0, fallback: original.title) } ?? original.title,
                artist: artist.map { cleaned($0, fallback: original.artist) } ?? original.artist,
                album: album.map { cleaned($0, fallback: original.album) } ?? original.album,
                genre: genre.map { cleaned($0, fallback: original.genre) } ?? original.genre
            )

            playlist[index] = updatedTrack
            updatedTracksForDisk.append(updatedTrack)
            let indexedTrack = IndexedTrack(
                path: updatedTrack.url.path,
                title: updatedTrack.title,
                artist: updatedTrack.artist,
                album: updatedTrack.album,
                genre: updatedTrack.genre
            )
            self.index.tracks.removeAll { $0.path == updatedTrack.url.path }
            self.index.tracks.append(indexedTrack)
            self.index.manualEdits[updatedTrack.url.path] = indexedTrack

            if updatedTrack.url == currentURL {
                updatedCurrentTrack = updatedTrack
            }
        }

        self.index.tracks.sort { lhs, rhs in
            lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
                || (lhs.artist == rhs.artist && lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending)
        }

        sortPlaylistPreservingCurrentTrack()
        if let currentURL,
           let newIndex = playlist.firstIndex(where: { $0.url == currentURL }) {
            currentIndex = newIndex
        }
        persistCurrentIndex()
        writeMetadataToFiles(update: fileUpdate, tracks: updatedTracksForDisk)
        if let updatedCurrentTrack {
            refreshArtwork(for: updatedCurrentTrack)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.nextTrack()
        }
    }

    private func loadTrack(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        let track = playlist[index]
        do {
            let player = try AVAudioPlayer(contentsOf: track.url)
            player.delegate = self
            player.prepareToPlay()
            player.volume = volume
            audioPlayer = player
            currentIndex = index
            duration = max(player.duration, 1)
            currentTime = 0
            errorMessage = nil
            refreshArtwork(for: track)
        } catch {
            errorMessage = "Unable to play \(track.url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func groupsBy(_ keyPath: KeyPath<Track, String>) -> [LibraryGroup] {
        let grouped = Dictionary(grouping: playlist) { track -> String in
            let value = track[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "Unknown" : value
        }

        return grouped
            .map { name, tracks in
                LibraryGroup(name: name, tracks: tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func sortPlaylistPreservingCurrentTrack() {
        let currentURL = currentTrack?.url
        playlist.sort { lhs, rhs in
            switch sortOption {
            case .title:
                return compare(lhs.title, rhs.title, fallback: lhs.artist, rhs.artist)
            case .artist:
                return compare(lhs.artist, rhs.artist, fallback: lhs.title, rhs.title)
            case .album:
                return compare(lhs.album, rhs.album, fallback: lhs.title, rhs.title)
            case .genre:
                return compare(lhs.genre, rhs.genre, fallback: lhs.artist, rhs.artist)
            }
        }
        if let currentURL,
           let index = playlist.firstIndex(where: { $0.url == currentURL }) {
            currentIndex = index
        }
    }

    private func compare(_ lhs: String, _ rhs: String, fallback lhsFallback: String, _ rhsFallback: String) -> Bool {
        let primary = lhs.localizedCaseInsensitiveCompare(rhs)
        if primary == .orderedSame {
            return lhsFallback.localizedCaseInsensitiveCompare(rhsFallback) == .orderedAscending
        }
        return primary == .orderedAscending
    }

    private func cleaned(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func writeMetadataToFiles(update: FileMetadataUpdate, tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        indexStatus = "Saving metadata to \(tracks.count) file(s)..."

        Task { [fileMetadataWriter] in
            let failures = await fileMetadataWriter.write(update: update, to: tracks)

            await MainActor.run {
                if failures.isEmpty {
                    self.indexStatus = "Saved metadata to \(tracks.count) file(s)"
                } else {
                    self.indexStatus = "Saved app metadata; \(failures.count) file write(s) failed"
                    self.errorMessage = failures.prefix(3).joined(separator: "\n")
                }
            }
        }
    }

    private func refreshArtwork(for track: Track) {
        artworkImage = nil
        isRefreshingArtwork = true
        Task { [artworkProvider] in
            let data = await artworkProvider.artworkData(for: track)
            let image = data.flatMap(NSImage.init(data:))
            await MainActor.run {
                if self.currentTrack?.url == track.url {
                    self.artworkImage = image
                }
                self.isRefreshingArtwork = false
            }
        }
    }

    private func trackFromURL(_ url: URL) -> Track {
        let filename = url.deletingPathExtension().lastPathComponent
        if let separator = filename.range(of: " - ") {
            let artist = String(filename[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(filename[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty && !title.isEmpty {
                return Track(url: url, title: title, artist: artist, album: "Unknown Album", genre: "Unknown Genre")
            }
        }

        return Track(url: url, title: filename, artist: "Unknown Artist", album: "Unknown Album", genre: "Unknown Genre")
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(refreshProgress), userInfo: nil, repeats: true)
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    @objc private func refreshProgress() {
        guard let audioPlayer else { return }
        currentTime = audioPlayer.currentTime
        duration = max(audioPlayer.duration, 1)
    }

    private func startReindexScheduler() {
        reindexTimer?.invalidate()
        reindexTimer = Timer.scheduledTimer(timeInterval: 120, target: self, selector: #selector(triggerPeriodicReindex), userInfo: nil, repeats: true)
    }

    @objc private func triggerPeriodicReindex() {
        scheduleReindex(reason: "Background refresh")
    }

    private func loadIndexOnLaunch() async {
        if let existing = await indexer.loadIndex() {
            libraryRoots = existing.roots.map(\.path)

            if existing.version == LibraryIndex.currentVersion {
                index = existing
                applyIndexedTracks(existing.tracks)
                indexStatus = "Loaded \(existing.tracks.count) tracks from index"
            } else {
                index = LibraryIndex(version: LibraryIndex.currentVersion, roots: [], tracks: [], updatedAt: .distantPast)
                playlist = []
                currentIndex = nil
                indexStatus = "Metadata index upgraded; rebuilding library"
            }
        }

        scheduleReindex(reason: "Checking for library changes")
    }

    private func scheduleReindex(reason: String) {
        guard !isReindexing else { return }
        guard !libraryRoots.isEmpty else {
            indexStatus = "Add library folders to build your index"
            return
        }

        isReindexing = true
        indexStatus = reason

        let roots = libraryRoots
        let currentIndex = index

        Task.detached(priority: .utility) { [indexer] in
            var resultIndex = currentIndex
            var changed = 0

            for root in roots {
                let previous = resultIndex.roots.first { $0.path == root }
                let outcome = await indexer.scan(rootPath: root, previousRoot: previous)

                switch outcome {
                case .skippedUnchanged:
                    continue
                case let .rebuilt(newRootIndex, tracks):
                    changed += 1
                    resultIndex.roots.removeAll { $0.path == root }
                    resultIndex.roots.append(newRootIndex)
                    resultIndex.tracks.removeAll { $0.path.hasPrefix(root + "/") }
                    resultIndex.tracks.append(contentsOf: tracks)
                }
            }

            resultIndex.tracks.sort { lhs, rhs in
                lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
                    || (lhs.artist == rhs.artist && lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending)
            }
            resultIndex.applyManualEditsForExistingFiles()
            resultIndex.updatedAt = Date()
            await indexer.saveIndex(resultIndex)

            await MainActor.run {
                self.finishReindex(newIndex: resultIndex, changedRoots: changed)
            }
        }
    }

    private func finishReindex(newIndex: LibraryIndex, changedRoots: Int) {
        index = newIndex
        applyIndexedTracks(newIndex.tracks)
        isReindexing = false

        if changedRoots == 0 {
            indexStatus = "Library up to date (\(playlist.count) tracks)"
        } else {
            indexStatus = "Reindexed \(changedRoots) folder(s), \(playlist.count) tracks available"
        }
    }

    private func applyIndexedTracks(_ entries: [IndexedTrack]) {
        let currentURL = currentTrack?.url
        playlist = entries.map {
            Track(
                url: URL(fileURLWithPath: $0.path),
                title: $0.title,
                artist: $0.artist,
                album: $0.album,
                genre: $0.genre
            )
        }
        sortPlaylistPreservingCurrentTrack()

        if let currentURL,
           let newIndex = playlist.firstIndex(where: { $0.url == currentURL }) {
            currentIndex = newIndex
        } else if playlist.isEmpty {
            currentIndex = nil
            pause()
        } else if currentIndex == nil {
            currentIndex = 0
        }
    }

    private func persistCurrentIndex() {
        index.roots = libraryRoots.map { root in
            index.roots.first(where: { $0.path == root }) ?? LibraryRootIndex(path: root, fingerprint: RootFingerprint(fileCount: 0, latestModificationTime: 0))
        }
        index.updatedAt = Date()

        let indexToSave = index
        Task.detached(priority: .utility) { [indexer] in
            await indexer.saveIndex(indexToSave)
        }
    }
}

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @State private var editingSession: MetadataEditSession?
    @State private var selectedTrackIDs: Set<Track.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            groovesharkNav
            actionToolbar
            contentArea
            bottomPlayer
        }
        .background(Color.grooveWindow)
        .sheet(item: $editingSession) { session in
            MetadataEditorView(tracks: session.tracks) { updatedTitle, updatedArtist, updatedAlbum, updatedGenre in
                player.updateMetadata(
                    for: session.tracks,
                    title: updatedTitle,
                    artist: updatedArtist,
                    album: updatedAlbum,
                    genre: updatedGenre
                )
                selectedTrackIDs.removeAll()
                editingSession = nil
            } onCancel: {
                editingSession = nil
            }
        }
    }

    private var groovesharkNav: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 18))
                Text("Grooveshark")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 13)

            navItem("Search")
            navItem("Music")
            navItem("Explore")
            navItem("Community")

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "person.crop.square.fill")
                    .foregroundStyle(.orange)
                Text(NSUserName())
                    .foregroundStyle(.white.opacity(0.82))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.gray)
                Text("Search...")
                    .foregroundStyle(.gray)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(width: 140, height: 22)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 11))
            .padding(.trailing, 9)
        }
        .frame(height: 38)
        .background(
            LinearGradient(colors: [Color(red: 0.18, green: 0.18, blue: 0.18), Color.black], startPoint: .top, endPoint: .bottom)
        )
    }

    private func navItem(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 12)
            .frame(height: 38)
    }

    private var actionToolbar: some View {
        HStack(spacing: 7) {
            toolbarButton("Play Radio", systemImage: "play.fill")
            smallToolbarButton(systemImage: "gearshape")
            toolbarButton("Play All", systemImage: "play.fill") {
                if let first = player.playlist.first {
                    player.selectTrack(first)
                }
            }
            toolbarButton("Add All", systemImage: "plus") {
                player.addLibraryFolders()
            }

            Spacer()

            Picker("Grouping", selection: $player.libraryGrouping) {
                ForEach(LibraryGrouping.allCases) { grouping in
                    Text(grouping.rawValue).tag(grouping)
                }
            }
            .labelsHidden()
            .frame(width: 155)

            Picker("Sort", selection: $player.sortOption) {
                ForEach(LibrarySortOption.allCases) { option in
                    Text("Sort by \(option.rawValue)").tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 170)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            LinearGradient(colors: [Color.white, Color(red: 0.83, green: 0.84, blue: 0.86)], startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.25)).frame(height: 1) }
    }

    private func toolbarButton(_ title: String, systemImage: String, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black.opacity(0.78))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(LinearGradient(colors: [Color.white, Color(red: 0.80, green: 0.81, blue: 0.83)], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func smallToolbarButton(systemImage: String) -> some View {
        Button {} label: {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.black.opacity(0.72))
                .frame(width: 28, height: 22)
                .background(LinearGradient(colors: [Color.white, Color(red: 0.80, green: 0.81, blue: 0.83)], startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var contentArea: some View {
        HStack(spacing: 0) {
            sidebar
            songTable
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            albumArt
                .padding(.horizontal, 10)
                .padding(.top, 10)

            Text(player.currentTrack?.artist ?? selectedSidebarArtist)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            Button {
                player.addLibraryFolders()
            } label: {
                Label("Follow", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.78))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 7)

            Button {
                player.forceRefreshArtwork()
            } label: {
                Label(player.isRefreshingArtwork ? "Refreshing Art" : "Refresh Art", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.78))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(player.currentTrack == nil || player.isRefreshingArtwork)
            .padding(.horizontal, 12)
            .padding(.top, 6)

            Button {
                openMetadataEditor()
            } label: {
                Label(editMetadataTitle, systemImage: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.78))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(metadataEditTracks.isEmpty)
            .padding(.horizontal, 12)
            .padding(.top, 6)

            VStack(spacing: 0) {
                sidebarItem("Activity", systemImage: "figure.walk")
                sidebarItem("Songs", systemImage: "music.note", selected: true)
                sidebarItem("Albums", systemImage: "square.stack")
                sidebarItem("Events", systemImage: "calendar")
                sidebarItem("Fans", systemImage: "person.2.fill")
            }
            .padding(.top, 13)

            VStack(alignment: .leading, spacing: 3) {
                Text("Library Folders")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black.opacity(0.70))
                    .padding(.bottom, 3)
                if player.libraryRoots.isEmpty {
                    Text("Add folders like Music or Downloads/Music.")
                        .foregroundStyle(Color.gray)
                } else {
                    ForEach(player.libraryRoots, id: \.self) { root in
                        Button {
                            player.removeLibraryRoot(root)
                        } label: {
                            Text(URL(fileURLWithPath: root).lastPathComponent)
                                .lineLimit(1)
                                .foregroundStyle(Color.grooveOrange)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(12)

            Spacer()
        }
        .frame(width: 188)
        .background(Color(red: 0.89, green: 0.90, blue: 0.89))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.black.opacity(0.22)).frame(width: 1) }
    }

    private var selectedSidebarArtist: String {
        player.playlist.first?.artist ?? "Grooveshark"
    }

    private var metadataEditTracks: [Track] {
        let selected = player.playlist.filter { selectedTrackIDs.contains($0.id) }
        if !selected.isEmpty {
            return selected
        }
        return player.currentTrack.map { [$0] } ?? []
    }

    private var editMetadataTitle: String {
        let count = metadataEditTracks.count
        return count > 1 ? "Edit \(count) Songs" : "Edit Metadata"
    }

    private func openMetadataEditor() {
        let tracks = metadataEditTracks
        guard !tracks.isEmpty else { return }
        editingSession = MetadataEditSession(tracks: tracks)
    }

    private var albumArt: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = player.artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color(red: 0.16, green: 0.19, blue: 0.20), Color(red: 0.66, green: 0.68, blue: 0.58)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note.list")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
            }
            Text(player.currentTrack?.album ?? "Local Library")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .lineLimit(2)
                .padding(8)
        }
        .frame(height: 142)
        .clipShape(Rectangle())
        .overlay(Rectangle().stroke(Color.black.opacity(0.35), lineWidth: 1))
    }

    private func sidebarItem(_ title: String, systemImage: String, selected: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)
            Text(title)
            Spacer()
        }
        .font(.system(size: 13, weight: selected ? .bold : .regular))
        .foregroundStyle(selected ? .white : Color.black.opacity(0.66))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(selected ? Color.grooveOrange : Color.clear)
    }

    private var songTable: some View {
        VStack(spacing: 0) {
            tableHeader

            if player.playlist.isEmpty {
                VStack(spacing: 10) {
                    Text("No songs yet")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.65))
                    Text("Use Add All to select library folders. The indexer will find audio files and fill this Grooveshark-style table.")
                        .font(.system(size: 13))
                        .foregroundStyle(.gray)
                        .multilineTextAlignment(.center)
                    Button("Add Library Folder") {
                        player.addLibraryFolders()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(player.playlist.enumerated()), id: \.element.id) { index, track in
                            songRow(track: track, index: index, isSelected: selectedTrackIDs.contains(track.id))
                        }
                    }
                }
                .background(Color.white)
            }

            HStack {
                Text(player.indexStatus)
                    .foregroundStyle(player.isReindexing ? Color.grooveOrange : Color.gray)
                Spacer()
                Text("\(player.playlist.count) Songs in Queue")
                    .fontWeight(.bold)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(red: 0.92, green: 0.92, blue: 0.92))
        }
        .background(Color.white)
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            sortHeader("Song", option: .title)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("Artist", option: .artist)
                .frame(width: 220, alignment: .leading)
            sortHeader("Album", option: .album)
                .frame(width: 260, alignment: .leading)
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(.black.opacity(0.68))
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 25)
        .background(Color(red: 0.95, green: 0.95, blue: 0.95))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.13)).frame(height: 1) }
    }

    private func sortHeader(_ title: String, option: LibrarySortOption) -> some View {
        Button {
            player.sortOption = option
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if player.sortOption == option {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func songRow(track: Track, index: Int, isSelected: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                if player.currentTrack?.url == track.url {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.grooveOrange)
                }
                Text(track.title)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.artist)
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)

            Text(track.album)
                .lineLimit(1)
                .frame(width: 260, alignment: .leading)
        }
        .font(.system(size: 12))
        .foregroundStyle(.black.opacity(0.72))
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 26)
        .background(rowBackground(index: index, isSelected: isSelected))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.035)).frame(height: 1) }
        .contentShape(Rectangle())
        .overlay {
            RowClickOverlay(
                onSingleClick: { commandPressed in
                    if commandPressed {
                        toggleSelection(track)
                    } else {
                        selectedTrackIDs = [track.id]
                    }
                },
                onDoubleClick: {
                    player.selectTrack(track)
                }
            )
        }
    }

    private func rowBackground(index: Int, isSelected: Bool) -> Color {
        if isSelected {
            return Color.grooveOrange.opacity(0.28)
        }
        return index.isMultiple(of: 2) ? Color.white : Color(red: 0.965, green: 0.965, blue: 0.965)
    }

    private func toggleSelection(_ track: Track) {
        if selectedTrackIDs.contains(track.id) {
            selectedTrackIDs.remove(track.id)
        } else {
            selectedTrackIDs.insert(track.id)
        }
    }

    private var bottomPlayer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                Text(player.currentTrack.map { "\($0.title) by \($0.artist)" } ?? "Nothing playing")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.white.opacity(0.7))
                Text("\(player.playlist.count) Songs in Queue")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                Image(systemName: "square.and.arrow.down")
                Image(systemName: "trash")
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 12)
            .frame(height: 25)
            .background(LinearGradient(colors: [Color(red: 0.16, green: 0.16, blue: 0.16), Color.black], startPoint: .top, endPoint: .bottom))

            HStack(spacing: 12) {
                Button(action: player.playPause) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                }
                Button(action: player.previousTrack) {
                    Image(systemName: "backward.end.fill")
                }
                Button(action: player.nextTrack) {
                    Image(systemName: "forward.end.fill")
                }

                Text(formatTime(player.currentTime))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.82))

                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...player.duration
                )
                .tint(Color.grooveOrange)

                Text(formatTime(player.duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.82))

                Image(systemName: "shuffle")
                Image(systemName: "repeat")
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.fill")
                    Slider(
                        value: Binding(
                            get: { Double(player.volume) },
                            set: { player.volume = Float($0) }
                        ),
                        in: 0...1
                    )
                    .tint(Color.grooveOrange)
                    .frame(width: 82)
                }
                Text("RADIO")
                    .font(.system(size: 10, weight: .bold))
                Text("OFF")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 50)
            .background(LinearGradient(colors: [Color(red: 0.08, green: 0.08, blue: 0.08), Color.black], startPoint: .top, endPoint: .bottom))
        }
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    private func formatTime(_ value: TimeInterval) -> String {
        if value.isNaN || value.isInfinite { return "00:00" }
        let totalSeconds = Int(value)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct RowClickOverlay: NSViewRepresentable {
    let onSingleClick: (Bool) -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }

    final class ClickView: NSView {
        var onSingleClick: ((Bool) -> Void)?
        var onDoubleClick: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                onDoubleClick?()
                return
            }
            onSingleClick?(event.modifierFlags.contains(.command))
        }
    }
}

struct MetadataEditorView: View {
    let tracks: [Track]
    let onSave: (String?, String?, String?, String?) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var genre: String

    private let titleEditable: Bool
    private let artistEditable: Bool
    private let albumEditable: Bool
    private let genreEditable: Bool

    init(
        tracks: [Track],
        onSave: @escaping (String?, String?, String?, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.tracks = tracks
        self.onSave = onSave
        self.onCancel = onCancel
        titleEditable = Self.hasSharedValue(tracks, \.title)
        artistEditable = Self.hasSharedValue(tracks, \.artist)
        albumEditable = Self.hasSharedValue(tracks, \.album)
        genreEditable = Self.hasSharedValue(tracks, \.genre)
        _title = State(initialValue: titleEditable ? tracks.first?.title ?? "" : "Mixed Values")
        _artist = State(initialValue: artistEditable ? tracks.first?.artist ?? "" : "Mixed Values")
        _album = State(initialValue: albumEditable ? tracks.first?.album ?? "" : "Mixed Values")
        _genre = State(initialValue: genreEditable ? tracks.first?.genre ?? "" : "Mixed Values")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tracks.count > 1 ? "Edit Metadata (\(tracks.count) Songs)" : "Edit Metadata")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(tracks.count == 1 ? tracks[0].url.lastPathComponent : "Batch edit")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.18, green: 0.18, blue: 0.18), Color.black],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            VStack(alignment: .leading, spacing: 12) {
                metadataField("Song", text: $title, isEditable: titleEditable)
                metadataField("Artist", text: $artist, isEditable: artistEditable)
                metadataField("Album", text: $album, isEditable: albumEditable)
                metadataField("Genre", text: $genre, isEditable: genreEditable)

                Text(helpText)
                    .font(.system(size: 11))
                    .foregroundStyle(.black.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .background(Color(red: 0.91, green: 0.91, blue: 0.89))

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black.opacity(0.72))
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))

                Spacer()

                Button("Save Changes") {
                    onSave(
                        titleEditable ? title : nil,
                        artistEditable ? artist : nil,
                        albumEditable ? album : nil,
                        genreEditable ? genre : nil
                    )
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 24)
                .background(Color.grooveOrange)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))
            }
            .padding(14)
            .background(
                LinearGradient(
                    colors: [Color.white, Color(red: 0.83, green: 0.84, blue: 0.86)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .frame(width: 440)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var helpText: String {
        if tracks.count == 1 {
            return "Changes are saved to this app's library index and used for display, sorting, grouping, and artwork lookup."
        }
        return "Only fields with the same value across all selected songs are editable. Enabled fields will be applied to all selected songs."
    }

    private func metadataField(_ label: String, text: Binding<String>, isEditable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isEditable ? .black.opacity(0.68) : .black.opacity(0.35))
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(isEditable ? .black : .black.opacity(0.42))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(isEditable ? Color.white : Color(red: 0.82, green: 0.82, blue: 0.80))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.24), lineWidth: 1))
                .disabled(!isEditable)
        }
    }

    private static func hasSharedValue(_ tracks: [Track], _ keyPath: KeyPath<Track, String>) -> Bool {
        guard let first = tracks.first?[keyPath: keyPath] else { return false }
        return tracks.allSatisfy { $0[keyPath: keyPath] == first }
    }
}

private extension Color {
    static let grooveOrange = Color(red: 0.94, green: 0.39, blue: 0.00)
    static let grooveWindow = Color(red: 0.80, green: 0.82, blue: 0.84)
}

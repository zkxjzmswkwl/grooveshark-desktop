import Foundation

struct Track: Identifiable, Equatable, Hashable {
    var id: String { url.path }
    let url: URL
    let title: String
    let artist: String
    let album: String
    let genre: String
    let trackNumber: Int?
    let fidelityLabel: String
}

enum LibraryGrouping: String, CaseIterable, Identifiable, Codable {
    case all = "All"
    case artist = "Artist"
    case genre = "Genre"

    var id: String { rawValue }
}

enum LibrarySortOption: String, CaseIterable, Identifiable, Codable {
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

struct SavedPlaylist: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var trackPaths: [String]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, trackPaths: [String], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.trackPaths = trackPaths
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct PlaylistLibrary: Codable {
    static let currentVersion = 1

    var version: Int
    var playlists: [SavedPlaylist]

    static let `default` = PlaylistLibrary(version: currentVersion, playlists: [])

    init(version: Int = PlaylistLibrary.currentVersion, playlists: [SavedPlaylist]) {
        self.version = version
        self.playlists = playlists
    }

    mutating func migrateIfNeeded() {
        version = Self.currentVersion
    }
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
    let trackNumber: Int?
    let fidelityLabel: String

    init(
        path: String,
        title: String,
        artist: String,
        album: String,
        genre: String,
        trackNumber: Int? = nil,
        fidelityLabel: String? = nil
    ) {
        self.path = path
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.trackNumber = trackNumber
        self.fidelityLabel = fidelityLabel ?? AudioFidelityFormatter.fallbackLabel(forPath: path)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album) ?? "Unknown Album"
        genre = try container.decode(String.self, forKey: .genre)
        trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        fidelityLabel = try container.decodeIfPresent(String.self, forKey: .fidelityLabel)
            ?? AudioFidelityFormatter.fallbackLabel(forPath: path)
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
    static let currentVersion = 5

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
            FileManager.default.fileExists(atPath: FilePathNormalization.canonical(path))
        }

        for (_, editedTrack) in manualEdits {
            tracks.removeAll { FilePathNormalization.pathsMatch($0.path, editedTrack.path) }
            tracks.append(editedTrack)
        }

        tracks.sort { lhs, rhs in
            lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
                || (lhs.artist == rhs.artist && lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending)
        }
    }

    /// Normalize stored paths so manual edits keys always match scanned `IndexedTrack.path` values after reindex.
    mutating func canonicalizeAllFilePaths() {
        tracks = tracks.map { entry in
            IndexedTrack(
                path: FilePathNormalization.canonical(entry.path),
                title: entry.title,
                artist: entry.artist,
                album: entry.album,
                genre: entry.genre,
                trackNumber: entry.trackNumber,
                fidelityLabel: entry.fidelityLabel
            )
        }
        var rebuilt: [String: IndexedTrack] = [:]
        for (_, edited) in manualEdits {
            let p = FilePathNormalization.canonical(edited.path)
            rebuilt[p] = IndexedTrack(
                path: p,
                title: edited.title,
                artist: edited.artist,
                album: edited.album,
                genre: edited.genre,
                trackNumber: edited.trackNumber,
                fidelityLabel: edited.fidelityLabel
            )
        }
        roots = roots.map { LibraryRootIndex(path: FilePathNormalization.canonical($0.path), fingerprint: $0.fingerprint) }
    }
}

enum AudioFidelityFormatter {
    private static let losslessExtensions: Set<String> = ["flac", "alac", "wav", "aiff", "aif", "ape"]
    private static let lossyExtensions: Set<String> = ["mp3", "m4a", "aac", "ogg", "opus", "wma"]

    static func label(kbps: Int?, pathExtension: String) -> String {
        if let kbps, kbps > 0 {
            return "\(kbps) kbps"
        }
        return fallbackLabel(forExtension: pathExtension)
    }

    static func fallbackLabel(forPath path: String) -> String {
        fallbackLabel(forExtension: URL(fileURLWithPath: path).pathExtension)
    }

    static func fallbackLabel(forExtension ext: String) -> String {
        let lowered = ext.lowercased()
        if losslessExtensions.contains(lowered) { return "Lossless" }
        if lossyExtensions.contains(lowered) { return "Lossy" }
        return lowered.isEmpty ? "Unknown" : lowered.uppercased()
    }
}

struct ITunesArtworkResponse: Decodable {
    let results: [ITunesArtworkResult]
}

struct ITunesArtworkResult: Decodable {
    let artworkUrl100: String?
    let artistName: String?
    let collectionName: String?
    let trackName: String?
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

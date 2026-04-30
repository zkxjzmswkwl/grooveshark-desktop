import Foundation

struct Track: Identifiable, Equatable, Hashable {
    var id: String { url.path }
    let url: URL
    let title: String
    let artist: String
    let album: String
    let genre: String
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
                genre: entry.genre
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
                genre: edited.genre
            )
        }
        roots = roots.map { LibraryRootIndex(path: FilePathNormalization.canonical($0.path), fingerprint: $0.fingerprint) }
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

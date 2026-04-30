import CryptoKit
import Foundation

enum AlbumArtworkIdentity {
    /// One cache entry per album: primary artist (no `feat.` / `ft.` tail) + album, both reduced to comparable tokens.
    static func normalizedKey(artist: String, album: String) -> String {
        let left = collapsedAlphanumeric(primaryArtistForAlbum(artist))
        let right = collapsedAlphanumeric(album)
        let a = left.isEmpty ? "unknown" : left
        let b = right.isEmpty ? "unknown" : right
        return "\(a)|\(b)"
    }

    /// First billed artist so "Band feat. Guest" and "Band" share album art.
    private static func primaryArtistForAlbum(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let delimiters = [
            " feat.", " feat ", " ft.", " ft ", " featuring ", " with ",
        ]
        for d in delimiters {
            if let range = s.range(of: d, options: .caseInsensitive) {
                s = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if s.isEmpty { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        return s
    }

    private static func collapsedAlphanumeric(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }

    static func hashedFilenameStem(forNormalizedKey key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func paths(
        artist: String,
        album: String,
        artworkDirectory: URL
    ) -> (normalizedKey: String, mainURL: URL, fingerprintURL: URL) {
        let key = normalizedKey(artist: artist, album: album)
        let stem = hashedFilenameStem(forNormalizedKey: key)
        let main = artworkDirectory.appendingPathComponent("\(stem).jpg")
        let fp = artworkDirectory.appendingPathComponent("\(stem)_fingerprint.jpg")
        return (key, main, fp)
    }
}

struct AlbumArtworkDiskIndex: Codable {
    static let currentVersion = 1
    var version = 1

    struct Entry: Codable, Equatable {
        var artist: String
        var album: String
        /// Basename stored under Application Support artwork directory.
        var filename: String
        var cachedAt: Date
        var source: String?
    }

    var entries: [String: Entry]

    init() {
        entries = [:]
    }
}

final class AlbumArtworkIndexStore {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let decoder = JSONDecoder()

    func load() -> AlbumArtworkDiskIndex {
        guard let url = indexURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var decoded = try? decoder.decode(AlbumArtworkDiskIndex.self, from: data)
        else {
            return AlbumArtworkDiskIndex()
        }
        decoded.version = AlbumArtworkDiskIndex.currentVersion
        return decoded
    }

    func save(_ index: AlbumArtworkDiskIndex) {
        guard let url = indexURL() else { return }
        var copy = index
        copy.version = AlbumArtworkDiskIndex.currentVersion
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(copy) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func indexURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("LiquidFLACPlayer", isDirectory: true)
            .appendingPathComponent("album-artwork-map.json", isDirectory: false)
    }
}

import AVFoundation
import CoreServices
import Foundation

actor LibraryIndexer {
    private let fileManager = FileManager.default
    private var highestSaveGeneration: UInt64 = 0
    private let audioExtensions: Set<String> = [
        "flac", "mp3", "m4a", "aac", "aiff", "aif", "wav", "alac", "ogg", "opus"
    ]

    func loadIndex() -> LibraryIndex? {
        let url = indexURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LibraryIndex.self, from: data)
    }

    /// `generation` must increase whenever the in-memory index advances. Older generations are ignored
    /// so concurrent `persistCurrentIndex` saves cannot roll the JSON file back to stale metadata.
    func saveIndex(_ index: LibraryIndex, generation: UInt64) {
        guard generation >= highestSaveGeneration else { return }
        highestSaveGeneration = generation

        let url = indexURL()
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(index)
            try data.write(to: url, options: .atomic)
        } catch {
            // Silent failure keeps playback functional even if index persistence fails.
        }
    }

    func scan(rootPath: String, previousRoot: LibraryRootIndex?, forceFullRebuild: Bool = false) async -> LibraryScanOutcome {
        let canonicalRoot = FilePathNormalization.canonical(rootPath)
        let rootURL = URL(fileURLWithPath: canonicalRoot)
        let fingerprint = buildFingerprint(for: rootURL)

        if !forceFullRebuild, let previousRoot, previousRoot.fingerprint == fingerprint {
            return .skippedUnchanged
        }

        let files = discoverAudioFiles(in: rootURL)
        var indexedTracks: [IndexedTrack] = []
        indexedTracks.reserveCapacity(files.count)

        for file in files {
            let metadata = await extractMetadata(for: file)
            indexedTracks.append(
                IndexedTrack(
                    path: FilePathNormalization.canonical(file.path),
                    title: metadata.title,
                    artist: metadata.artist,
                    album: metadata.album,
                    genre: metadata.genre
                )
            )
        }

        return .rebuilt(
            newRootIndex: LibraryRootIndex(path: canonicalRoot, fingerprint: fingerprint),
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
        if url.pathExtension.lowercased() == "flac",
           let flacMetadata = flacVorbisMetadata(for: url) {
            return flacMetadata
        }

        let asset = AVURLAsset(url: url)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent

        let metadataItems = allMetadataItems(for: asset)
        let fallback = fallbackMetadata(from: fallbackTitle)
        let finderMetadata = spotlightMetadata(for: url)

        let title: String
        if let tagTitle = metadataValue(in: metadataItems, exactKeys: ["title", "tit2", "©nam", "name"], containsKeys: ["title"]) {
            title = tagTitle
        } else if let finderTitle = finderMetadata.title {
            title = finderTitle
        } else {
            title = fallback.title
        }

        let artist: String
        if let tagArtist = cleanArtistValue(metadataValue(in: metadataItems, exactKeys: ["artist", "albumartist", "album_artist", "tpe1", "©art"], containsKeys: ["artist", "performer"])) {
            artist = tagArtist
        } else if let finderArtist = finderMetadata.artist {
            artist = finderArtist
        } else {
            artist = fallback.artist
        }

        let album: String
        if let tagAlbum = metadataValue(in: metadataItems, exactKeys: ["album", "albumname", "talb", "©alb"], containsKeys: ["album"]) {
            album = tagAlbum
        } else if let finderAlbum = finderMetadata.album {
            album = finderAlbum
        } else {
            album = fallback.album
        }

        let genre: String
        if let tagGenre = metadataValue(in: metadataItems, exactKeys: ["genre", "tcon", "©gen"], containsKeys: ["genre"]) {
            genre = tagGenre
        } else if let finderGenre = finderMetadata.genre {
            genre = finderGenre
        } else {
            genre = fallback.genre
        }

        return (title, artist, album, genre)
    }

    private func flacVorbisMetadata(for url: URL) -> (title: String, artist: String, album: String, genre: String)? {
        guard let metaflac = findExecutable(named: "metaflac") else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: metaflac)
        process.arguments = [
            "--show-tag=TITLE",
            "--show-tag=ARTIST",
            "--show-tag=ALBUM",
            "--show-tag=GENRE",
            url.path
        ]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            let tags = parseVorbisTags(text)
            let fallback = fallbackMetadata(from: url.deletingPathExtension().lastPathComponent)

            return (
                title: tags["TITLE"] ?? fallback.title,
                artist: cleanArtistValue(tags["ARTIST"]) ?? fallback.artist,
                album: tags["ALBUM"] ?? fallback.album,
                genre: tags["GENRE"] ?? fallback.genre
            )
        } catch {
            return nil
        }
    }

    private func parseVorbisTags(_ text: String) -> [String: String] {
        var tags: [String: String] = [:]

        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            tags[key] = value
        }

        return tags
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

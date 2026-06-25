import AVFoundation
import CoreServices
import Foundation

/// All filesystem scanning, metadata extraction (which spawns `metaflac` and reads tags
/// synchronously), and index persistence run on dedicated GCD queues instead of the Swift
/// concurrency cooperative thread pool, so a long library scan never blocks the main thread
/// or starves other async work.
final class LibraryIndexer: @unchecked Sendable {
    private let fileManager = FileManager.default
    private var highestSaveGeneration: UInt64 = 0
    private let audioExtensions: Set<String> = [
        "flac", "mp3", "m4a", "aac", "aiff", "aif", "wav", "alac", "ogg", "opus"
    ]

    /// Serial queue for reading/writing the on-disk index. Serializing here keeps the
    /// `highestSaveGeneration` guard correct and prevents concurrent writes to the JSON file.
    private let ioQueue = DispatchQueue(label: "com.grooveshark.library-index.io", qos: .utility)
    /// Serial queue for the heavy scan/metadata work, kept separate so a long scan never
    /// blocks a pending index save (or vice versa).
    private let scanQueue = DispatchQueue(label: "com.grooveshark.library-index.scan", qos: .utility)

    func loadIndex() async -> LibraryIndex? {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: self.performLoadIndex())
            }
        }
    }

    /// `generation` must increase whenever the in-memory index advances. Older generations are ignored
    /// so concurrent `persistCurrentIndex` saves cannot roll the JSON file back to stale metadata.
    func saveIndex(_ index: LibraryIndex, generation: UInt64) async {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                self.performSaveIndex(index, generation: generation)
                continuation.resume()
            }
        }
    }

    func scan(rootPath: String, previousRoot: LibraryRootIndex?, forceFullRebuild: Bool = false) async -> LibraryScanOutcome {
        await withCheckedContinuation { continuation in
            scanQueue.async {
                let outcome = self.performScan(
                    rootPath: rootPath,
                    previousRoot: previousRoot,
                    forceFullRebuild: forceFullRebuild
                )
                continuation.resume(returning: outcome)
            }
        }
    }

    private func performLoadIndex() -> LibraryIndex? {
        let url = indexURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LibraryIndex.self, from: data)
    }

    private func performSaveIndex(_ index: LibraryIndex, generation: UInt64) {
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

    private func performScan(rootPath: String, previousRoot: LibraryRootIndex?, forceFullRebuild: Bool) -> LibraryScanOutcome {
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
            let metadata = extractMetadata(for: file)
            indexedTracks.append(
                IndexedTrack(
                    path: FilePathNormalization.canonical(file.path),
                    title: metadata.title,
                    artist: metadata.artist,
                    album: metadata.album,
                    genre: metadata.genre,
                    trackNumber: metadata.trackNumber,
                    fidelityLabel: metadata.fidelityLabel
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
            .appendingPathComponent("GrooveShark", isDirectory: true)
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

    private func extractMetadata(for url: URL) -> (
        title: String,
        artist: String,
        album: String,
        genre: String,
        trackNumber: Int?,
        fidelityLabel: String
    ) {
        if url.pathExtension.lowercased() == "flac",
           let flacMetadata = flacVorbisMetadata(for: url) {
            return flacMetadata
        }

        let asset = AVURLAsset(url: url)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent

        let metadataItems = allMetadataItems(for: asset)
        let fallback = fallbackMetadata(from: fallbackTitle)
        let finderMetadata = spotlightMetadata(for: url)
        let bitrateKbps = estimatedBitrateKbps(for: asset)

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

        let trackNumber = metadataTrackNumber(in: metadataItems) ?? finderMetadata.trackNumber

        return (
            title,
            artist,
            album,
            genre,
            trackNumber,
            AudioFidelityFormatter.label(kbps: bitrateKbps, pathExtension: url.pathExtension)
        )
    }

    private func flacVorbisMetadata(for url: URL) -> (
        title: String,
        artist: String,
        album: String,
        genre: String,
        trackNumber: Int?,
        fidelityLabel: String
    )? {
        guard let metaflac = findExecutable(named: "metaflac") else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: metaflac)
        process.arguments = [
            "--show-tag=TITLE",
            "--show-tag=ARTIST",
            "--show-tag=ALBUM",
            "--show-tag=GENRE",
            "--show-tag=TRACKNUMBER",
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
                genre: tags["GENRE"] ?? fallback.genre,
                trackNumber: parseTrackNumber(tags["TRACKNUMBER"]),
                fidelityLabel: "Lossless"
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

    private func spotlightMetadata(for url: URL) -> (title: String?, artist: String?, album: String?, genre: String?, trackNumber: Int?) {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) else {
            return (nil, nil, nil, nil, nil)
        }

        let title = mdString(item, kMDItemTitle)
        let authors = mdString(item, kMDItemAuthors)
        let performers = mdString(item, kMDItemPerformers)
        let artist = cleanArtistValue(authors) ?? cleanArtistValue(performers)
        let album = mdString(item, kMDItemAlbum)
        let genre = mdString(item, kMDItemMusicalGenre)
        let trackNumber = mdInt(item, kMDItemAudioTrackNumber)

        return (
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            trackNumber: trackNumber
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

    private func mdInt(_ item: MDItem, _ attribute: CFString) -> Int? {
        guard let value = MDItemCopyAttribute(item, attribute) else { return nil }

        if let number = value as? NSNumber {
            let intValue = number.intValue
            return intValue > 0 ? intValue : nil
        }

        if let string = value as? String {
            return parseTrackNumber(string)
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

    private func estimatedBitrateKbps(for asset: AVURLAsset) -> Int? {
        let rates = asset
            .tracks(withMediaType: .audio)
            .map(\.estimatedDataRate)
            .filter { $0 > 0 }
        guard let rate = rates.max() else { return nil }
        return Int((rate / 1000).rounded())
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

    private func metadataTrackNumber(in items: [AVMetadataItem]) -> Int? {
        for item in items {
            let keys = metadataKeys(for: item)
            guard keys.contains(where: isTrackNumberKey) else { continue }

            if let number = item.numberValue {
                let intValue = number.intValue
                if intValue > 0 {
                    return intValue
                }
            }

            if let parsed = parseTrackNumber(item.stringValue) {
                return parsed
            }
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

    private func parseTrackNumber(_ value: String?) -> Int? {
        guard let cleaned = cleanMetadataString(value) else { return nil }

        let leadingPart = cleaned.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? cleaned
        let digits = leadingPart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(digits), parsed > 0 else { return nil }
        return parsed
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

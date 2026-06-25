import AppKit
import Foundation

actor ArtworkProvider {
    private let fileManager = FileManager.default
    private let indexStore = AlbumArtworkIndexStore()

    private func albumArtworkDirectory() -> URL {
        let appSupport =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("GrooveShark/artwork/by-album", isDirectory: true)
    }

    func cachedArtworkData(for track: Track) -> Data? {
        let (_, mainURL, fpURL) = AlbumArtworkIdentity.paths(
            artist: track.artist,
            album: track.album,
            artworkDirectory: albumArtworkDirectory()
        )

        if let localArtwork = localFolderArtworkData(for: track) {
            return localArtwork
        }
        if let cached = try? Data(contentsOf: mainURL) {
            return cached
        }
        if let cachedFingerprint = try? Data(contentsOf: fpURL) {
            return cachedFingerprint
        }
        return nil
    }

    func artworkData(for track: Track) async -> Data? {
        let (_, mainURL, fpURL) = AlbumArtworkIdentity.paths(
            artist: track.artist,
            album: track.album,
            artworkDirectory: albumArtworkDirectory()
        )

        // User-supplied album art should override any cached remote guess.
        if let localArtwork = localFolderArtworkData(for: track) {
            return localArtwork
        }

        // 1–2: App cache first (fast). Previously AcoustID ran before these and blocked on fpcalc + network.
        if let cached = try? Data(contentsOf: mainURL) {
            return cached
        }
        if let cachedFingerprint = try? Data(contentsOf: fpURL) {
            return cachedFingerprint
        }

        // 3: iTunes (single HTTP fetch, no subprocess).
        if let artworkURL = await lookupITunesArtworkURL(for: track) {
            do {
                let (data, _) = try await URLSession.shared.data(from: artworkURL)
                try fileManager.createDirectory(at: mainURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: mainURL, options: [.atomic])
                persistMapEntry(for: track, filename: mainURL.lastPathComponent, source: "itunes")
                return data
            } catch {
                // Try AcoustID below.
            }
        }

        // 4: AcoustID + Cover Art Archive (fpcalc + APIs) — last resort.
        return await downloadFingerprintArtworkFromAcoustid(for: track, fingerprintURL: fpURL)
    }

    func refreshArtworkData(for track: Track) async -> Data? {
        let (_, mainURL, fpURL) = AlbumArtworkIdentity.paths(
            artist: track.artist,
            album: track.album,
            artworkDirectory: albumArtworkDirectory()
        )
        try? fileManager.removeItem(at: mainURL)
        try? fileManager.removeItem(at: fpURL)
        removeMapEntry(for: track)

        return await artworkData(for: track)
    }

    private func localFolderArtworkData(for track: Track) -> Data? {
        let albumFolder = track.url.deletingLastPathComponent()
        let preferredNames = ["cover.jpg", "cover.png"]

        for name in preferredNames {
            let url = albumFolder.appendingPathComponent(name, isDirectory: false)
            if let data = try? Data(contentsOf: url) {
                return data
            }
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: albumFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for name in preferredNames {
            if let match = contents.first(where: { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }),
               let data = try? Data(contentsOf: match) {
                return data
            }
        }

        return nil
    }

    private func downloadFingerprintArtworkFromAcoustid(for track: Track, fingerprintURL: URL) async -> Data? {
        guard let artworkURL = await lookupFingerprintArtworkURL(for: track) else { return nil }

        do {
            var request = URLRequest(url: artworkURL)
            request.setValue("GrooveShark/0.1 (local macOS player)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return nil
            }
            try fileManager.createDirectory(at: fingerprintURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fingerprintURL, options: [.atomic])
            persistMapEntry(for: track, filename: fingerprintURL.lastPathComponent, source: "acoustid")
            return data
        } catch {
            return nil
        }
    }

    private func persistMapEntry(for track: Track, filename: String, source: String?) {
        let key = AlbumArtworkIdentity.normalizedKey(artist: track.artist, album: track.album)
        var disk = indexStore.load()
        disk.entries[key] = AlbumArtworkDiskIndex.Entry(
            artist: track.artist,
            album: track.album,
            filename: filename,
            cachedAt: Date(),
            source: source
        )
        indexStore.save(disk)
    }

    private func removeMapEntry(for track: Track) {
        let key = AlbumArtworkIdentity.normalizedKey(artist: track.artist, album: track.album)
        var disk = indexStore.load()
        disk.entries.removeValue(forKey: key)
        indexStore.save(disk)
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
        let albumIsKnown = !isPlaceholder(track.album, placeholder: "Unknown Album")
        let term = "\(track.artist) \(albumIsKnown ? track.album : track.title)"
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: albumIsKnown ? "album" : "song"),
            URLQueryItem(name: "limit", value: "10")
        ]

        guard let url = components?.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ITunesArtworkResponse.self, from: data)
            return bestITunesArtworkURL(from: response.results, matching: track)
        } catch {
            return nil
        }
    }

    private func bestITunesArtworkURL(from results: [ITunesArtworkResult], matching track: Track) -> URL? {
        let albumIsKnown = !isPlaceholder(track.album, placeholder: "Unknown Album")
        let artistIsKnown = !isPlaceholder(track.artist, placeholder: "Unknown Artist")

        let ranked = results.enumerated().compactMap { offset, result -> (url: URL, score: Int, offset: Int)? in
            guard let rawURL = result.artworkUrl100,
                  let url = URL(string: rawURL.replacingOccurrences(of: "100x100bb", with: "600x600bb")) else {
                return nil
            }

            let artistScore = artistMatchScore(candidate: result.artistName ?? "", target: track.artist)
            if artistIsKnown && artistScore == 0 {
                return nil
            }

            let score: Int
            if albumIsKnown {
                let albumScore = matchScore(candidate: result.collectionName ?? "", target: track.album)
                guard albumScore >= 6 else { return nil }
                score = albumScore + artistScore
            } else {
                let titleScore = matchScore(candidate: result.trackName ?? "", target: track.title)
                guard titleScore >= 6 else { return nil }
                score = titleScore + artistScore
            }

            return (url, score, offset)
        }
        .sorted {
            if $0.score == $1.score {
                return $0.offset < $1.offset
            }
            return $0.score > $1.score
        }

        return ranked.first?.url
    }

    private func matchScore(candidate: String, target: String) -> Int {
        let left = normalized(candidate)
        let right = normalized(target)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 10 }
        if left.contains(right) || right.contains(left) { return 6 }
        return 0
    }

    private func artistMatchScore(candidate: String, target: String) -> Int {
        matchScore(candidate: primaryArtist(candidate), target: primaryArtist(target))
    }

    private func isPlaceholder(_ value: String, placeholder: String) -> Bool {
        let normalizedValue = normalized(value)
        return normalizedValue.isEmpty || normalizedValue == normalized(placeholder)
    }

    private func primaryArtist(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let delimiters = [
            " feat.", " feat ", " ft.", " ft ", " featuring ", " with ",
        ]
        for delimiter in delimiters {
            if let range = value.range(of: delimiter, options: .caseInsensitive) {
                value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return value.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : value
    }
}

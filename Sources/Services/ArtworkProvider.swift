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
            .appendingPathComponent("LiquidFLACPlayer/artwork/by-album", isDirectory: true)
    }

    func artworkData(for track: Track) async -> Data? {
        let (_, mainURL, fpURL) = AlbumArtworkIdentity.paths(
            artist: track.artist,
            album: track.album,
            artworkDirectory: albumArtworkDirectory()
        )

        // 1–2: Local files first (fast). Previously AcoustID ran before these and blocked on fpcalc + network.
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

    private func downloadFingerprintArtworkFromAcoustid(for track: Track, fingerprintURL: URL) async -> Data? {
        guard let artworkURL = await lookupFingerprintArtworkURL(for: track) else { return nil }

        do {
            var request = URLRequest(url: artworkURL)
            request.setValue("mplayer/0.1 (local macOS player)", forHTTPHeaderField: "User-Agent")
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
}

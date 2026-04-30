import Foundation

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
            if let verificationError = verifyFLAC(update: update, url: url, metaflac: metaflac) {
                return verificationError
            }
            reimportSpotlightMetadata(for: url)
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

    private func verifyFLAC(update: FileMetadataUpdate, url: URL, metaflac: String) -> String? {
        let expected = [
            "TITLE": update.title,
            "ARTIST": update.artist,
            "ALBUM": update.album,
            "GENRE": update.genre
        ].compactMapValues { $0 }

        guard !expected.isEmpty else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: metaflac)
        process.arguments = expected.keys.sorted().map { "--show-tag=\($0)" } + [url.path]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return "could not verify written metadata"
            }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            let actual = parseVorbisTags(text)

            for (key, expectedValue) in expected {
                if actual[key] != expectedValue {
                    return "metadata verification failed for \(key)"
                }
            }
            return nil
        } catch {
            return "could not verify written metadata: \(error.localizedDescription)"
        }
    }

    private func parseVorbisTags(_ text: String) -> [String: String] {
        var tags: [String: String] = [:]

        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            tags[key] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return tags
    }
    private func reimportSpotlightMetadata(for url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
        process.arguments = [url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // The file tags are already written; Spotlight refresh is best-effort.
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
}

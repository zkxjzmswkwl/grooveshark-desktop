import Foundation

struct YouTubeDownloadResult: Sendable {
    let downloadRoot: URL
    let downloadedFiles: [URL]
    let skippedCount: Int
}

struct YouTubeDownloadProgressUpdate: Sendable {
    let url: String
    let title: String
    let phase: YouTubeDownloadPhase
    let progress: Double?
    let downloadedPath: String?
    let errorMessage: String?
}

enum YouTubeDownloadPhase: String, Sendable {
    case queued
    case downloading
    case completed
    case skipped
    case failed
}

enum YouTubeDownloadError: LocalizedError {
    case ytdlpNotFound
    case invalidURL(String)
    case downloadFailed(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .ytdlpNotFound:
            return "yt-dlp was not found. Install it with: brew install yt-dlp"
        case let .invalidURL(url):
            return "Not a YouTube URL: \(url)"
        case let .downloadFailed(message):
            return message
        case let .processFailed(message):
            return message
        }
    }
}

/// `yt-dlp` downloads spawn a child process and stream progress for the full (often multi-minute)
/// duration of each download. All of that blocking process/pipe work runs on a dedicated GCD queue
/// instead of the Swift concurrency cooperative thread pool, and progress is delivered back to the
/// async caller through an `AsyncStream` so the UI never blocks.
final class YouTubeDownloadService: @unchecked Sendable {
    static let downloadFolderName = "YouTube"

    private let fileManager = FileManager.default
    /// Serial queue that owns each download's process lifecycle so it never ties up a
    /// cooperative-pool thread for the duration of the download.
    private let workQueue = DispatchQueue(label: "com.grooveshark.youtube-download.work", qos: .utility)
    /// Used to drain a child process's stderr concurrently with its stdout, avoiding a pipe-buffer deadlock.
    private let drainQueue = DispatchQueue(label: "com.grooveshark.youtube-download.drain", qos: .utility)

    func downloadRootURL() async -> URL {
        rootURL()
    }

    func isYTDLPAvailable() async -> Bool {
        // Run on a global queue (not workQueue) so this quick check isn't blocked behind an
        // in-flight, possibly multi-minute, download.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.resolveYTDLPExecutable() != nil)
            }
        }
    }

    func download(
        urls: [String],
        progress: (@Sendable (YouTubeDownloadProgressUpdate) async -> Void)? = nil
    ) async throws -> YouTubeDownloadResult {
        let stream = AsyncStream<DownloadEvent> { continuation in
            workQueue.async {
                do {
                    let result = try self.performDownload(urls: urls) { update in
                        continuation.yield(.progress(update))
                    }
                    continuation.yield(.completed(result))
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
        }

        // Forward buffered progress updates to the caller (which hops to the main actor for UI),
        // then surface the final result once the background work has finished.
        var result: YouTubeDownloadResult?
        var failureMessage: String?
        for await event in stream {
            switch event {
            case let .progress(update):
                await progress?(update)
            case let .completed(value):
                result = value
            case let .failed(message):
                failureMessage = message
            }
        }

        if let result {
            return result
        }
        throw YouTubeDownloadError.downloadFailed(failureMessage ?? "Download ended unexpectedly.")
    }

    private enum DownloadEvent: Sendable {
        case progress(YouTubeDownloadProgressUpdate)
        case completed(YouTubeDownloadResult)
        case failed(String)
    }

    /// Collects a child process's full stderr text while it is drained on a background queue,
    /// so the error message is still available after the pipe has been consumed.
    private final class StderrCollector: @unchecked Sendable {
        var text = ""
    }

    private func performDownload(
        urls: [String],
        emit: @escaping @Sendable (YouTubeDownloadProgressUpdate) -> Void
    ) throws -> YouTubeDownloadResult {
        guard let ytdlp = resolveYTDLPExecutable() else {
            throw YouTubeDownloadError.ytdlpNotFound
        }

        let normalizedURLs = Self.normalizeURLs(urls)
        guard !normalizedURLs.isEmpty else {
            throw YouTubeDownloadError.invalidURL("(empty)")
        }

        let root = rootURL()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        var downloadedFiles: [URL] = []
        var skippedCount = 0
        var failureCount = 0

        for url in normalizedURLs {
            emit(YouTubeDownloadProgressUpdate(
                url: url,
                title: url,
                phase: .queued,
                progress: nil,
                downloadedPath: nil,
                errorMessage: nil
            ))

            do {
                let startedAt = Date()
                let outcome = try downloadSingle(url: url, ytdlp: ytdlp, root: root, emit: emit)
                switch outcome {
                case let .downloaded(primaryPath):
                    let newFiles = newlyDownloadedFiles(in: root, since: startedAt.addingTimeInterval(-2))
                    if newFiles.isEmpty, let path = primaryPath {
                        downloadedFiles.append(URL(fileURLWithPath: path))
                    } else {
                        downloadedFiles.append(contentsOf: newFiles)
                    }
                case .skipped:
                    skippedCount += 1
                }
            } catch {
                failureCount += 1
                emit(YouTubeDownloadProgressUpdate(
                    url: url,
                    title: url,
                    phase: .failed,
                    progress: nil,
                    downloadedPath: nil,
                    errorMessage: error.localizedDescription
                ))
            }
        }

        if downloadedFiles.isEmpty, skippedCount == 0, failureCount > 0 {
            throw YouTubeDownloadError.downloadFailed("All downloads failed.")
        }

        return YouTubeDownloadResult(
            downloadRoot: root,
            downloadedFiles: downloadedFiles,
            skippedCount: skippedCount
        )
    }

    private func rootURL() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("GrooveShark", isDirectory: true)
            .appendingPathComponent(Self.downloadFolderName, isDirectory: true)
    }

    private enum SingleDownloadOutcome {
        case downloaded(primaryPath: String?)
        case skipped
    }

    private func downloadSingle(
        url: String,
        ytdlp: String,
        root: URL,
        emit: @escaping @Sendable (YouTubeDownloadProgressUpdate) -> Void
    ) throws -> SingleDownloadOutcome {
        let title = try fetchTitle(url: url, ytdlp: ytdlp)

        emit(YouTubeDownloadProgressUpdate(
            url: url,
            title: title,
            phase: .downloading,
            progress: 0,
            downloadedPath: nil,
            errorMessage: nil
        ))

        let outputTemplate = root.appendingPathComponent("%(uploader)s - %(title)s.%(ext)s").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = [
            "-x",
            "--audio-format", "mp3",
            "--audio-quality", "0",
            "--embed-metadata",
            "--embed-thumbnail",
            "--convert-thumbnails", "jpg",
            "--no-overwrites",
            "--newline",
            "--progress",
            "-o", outputTemplate,
            "--print", "after_move:filepath",
            url,
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Drain stderr (progress) on a separate queue so its pipe buffer can't fill and deadlock
        // yt-dlp while we block reading stdout on this queue.
        nonisolated(unsafe) let stderrHandle = stderrPipe.fileHandleForReading
        let stderrCollector = StderrCollector()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        drainQueue.async {
            stderrCollector.text = self.consumeProgressLines(
                from: stderrHandle,
                url: url,
                title: title,
                emit: emit
            )
            drainGroup.leave()
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        drainGroup.wait()

        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let stderr = stderrCollector.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = stderr.isEmpty ? "yt-dlp exited with status \(process.terminationStatus)" : stderr
            throw YouTubeDownloadError.downloadFailed(message)
        }

        if stdout.isEmpty {
            emit(YouTubeDownloadProgressUpdate(
                url: url,
                title: title,
                phase: .skipped,
                progress: 1,
                downloadedPath: nil,
                errorMessage: nil
            ))
            return .skipped
        }

        let downloadedPaths = stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        emit(YouTubeDownloadProgressUpdate(
            url: url,
            title: title,
            phase: .completed,
            progress: 1,
            downloadedPath: downloadedPaths.last,
            errorMessage: nil
        ))

        return .downloaded(primaryPath: downloadedPaths.last)
    }

    private func newlyDownloadedFiles(in root: URL, since start: Date) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= start
            else { continue }
            files.append(fileURL)
        }
        return files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func fetchTitle(url: String, ytdlp: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = ["--print", "%(title)s", "--no-playlist", url]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let title = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? url

        guard process.terminationStatus == 0, !title.isEmpty else {
            throw YouTubeDownloadError.downloadFailed("Could not read video title.")
        }

        return title
    }

    /// Reads progress lines from the process's stderr, emitting download progress, and returns the
    /// full captured stderr text (used to build an error message if the process fails).
    private func consumeProgressLines(
        from handle: FileHandle,
        url: String,
        title: String,
        emit: @Sendable (YouTubeDownloadProgressUpdate) -> Void
    ) -> String {
        var buffer = Data()
        var captured = Data()

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            captured.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)

                guard let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    line.contains("[download]")
                else { continue }

                let fraction = Self.parseDownloadFraction(from: line)
                emit(YouTubeDownloadProgressUpdate(
                    url: url,
                    title: title,
                    phase: .downloading,
                    progress: fraction,
                    downloadedPath: nil,
                    errorMessage: nil
                ))
            }
        }

        return String(data: captured, encoding: .utf8) ?? ""
    }

    private func resolveYTDLPExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp",
        ]

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["yt-dlp"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, fileManager.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    static func normalizeURLs(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for entry in raw {
            let pieces = entry
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: .newlines)

            for piece in pieces {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard isYouTubeURL(trimmed) else { continue }
                guard seen.insert(trimmed).inserted else { continue }
                result.append(trimmed)
            }
        }

        return result
    }

    static func isYouTubeURL(_ string: String) -> Bool {
        let lowered = string.lowercased()
        return lowered.contains("youtube.com/") || lowered.contains("youtu.be/") || lowered.contains("music.youtube.com/")
    }

    static func parseDownloadFraction(from line: String) -> Double? {
        guard let percentRange = line.range(of: #"\d+(?:\.\d+)?%"#, options: .regularExpression) else {
            return nil
        }
        let percentToken = line[percentRange].dropLast()
        return (Double(percentToken) ?? 0) / 100
    }
}

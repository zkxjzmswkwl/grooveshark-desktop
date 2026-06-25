import Darwin
import Foundation

struct SharedLibraryTrack: Codable, Identifiable, Sendable {
    let id: String
    let relativePath: String
    let title: String
    let artist: String
    let album: String
    let genre: String
    let trackNumber: Int?
}

struct SharedLibraryDownloadResult: Sendable {
    let importedRoot: URL
    let downloadedTracks: Int
}

struct LibraryTransferQueueSnapshot: Sendable {
    let completed: [SharedLibraryTrack]
    let current: [SharedLibraryTrack]
    let upcoming: [SharedLibraryTrack]

    static let empty = LibraryTransferQueueSnapshot(completed: [], current: [], upcoming: [])
}

struct RsyncModule: Sendable, Equatable {
    let name: String
    let path: String
}

actor LibrarySharingService {
    private let fileManager = FileManager.default
    private var daemonProcess: Process?
    private var configURL: URL?
    private var modules: [RsyncModule] = []
    private var port: UInt16?

    func isRsyncAvailable() -> Bool {
        RsyncExecutable.path() != nil
    }

    func start(port: UInt16, roots: [String]) async throws -> String {
        guard let rsync = RsyncExecutable.path() else {
            throw LibrarySharingError.rsyncNotFound
        }
        guard !roots.isEmpty else {
            throw LibrarySharingError.emptyLibrary
        }

        stop()

        let preparedRoots = try prepareRoots(roots)
        let builtModules = Self.makeModules(from: preparedRoots)
        let configURL = try writeDaemonConfig(port: port, modules: builtModules)
        let process = try await launchDaemon(rsync: rsync, configURL: configURL)

        daemonProcess = process
        self.configURL = configURL
        modules = builtModules
        self.port = port

        let host = Self.primaryLANAddress() ?? "localhost"
        return "rsync://\(host):\(port)/"
    }

    func stop() {
        if let process = daemonProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        daemonProcess = nil
        port = nil
        modules = []
    }

    func updateSharedLibrary(roots: [String]) async throws {
        guard daemonProcess != nil, let port else { return }
        let endpoint = try await start(port: port, roots: roots)
        _ = endpoint
    }

    func sharingTransferSnapshot() -> LibraryTransferQueueSnapshot {
        let upcoming = modules.map { module in
            SharedLibraryTrack(
                id: module.name,
                relativePath: module.name,
                title: module.name,
                artist: module.path,
                album: "",
                genre: "",
                trackNumber: nil
            )
        }
        return LibraryTransferQueueSnapshot(completed: [], current: [], upcoming: upcoming)
    }

    private func prepareRoots(_ roots: [String]) throws -> [String] {
        var prepared: [String] = []
        for root in roots {
            let canonical = FilePathNormalization.canonical(root)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw LibrarySharingError.invalidLibraryRoot(canonical)
            }
            prepared.append(canonical)
        }
        return prepared
    }

    private func writeDaemonConfig(port: UInt16, modules: [RsyncModule]) throws -> URL {
        let configDir = Self.rsyncSupportDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)

        let logFile = configDir.appendingPathComponent("rsyncd.log").path
        var lines = [
            "use chroot = no",
            "read only = yes",
            "hosts allow = *",
            "max connections = 8",
            "log file = \(logFile)",
            "port = \(port)",
            "",
        ]

        for module in modules {
            lines.append("[\(module.name)]")
            lines.append("path = \(module.path)")
            lines.append("comment = GrooveShark library root")
            lines.append("")
        }

        let configURL = configDir.appendingPathComponent("rsyncd.conf")
        try lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    private func launchDaemon(rsync: String, configURL: URL) async throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rsync)
        process.arguments = ["--daemon", "--config=\(configURL.path)", "--no-detach"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        try await Task.sleep(nanoseconds: 200_000_000)

        guard process.isRunning else {
            let stderr = readAll(from: process.standardError as? Pipe)
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LibrarySharingError.daemonStartFailed(message.isEmpty ? "rsync daemon exited immediately." : message)
        }
        return process
    }

    private static func makeModules(from roots: [String]) -> [RsyncModule] {
        var usedNames: Set<String> = []
        var modules: [RsyncModule] = []

        for (index, root) in roots.enumerated() {
            let baseName = (root as NSString).lastPathComponent
            var name = sanitizeModuleName(baseName)
            if name.isEmpty {
                name = "library\(index + 1)"
            }
            var suffix = 2
            while usedNames.contains(name) {
                name = "\(sanitizeModuleName(baseName))\(suffix)"
                suffix += 1
            }
            usedNames.insert(name)
            modules.append(RsyncModule(name: name, path: root))
        }
        return modules
    }

    private static func sanitizeModuleName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let collapsed = String(cleaned)
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return String(collapsed.prefix(48))
    }

    private static func rsyncSupportDirectory(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("GrooveShark", isDirectory: true)
            .appendingPathComponent("rsync", isDirectory: true)
    }

    private static func primaryLANAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer = first
        while true {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp,
               !isLoopback,
               let addr = interface.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let count = hostname.firstIndex(of: 0) ?? hostname.count
                    let bytes = hostname.prefix(count).map { UInt8(bitPattern: $0) }
                    return String(decoding: bytes, as: UTF8.self)
                }
            }

            guard let next = interface.ifa_next else { break }
            pointer = next
        }

        return nil
    }
}

actor LibrarySharingClient {
    private let fileManager = FileManager.default
    private let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "alac", "wma", "ape", "wv",
    ]

    func downloadLibrary(
        from address: String,
        to destinationRoot: URL,
        progress: (@Sendable (LibraryTransferQueueSnapshot) async -> Void)? = nil
    ) async throws -> SharedLibraryDownloadResult {
        guard let rsync = RsyncExecutable.path() else {
            throw LibrarySharingError.rsyncNotFound
        }

        let endpoint = try parseEndpoint(from: address)
        let modules = try await listModules(rsync: rsync, endpoint: endpoint)
        guard !modules.isEmpty else { throw LibrarySharingError.emptyLibrary }

        let importRoot = makeImportRoot(endpoint: endpoint, destinationRoot: destinationRoot)
        try fileManager.createDirectory(at: importRoot, withIntermediateDirectories: true)

        var completed: [SharedLibraryTrack] = []
        var upcoming = modules.map { moduleTrack($0) }
        await progress?(LibraryTransferQueueSnapshot(completed: completed, current: [], upcoming: upcoming))

        for module in modules {
            upcoming.removeAll { $0.id == module.name }
            let current = [moduleTrack(module)]
            await progress?(LibraryTransferQueueSnapshot(completed: completed, current: current, upcoming: upcoming))

            let moduleDestination = importRoot.appendingPathComponent(module.name, isDirectory: true)
            try fileManager.createDirectory(at: moduleDestination, withIntermediateDirectories: true)

            let source = "rsync://\(endpoint.host):\(endpoint.port)/\(module.name)/"
            let completedSnapshot = completed
            let upcomingSnapshot = upcoming
            try await runRsync(
                rsync: rsync,
                source: source,
                destination: moduleDestination.path.hasSuffix("/") ? moduleDestination.path : moduleDestination.path + "/",
                onProgressLine: { line in
                    guard let track = Self.trackFromProgressLine(line, module: module) else { return }
                    await progress?(LibraryTransferQueueSnapshot(
                        completed: completedSnapshot,
                        current: [track],
                        upcoming: upcomingSnapshot
                    ))
                }
            )

            completed.append(moduleTrack(module))
            await progress?(LibraryTransferQueueSnapshot(completed: completed, current: [], upcoming: upcoming))
        }

        await progress?(LibraryTransferQueueSnapshot(completed: completed, current: [], upcoming: []))

        let downloadedTracks = countAudioFiles(at: importRoot)
        return SharedLibraryDownloadResult(importedRoot: importRoot, downloadedTracks: downloadedTracks)
    }

    private func listModules(rsync: String, endpoint: RsyncEndpoint) async throws -> [RsyncModule] {
        let target = "rsync://\(endpoint.host):\(endpoint.port)/"
        let output = try await runProcessCollectingOutput(
            executable: rsync,
            arguments: [target]
        )
        return Self.parseModuleList(output)
    }

    private func runRsync(
        rsync: String,
        source: String,
        destination: String,
        onProgressLine: (@Sendable (String) async -> Void)?
    ) async throws {
        let status = try await runProcess(
            executable: rsync,
            arguments: ["-av", "--progress", "--partial", source, destination],
            onLine: { line in
                if let onProgressLine {
                    await onProgressLine(line)
                }
            }
        )
        guard status == 0 else {
            throw LibrarySharingError.rsyncExitFailed(status)
        }
    }

    private func runProcessCollectingOutput(executable: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0 else {
                    let message = String(data: stderr, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let message, !message.isEmpty {
                        continuation.resume(throwing: LibrarySharingError.rsyncMessageFailed(message))
                    } else {
                        continuation.resume(throwing: LibrarySharingError.rsyncExitFailed(process.terminationStatus))
                    }
                    return
                }
                continuation.resume(returning: String(data: stdout, encoding: .utf8) ?? "")
            }
        }
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        onLine: (@Sendable (String) async -> Void)?
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let onLine, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                Task { await onLine(line) }
            }
        }

        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus != 0,
                   let message = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !message.isEmpty {
                    continuation.resume(throwing: LibrarySharingError.rsyncMessageFailed(message))
                } else {
                    continuation.resume(returning: process.terminationStatus)
                }
            }
        }
    }

    private func parseEndpoint(from address: String) throws -> RsyncEndpoint {
        var trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibrarySharingError.invalidAddress }

        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            throw LibrarySharingError.legacyHTTPAddress
        }

        if !trimmed.lowercased().hasPrefix("rsync://") {
            trimmed = "rsync://\(trimmed)"
        }

        guard let components = URLComponents(string: trimmed),
              let host = components.host,
              !host.isEmpty
        else {
            throw LibrarySharingError.invalidAddress
        }

        let port = UInt16(components.port ?? 873)
        return RsyncEndpoint(host: host, port: port)
    }

    private func makeImportRoot(endpoint: RsyncEndpoint, destinationRoot: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        return destinationRoot.appendingPathComponent("Shared-\(endpoint.host)-\(stamp)", isDirectory: true)
    }

    private func moduleTrack(_ module: RsyncModule) -> SharedLibraryTrack {
        SharedLibraryTrack(
            id: module.name,
            relativePath: module.name,
            title: module.name,
            artist: module.path,
            album: "",
            genre: "",
            trackNumber: nil
        )
    }

    private func countAudioFiles(at root: URL) -> Int {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let ext = url.pathExtension.lowercased()
            if audioExtensions.contains(ext) {
                count += 1
            }
        }
        return count
    }

    private static func parseModuleList(_ output: String) -> [RsyncModule] {
        var modules: [RsyncModule] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("rsync") else { continue }
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            guard let name = parts.first.map(String.init), !name.isEmpty else { continue }
            if name == "total" || name == "size" { continue }
            modules.append(RsyncModule(name: name, path: name))
        }
        return modules
    }

    private static func trackFromProgressLine(_ line: String, module: RsyncModule) -> SharedLibraryTrack? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("%"), !trimmed.hasPrefix("sending") else { return nil }
        return SharedLibraryTrack(
            id: "\(module.name)-progress",
            relativePath: trimmed,
            title: trimmed,
            artist: module.name,
            album: "",
            genre: "",
            trackNumber: nil
        )
    }

}

private enum RsyncExecutable {
    static func path() -> String? {
        let candidates = [
            "/opt/homebrew/bin/rsync",
            "/usr/local/bin/rsync",
            "/usr/bin/rsync",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}

private struct RsyncEndpoint: Sendable {
    let host: String
    let port: UInt16
}

enum LibrarySharingError: LocalizedError {
    case invalidPort
    case invalidAddress
    case legacyHTTPAddress
    case emptyLibrary
    case rsyncNotFound
    case daemonStartFailed(String)
    case invalidLibraryRoot(String)
    case rsyncExitFailed(Int32)
    case rsyncMessageFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "Choose a port between 1024 and 65535."
        case .invalidAddress:
            return "Enter a valid rsync address such as rsync://192.168.1.20:873/ or 192.168.1.20:873."
        case .legacyHTTPAddress:
            return "Library sharing now uses rsync. Use an rsync:// address instead of http://."
        case .emptyLibrary:
            return "The shared library has no modules to download."
        case .rsyncNotFound:
            return "rsync was not found. macOS includes /usr/bin/rsync; you can also install a newer rsync with Homebrew."
        case let .daemonStartFailed(message):
            return "Could not start rsync daemon: \(message)"
        case let .invalidLibraryRoot(path):
            return "Library folder does not exist: \(path)"
        case let .rsyncExitFailed(code):
            return "rsync failed with exit code \(code)."
        case let .rsyncMessageFailed(message):
            return "rsync failed: \(message)"
        }
    }
}

private func readAll(from pipe: Pipe?) -> String {
    guard let pipe else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

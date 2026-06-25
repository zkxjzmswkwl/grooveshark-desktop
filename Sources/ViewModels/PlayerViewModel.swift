import AppKit
import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PlayerViewModel: NSObject, ObservableObject {
    @Published var playlist: [Track] = [] {
        didSet { applySearchFilter() }
    }
    @Published var searchQuery = "" {
        didSet { applySearchFilter() }
    }
    @Published private(set) var filteredPlaylist: [Track] = []
    @Published var currentIndex: Int?
    @Published var isPlaying = false
    @Published var duration: TimeInterval = 1
    @Published var currentTime: TimeInterval = 0
    @Published private var userSettings = UserSettings.default
    @Published var errorMessage: String?
    @Published var libraryRoots: [String] = []
    @Published private(set) var savedPlaylists: [SavedPlaylist] = []
    @Published var selectedPlaylistID: SavedPlaylist.ID?

    var volume: Float {
        get { userSettings.volume }
        set { updateUserSetting(\.volume, to: newValue) }
    }

    var username: String {
        get { userSettings.username }
        set { updateUserSetting(\.username, to: newValue) }
    }

    var darkModeEnabled: Bool {
        get { userSettings.darkModeEnabled }
        set { updateUserSetting(\.darkModeEnabled, to: newValue) }
    }

    var showFidelityColumn: Bool {
        get { userSettings.showFidelityColumn }
        set { updateUserSetting(\.showFidelityColumn, to: newValue) }
    }

    var libraryGrouping: LibraryGrouping {
        get { userSettings.libraryGrouping }
        set { updateUserSetting(\.libraryGrouping, to: newValue) }
    }

    var sortOption: LibrarySortOption {
        get { userSettings.librarySortOption }
        set { updateUserSetting(\.librarySortOption, to: newValue) }
    }
    @Published var indexStatus: String = "No library indexed yet"
    @Published var isReindexing = false
    @Published var artworkImage: NSImage?
    @Published var isRefreshingArtwork = false
    @Published var isShowingSettings = false
    @Published var isShowingYouTubeDownload = false
    @Published var isAuthorizingLastFM = false
    @Published var isSharingLibrary = false
    @Published var isDownloadingSharedLibrary = false
    @Published var librarySharingStatus = "Library sharing is off"
    @Published var librarySharingAddress = ""
    @Published private(set) var sharingTransferSnapshot: LibraryTransferQueueSnapshot = .empty
    @Published private(set) var downloadTransferSnapshot: LibraryTransferQueueSnapshot = .empty
    @Published var isDownloadingFromYouTube = false
    @Published var youtubeDownloadStatus = "Paste one or more YouTube links."
    @Published var youtubeDownloadItems: [YouTubeDownloadItem] = []
    @Published private(set) var cachedAlbumGroups: [AlbumGroup] = []
    let artworkStore = AlbumArtworkStore()

    /// `AlbumArtworkIdentity` key for `artworkImage`; avoids refetch when switching tracks on the same album.
    private var loadedArtworkAlbumKey: String?
    private var albumArtworkLoadTasks: [String: Task<Void, Never>] = [:]
    private var albumArtworkWarmTask: Task<Void, Never>?

    private let playbackEngine = AudioPlaybackEngine()
    private var progressTimer: Timer?
    private var reindexTimer: Timer?
    private var indexPersistenceGeneration: UInt64 = 0
    private var index = LibraryIndex(version: LibraryIndex.currentVersion, roots: [], tracks: [], updatedAt: .distantPast)
    private let indexer = LibraryIndexer()
    private let artworkProvider = ArtworkProvider()
    private let fileMetadataWriter = FileMetadataWriter()
    private let userSettingsStore = UserSettingsStore()
    private let playCountStore = PlayCountStore()
    private let playlistStore = PlaylistStore()
    private let lastFMScrobbler = LastFMScrobbler()
    private let librarySharingService = LibrarySharingService()
    private let librarySharingClient = LibrarySharingClient()
    private let youtubeDownloadService = YouTubeDownloadService()
    @Published private(set) var playCounts: [String: Int] = [:]
    private var libraryCatalog: [Track] = []

    private var listenedSecondsThisTrack: TimeInterval = 0
    private var playbackTickAnchor: Date?
    private var creditedPlayForCurrentTrackLoad = false
    private var playbackStartedAtForCurrentTrack: Date?
    private var sentNowPlayingForCurrentTrackLoad = false
    private var submittedScrobbleForCurrentTrackLoad = false

    override init() {
        super.init()
        playbackEngine.onPlaybackFinished = { [weak self] in
            self?.nextTrack()
        }
        applySearchFilter()
        playCounts = playCountStore.load()
        savedPlaylists = playlistStore.load().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        applyLoadedUserSettings(userSettingsStore.load())
        Task { await loadIndexOnLaunch() }
        startReindexScheduler()
    }

    deinit {
        Task { [librarySharingService] in
            await librarySharingService.stop()
        }
    }

    var currentUserSettings: UserSettings {
        userSettings
    }

    var equalizer: EqualizerSettings {
        userSettings.equalizer
    }

    func setEqualizerEnabled(_ isEnabled: Bool) {
        updateUserSettings { $0.equalizer.isEnabled = isEnabled }
    }

    func setEqualizerPreamp(_ value: Float) {
        updateUserSettings { $0.equalizer.setPreamp(value) }
    }

    func setEqualizerBandGain(_ gain: Float, atBandIndex index: Int) {
        updateUserSettings { $0.equalizer.setGain(gain, atBandIndex: index) }
    }

    func applyEqualizerPreset(_ preset: EqualizerPreset) {
        updateUserSettings { $0.equalizer.apply(preset: preset) }
    }

    func resetEqualizer() {
        updateUserSettings { $0.equalizer.apply(preset: .flat) }
    }

    var canBeginLastFMAuthorization: Bool {
        !userSettings.lastFMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canShareLibrary: Bool {
        !libraryRoots.isEmpty
    }

    private var lastFMCredentials: LastFMCredentials? {
        guard userSettings.lastFMScrobblingEnabled else { return nil }
        let apiKey = userSettings.lastFMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiSecret = userSettings.lastFMAPISecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionKey = userSettings.lastFMSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !apiSecret.isEmpty, !sessionKey.isEmpty else { return nil }
        return LastFMCredentials(apiKey: apiKey, apiSecret: apiSecret, sessionKey: sessionKey)
    }

    func beginLastFMAuthorization() {
        let apiKey = userSettings.lastFMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiSecret = userSettings.lastFMAPISecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !apiSecret.isEmpty else {
            errorMessage = "Enter your Last.fm API key and shared secret before connecting."
            return
        }
        guard !isAuthorizingLastFM else { return }
        isAuthorizingLastFM = true

        Task { [lastFMScrobbler] in
            do {
                let token = try await lastFMScrobbler.fetchAuthorizationToken(apiKey: apiKey)
                let authURL = try Self.makeLastFMAuthorizationURL(apiKey: apiKey, token: token)
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)

                    if NSWorkspace.shared.open(authURL) {
                        self.errorMessage = "Opened Last.fm authorization. Waiting for approval..."
                    } else {
                        self.errorMessage = "Got Last.fm token, but could not open browser. Token copied to clipboard."
                    }
                }

                let session = try await waitForLastFMSession(
                    token: token,
                    apiKey: apiKey,
                    apiSecret: apiSecret,
                    scrobbler: lastFMScrobbler
                )

                await MainActor.run {
                    self.updateUserSettings { settings in
                        settings.lastFMSessionKey = session.key
                        settings.lastFMScrobblingEnabled = true
                        if settings.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            settings.username = session.name
                        }
                    }
                    self.errorMessage = "Connected Last.fm as \(session.name). Scrobbling is enabled."
                    self.isAuthorizingLastFM = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isAuthorizingLastFM = false
                }
            }
        }
    }

    private func waitForLastFMSession(
        token: String,
        apiKey: String,
        apiSecret: String,
        scrobbler: LastFMScrobbler
    ) async throws -> LastFMSession {
        let attempts = 60
        for attempt in 0..<attempts {
            do {
                return try await scrobbler.fetchSession(apiKey: apiKey, apiSecret: apiSecret, token: token)
            } catch let LastFMError.api(code, _) where code == 14 {
                if attempt < attempts - 1 {
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
            }
        }
        throw LastFMError.api(code: 14, message: "Authorization timed out. Approve in browser and try again.")
    }

    private static func makeLastFMAuthorizationURL(apiKey: String, token: String) throws -> URL {
        var components = URLComponents(string: "https://www.last.fm/api/auth/")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token),
        ]
        guard let url = components.url else {
            throw LastFMError.invalidRequest
        }
        return url
    }

    private func applyLoadedUserSettings(_ settings: UserSettings) {
        applyUserSettings(settings, persist: false)
    }

    func binding<Value>(for value: UserSettingValue<Value>) -> Binding<Value> {
        Binding(
            get: { value.get(self.userSettings) },
            set: { newValue in
                self.updateUserSettings { settings in
                    value.set(&settings, newValue)
                }
            }
        )
    }

    func settingBinding<Value>(_ keyPath: WritableKeyPath<UserSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.userSettings[keyPath: keyPath] },
            set: { self.updateUserSetting(keyPath, to: $0) }
        )
    }

    private func updateUserSetting<Value>(_ keyPath: WritableKeyPath<UserSettings, Value>, to value: Value) {
        updateUserSettings { $0[keyPath: keyPath] = value }
    }

    private func updateUserSettings(_ update: (inout UserSettings) -> Void) {
        var settings = userSettings
        update(&settings)
        applyUserSettings(settings, persist: true)
    }

    private func applyUserSettings(_ settings: UserSettings, persist: Bool) {
        let previousSortOption = userSettings.librarySortOption
        let previousSharingPort = userSettings.librarySharingPort
        var settings = settings
        settings.version = UserSettings.currentVersion

        userSettings = settings
        playbackEngine.volume = settings.volume
        playbackEngine.applyEqualizer(settings.equalizer)

        if previousSortOption != settings.librarySortOption {
            rebuildDisplayedPlaylist()
        }

        if previousSharingPort != settings.librarySharingPort, isSharingLibrary {
            stopLibrarySharing()
            startLibrarySharing()
        }

        if persist {
            userSettingsStore.save(settings)
        }
    }

    var currentTrack: Track? {
        guard let currentIndex else { return nil }
        guard playlist.indices.contains(currentIndex) else { return nil }
        return playlist[currentIndex]
    }

    var hasActiveSearch: Bool {
        !normalizedSearchQuery.isEmpty
    }

    var isViewingSavedPlaylist: Bool {
        selectedPlaylistID != nil
    }

    var selectedPlaylistName: String {
        guard let selectedPlaylistID,
              let playlist = savedPlaylists.first(where: { $0.id == selectedPlaylistID }) else {
            return "All Songs"
        }
        return playlist.name
    }

    func playCount(for track: Track) -> Int {
        playCounts[FilePathNormalization.canonical(track.url.path)] ?? 0
    }

    var groupedLibrary: [LibraryGroup] {
        switch libraryGrouping {
        case .all:
            return [LibraryGroup(name: "All Tracks", tracks: playlist)]
        case .artist:
            return groupsBy(\.artist)
        case .genre:
            return groupsBy(\.genre)
        }
    }

    var albumGroups: [AlbumGroup] {
        cachedAlbumGroups
    }

    func warmAlbumArtworkFromDisk(for groups: [AlbumGroup]) {
        albumArtworkWarmTask?.cancel()
        let missingGroups = groups.filter { !artworkStore.contains(key: $0.id) }
        guard !missingGroups.isEmpty else { return }

        albumArtworkWarmTask = Task { [artworkProvider, artworkStore] in
            var loaded: [String: NSImage] = [:]
            loaded.reserveCapacity(missingGroups.count)

            await withTaskGroup(of: (String, NSImage?).self) { taskGroup in
                for group in missingGroups {
                    if Task.isCancelled { return }
                    let key = group.id
                    let track = group.representativeTrack
                    taskGroup.addTask {
                        guard let data = await artworkProvider.cachedArtworkData(for: track) else {
                            return (key, nil)
                        }
                        return (key, AlbumCoverImage.thumbnail(from: data))
                    }
                }

                for await (key, image) in taskGroup {
                    if let image {
                        loaded[key] = image
                    }
                }
            }

            guard !Task.isCancelled, !loaded.isEmpty else { return }
            await MainActor.run {
                artworkStore.mergeImages(loaded)
            }
        }
    }

    func loadAlbumArtwork(for group: AlbumGroup) {
        let key = group.id
        guard !artworkStore.contains(key: key) else { return }
        guard albumArtworkLoadTasks[key] == nil else { return }

        let track = group.representativeTrack
        albumArtworkLoadTasks[key] = Task { [artworkProvider, artworkStore] in
            if let data = await artworkProvider.cachedArtworkData(for: track),
               let image = AlbumCoverImage.thumbnail(from: data) {
                await MainActor.run {
                    self.albumArtworkLoadTasks[key] = nil
                    artworkStore.setImage(image, for: key)
                }
                return
            }

            let data = await artworkProvider.artworkData(for: track)
            let image = data.flatMap { AlbumCoverImage.thumbnail(from: $0) }
            await MainActor.run {
                self.albumArtworkLoadTasks[key] = nil
                if let image {
                    artworkStore.setImage(image, for: key)
                }
            }
        }
    }

    func prefetchAlbumArtwork(around index: Int, in groups: [AlbumGroup]) {
        guard !groups.isEmpty else { return }
        let neighborIndexes = [index - 4, index - 3, index - 2, index - 1, index, index + 1, index + 2, index + 3, index + 4]
        for neighborIndex in neighborIndexes where groups.indices.contains(neighborIndex) {
            loadAlbumArtwork(for: groups[neighborIndex])
        }
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.title = "Choose audio files"

        guard panel.runModal() == .OK else { return }

        let tracks = panel.urls.map(trackFromURL)
        guard !tracks.isEmpty else {
            errorMessage = "No audio files were selected."
            return
        }

        let shouldAutoPlayFirstTrack = playlist.isEmpty && currentTrack == nil
        mergeTracksIntoLibraryCatalog(tracks)
        rebuildDisplayedPlaylist()

        if shouldAutoPlayFirstTrack, !playlist.isEmpty {
            loadTrack(at: 0)
            play()
        }
    }

    func addLibraryFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.title = "Choose Library Folders"

        guard panel.runModal() == .OK else { return }

        var added = false
        for url in panel.urls {
            let path = FilePathNormalization.canonical(url.path)
            if !libraryRoots.contains(where: { FilePathNormalization.pathsMatch($0, path) }) {
                libraryRoots.append(path)
                added = true
            }
        }

        if added {
            libraryRoots.sort()
            scheduleReindex(reason: "Scanning newly added folders")
        }
    }

    func removeLibraryRoot(_ path: String) {
        let root = FilePathNormalization.canonical(path)
        libraryRoots.removeAll { FilePathNormalization.pathsMatch($0, root) }
        index.roots.removeAll { FilePathNormalization.pathsMatch($0.path, root) }
        index.tracks.removeAll { track in
            FilePathNormalization.isUnderLibraryRoot(track.path, libraryRoot: root)
        }
        index.manualEdits = index.manualEdits.filter { _, track in
            !FilePathNormalization.isUnderLibraryRoot(track.path, libraryRoot: root)
        }
        applyIndexedTracks(index.tracks)
        persistCurrentIndex()
    }

    func startLibrarySharing() {
        guard !isSharingLibrary else { return }
        guard !libraryRoots.isEmpty else {
            errorMessage = "Add a library folder before starting library sharing."
            return
        }

        let rawPort = userSettings.librarySharingPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(rawPort), (1024 ... 65535).contains(port) else {
            errorMessage = LibrarySharingError.invalidPort.localizedDescription
            return
        }

        librarySharingStatus = "Starting rsync sharing..."
        sharingTransferSnapshot = .empty

        let roots = libraryRoots
        Task { [librarySharingService] in
            let rsyncAvailable = await librarySharingService.isRsyncAvailable()
            guard rsyncAvailable else {
                await MainActor.run {
                    self.errorMessage = LibrarySharingError.rsyncNotFound.localizedDescription
                    self.librarySharingStatus = "Library sharing is off"
                }
                return
            }

            do {
                let endpoint = try await librarySharingService.start(port: port, roots: roots)
                let snapshot = await librarySharingService.sharingTransferSnapshot()
                await MainActor.run {
                    self.isSharingLibrary = true
                    self.librarySharingAddress = endpoint
                    self.sharingTransferSnapshot = snapshot
                    self.updateLibrarySharingStatusLine()
                    self.indexStatus = "Library sharing is active (rsync)"
                }
            } catch {
                await MainActor.run {
                    self.isSharingLibrary = false
                    self.librarySharingAddress = ""
                    self.librarySharingStatus = "Library sharing is off"
                    self.errorMessage = "Could not start sharing: \(error.localizedDescription)"
                }
            }
        }
    }

    func stopLibrarySharing() {
        guard isSharingLibrary else { return }
        Task { [librarySharingService] in
            await librarySharingService.stop()
            await MainActor.run {
                self.isSharingLibrary = false
                self.librarySharingAddress = ""
                self.librarySharingStatus = "Library sharing is off"
                self.sharingTransferSnapshot = .empty
                self.indexStatus = "Stopped library sharing"
            }
        }
    }

    func copyLibrarySharingAddressToClipboard() {
        guard !librarySharingAddress.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(librarySharingAddress, forType: .string)
        indexStatus = "Copied share address"
    }

    func promptToDownloadSharedLibrary() {
        guard !isDownloadingSharedLibrary else { return }

        let alert = NSAlert()
        alert.messageText = "Download Shared Library"
        alert.informativeText = "Enter the rsync address from the other user, for example rsync://192.168.1.42:873/"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "rsync://host:port/"
        field.stringValue = "rsync://192.168.1.42:\(userSettings.librarySharingPort)/"
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            errorMessage = "Enter an address to download from."
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose where to save the downloaded library"
        panel.prompt = "Choose Folder"

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        downloadSharedLibrary(from: address, destinationRoot: destination)
    }

    func isYouTubeDownloadAvailable() async -> Bool {
        await youtubeDownloadService.isYTDLPAvailable()
    }

    func downloadFromYouTube(urlText: String) {
        guard !isDownloadingFromYouTube else { return }

        let urls = YouTubeDownloadService.normalizeURLs([urlText])
        guard !urls.isEmpty else {
            youtubeDownloadStatus = "Enter at least one valid YouTube URL."
            errorMessage = "Enter at least one valid YouTube URL."
            return
        }

        isDownloadingFromYouTube = true
        youtubeDownloadItems = urls.map {
            YouTubeDownloadItem(
                id: $0,
                title: $0,
                phase: .queued,
                progress: nil,
                downloadedPath: nil,
                errorMessage: nil
            )
        }
        youtubeDownloadStatus = "Starting download..."
        indexStatus = "Downloading from YouTube..."

        Task { [youtubeDownloadService] in
            do {
                let result = try await youtubeDownloadService.download(urls: urls) { update in
                    await MainActor.run {
                        if let index = self.youtubeDownloadItems.firstIndex(where: { $0.id == update.url }) {
                            self.youtubeDownloadItems[index].title = update.title
                            self.youtubeDownloadItems[index].phase = update.phase
                            self.youtubeDownloadItems[index].progress = update.progress
                            self.youtubeDownloadItems[index].downloadedPath = update.downloadedPath
                            self.youtubeDownloadItems[index].errorMessage = update.errorMessage
                        }

                        switch update.phase {
                        case .queued:
                            self.youtubeDownloadStatus = "Queued: \(update.title)"
                        case .downloading:
                            if let progress = update.progress {
                                self.youtubeDownloadStatus = "Downloading \(update.title) — \(Int(progress * 100))%"
                            } else {
                                self.youtubeDownloadStatus = "Downloading \(update.title)..."
                            }
                        case .completed:
                            self.youtubeDownloadStatus = "Downloaded: \(update.title)"
                        case .skipped:
                            self.youtubeDownloadStatus = "Already downloaded: \(update.title)"
                        case .failed:
                            self.youtubeDownloadStatus = "Failed: \(update.errorMessage ?? update.title)"
                        }
                    }
                }

                await MainActor.run {
                    self.isDownloadingFromYouTube = false
                    self.ensureYouTubeLibraryRoot(result.downloadRoot.path)

                    let failedCount = self.youtubeDownloadItems.filter { $0.phase == .failed }.count
                    if result.downloadedFiles.isEmpty, result.skippedCount > 0, failedCount == 0 {
                        self.youtubeDownloadStatus = "All \(result.skippedCount) track(s) were already in your library."
                        self.indexStatus = "YouTube downloads up to date"
                    } else if failedCount > 0, result.downloadedFiles.isEmpty {
                        self.youtubeDownloadStatus = "All downloads failed."
                        self.indexStatus = "YouTube download failed"
                    } else {
                        var message = "Added \(result.downloadedFiles.count) track(s) to your library."
                        if result.skippedCount > 0 {
                            message += " Skipped \(result.skippedCount) existing."
                        }
                        if failedCount > 0 {
                            message += " \(failedCount) failed."
                        }
                        self.youtubeDownloadStatus = message
                        self.indexStatus = "Downloaded \(result.downloadedFiles.count) track(s) from YouTube"
                    }

                    if !result.downloadedFiles.isEmpty || result.skippedCount > 0 {
                        self.scheduleReindex(reason: "Indexing YouTube downloads", forceFullRebuild: true)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isDownloadingFromYouTube = false
                    self.youtubeDownloadStatus = error.localizedDescription
                    self.errorMessage = "YouTube download failed: \(error.localizedDescription)"
                    self.indexStatus = "YouTube download failed"
                }
            }
        }
    }

    private func ensureYouTubeLibraryRoot(_ path: String) {
        let root = FilePathNormalization.canonical(path)
        guard !libraryRoots.contains(where: { FilePathNormalization.pathsMatch($0, root) }) else { return }
        libraryRoots.append(root)
        libraryRoots.sort()
    }

    private func downloadSharedLibrary(from address: String, destinationRoot: URL) {
        guard !isDownloadingSharedLibrary else { return }
        isDownloadingSharedLibrary = true
        downloadTransferSnapshot = .empty
        indexStatus = "Downloading shared library via rsync..."

        Task { [librarySharingClient, librarySharingService] in
            let rsyncAvailable = await librarySharingService.isRsyncAvailable()
            guard rsyncAvailable else {
                await MainActor.run {
                    self.isDownloadingSharedLibrary = false
                    self.errorMessage = LibrarySharingError.rsyncNotFound.localizedDescription
                    self.indexStatus = "Shared library download failed"
                }
                return
            }

            do {
                let result = try await librarySharingClient.downloadLibrary(
                    from: address,
                    to: destinationRoot
                ) { snapshot in
                    await MainActor.run {
                        self.downloadTransferSnapshot = snapshot
                    }
                }
                await MainActor.run {
                    self.isDownloadingSharedLibrary = false
                    let importedPath = FilePathNormalization.canonical(result.importedRoot.path)
                    if !self.libraryRoots.contains(where: { FilePathNormalization.pathsMatch($0, importedPath) }) {
                        self.libraryRoots.append(importedPath)
                        self.libraryRoots.sort()
                    }
                    self.indexStatus = "Downloaded \(result.downloadedTracks) tracks from \(address)"
                    self.scheduleReindex(reason: "Indexing downloaded shared library", forceFullRebuild: true)
                }
            } catch {
                await MainActor.run {
                    self.isDownloadingSharedLibrary = false
                    self.errorMessage = "Download failed: \(error.localizedDescription)"
                    self.indexStatus = "Shared library download failed"
                }
            }
        }
    }

    func selectPlaylist(_ playlistID: SavedPlaylist.ID?) {
        selectedPlaylistID = playlistID
        rebuildDisplayedPlaylist()
    }

    func promptToCreatePlaylist(with tracks: [Track]) {
        let uniquePaths = Array(Set(tracks.map { canonicalTrackPath(for: $0) })).sorted()
        guard !uniquePaths.isEmpty else {
            errorMessage = "Select one or more songs to create a playlist."
            return
        }

        let alert = NSAlert()
        alert.messageText = "Create Playlist"
        alert.informativeText = "Choose a name for your new playlist."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Playlist name"
        field.stringValue = "New Playlist"
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Playlist name cannot be empty."
            return
        }

        if savedPlaylists.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            errorMessage = "A playlist named \"\(name)\" already exists."
            return
        }

        let playlist = SavedPlaylist(name: name, trackPaths: uniquePaths)
        savedPlaylists.append(playlist)
        sortAndPersistPlaylists()
        selectedPlaylistID = playlist.id
        rebuildDisplayedPlaylist()
    }

    func addTracksToSelectedPlaylist(_ tracks: [Track]) {
        guard let selectedPlaylistID,
              let index = savedPlaylists.firstIndex(where: { $0.id == selectedPlaylistID }) else {
            errorMessage = "Select a playlist first."
            return
        }

        let additions = Set(tracks.map { canonicalTrackPath(for: $0) })
        guard !additions.isEmpty else { return }

        let existing = Set(savedPlaylists[index].trackPaths.map(FilePathNormalization.canonical))
        let merged = Array(existing.union(additions)).sorted()
        savedPlaylists[index].trackPaths = merged
        savedPlaylists[index].updatedAt = Date()
        sortAndPersistPlaylists()
        rebuildDisplayedPlaylist()
    }

    func addTracks(_ tracks: [Track], to playlistID: SavedPlaylist.ID) {
        guard let index = savedPlaylists.firstIndex(where: { $0.id == playlistID }) else {
            errorMessage = "Playlist could not be found."
            return
        }

        let additions = Set(tracks.map { canonicalTrackPath(for: $0) })
        guard !additions.isEmpty else {
            errorMessage = "Select one or more songs to add."
            return
        }

        let existing = Set(savedPlaylists[index].trackPaths.map(FilePathNormalization.canonical))
        let merged = Array(existing.union(additions)).sorted()
        savedPlaylists[index].trackPaths = merged
        savedPlaylists[index].updatedAt = Date()
        sortAndPersistPlaylists()
        rebuildDisplayedPlaylist()
    }

    func removeTracksFromSelectedPlaylist(_ tracks: [Track]) {
        guard let selectedPlaylistID,
              let index = savedPlaylists.firstIndex(where: { $0.id == selectedPlaylistID }) else {
            return
        }

        let removals = Set(tracks.map { canonicalTrackPath(for: $0) })
        guard !removals.isEmpty else { return }

        savedPlaylists[index].trackPaths.removeAll { removals.contains(FilePathNormalization.canonical($0)) }
        savedPlaylists[index].updatedAt = Date()
        sortAndPersistPlaylists()
        rebuildDisplayedPlaylist()
    }

    func deletePlaylist(_ playlist: SavedPlaylist) {
        savedPlaylists.removeAll { $0.id == playlist.id }
        if selectedPlaylistID == playlist.id {
            selectedPlaylistID = nil
        }
        sortAndPersistPlaylists()
        rebuildDisplayedPlaylist()
    }

    func executePlaylistScript(_ script: String) -> String {
        let lines = script
            .components(separatedBy: .newlines)
            .enumerated()
            .compactMap { index, rawLine -> (Int, String)? in
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("--") else { return nil }
                return (index + 1, trimmed)
            }

        guard !lines.isEmpty else {
            return "No commands to run."
        }

        var output: [String] = []
        var successCount = 0

        for (lineNumber, line) in lines {
            do {
                let result = try executePlaylistScriptCommand(line)
                output.append("OK line \(lineNumber): \(result)")
                successCount += 1
            } catch {
                output.append("ERR line \(lineNumber): \(error.localizedDescription)")
            }
        }

        if successCount == 0 {
            errorMessage = "No commands succeeded."
        } else {
            errorMessage = nil
        }

        return output.joined(separator: "\n")
    }

    private func executePlaylistScriptCommand(_ line: String) throws -> String {
        if let playlistName = scriptCapture(
            in: line,
            pattern: #"^NEW\s+PLAYLIST\s*\(\s*'([^']+)'\s*\)\s*$"#,
            group: 1
        ) {
            let id = createPlaylistIfMissing(named: playlistName)
            selectedPlaylistID = id
            rebuildDisplayedPlaylist()
            return "Playlist '\(playlistName)' is ready."
        }

        if let artist = scriptCapture(
            in: line,
            pattern: #"^INSERT\s+LIBRARY\.BYARTIST\s*\(\s*'([^']+)'\s*\)\s+INTO\s+PLAYLIST\s*\(\s*'([^']+)'\s*\)\s*$"#,
            group: 1
        ), let playlistName = scriptCapture(
            in: line,
            pattern: #"^INSERT\s+LIBRARY\.BYARTIST\s*\(\s*'([^']+)'\s*\)\s+INTO\s+PLAYLIST\s*\(\s*'([^']+)'\s*\)\s*$"#,
            group: 2
        ) {
            return try insertLibraryByArtist(artist: artist, intoPlaylistNamed: playlistName)
        }

        throw PlaylistScriptError.unsupportedCommand
    }

    private func scriptCapture(in line: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > group,
              let captured = Range(match.range(at: group), in: line)
        else {
            return nil
        }
        return String(line[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createPlaylistIfMissing(named rawName: String) -> SavedPlaylist.ID {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = savedPlaylists.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return existing.id
        }
        let playlist = SavedPlaylist(name: name, trackPaths: [])
        savedPlaylists.append(playlist)
        sortAndPersistPlaylists()
        return playlist.id
    }

    private func insertLibraryByArtist(artist rawArtist: String, intoPlaylistNamed rawPlaylistName: String) throws -> String {
        let artist = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlistName = rawPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !playlistName.isEmpty else {
            throw PlaylistScriptError.invalidArguments
        }

        let matches = libraryCatalog.filter {
            $0.artist.localizedCaseInsensitiveCompare(artist) == .orderedSame
        }
        guard !matches.isEmpty else {
            throw PlaylistScriptError.artistNotFound(artist)
        }

        let playlistID = createPlaylistIfMissing(named: playlistName)
        addTracks(matches, to: playlistID)
        selectedPlaylistID = playlistID
        rebuildDisplayedPlaylist()
        return "Inserted \(matches.count) track(s) by '\(artist)' into '\(playlistName)'."
    }

    func playPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard playbackEngine.hasLoadedTrack else {
            if !playlist.isEmpty, currentIndex == nil {
                loadTrack(at: 0)
                play()
            }
            return
        }
        if playbackStartedAtForCurrentTrack == nil {
            playbackStartedAtForCurrentTrack = Date()
        }
        playbackEngine.play()
        isPlaying = true
        startProgressTimer()
        submitNowPlayingIfNeeded()
    }

    func pause() {
        playbackEngine.pause()
        isPlaying = false
        playbackTickAnchor = nil
        stopProgressTimer()
    }

    func nextTrack() {
        guard let currentIndex else { return }
        let next = currentIndex + 1
        guard playlist.indices.contains(next) else {
            pause()
            return
        }
        loadTrack(at: next)
        play()
    }

    func previousTrack() {
        guard let currentIndex else { return }
        if currentTime > 2 {
            seek(to: 0)
            return
        }
        let previous = currentIndex - 1
        guard playlist.indices.contains(previous) else { return }
        loadTrack(at: previous)
        play()
    }

    func selectTrack(_ track: Track) {
        guard let idx = playlist.firstIndex(where: { $0.url == track.url }) else { return }
        loadTrack(at: idx)
        play()
    }

    func seek(to value: TimeInterval) {
        guard playbackEngine.hasLoadedTrack else { return }
        playbackEngine.seek(to: value)
        currentTime = playbackEngine.currentTime
    }

    func forceRefreshArtwork() {
        guard let track = currentTrack else { return }
        loadedArtworkAlbumKey = nil
        artworkImage = nil
        isRefreshingArtwork = true

        Task { [artworkProvider] in
            let data = await artworkProvider.refreshArtworkData(for: track)
            let image = data.flatMap(NSImage.init(data:))
            let albumKey = AlbumArtworkIdentity.normalizedKey(artist: track.artist, album: track.album)

            await MainActor.run {
                if self.currentTrack?.url == track.url {
                    self.artworkImage = image
                    self.loadedArtworkAlbumKey = image != nil ? albumKey : nil
                }
                self.isRefreshingArtwork = false
            }
        }
    }

    func updateMetadata(for track: Track, title: String, artist: String, album: String, genre: String) {
        updateMetadata(for: [track], title: title, artist: artist, album: album, genre: genre)
    }

    func updateMetadata(for tracks: [Track], title: String?, artist: String?, album: String?, genre: String?) {
        let urls = Set(tracks.map(\.url))
        guard !urls.isEmpty else { return }
        let currentURL = currentTrack?.url
        var updatedCurrentTrack: Track?
        var updatedTracksForDisk: [Track] = []
        let fileUpdate = FileMetadataUpdate(title: title, artist: artist, album: album, genre: genre)

        for index in libraryCatalog.indices {
            let original = libraryCatalog[index]
            guard urls.contains(original.url) else { continue }

            let updatedTrack = Track(
                url: original.url,
                title: title.map { cleaned($0, fallback: original.title) } ?? original.title,
                artist: artist.map { cleaned($0, fallback: original.artist) } ?? original.artist,
                album: album.map { cleaned($0, fallback: original.album) } ?? original.album,
                genre: genre.map { cleaned($0, fallback: original.genre) } ?? original.genre,
                trackNumber: original.trackNumber,
                fidelityLabel: original.fidelityLabel
            )

            libraryCatalog[index] = updatedTrack
            updatedTracksForDisk.append(updatedTrack)
            let pathForIndex = FilePathNormalization.canonical(updatedTrack.url.path)
            let indexedTrack = IndexedTrack(
                path: pathForIndex,
                title: updatedTrack.title,
                artist: updatedTrack.artist,
                album: updatedTrack.album,
                genre: updatedTrack.genre,
                trackNumber: updatedTrack.trackNumber,
                fidelityLabel: updatedTrack.fidelityLabel
            )
            self.index.tracks.removeAll { FilePathNormalization.pathsMatch($0.path, pathForIndex) }
            self.index.tracks.append(indexedTrack)
            self.index.manualEdits[pathForIndex] = indexedTrack

            if updatedTrack.url == currentURL {
                updatedCurrentTrack = updatedTrack
            }
        }

        self.index.tracks.sort { lhs, rhs in
            lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
                || (lhs.artist == rhs.artist && lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending)
        }

        rebuildDisplayedPlaylist()
        persistCurrentIndex()
        writeMetadataToFiles(update: fileUpdate, tracks: updatedTracksForDisk)
        if let updatedCurrentTrack {
            refreshArtwork(for: updatedCurrentTrack)
        }
    }

    private func loadTrack(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        let track = playlist[index]
        resetPlayCountSessionState()
        resetScrobbleSessionState()
        do {
            try playbackEngine.load(url: track.url)
            playbackEngine.volume = volume
            playbackEngine.applyEqualizer(userSettings.equalizer)
            currentIndex = index
            duration = max(playbackEngine.duration, 1)
            currentTime = 0
            errorMessage = nil
            refreshArtwork(for: track)
        } catch {
            errorMessage = "Unable to play \(track.url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private static func buildAlbumGroups(from tracks: [Track], sortedBy sortOption: LibrarySortOption) -> [AlbumGroup] {
        let grouped = Dictionary(grouping: tracks) { track in
            AlbumArtworkIdentity.normalizedKey(artist: track.artist, album: track.album)
        }

        let groups = grouped.values.compactMap { albumTracks -> AlbumGroup? in
            guard !albumTracks.isEmpty else { return nil }
            let sortedTracks = albumTracks.sorted { lhs, rhs in
                let leftNumber = lhs.trackNumber ?? Int.max
                let rightNumber = rhs.trackNumber ?? Int.max
                if leftNumber != rightNumber { return leftNumber < rightNumber }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            let representative = sortedTracks[0]
            return AlbumGroup(
                artist: representative.artist,
                album: representative.album,
                tracks: sortedTracks
            )
        }

        return groups.sorted { lhs, rhs in
            switch sortOption {
            case .artist:
                if lhs.artist != rhs.artist {
                    return lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
                }
                return lhs.album.localizedCaseInsensitiveCompare(rhs.album) == .orderedAscending
            case .album, .title, .genre:
                return lhs.album.localizedCaseInsensitiveCompare(rhs.album) == .orderedAscending
            }
        }
    }

    private func groupsBy(_ keyPath: KeyPath<Track, String>) -> [LibraryGroup] {
        let grouped = Dictionary(grouping: playlist) { track -> String in
            let value = track[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "Unknown" : value
        }

        return grouped
            .map { name, tracks in
                LibraryGroup(name: name, tracks: sortedTracks(tracks))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applySearchFilter() {
        let query = normalizedSearchQuery
        guard !query.isEmpty else {
            filteredPlaylist = playlist
            refreshCachedAlbumGroups()
            return
        }

        filteredPlaylist = playlist.filter { track in
            trackMatchesSearch(track, query: query)
        }
        refreshCachedAlbumGroups()
    }

    private func refreshCachedAlbumGroups() {
        let tracks = hasActiveSearch ? filteredPlaylist : playlist
        cachedAlbumGroups = Self.buildAlbumGroups(from: tracks, sortedBy: sortOption)
    }

    private func trackMatchesSearch(_ track: Track, query: String) -> Bool {
        let fields = [
            track.title,
            track.artist,
            track.album,
            track.genre,
            track.url.deletingPathExtension().lastPathComponent
        ]
        return fields.contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func rebuildDisplayedPlaylist() {
        let currentURL = currentTrack?.url
        let visibleTracks = tracksForSelectedPlaylist()
        playlist = sortedTracks(visibleTracks)

        if let currentURL,
           let index = playlist.firstIndex(where: { $0.url == currentURL }) {
            currentIndex = index
        } else if playlist.isEmpty {
            currentIndex = nil
            pause()
        } else if currentIndex == nil || !playlist.indices.contains(currentIndex ?? -1) {
            currentIndex = 0
        }
        refreshCachedAlbumGroups()
    }

    private func sortedTracks(_ tracks: [Track]) -> [Track] {
        tracks.sorted { lhs, rhs in
            switch sortOption {
            case .title:
                return compareTracks(lhs, rhs, primary: \.title)
            case .artist:
                return compareTracks(lhs, rhs, primary: \.artist)
            case .album:
                return compareTracks(lhs, rhs, primary: \.album)
            case .genre:
                return compareTracks(lhs, rhs, primary: \.genre)
            }
        }
    }

    private func tracksForSelectedPlaylist() -> [Track] {
        guard let selectedPlaylistID,
              let saved = savedPlaylists.first(where: { $0.id == selectedPlaylistID }) else {
            return libraryCatalog
        }
        let pathSet = Set(saved.trackPaths.map(FilePathNormalization.canonical))
        return libraryCatalog.filter { pathSet.contains(canonicalTrackPath(for: $0)) }
    }

    private func mergeTracksIntoLibraryCatalog(_ tracks: [Track]) {
        var mergedByPath: [String: Track] = Dictionary(
            uniqueKeysWithValues: libraryCatalog.map { (canonicalTrackPath(for: $0), $0) }
        )
        for track in tracks {
            mergedByPath[canonicalTrackPath(for: track)] = track
        }
        libraryCatalog = Array(mergedByPath.values)
        refreshLibrarySharingSnapshotIfNeeded()
    }

    private func canonicalTrackPath(for track: Track) -> String {
        FilePathNormalization.canonical(track.url.path)
    }

    private func refreshLibrarySharingSnapshotIfNeeded() {
        guard isSharingLibrary else { return }
        let roots = libraryRoots
        Task { [librarySharingService] in
            do {
                try await librarySharingService.updateSharedLibrary(roots: roots)
                let snapshot = await librarySharingService.sharingTransferSnapshot()
                await MainActor.run {
                    self.sharingTransferSnapshot = snapshot
                    self.updateLibrarySharingStatusLine()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Could not refresh library sharing: \(error.localizedDescription)"
                }
            }
        }
    }

    private func updateLibrarySharingStatusLine() {
        guard isSharingLibrary else {
            librarySharingStatus = "Library sharing is off"
            return
        }

        let moduleCount = sharingTransferSnapshot.upcoming.count
        if moduleCount > 0 {
            librarySharingStatus = "Sharing \(moduleCount) library folder\(moduleCount == 1 ? "" : "s") at \(librarySharingAddress)"
        } else {
            librarySharingStatus = "Sharing library at \(librarySharingAddress)"
        }
    }

    private func sortAndPersistPlaylists() {
        savedPlaylists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        playlistStore.save(savedPlaylists)
    }

    private func cleanupPlaylistsForAvailableTracks() {
        let availablePaths = Set(libraryCatalog.map(canonicalTrackPath(for:)))
        var changed = false

        for index in savedPlaylists.indices {
            let before = savedPlaylists[index].trackPaths
            let after = before.filter { availablePaths.contains(FilePathNormalization.canonical($0)) }
            if before != after {
                savedPlaylists[index].trackPaths = after
                savedPlaylists[index].updatedAt = Date()
                changed = true
            }
        }

        if changed {
            sortAndPersistPlaylists()
        }
    }

    private func compareTracks(_ lhs: Track, _ rhs: Track, primary: KeyPath<Track, String>) -> Bool {
        let comparisons: [ComparisonResult] = [
            lhs[keyPath: primary].localizedCaseInsensitiveCompare(rhs[keyPath: primary]),
            primary == \.album ? .orderedSame : lhs.album.localizedCaseInsensitiveCompare(rhs.album),
            compareTrackNumbers(lhs.trackNumber, rhs.trackNumber),
            lhs.title.localizedCaseInsensitiveCompare(rhs.title),
            lhs.artist.localizedCaseInsensitiveCompare(rhs.artist),
            lhs.url.path.localizedCaseInsensitiveCompare(rhs.url.path)
        ]

        return comparisons.first { $0 != .orderedSame } == .orderedAscending
    }

    private func compareTrackNumbers(_ lhs: Int?, _ rhs: Int?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (left?, right?) where left < right:
            return .orderedAscending
        case let (left?, right?) where left > right:
            return .orderedDescending
        case (_?, nil):
            return .orderedAscending
        case (nil, _?):
            return .orderedDescending
        default:
            return .orderedSame
        }
    }

    private func cleaned(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func writeMetadataToFiles(update: FileMetadataUpdate, tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        indexStatus = "Saving metadata to \(tracks.count) file(s)..."

        Task { [fileMetadataWriter] in
            let failures = await fileMetadataWriter.write(update: update, to: tracks)

            await MainActor.run {
                if failures.isEmpty {
                    self.indexStatus = "Saved metadata to \(tracks.count) file(s)"
                } else {
                    self.indexStatus = "Saved app metadata; \(failures.count) file write(s) failed"
                    self.errorMessage = failures.prefix(3).joined(separator: "\n")
                }
            }
        }
    }

    private func refreshArtwork(for track: Track) {
        let albumKey = AlbumArtworkIdentity.normalizedKey(artist: track.artist, album: track.album)
        if artworkImage != nil, loadedArtworkAlbumKey == albumKey {
            isRefreshingArtwork = false
            return
        }

        isRefreshingArtwork = true
        Task { [artworkProvider] in
            let data = await artworkProvider.artworkData(for: track)
            let image = data.flatMap(NSImage.init(data:))
            await MainActor.run {
                guard self.currentTrack?.url == track.url else { return }
                self.artworkImage = image
                self.loadedArtworkAlbumKey = image != nil ? albumKey : nil
                self.isRefreshingArtwork = false
            }
        }

        prefetchNeighborArtwork()
    }

    private func prefetchNeighborArtwork() {
        guard let idx = currentIndex else { return }
        let neighbors = [idx + 1, idx - 1].filter { playlist.indices.contains($0) }
        for neighborIndex in neighbors {
            let track = playlist[neighborIndex]
            Task(priority: .utility) { [artworkProvider] in
                _ = await artworkProvider.artworkData(for: track)
            }
        }
    }

    private func trackFromURL(_ url: URL) -> Track {
        let filename = url.deletingPathExtension().lastPathComponent
        if let separator = filename.range(of: " - ") {
            let artist = String(filename[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(filename[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty && !title.isEmpty {
                return Track(
                    url: url,
                    title: title,
                    artist: artist,
                    album: "Unknown Album",
                    genre: "Unknown Genre",
                    trackNumber: nil,
                    fidelityLabel: AudioFidelityFormatter.fallbackLabel(forExtension: url.pathExtension)
                )
            }
        }

        return Track(
            url: url,
            title: filename,
            artist: "Unknown Artist",
            album: "Unknown Album",
            genre: "Unknown Genre",
            trackNumber: nil,
            fidelityLabel: AudioFidelityFormatter.fallbackLabel(forExtension: url.pathExtension)
        )
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(refreshProgress), userInfo: nil, repeats: true)
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func resetPlayCountSessionState() {
        listenedSecondsThisTrack = 0
        playbackTickAnchor = nil
        creditedPlayForCurrentTrackLoad = false
    }

    private func resetScrobbleSessionState() {
        playbackStartedAtForCurrentTrack = nil
        sentNowPlayingForCurrentTrackLoad = false
        submittedScrobbleForCurrentTrackLoad = false
    }

    private func recordPlayIfEligible() {
        guard !creditedPlayForCurrentTrackLoad,
              listenedSecondsThisTrack >= PlayCountStore.secondsRequiredForOnePlay,
              let track = currentTrack
        else { return }
        creditedPlayForCurrentTrackLoad = true
        let path = FilePathNormalization.canonical(track.url.path)
        playCounts[path] = (playCounts[path] ?? 0) + 1
        playCountStore.save(playCounts)
    }

    private func submitNowPlayingIfNeeded() {
        guard !sentNowPlayingForCurrentTrackLoad,
              let credentials = lastFMCredentials,
              let track = currentTrack,
              playbackEngine.hasLoadedTrack
        else { return }

        sentNowPlayingForCurrentTrackLoad = true
        let trackDuration = playbackEngine.duration

        Task { [lastFMScrobbler] in
            do {
                try await lastFMScrobbler.updateNowPlaying(
                    credentials: credentials,
                    track: track,
                    duration: trackDuration
                )
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func submitScrobbleIfEligible() {
        guard !submittedScrobbleForCurrentTrackLoad,
              let credentials = lastFMCredentials,
              let track = currentTrack,
              let startedAt = playbackStartedAtForCurrentTrack,
              playbackEngine.hasLoadedTrack
        else { return }

        let trackDuration = max(playbackEngine.duration, 0)
        let threshold = max(30, min(trackDuration * 0.5, 240))
        guard listenedSecondsThisTrack >= threshold else { return }

        submittedScrobbleForCurrentTrackLoad = true
        Task { [lastFMScrobbler] in
            do {
                try await lastFMScrobbler.scrobble(
                    credentials: credentials,
                    track: track,
                    startedAt: startedAt,
                    duration: trackDuration
                )
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    @objc private func refreshProgress() {
        guard playbackEngine.hasLoadedTrack else { return }

        let now = Date()
        if let anchor = playbackTickAnchor {
            listenedSecondsThisTrack += now.timeIntervalSince(anchor)
            recordPlayIfEligible()
        }
        playbackTickAnchor = now

        currentTime = playbackEngine.currentTime
        duration = max(playbackEngine.duration, 1)
        submitScrobbleIfEligible()
    }

    private func startReindexScheduler() {
        reindexTimer?.invalidate()
        reindexTimer = Timer.scheduledTimer(timeInterval: 120, target: self, selector: #selector(triggerPeriodicReindex), userInfo: nil, repeats: true)
    }

    @objc private func triggerPeriodicReindex() {
        scheduleReindex(reason: "Background refresh")
    }

    private func loadIndexOnLaunch() async {
        var forceFullRebuild = false
        if let existing = await indexer.loadIndex() {
            libraryRoots = existing.roots.map { FilePathNormalization.canonical($0.path) }.sorted()

            if existing.version == LibraryIndex.currentVersion {
                var loadedIndex = existing
                loadedIndex.canonicalizeAllFilePaths()
                loadedIndex.applyManualEditsForExistingFiles()
                index = loadedIndex
                applyIndexedTracks(loadedIndex.tracks)
                indexStatus = "Loaded \(loadedIndex.tracks.count) tracks from index"
            } else {
                var loadedIndex = LibraryIndex(
                    version: LibraryIndex.currentVersion,
                    roots: existing.roots,
                    tracks: existing.tracks,
                    updatedAt: existing.updatedAt,
                    manualEdits: existing.manualEdits
                )
                loadedIndex.canonicalizeAllFilePaths()
                loadedIndex.applyManualEditsForExistingFiles()
                index = loadedIndex
                applyIndexedTracks(loadedIndex.tracks)
                forceFullRebuild = true
                indexStatus = "Metadata index upgraded; rebuilding library"
            }
        }

        let youtubeRoot = await youtubeDownloadService.downloadRootURL()
        let youtubePath = FilePathNormalization.canonical(youtubeRoot.path)
        if FileManager.default.fileExists(atPath: youtubePath) {
            ensureYouTubeLibraryRoot(youtubePath)
        }

        scheduleReindex(reason: "Checking for library changes", forceFullRebuild: forceFullRebuild)
    }

    /// Forces a full metadata read from disk for every library folder (same as a fingerprint miss on all roots).
    func rescanLibraryFromDisk() {
        scheduleReindex(reason: "Rescanning library from disk", forceFullRebuild: true)
    }

    private func scheduleReindex(reason: String, forceFullRebuild: Bool = false) {
        guard !isReindexing else { return }
        guard !libraryRoots.isEmpty else {
            indexStatus = "Add library folders to build your index"
            return
        }

        isReindexing = true
        indexStatus = reason

        let roots = libraryRoots
        let currentIndex = index

        Task.detached(priority: .utility) { [indexer] in
            var resultIndex = currentIndex
            var changed = 0

            for root in roots {
                let previous = resultIndex.roots.first { FilePathNormalization.pathsMatch($0.path, root) }
                let outcome = await indexer.scan(rootPath: root, previousRoot: previous, forceFullRebuild: forceFullRebuild)

                switch outcome {
                case .skippedUnchanged:
                    continue
                case let .rebuilt(newRootIndex, tracks):
                    changed += 1
                    resultIndex.roots.removeAll { FilePathNormalization.pathsMatch($0.path, root) }
                    resultIndex.roots.append(newRootIndex)
                    resultIndex.tracks.removeAll { FilePathNormalization.isUnderLibraryRoot($0.path, libraryRoot: root) }
                    resultIndex.tracks.append(contentsOf: tracks)
                }
            }

            // Do not save here: scans start from a snapshot; saving before merge would write
            // stale tracks/manualEdits and could race with persistCurrentIndex(), leaving disk
            // stuck on old metadata. finishReindex merges live manual edits then persists once.

            await MainActor.run {
                self.finishReindex(newIndex: resultIndex, changedRoots: changed)
            }
        }
    }

    private func finishReindex(newIndex: LibraryIndex, changedRoots: Int) {
        var mergedIndex = newIndex
        // Reindexing runs from a snapshot. If the user edits metadata while the
        // scan is in flight, keep the live manual edits instead of the stale scan.
        mergedIndex.manualEdits.merge(index.manualEdits) { _, liveEdit in liveEdit }
        mergedIndex.applyManualEditsForExistingFiles()

        index = mergedIndex
        applyIndexedTracks(mergedIndex.tracks)
        persistCurrentIndex()
        isReindexing = false

        if changedRoots == 0 {
            indexStatus = "Library up to date (\(playlist.count) tracks)"
        } else {
            indexStatus = "Reindexed \(changedRoots) folder(s), \(playlist.count) tracks available"
        }
    }

    private func applyIndexedTracks(_ entries: [IndexedTrack]) {
        libraryCatalog = entries.map {
            Track(
                url: URL(fileURLWithPath: $0.path),
                title: $0.title,
                artist: $0.artist,
                album: $0.album,
                genre: $0.genre,
                trackNumber: $0.trackNumber,
                fidelityLabel: $0.fidelityLabel
            )
        }
        cleanupPlaylistsForAvailableTracks()
        rebuildDisplayedPlaylist()
        refreshLibrarySharingSnapshotIfNeeded()
    }

    private func persistCurrentIndex() {
        indexPersistenceGeneration += 1
        let generation = indexPersistenceGeneration

        index.roots = libraryRoots.map { root in
            index.roots.first(where: { FilePathNormalization.pathsMatch($0.path, root) })
                ?? LibraryRootIndex(path: root, fingerprint: RootFingerprint(fileCount: 0, latestModificationTime: 0))
        }
        index.updatedAt = Date()

        let indexToSave = index
        Task.detached(priority: .utility) { [indexer] in
            await indexer.saveIndex(indexToSave, generation: generation)
        }
    }
}

private enum PlaylistScriptError: LocalizedError {
    case unsupportedCommand
    case invalidArguments
    case artistNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedCommand:
            return "Unsupported command. Try NEW PLAYLIST('Name') or INSERT Library.ByArtist('Artist') INTO Playlist('Name')."
        case .invalidArguments:
            return "Invalid arguments. Check quoted values."
        case let .artistNotFound(name):
            return "No library tracks found for artist '\(name)'."
        }
    }
}

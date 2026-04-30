import AppKit
import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PlayerViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playlist: [Track] = []
    @Published var currentIndex: Int?
    @Published var isPlaying = false
    @Published var duration: TimeInterval = 1
    @Published var currentTime: TimeInterval = 0
    @Published private var userSettings = UserSettings.default
    @Published var errorMessage: String?
    @Published var libraryRoots: [String] = []

    var volume: Float {
        get { userSettings.volume }
        set { updateUserSetting(\.volume, to: newValue) }
    }

    var username: String {
        get { userSettings.username }
        set { updateUserSetting(\.username, to: newValue) }
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

    /// `AlbumArtworkIdentity` key for `artworkImage`; avoids refetch when switching tracks on the same album.
    private var loadedArtworkAlbumKey: String?

    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private var reindexTimer: Timer?
    private var indexPersistenceGeneration: UInt64 = 0
    private var index = LibraryIndex(version: LibraryIndex.currentVersion, roots: [], tracks: [], updatedAt: .distantPast)
    private let indexer = LibraryIndexer()
    private let artworkProvider = ArtworkProvider()
    private let fileMetadataWriter = FileMetadataWriter()
    private let userSettingsStore = UserSettingsStore()
    private let playCountStore = PlayCountStore()
    @Published private(set) var playCounts: [String: Int] = [:]

    private var listenedSecondsThisTrack: TimeInterval = 0
    private var playbackTickAnchor: Date?
    private var creditedPlayForCurrentTrackLoad = false

    override init() {
        super.init()
        playCounts = playCountStore.load()
        applyLoadedUserSettings(userSettingsStore.load())
        Task { await loadIndexOnLaunch() }
        startReindexScheduler()
    }

    var currentUserSettings: UserSettings {
        userSettings
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
        var settings = settings
        settings.version = UserSettings.currentVersion

        userSettings = settings
        audioPlayer?.volume = settings.volume

        if previousSortOption != settings.librarySortOption {
            sortPlaylistPreservingCurrentTrack()
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

        if playlist.isEmpty {
            playlist = tracks
            sortPlaylistPreservingCurrentTrack()
            loadTrack(at: 0)
            play()
        } else {
            playlist.append(contentsOf: tracks)
            sortPlaylistPreservingCurrentTrack()
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

    func playPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let audioPlayer else {
            if !playlist.isEmpty, currentIndex == nil {
                loadTrack(at: 0)
                play()
            }
            return
        }
        audioPlayer.play()
        isPlaying = true
        startProgressTimer()
    }

    func pause() {
        audioPlayer?.pause()
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
        guard let audioPlayer else { return }
        audioPlayer.currentTime = max(0, min(value, audioPlayer.duration))
        currentTime = audioPlayer.currentTime
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

        for index in playlist.indices {
            let original = playlist[index]
            guard urls.contains(original.url) else { continue }

            let updatedTrack = Track(
                url: original.url,
                title: title.map { cleaned($0, fallback: original.title) } ?? original.title,
                artist: artist.map { cleaned($0, fallback: original.artist) } ?? original.artist,
                album: album.map { cleaned($0, fallback: original.album) } ?? original.album,
                genre: genre.map { cleaned($0, fallback: original.genre) } ?? original.genre
            )

            playlist[index] = updatedTrack
            updatedTracksForDisk.append(updatedTrack)
            let pathForIndex = FilePathNormalization.canonical(updatedTrack.url.path)
            let indexedTrack = IndexedTrack(
                path: pathForIndex,
                title: updatedTrack.title,
                artist: updatedTrack.artist,
                album: updatedTrack.album,
                genre: updatedTrack.genre
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

        sortPlaylistPreservingCurrentTrack()
        if let currentURL,
           let newIndex = playlist.firstIndex(where: { $0.url == currentURL }) {
            currentIndex = newIndex
        }
        persistCurrentIndex()
        writeMetadataToFiles(update: fileUpdate, tracks: updatedTracksForDisk)
        if let updatedCurrentTrack {
            refreshArtwork(for: updatedCurrentTrack)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.nextTrack()
        }
    }

    private func loadTrack(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        let track = playlist[index]
        resetPlayCountSessionState()
        do {
            let player = try AVAudioPlayer(contentsOf: track.url)
            player.delegate = self
            player.prepareToPlay()
            player.volume = volume
            audioPlayer = player
            currentIndex = index
            duration = max(player.duration, 1)
            currentTime = 0
            errorMessage = nil
            refreshArtwork(for: track)
        } catch {
            errorMessage = "Unable to play \(track.url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func groupsBy(_ keyPath: KeyPath<Track, String>) -> [LibraryGroup] {
        let grouped = Dictionary(grouping: playlist) { track -> String in
            let value = track[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "Unknown" : value
        }

        return grouped
            .map { name, tracks in
                LibraryGroup(name: name, tracks: tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func sortPlaylistPreservingCurrentTrack() {
        let currentURL = currentTrack?.url
        playlist.sort { lhs, rhs in
            switch sortOption {
            case .title:
                return compare(lhs.title, rhs.title, fallback: lhs.artist, rhs.artist)
            case .artist:
                return compare(lhs.artist, rhs.artist, fallback: lhs.title, rhs.title)
            case .album:
                return compare(lhs.album, rhs.album, fallback: lhs.title, rhs.title)
            case .genre:
                return compare(lhs.genre, rhs.genre, fallback: lhs.artist, rhs.artist)
            }
        }
        if let currentURL,
           let index = playlist.firstIndex(where: { $0.url == currentURL }) {
            currentIndex = index
        }
    }

    private func compare(_ lhs: String, _ rhs: String, fallback lhsFallback: String, _ rhsFallback: String) -> Bool {
        let primary = lhs.localizedCaseInsensitiveCompare(rhs)
        if primary == .orderedSame {
            return lhsFallback.localizedCaseInsensitiveCompare(rhsFallback) == .orderedAscending
        }
        return primary == .orderedAscending
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
                return Track(url: url, title: title, artist: artist, album: "Unknown Album", genre: "Unknown Genre")
            }
        }

        return Track(url: url, title: filename, artist: "Unknown Artist", album: "Unknown Album", genre: "Unknown Genre")
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

    @objc private func refreshProgress() {
        guard let audioPlayer else { return }

        let now = Date()
        if let anchor = playbackTickAnchor {
            listenedSecondsThisTrack += now.timeIntervalSince(anchor)
            recordPlayIfEligible()
        }
        playbackTickAnchor = now

        currentTime = audioPlayer.currentTime
        duration = max(audioPlayer.duration, 1)
    }

    private func startReindexScheduler() {
        reindexTimer?.invalidate()
        reindexTimer = Timer.scheduledTimer(timeInterval: 120, target: self, selector: #selector(triggerPeriodicReindex), userInfo: nil, repeats: true)
    }

    @objc private func triggerPeriodicReindex() {
        scheduleReindex(reason: "Background refresh")
    }

    private func loadIndexOnLaunch() async {
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
                index = LibraryIndex(version: LibraryIndex.currentVersion, roots: [], tracks: [], updatedAt: .distantPast)
                playlist = []
                currentIndex = nil
                indexStatus = "Metadata index upgraded; rebuilding library"
            }
        }

        scheduleReindex(reason: "Checking for library changes")
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
        let currentURL = currentTrack?.url
        playlist = entries.map {
            Track(
                url: URL(fileURLWithPath: $0.path),
                title: $0.title,
                artist: $0.artist,
                album: $0.album,
                genre: $0.genre
            )
        }
        sortPlaylistPreservingCurrentTrack()

        if let currentURL,
           let newIndex = playlist.firstIndex(where: { $0.url == currentURL }) {
            currentIndex = newIndex
        } else if playlist.isEmpty {
            currentIndex = nil
            pause()
        } else if currentIndex == nil {
            currentIndex = 0
        }
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

import AppKit
import SwiftUI

struct PlayerView: View {
    private struct SongContextMenuState {
        let tracks: [Track]
        let position: CGPoint
    }

    @EnvironmentObject private var player: PlayerViewModel
    @State private var editingSession: MetadataEditSession?
    @State private var selectedTrackIDs: Set<Track.ID> = []
    @State private var songContextMenu: SongContextMenuState?
    @State private var containerSize: CGSize = .zero
    @State private var containerFrameInWindow: CGRect = .zero
    @State private var songContextMenuSize: CGSize = CGSize(width: 230, height: 160)

    var body: some View {
        VStack(spacing: 0) {
            groovesharkNav
            actionToolbar
            contentArea
            bottomPlayer
        }
        .coordinateSpace(name: "playerRoot")
        .background(
            WindowFrameReader { frameInWindow in
                containerFrameInWindow = frameInWindow
                containerSize = frameInWindow.size
            }
        )
        .background(Color.grooveWindow)
        .sheet(item: $editingSession) { session in
            MetadataEditorView(tracks: session.tracks) { updatedTitle, updatedArtist, updatedAlbum, updatedGenre in
                player.updateMetadata(
                    for: session.tracks,
                    title: updatedTitle,
                    artist: updatedArtist,
                    album: updatedAlbum,
                    genre: updatedGenre
                )
                selectedTrackIDs.removeAll()
                editingSession = nil
            } onCancel: {
                editingSession = nil
            }
        }
        .sheet(isPresented: $player.isShowingSettings) {
            UserSettingsView()
                .environmentObject(player)
        }
        .onChange(of: player.selectedPlaylistID) { _, _ in
            selectedTrackIDs.removeAll()
            songContextMenu = nil
        }
        .overlay {
            if let menu = songContextMenu {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.black.opacity(0.001))
                        .ignoresSafeArea()
                        .onTapGesture {
                            songContextMenu = nil
                        }

                    themedSongContextMenu(for: menu.tracks)
                        .frame(width: 230, alignment: .leading)
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { songContextMenuSize = proxy.size }
                                    .onChange(of: proxy.size) { _, newSize in
                                        songContextMenuSize = newSize
                                    }
                            }
                        )
                        .offset(
                            x: clampedContextMenuOriginX(for: menu.position),
                            y: clampedContextMenuOriginY(for: menu.position)
                        )
                }
            }
        }
        .appFontScale(CGFloat(player.currentUserSettings.fontScale))
    }

    private var groovesharkNav: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(.white)
                    .appFont(size: 18)
                Text("GrooveShark")
                    .appFont(size: 17, weight: .bold, design: .rounded)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 13)

            navItem("Search")
            navItem("Music")
            navItem("Explore")
            navItem("Community")

            Spacer()

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.square.fill")
                        .foregroundStyle(.orange)
                    Text(player.username)
                        .foregroundStyle(.white.opacity(0.82))
                    Image(systemName: "chevron.down")
                        .appFont(size: 9)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .appFont(size: 12)
                .padding(.horizontal, 10)

                Button {
                    player.isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .appFont(size: 12)
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.gray)
                    TextField("Search", text: $player.searchQuery)
                        .textFieldStyle(.plain)
                        .appFont(size: 12)
                        .foregroundStyle(.black.opacity(0.8))
                        .disableAutocorrection(true)
                    if !player.searchQuery.isEmpty {
                        Button {
                            player.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.gray.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: 180, height: 22)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 11))
            }
            .padding(.trailing, 9)
        }
        .frame(height: 38)
        .background(
            LinearGradient(colors: [Color(red: 0.18, green: 0.18, blue: 0.18), Color.black], startPoint: .top, endPoint: .bottom)
        )
    }

    private func navItem(_ title: String) -> some View {
        Text(title)
            .appFont(size: 12, weight: .semibold)
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 12)
            .frame(height: 38)
    }

    private var actionToolbar: some View {
        HStack(spacing: 7) {
            toolbarButton("Play Radio", systemImage: "play.fill")
            toolbarButton("Play All", systemImage: "play.fill") {
                if let first = player.playlist.first {
                    player.selectTrack(first)
                }
            }
            toolbarButton("Add All", systemImage: "plus") {
                player.addLibraryFolders()
            }
            toolbarButton("Download Shared", systemImage: "square.and.arrow.down") {
                player.promptToDownloadSharedLibrary()
            }
            addToPlaylistMenu
            if player.isViewingSavedPlaylist {
                toolbarButton("Remove Selected", systemImage: "minus.circle") {
                    player.removeTracksFromSelectedPlaylist(selectedTracks)
                    selectedTrackIDs.removeAll()
                }
                .disabled(selectedTracks.isEmpty)
            }

            Spacer()

            Picker("Grouping", selection: player.settingBinding(\.libraryGrouping)) {
                ForEach(LibraryGrouping.allCases) { grouping in
                    Text(grouping.rawValue).tag(grouping)
                }
            }
            .labelsHidden()
            .frame(width: 155)

            Picker("Sort", selection: player.settingBinding(\.librarySortOption)) {
                ForEach(LibrarySortOption.allCases) { option in
                    Text("Sort by \(option.rawValue)").tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 170)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            LinearGradient(colors: [Color.white, Color(red: 0.83, green: 0.84, blue: 0.86)], startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.25)).frame(height: 1) }
    }

    private func toolbarButton(_ title: String, systemImage: String, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .appFont(size: 10, weight: .bold)
                Text(title)
            }
            .appFont(size: 12, weight: .semibold)
            .foregroundStyle(.black.opacity(0.78))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(LinearGradient(colors: [Color.white, Color(red: 0.80, green: 0.81, blue: 0.83)], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var addToPlaylistMenu: some View {
        Menu {
            Button("New Playlist") {
                player.promptToCreatePlaylist(with: playlistActionTracks)
            }

            if !player.savedPlaylists.isEmpty {
                Divider()
                ForEach(player.savedPlaylists) { playlist in
                    Button("Add to \(playlist.name)") {
                        player.addTracks(playlistActionTracks, to: playlist.id)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "text.badge.plus")
                    .appFont(size: 10, weight: .bold)
                Text("Add to Playlist")
                Image(systemName: "chevron.down")
                    .appFont(size: 9, weight: .bold)
            }
            .appFont(size: 12, weight: .semibold)
            .foregroundStyle(.black.opacity(0.78))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(LinearGradient(colors: [Color.white, Color(red: 0.80, green: 0.81, blue: 0.83)], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .disabled(playlistActionTracks.isEmpty)
    }

    private func themedSongContextMenu(for tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tracks.count > 1 ? "\(tracks.count) songs selected" : tracks.first?.title ?? "Song")
                .appFont(size: 11, weight: .bold)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.32))

            Button {
                player.promptToCreatePlaylist(with: tracks)
                songContextMenu = nil
            } label: {
                contextMenuRowLabel("New Playlist from Selection", systemImage: "text.badge.plus")
            }
            .buttonStyle(.plain)

            if !player.savedPlaylists.isEmpty {
                Divider()
                    .overlay(Color.white.opacity(0.10))

                ForEach(player.savedPlaylists) { playlist in
                    Button {
                        player.addTracks(tracks, to: playlist.id)
                        songContextMenu = nil
                    } label: {
                        contextMenuRowLabel("Add to \(playlist.name)", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                }
            }

            if player.isViewingSavedPlaylist {
                Divider()
                    .overlay(Color.white.opacity(0.10))

                Button {
                    player.removeTracksFromSelectedPlaylist(tracks)
                    selectedTrackIDs.subtract(tracks.map(\.id))
                    songContextMenu = nil
                } label: {
                    contextMenuRowLabel("Remove from This Playlist", systemImage: "minus")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.15, green: 0.15, blue: 0.15), Color.black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.grooveOrange.opacity(0.65), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.42), radius: 8, x: 0, y: 4)
    }

    private func contextMenuRowLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .appFont(size: 10, weight: .bold)
                .frame(width: 14)
                .foregroundStyle(Color.grooveOrange)

            Text(title)
                .appFont(size: 12, weight: .semibold)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(0.90))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .contentShape(Rectangle())
    }

    private var contentArea: some View {
        HStack(spacing: 0) {
            sidebar
            songTable
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            albumArt
                .padding(.horizontal, 10)
                .padding(.top, 10)

            Text(player.currentTrack?.artist ?? selectedSidebarArtist)
                .appFont(size: 15, weight: .bold)
                .foregroundStyle(.black.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            // Button {
            //     player.addLibraryFolders()
            // } label: {
            //     Label("Follow", systemImage: "plus")
            //         .font(.system(size: 12, weight: .semibold))
            //         .foregroundStyle(.black.opacity(0.78))
            //         .padding(.horizontal, 8)
            //         .frame(height: 22)
            //         .background(Color.white)
            //         .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.25), lineWidth: 1))
            // }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 7)

            Button {
                player.forceRefreshArtwork()
            } label: {
                Label(player.isRefreshingArtwork ? "Refreshing Art" : "Refresh Art", systemImage: "arrow.clockwise")
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(.black.opacity(0.78))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(player.currentTrack == nil || player.isRefreshingArtwork)
            .padding(.horizontal, 12)
            .padding(.top, 6)

            Button {
                openMetadataEditor()
            } label: {
                Label(editMetadataTitle, systemImage: "pencil")
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(.black.opacity(0.78))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(metadataEditTracks.isEmpty)
            .padding(.horizontal, 12)
            .padding(.top, 6)

            VStack(alignment: .leading, spacing: 6) {
                Text("Playlists")
                    .appFont(size: 12, weight: .bold)
                    .foregroundStyle(.black.opacity(0.70))

                playlistRow(
                    title: "All Songs",
                    systemImage: "music.note.list",
                    isSelected: player.selectedPlaylistID == nil
                ) {
                    player.selectPlaylist(nil)
                }

                ForEach(player.savedPlaylists) { playlist in
                    HStack(spacing: 4) {
                        playlistRow(
                            title: playlist.name,
                            systemImage: "music.note",
                            isSelected: player.selectedPlaylistID == playlist.id
                        ) {
                            player.selectPlaylist(playlist.id)
                        }

                        Button {
                            player.deletePlaylist(playlist)
                            selectedTrackIDs.removeAll()
                        } label: {
                            Image(systemName: "trash")
                                .appFont(size: 10, weight: .semibold)
                                .foregroundStyle(.black.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 13)

            VStack(alignment: .leading, spacing: 3) {
                Text("Library Folders")
                    .appFont(size: 12, weight: .bold)
                    .foregroundStyle(.black.opacity(0.70))
                    .padding(.bottom, 3)
                if player.libraryRoots.isEmpty {
                    Text("Add folders like Music or Downloads/Music.")
                        .foregroundStyle(Color.gray)
                } else {
                    ForEach(player.libraryRoots, id: \.self) { root in
                        Button {
                            player.removeLibraryRoot(root)
                        } label: {
                            Text(URL(fileURLWithPath: root).lastPathComponent)
                                .lineLimit(1)
                                .foregroundStyle(Color.grooveOrange)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .appFont(size: 12, weight: .semibold)
            .padding(12)

            Spacer()
        }
        .frame(width: 188)
        .background(Color(red: 0.89, green: 0.90, blue: 0.89))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.black.opacity(0.22)).frame(width: 1) }
    }

    private var selectedSidebarArtist: String {
        player.playlist.first?.artist ?? "GrooveShark"
    }

    private var metadataEditTracks: [Track] {
        let selected = player.playlist.filter { selectedTrackIDs.contains($0.id) }
        if !selected.isEmpty {
            return selected
        }
        return player.currentTrack.map { [$0] } ?? []
    }

    private var selectedTracks: [Track] {
        player.playlist.filter { selectedTrackIDs.contains($0.id) }
    }

    private var playlistActionTracks: [Track] {
        if !selectedTracks.isEmpty {
            return selectedTracks
        }
        return player.currentTrack.map { [$0] } ?? []
    }

    private var editMetadataTitle: String {
        let count = metadataEditTracks.count
        return count > 1 ? "Edit \(count) Songs" : "Edit Metadata"
    }

    private func openMetadataEditor() {
        let tracks = metadataEditTracks
        guard !tracks.isEmpty else { return }
        editingSession = MetadataEditSession(tracks: tracks)
    }

    private var albumArt: some View {
        ZStack(alignment: .bottomLeading) {
            Color(red: 0.12, green: 0.12, blue: 0.13)
            Group {
                if let image = player.artworkImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.19, blue: 0.20), Color(red: 0.66, green: 0.68, blue: 0.58)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note.list")
                        .appFont(size: 48, weight: .light)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(player.currentTrack?.album ?? "Local Library")
                .appFont(size: 11, weight: .bold)
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .lineLimit(2)
                .padding(8)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.35), lineWidth: 1))
    }

    private func playlistRow(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                Spacer()
            }
            .appFont(size: 12, weight: isSelected ? .bold : .regular)
            .foregroundStyle(isSelected ? .white : Color.black.opacity(0.66))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.grooveOrange : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.plain)
    }

    private var songTable: some View {
        VStack(spacing: 0) {
            tableHeader

            if player.playlist.isEmpty {
                VStack(spacing: 10) {
                    Text("No songs yet")
                        .appFont(size: 18, weight: .semibold)
                        .foregroundStyle(.black.opacity(0.65))
                    Text("Use Add All to select library folders. The indexer will find audio files and fill this GrooveShark-style table.")
                        .appFont(size: 13)
                        .foregroundStyle(.gray)
                        .multilineTextAlignment(.center)
                    Button("Add Library Folder") {
                        player.addLibraryFolders()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            } else if player.filteredPlaylist.isEmpty {
                VStack(spacing: 10) {
                    Text("No matching songs")
                        .appFont(size: 18, weight: .semibold)
                        .foregroundStyle(.black.opacity(0.65))
                    Text("Try a different search term for title, artist, album, or genre.")
                        .appFont(size: 13)
                        .foregroundStyle(.gray)
                        .multilineTextAlignment(.center)
                    Button("Clear Search") {
                        player.searchQuery = ""
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(player.filteredPlaylist.enumerated()), id: \.element.id) { index, track in
                            songRow(track: track, index: index, isSelected: selectedTrackIDs.contains(track.id))
                        }
                    }
                }
                .background(Color.white)
            }

            HStack {
                Text(player.indexStatus)
                    .foregroundStyle(player.isReindexing ? Color.grooveOrange : Color.gray)
                Spacer()
                Text(songCountLabel)
                    .fontWeight(.bold)
            }
            .appFont(size: 12)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(red: 0.92, green: 0.92, blue: 0.92))
        }
        .background(Color.white)
    }

    private var songCountLabel: String {
        let scope = player.isViewingSavedPlaylist ? "\(player.selectedPlaylistName)" : "Queue"
        if player.hasActiveSearch {
            return "\(player.filteredPlaylist.count) of \(player.playlist.count) Songs in \(scope)"
        }
        return "\(player.playlist.count) Songs in \(scope)"
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            sortHeader("Song", option: .title)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("Artist", option: .artist)
                .frame(width: 220, alignment: .leading)
            sortHeader("Album", option: .album)
                .frame(width: 212, alignment: .leading)
            Text("Plays")
                .frame(width: 48, alignment: .trailing)
        }
        .appFont(size: 12, weight: .bold)
        .foregroundStyle(.black.opacity(0.68))
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 25)
        .background(Color(red: 0.95, green: 0.95, blue: 0.95))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.13)).frame(height: 1) }
    }

    private func sortHeader(_ title: String, option: LibrarySortOption) -> some View {
        Button {
            player.sortOption = option
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if player.sortOption == option {
                    Image(systemName: "chevron.up")
                        .appFont(size: 8, weight: .bold)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func songRow(track: Track, index: Int, isSelected: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                if player.currentTrack?.url == track.url {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .appFont(size: 10)
                        .foregroundStyle(Color.grooveOrange)
                }
                Text(track.title)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.artist)
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)

            Text(track.album)
                .lineLimit(1)
                .frame(width: 212, alignment: .leading)

            Text("\(player.playCount(for: track))")
                .lineLimit(1)
                .frame(width: 48, alignment: .trailing)
        }
        .appFont(size: 12)
        .foregroundStyle(.black.opacity(0.72))
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 26)
        .background(rowBackground(index: index, isSelected: isSelected))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.035)).frame(height: 1) }
        .contentShape(Rectangle())
        .overlay {
            RowClickOverlay(
                onSingleClick: { commandPressed in
                    songContextMenu = nil
                    if commandPressed {
                        toggleSelection(track)
                    } else {
                        selectedTrackIDs = [track.id]
                    }
                },
                onDoubleClick: {
                    songContextMenu = nil
                    player.selectTrack(track)
                },
                onSecondaryClick: { pointInWindow in
                    if !selectedTrackIDs.contains(track.id) {
                        selectedTrackIDs = [track.id]
                    }
                    let tracks = selectedTracks.isEmpty ? [track] : selectedTracks
                    songContextMenu = SongContextMenuState(
                        tracks: tracks,
                        position: contextMenuPositionFromWindow(pointInWindow)
                    )
                }
            )
        }
    }

    private func contextMenuPositionFromWindow(_ pointInWindow: CGPoint) -> CGPoint {
        guard !containerFrameInWindow.isEmpty else {
            return CGPoint(x: containerSize.width * 0.5, y: containerSize.height * 0.5)
        }

        let localX = pointInWindow.x - containerFrameInWindow.minX
        let localYFromBottom = pointInWindow.y - containerFrameInWindow.minY
        let localY = containerSize.height - localYFromBottom
        return CGPoint(x: localX, y: localY)
    }

    private func clampedContextMenuOriginX(for clickPoint: CGPoint) -> CGFloat {
        let padding: CGFloat = 6
        let maxX = max(padding, containerSize.width - songContextMenuSize.width - padding)
        return min(max(clickPoint.x, padding), maxX)
    }

    private func clampedContextMenuOriginY(for clickPoint: CGPoint) -> CGFloat {
        let padding: CGFloat = 6
        let maxY = max(padding, containerSize.height - songContextMenuSize.height - padding)
        return min(max(clickPoint.y, padding), maxY)
    }

    private func rowBackground(index: Int, isSelected: Bool) -> Color {
        if isSelected {
            return Color.grooveOrange.opacity(0.28)
        }
        return index.isMultiple(of: 2) ? Color.white : Color(red: 0.965, green: 0.965, blue: 0.965)
    }

    private func toggleSelection(_ track: Track) {
        if selectedTrackIDs.contains(track.id) {
            selectedTrackIDs.remove(track.id)
        } else {
            selectedTrackIDs.insert(track.id)
        }
    }

    private var bottomPlayer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .appFont(size: 10, weight: .bold)
                    .foregroundStyle(.white.opacity(0.65))
                Text(player.currentTrack.map { "\($0.title) by \($0.artist)" } ?? "Nothing playing")
                    .appFont(size: 12, weight: .bold)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.white.opacity(0.7))
                Text(songCountLabel)
                    .appFont(size: 11, weight: .bold)
                    .foregroundStyle(.white)
                Image(systemName: "square.and.arrow.down")
                Image(systemName: "trash")
            }
            .appFont(size: 12)
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 12)
            .frame(height: 25)
            .background(LinearGradient(colors: [Color(red: 0.16, green: 0.16, blue: 0.16), Color.black], startPoint: .top, endPoint: .bottom))

            HStack(spacing: 12) {
                Button(action: player.playPause) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .appFont(size: 20)
                }
                Button(action: player.previousTrack) {
                    Image(systemName: "backward.end.fill")
                }
                Button(action: player.nextTrack) {
                    Image(systemName: "forward.end.fill")
                }

                Text(formatTime(player.currentTime))
                    .appMonospacedDigitFont(size: 11)
                    .foregroundStyle(.white.opacity(0.82))

                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...player.duration
                )
                .tint(Color.grooveOrange)

                Text(formatTime(player.duration))
                    .appMonospacedDigitFont(size: 11)
                    .foregroundStyle(.white.opacity(0.82))

                Image(systemName: "shuffle")
                Image(systemName: "repeat")
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.fill")
                    Slider(
                        value: Binding(
                            get: { Double(player.volume) },
                            set: { player.volume = Float($0) }
                        ),
                        in: 0...1
                    )
                    .tint(Color.grooveOrange)
                    .frame(width: 82)
                }
                Text("RADIO")
                    .appFont(size: 10, weight: .bold)
                Text("OFF")
                    .appFont(size: 10, weight: .bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 50)
            .background(LinearGradient(colors: [Color(red: 0.08, green: 0.08, blue: 0.08), Color.black], startPoint: .top, endPoint: .bottom))
        }
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    private func formatTime(_ value: TimeInterval) -> String {
        if value.isNaN || value.isInfinite { return "00:00" }
        let totalSeconds = Int(value)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct WindowFrameReader: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> WindowFrameView {
        let view = WindowFrameView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WindowFrameView, context: Context) {
        nsView.onChange = onChange
        nsView.reportFrame()
    }
}

private final class WindowFrameView: NSView {
    var onChange: ((CGRect) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    func reportFrame() {
        guard window != nil else { return }
        let frameInWindow = convert(bounds, to: nil)
        if !frameInWindow.isEmpty {
            onChange?(frameInWindow)
        }
    }
}

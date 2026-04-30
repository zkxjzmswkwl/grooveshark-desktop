import AppKit
import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @State private var editingSession: MetadataEditSession?
    @State private var isShowingSettings = false
    @State private var selectedTrackIDs: Set<Track.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            groovesharkNav
            actionToolbar
            contentArea
            bottomPlayer
        }
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
        .sheet(isPresented: $isShowingSettings) {
            UserSettingsView()
                .environmentObject(player)
        }
    }

    private var groovesharkNav: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 18))
                Text("Grooveshark")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 13)

            navItem("Search")
            navItem("Music")
            navItem("Explore")
            navItem("Community")

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "person.crop.square.fill")
                    .foregroundStyle(.orange)
                Text(player.username)
                    .foregroundStyle(.white.opacity(0.82))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.gray)
                Text("Search...")
                    .foregroundStyle(.gray)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(width: 140, height: 22)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 11))
            .padding(.trailing, 9)
        }
        .frame(height: 38)
        .background(
            LinearGradient(colors: [Color(red: 0.18, green: 0.18, blue: 0.18), Color.black], startPoint: .top, endPoint: .bottom)
        )
    }

    private func navItem(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 12)
            .frame(height: 38)
    }

    private var actionToolbar: some View {
        HStack(spacing: 7) {
            toolbarButton("Play Radio", systemImage: "play.fill")
            smallToolbarButton(systemImage: "gearshape") {
                    isShowingSettings = true
            }
            toolbarButton("Play All", systemImage: "play.fill") {
                if let first = player.playlist.first {
                    player.selectTrack(first)
                }
            }
            toolbarButton("Add All", systemImage: "plus") {
                player.addLibraryFolders()
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
                    .font(.system(size: 10, weight: .bold))
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black.opacity(0.78))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(LinearGradient(colors: [Color.white, Color(red: 0.80, green: 0.81, blue: 0.83)], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func smallToolbarButton(systemImage: String, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.black.opacity(0.72))
                .frame(width: 28, height: 22)
                .background(LinearGradient(colors: [Color.white, Color(red: 0.80, green: 0.81, blue: 0.83)], startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
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
                .font(.system(size: 15, weight: .bold))
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
                    .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 12, weight: .semibold))
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

            VStack(spacing: 0) {
                sidebarItem("Activity", systemImage: "figure.walk")
                sidebarItem("Songs", systemImage: "music.note", selected: true)
                sidebarItem("Albums", systemImage: "square.stack")
            }
            .padding(.top, 13)

            VStack(alignment: .leading, spacing: 3) {
                Text("Library Folders")
                    .font(.system(size: 12, weight: .bold))
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
            .font(.system(size: 12, weight: .semibold))
            .padding(12)

            Spacer()
        }
        .frame(width: 188)
        .background(Color(red: 0.89, green: 0.90, blue: 0.89))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.black.opacity(0.22)).frame(width: 1) }
    }

    private var selectedSidebarArtist: String {
        player.playlist.first?.artist ?? "Grooveshark"
    }

    private var metadataEditTracks: [Track] {
        let selected = player.playlist.filter { selectedTrackIDs.contains($0.id) }
        if !selected.isEmpty {
            return selected
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
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(player.currentTrack?.album ?? "Local Library")
                .font(.system(size: 11, weight: .bold))
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

    private func sidebarItem(_ title: String, systemImage: String, selected: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)
            Text(title)
            Spacer()
        }
        .font(.system(size: 13, weight: selected ? .bold : .regular))
        .foregroundStyle(selected ? .white : Color.black.opacity(0.66))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(selected ? Color.grooveOrange : Color.clear)
    }

    private var songTable: some View {
        VStack(spacing: 0) {
            tableHeader

            if player.playlist.isEmpty {
                VStack(spacing: 10) {
                    Text("No songs yet")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.65))
                    Text("Use Add All to select library folders. The indexer will find audio files and fill this Grooveshark-style table.")
                        .font(.system(size: 13))
                        .foregroundStyle(.gray)
                        .multilineTextAlignment(.center)
                    Button("Add Library Folder") {
                        player.addLibraryFolders()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(player.playlist.enumerated()), id: \.element.id) { index, track in
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
                Text("\(player.playlist.count) Songs in Queue")
                    .fontWeight(.bold)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(red: 0.92, green: 0.92, blue: 0.92))
        }
        .background(Color.white)
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
        .font(.system(size: 12, weight: .bold))
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
                        .font(.system(size: 8, weight: .bold))
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
                        .font(.system(size: 10))
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
        .font(.system(size: 12))
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
                    if commandPressed {
                        toggleSelection(track)
                    } else {
                        selectedTrackIDs = [track.id]
                    }
                },
                onDoubleClick: {
                    player.selectTrack(track)
                }
            )
        }
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
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                Text(player.currentTrack.map { "\($0.title) by \($0.artist)" } ?? "Nothing playing")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.white.opacity(0.7))
                Text("\(player.playlist.count) Songs in Queue")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                Image(systemName: "square.and.arrow.down")
                Image(systemName: "trash")
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 12)
            .frame(height: 25)
            .background(LinearGradient(colors: [Color(red: 0.16, green: 0.16, blue: 0.16), Color.black], startPoint: .top, endPoint: .bottom))

            HStack(spacing: 12) {
                Button(action: player.playPause) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                }
                Button(action: player.previousTrack) {
                    Image(systemName: "backward.end.fill")
                }
                Button(action: player.nextTrack) {
                    Image(systemName: "forward.end.fill")
                }

                Text(formatTime(player.currentTime))
                    .font(.system(size: 11).monospacedDigit())
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
                    .font(.system(size: 11).monospacedDigit())
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
                    .font(.system(size: 10, weight: .bold))
                Text("OFF")
                    .font(.system(size: 10, weight: .bold))
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

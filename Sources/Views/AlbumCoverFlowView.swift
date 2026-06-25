import AppKit
import SwiftUI

struct AlbumCoverFlowView: View, Equatable {
    let albumGroups: [AlbumGroup]
    let artworkStore: AlbumArtworkStore
    let indexStatus: String
    let isReindexing: Bool
    let isViewingSavedPlaylist: Bool
    let selectedPlaylistName: String
    let hasActiveSearch: Bool
    let filteredSongCount: Int
    let playlistIsEmpty: Bool
    let currentTrackID: Track.ID?
    let isPlaying: Bool
    let onAddLibraryFolders: () -> Void
    let onClearSearch: () -> Void
    let onSelectTrack: (Track) -> Void
    let onWarmArtwork: () -> Void
    let onPrefetchArtwork: (Int, [AlbumGroup]) -> Void
    let onLoadArtwork: (AlbumGroup) -> Void

    @Binding var selectedTrackIDs: Set<Track.ID>

    nonisolated static func == (lhs: AlbumCoverFlowView, rhs: AlbumCoverFlowView) -> Bool {
        lhs.albumGroups == rhs.albumGroups
            && lhs.indexStatus == rhs.indexStatus
            && lhs.isReindexing == rhs.isReindexing
            && lhs.isViewingSavedPlaylist == rhs.isViewingSavedPlaylist
            && lhs.selectedPlaylistName == rhs.selectedPlaylistName
            && lhs.hasActiveSearch == rhs.hasActiveSearch
            && lhs.filteredSongCount == rhs.filteredSongCount
            && lhs.playlistIsEmpty == rhs.playlistIsEmpty
            && lhs.currentTrackID == rhs.currentTrackID
            && lhs.isPlaying == rhs.isPlaying
            && lhs.selectedTrackIDs == rhs.selectedTrackIDs
    }

    var body: some View {
        CoverFlowScreen(
            albumGroups: albumGroups,
            artworkStore: artworkStore,
            indexStatus: indexStatus,
            isReindexing: isReindexing,
            isViewingSavedPlaylist: isViewingSavedPlaylist,
            selectedPlaylistName: selectedPlaylistName,
            hasActiveSearch: hasActiveSearch,
            filteredSongCount: filteredSongCount,
            playlistIsEmpty: playlistIsEmpty,
            currentTrackID: currentTrackID,
            isPlaying: isPlaying,
            onAddLibraryFolders: onAddLibraryFolders,
            onClearSearch: onClearSearch,
            onSelectTrack: onSelectTrack,
            onWarmArtwork: onWarmArtwork,
            onPrefetchArtwork: onPrefetchArtwork,
            onLoadArtwork: onLoadArtwork,
            selectedTrackIDs: $selectedTrackIDs
        )
    }
}

private struct CoverFlowScreen: View {
    let albumGroups: [AlbumGroup]
    let artworkStore: AlbumArtworkStore
    let indexStatus: String
    let isReindexing: Bool
    let isViewingSavedPlaylist: Bool
    let selectedPlaylistName: String
    let hasActiveSearch: Bool
    let filteredSongCount: Int
    let playlistIsEmpty: Bool
    let currentTrackID: Track.ID?
    let isPlaying: Bool
    let onAddLibraryFolders: () -> Void
    let onClearSearch: () -> Void
    let onSelectTrack: (Track) -> Void
    let onWarmArtwork: () -> Void
    let onPrefetchArtwork: (Int, [AlbumGroup]) -> Void
    let onLoadArtwork: (AlbumGroup) -> Void

    @Binding var selectedTrackIDs: Set<Track.ID>
    @State private var selectedAlbumIndex = 0

    private var selectedAlbum: AlbumGroup? {
        guard albumGroups.indices.contains(selectedAlbumIndex) else { return nil }
        return albumGroups[selectedAlbumIndex]
    }

    var body: some View {
        GeometryReader { geometry in
            let statusBarHeight: CGFloat = 28
            let carouselHeight = geometry.size.height * 0.6
            let tableHeight = max(0, geometry.size.height - carouselHeight - statusBarHeight)

            VStack(spacing: 0) {
                CoverFlowCarousel(
                    albumGroups: albumGroups,
                    artworkStore: artworkStore,
                    selectedAlbumIndex: $selectedAlbumIndex,
                    onLoadArtwork: onLoadArtwork
                )
                .frame(height: carouselHeight)

                EquatableView(
                    content: CoverFlowTrackTable(
                        album: selectedAlbum,
                        albumGroupsEmpty: albumGroups.isEmpty,
                        playlistIsEmpty: playlistIsEmpty,
                        hasActiveSearch: hasActiveSearch,
                        currentTrackID: currentTrackID,
                        isPlaying: isPlaying,
                        onAddLibraryFolders: onAddLibraryFolders,
                        onClearSearch: onClearSearch,
                        onSelectTrack: onSelectTrack,
                        selectedTrackIDs: $selectedTrackIDs
                    )
                )
                .frame(height: tableHeight)

                CoverFlowStatusBar(
                    indexStatus: indexStatus,
                    isReindexing: isReindexing,
                    albumCountLabel: albumCountLabel
                )
                .frame(height: statusBarHeight)
            }
        }
        .background(Color.black)
        .onAppear {
            clampSelectedAlbumIndex()
            onWarmArtwork()
            onPrefetchArtwork(selectedAlbumIndex, albumGroups)
        }
        .onChange(of: albumGroups.count) { _, _ in
            clampSelectedAlbumIndex()
            onWarmArtwork()
            onPrefetchArtwork(selectedAlbumIndex, albumGroups)
        }
        .onChange(of: selectedAlbumIndex) { _, newIndex in
            onPrefetchArtwork(newIndex, albumGroups)
        }
    }

    private var albumCountLabel: String {
        let scope = isViewingSavedPlaylist ? selectedPlaylistName : "Library"
        if hasActiveSearch {
            return "\(albumGroups.count) Albums (\(filteredSongCount) songs) in \(scope)"
        }
        return "\(albumGroups.count) Albums in \(scope)"
    }

    private func clampSelectedAlbumIndex() {
        guard !albumGroups.isEmpty else {
            selectedAlbumIndex = 0
            return
        }
        selectedAlbumIndex = min(max(selectedAlbumIndex, 0), albumGroups.count - 1)
    }
}

private struct CoverFlowCarousel: View {
    let albumGroups: [AlbumGroup]
    @ObservedObject var artworkStore: AlbumArtworkStore
    @Binding var selectedAlbumIndex: Int
    let onLoadArtwork: (AlbumGroup) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var coverSpacing: CGFloat = 160

    private let maxVisibleDistance: CGFloat = 6

    private var selectedAlbum: AlbumGroup? {
        guard albumGroups.indices.contains(selectedAlbumIndex) else { return nil }
        return albumGroups[selectedAlbumIndex]
    }

    var body: some View {
        GeometryReader { outer in
            let footerHeight: CGFloat = 56
            let stageHeight = max(120, outer.size.height - footerHeight)
            let coverSize = min(outer.size.width * 0.18, stageHeight * 0.72, 300)
            let spacing = max(140, coverSize * 1.08)
            let scrollPosition = CGFloat(selectedAlbumIndex) - dragOffset / spacing

            VStack(spacing: 8) {
                ZStack {
                    Color.black

                    ForEach(visibleAlbumIndexes(scrollPosition: scrollPosition), id: \.self) { index in
                        let distance = CGFloat(index) - scrollPosition
                        EquatableView(
                            content: CoverFlowAlbumTile(
                                group: albumGroups[index],
                                image: artworkStore.image(for: albumGroups[index].id),
                                distance: distance,
                                isDragging: isDragging,
                                coverSize: coverSize,
                                coverSpacing: spacing,
                                maxVisibleDistance: maxVisibleDistance,
                                onSelect: {
                                    withAnimation(.easeOut(duration: 0.22)) {
                                        selectedAlbumIndex = index
                                        dragOffset = 0
                                    }
                                },
                                onRequestArtwork: {
                                    onLoadArtwork(albumGroups[index])
                                }
                            )
                        )
                        .zIndex(1_000 - abs(distance))
                    }
                }
                .frame(width: outer.size.width, height: stageHeight, alignment: .top)
                .padding(.top, 8)
                .clipped()
                .contentShape(Rectangle())
                .gesture(coverFlowDragGesture(spacing: spacing))

                if let album = selectedAlbum {
                    VStack(spacing: 2) {
                        Text(album.album)
                            .appFont(size: 15, weight: .bold)
                        Text(album.artist)
                            .appFont(size: 13, weight: .medium)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: 420)
                }

                albumScrubber
                    .padding(.horizontal, 24)
            }
            .onAppear {
                coverSpacing = spacing
            }
            .onChange(of: spacing) { _, newSpacing in
                coverSpacing = newSpacing
            }
        }
        .background(Color.black)
    }

    private var albumScrubber: some View {
        Group {
            if albumGroups.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(selectedAlbumIndex) },
                        set: { newValue in
                            withAnimation(.easeOut(duration: 0.2)) {
                                selectedAlbumIndex = Int(newValue.rounded())
                            }
                        }
                    ),
                    in: 0...Double(max(albumGroups.count - 1, 0)),
                    step: 1
                )
                .tint(.white.opacity(0.55))
            }
        }
        .frame(height: 16)
    }

    private func coverFlowDragGesture(spacing: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                isDragging = true
                dragOffset = value.translation.width
            }
            .onEnded { value in
                isDragging = false
                let activeSpacing = spacing > 0 ? spacing : coverSpacing
                let currentPosition = CGFloat(selectedAlbumIndex) - value.translation.width / activeSpacing
                let target = Int(currentPosition.rounded())
                withAnimation(.easeOut(duration: 0.22)) {
                    selectedAlbumIndex = min(max(target, 0), max(albumGroups.count - 1, 0))
                    dragOffset = 0
                }
            }
    }

    private func visibleAlbumIndexes(scrollPosition: CGFloat) -> [Int] {
        guard !albumGroups.isEmpty else { return [] }
        let center = Int(scrollPosition.rounded())
        let span = Int(maxVisibleDistance.rounded(.up)) + 2
        let lower = max(0, center - span)
        let upper = min(albumGroups.count - 1, center + span)
        return Array(lower...upper)
    }
}

private struct CoverFlowAlbumTile: View, Equatable {
    let group: AlbumGroup
    let image: NSImage?
    let distance: CGFloat
    let isDragging: Bool
    let coverSize: CGFloat
    let coverSpacing: CGFloat
    let maxVisibleDistance: CGFloat
    let onSelect: () -> Void
    let onRequestArtwork: () -> Void

    nonisolated static func == (lhs: CoverFlowAlbumTile, rhs: CoverFlowAlbumTile) -> Bool {
        lhs.group == rhs.group
            && lhs.image === rhs.image
            && lhs.distance == rhs.distance
            && lhs.isDragging == rhs.isDragging
            && lhs.coverSize == rhs.coverSize
            && lhs.coverSpacing == rhs.coverSpacing
    }

    var body: some View {
        let absDistance = abs(distance)
        let angle = coverAngle(for: distance)
        let scale = coverScale(for: absDistance)
        let opacity = coverOpacity(for: absDistance)
        let showReflection = !isDragging && absDistance <= 2.2
        let showShadow = absDistance < 0.75

        VStack(spacing: 0) {
            coverArt(showShadow: showShadow)
            if showReflection {
                coverReflection
            }
        }
        .frame(width: coverSize, height: coverSize * 1.38, alignment: .top)
        .scaleEffect(scale, anchor: .top)
        .offset(x: distance * coverSpacing)
        .rotation3DEffect(
            .degrees(angle),
            axis: (x: 0, y: 1, z: 0),
            anchor: .center,
            perspective: 0.28
        )
        .opacity(opacity)
        .onTapGesture(perform: onSelect)
        .onAppear(perform: onRequestArtwork)
    }

    private func coverAngle(for distance: CGFloat) -> Double {
        let clamped = max(-maxVisibleDistance, min(maxVisibleDistance, distance))
        let sign: Double = clamped >= 0 ? 1 : -1
        let magnitude = Double(abs(clamped))
        // Gentler tilt keeps neighbors visible instead of stacking edge-on.
        let angle = magnitude <= 1
            ? magnitude * 36
            : min(56, 36 + (magnitude - 1) * 6)
        return sign * angle
    }

    private func coverScale(for absDistance: CGFloat) -> CGFloat {
        CGFloat(max(0.58, 1.0 - absDistance * 0.075))
    }

    private func coverOpacity(for absDistance: CGFloat) -> Double {
        Double(max(0.42, 1.0 - absDistance * 0.09))
    }

    private func coverArt(showShadow: Bool) -> some View {
        ZStack {
            Color(white: 0.12)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .appFont(size: 32, weight: .light)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: coverSize, height: coverSize)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: showShadow ? .black.opacity(0.55) : .clear, radius: 8, x: 0, y: 5)
    }

    private var coverReflection: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                Color(white: 0.12)
            }
        }
        .frame(width: coverSize, height: coverSize * 0.34)
        .clipped()
        .scaleEffect(x: 1, y: -1, anchor: .top)
        .mask(
            LinearGradient(
                colors: [.white.opacity(0.35), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }
}

private struct CoverFlowTrackTable: View, Equatable {
    let album: AlbumGroup?
    let albumGroupsEmpty: Bool
    let playlistIsEmpty: Bool
    let hasActiveSearch: Bool
    let currentTrackID: Track.ID?
    let isPlaying: Bool
    let onAddLibraryFolders: () -> Void
    let onClearSearch: () -> Void
    let onSelectTrack: (Track) -> Void

    @Binding var selectedTrackIDs: Set<Track.ID>

    nonisolated static func == (lhs: CoverFlowTrackTable, rhs: CoverFlowTrackTable) -> Bool {
        lhs.album == rhs.album
            && lhs.albumGroupsEmpty == rhs.albumGroupsEmpty
            && lhs.playlistIsEmpty == rhs.playlistIsEmpty
            && lhs.hasActiveSearch == rhs.hasActiveSearch
            && lhs.currentTrackID == rhs.currentTrackID
            && lhs.isPlaying == rhs.isPlaying
            && lhs.selectedTrackIDs == rhs.selectedTrackIDs
    }

    var body: some View {
        VStack(spacing: 0) {
            trackTableHeader

            if albumGroupsEmpty {
                emptyAlbumsState
            } else if let album {
                if album.tracks.isEmpty {
                    emptyAlbumsState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                                trackRow(track: track, index: index)
                            }
                        }
                    }
                    .background(Color.grooveSurfaceRaised)
                }
            }
        }
        .background(Color.grooveSurfaceRaised)
    }

    private var trackTableHeader: some View {
        HStack(spacing: 0) {
            Text("Song")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Artist")
                .frame(width: 180, alignment: .leading)
            Text("Album")
                .frame(width: 160, alignment: .leading)
            Text("Genre")
                .frame(width: 120, alignment: .leading)
        }
        .appFont(size: 12, weight: .bold)
        .foregroundStyle(Color.grooveTextSecondary)
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 25)
        .background(Color.grooveSurfaceSecondary)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.13)).frame(height: 1) }
    }

    private func trackRow(track: Track, index: Int) -> some View {
        let isSelected = selectedTrackIDs.contains(track.id)
        let isCurrent = currentTrackID == track.id

        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                if isCurrent {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .appFont(size: 10)
                        .foregroundStyle(Color.grooveOrange)
                }
                Text(track.title)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.artist)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            Text(track.album)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)

            Text(track.genre)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
        }
        .appFont(size: 12)
        .foregroundStyle(isSelected ? Color.white : Color.grooveTextPrimary.opacity(0.90))
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
                    onSelectTrack(track)
                },
                onSecondaryClick: { _ in }
            )
        }
    }

    private var emptyAlbumsState: some View {
        VStack(spacing: 10) {
            if playlistIsEmpty {
                Text("No albums yet")
                    .appFont(size: 18, weight: .semibold)
                    .foregroundStyle(Color.grooveTextPrimary.opacity(0.65))
                Text("Add library folders to browse your collection in Cover Flow.")
                    .appFont(size: 13)
                    .foregroundStyle(Color.grooveTextSecondary)
                    .multilineTextAlignment(.center)
                Button("Add Library Folder", action: onAddLibraryFolders)
                    .buttonStyle(.borderedProminent)
            } else {
                Text("No matching albums")
                    .appFont(size: 18, weight: .semibold)
                    .foregroundStyle(Color.grooveTextPrimary.opacity(0.65))
                Text("Try a different search term for title, artist, album, or genre.")
                    .appFont(size: 13)
                    .foregroundStyle(Color.grooveTextSecondary)
                    .multilineTextAlignment(.center)
                Button("Clear Search", action: onClearSearch)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.grooveSurfaceRaised)
    }

    private func rowBackground(index: Int, isSelected: Bool) -> Color {
        if isSelected {
            return Color(red: 0.20, green: 0.45, blue: 0.92)
        }
        return index.isMultiple(of: 2) ? Color.grooveSurfaceRaised : Color.grooveRowAlternate
    }

    private func toggleSelection(_ track: Track) {
        if selectedTrackIDs.contains(track.id) {
            selectedTrackIDs.remove(track.id)
        } else {
            selectedTrackIDs.insert(track.id)
        }
    }
}

private struct CoverFlowStatusBar: View, Equatable {
    let indexStatus: String
    let isReindexing: Bool
    let albumCountLabel: String

    var body: some View {
        HStack {
            Text(indexStatus)
                .foregroundStyle(isReindexing ? Color.grooveOrange : Color.gray)
            Spacer()
            Text(albumCountLabel)
                .fontWeight(.bold)
        }
        .appFont(size: 12)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Color.grooveSurfaceSecondary)
    }
}

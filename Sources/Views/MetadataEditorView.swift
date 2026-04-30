import SwiftUI

struct MetadataEditorView: View {
    let tracks: [Track]
    let onSave: (String?, String?, String?, String?) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var genre: String

    private let titleEditable: Bool
    private let artistEditable: Bool
    private let albumEditable: Bool
    private let genreEditable: Bool

    init(
        tracks: [Track],
        onSave: @escaping (String?, String?, String?, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.tracks = tracks
        self.onSave = onSave
        self.onCancel = onCancel
        titleEditable = Self.hasSharedValue(tracks, \.title)
        artistEditable = Self.hasSharedValue(tracks, \.artist)
        albumEditable = Self.hasSharedValue(tracks, \.album)
        genreEditable = Self.hasSharedValue(tracks, \.genre)
        _title = State(initialValue: titleEditable ? tracks.first?.title ?? "" : "Mixed Values")
        _artist = State(initialValue: artistEditable ? tracks.first?.artist ?? "" : "Mixed Values")
        _album = State(initialValue: albumEditable ? tracks.first?.album ?? "" : "Mixed Values")
        _genre = State(initialValue: genreEditable ? tracks.first?.genre ?? "" : "Mixed Values")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tracks.count > 1 ? "Edit Metadata (\(tracks.count) Songs)" : "Edit Metadata")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(tracks.count == 1 ? tracks[0].url.lastPathComponent : "Batch edit")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.18, green: 0.18, blue: 0.18), Color.black],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            VStack(alignment: .leading, spacing: 12) {
                metadataField("Song", text: $title, isEditable: titleEditable)
                metadataField("Artist", text: $artist, isEditable: artistEditable)
                metadataField("Album", text: $album, isEditable: albumEditable)
                metadataField("Genre", text: $genre, isEditable: genreEditable)

                Text(helpText)
                    .font(.system(size: 11))
                    .foregroundStyle(.black.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .background(Color(red: 0.91, green: 0.91, blue: 0.89))

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black.opacity(0.72))
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))

                Spacer()

                Button("Save Changes") {
                    onSave(
                        titleEditable ? title : nil,
                        artistEditable ? artist : nil,
                        albumEditable ? album : nil,
                        genreEditable ? genre : nil
                    )
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 24)
                .background(Color.grooveOrange)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))
            }
            .padding(14)
            .background(
                LinearGradient(
                    colors: [Color.white, Color(red: 0.83, green: 0.84, blue: 0.86)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .frame(width: 440)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var helpText: String {
        if tracks.count == 1 {
            return "Changes are saved to this app's library index and used for display, sorting, grouping, and artwork lookup."
        }
        return "Only fields with the same value across all selected songs are editable. Enabled fields will be applied to all selected songs."
    }

    private func metadataField(_ label: String, text: Binding<String>, isEditable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isEditable ? .black.opacity(0.68) : .black.opacity(0.35))
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(isEditable ? .black : .black.opacity(0.42))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(isEditable ? Color.white : Color(red: 0.82, green: 0.82, blue: 0.80))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.24), lineWidth: 1))
                .disabled(!isEditable)
        }
    }

    private static func hasSharedValue(_ tracks: [Track], _ keyPath: KeyPath<Track, String>) -> Bool {
        guard let first = tracks.first?[keyPath: keyPath] else { return false }
        return tracks.allSatisfy { $0[keyPath: keyPath] == first }
    }
}

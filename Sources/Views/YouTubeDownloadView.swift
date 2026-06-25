import SwiftUI

struct YouTubeDownloadItem: Identifiable, Equatable {
    let id: String
    var title: String
    var phase: YouTubeDownloadPhase
    var progress: Double?
    var downloadedPath: String?
    var errorMessage: String?
}

struct YouTubeDownloadView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @State private var urlText = ""
    @State private var ytdlpAvailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download from YouTube")
                .appFont(size: 18, weight: .bold)
                .foregroundStyle(Color.grooveTextPrimary)

            Text("Audio is saved to your GrooveShark library and indexed automatically.")
                .appFont(size: 12)
                .foregroundStyle(Color.grooveTextSecondary)

            if !ytdlpAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("yt-dlp is not installed. Run `brew install yt-dlp` in Terminal.")
                        .appFont(size: 12)
                        .foregroundStyle(Color.grooveTextSecondary)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            TextEditor(text: $urlText)
                .appFont(size: 12)
                .frame(minHeight: 90, maxHeight: 120)
                .padding(6)
                .background(Color.grooveSurfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.grooveBorder, lineWidth: 1))
                .disabled(player.isDownloadingFromYouTube)

            HStack {
                Button(player.isDownloadingFromYouTube ? "Downloading..." : "Download") {
                    player.downloadFromYouTube(urlText: urlText)
                }
                .disabled(
                    player.isDownloadingFromYouTube
                        || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !ytdlpAvailable
                )

                Spacer()

                Text(player.youtubeDownloadStatus)
                    .appFont(size: 11)
                    .foregroundStyle(Color.grooveTextSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }

            if !player.youtubeDownloadItems.isEmpty {
                List(player.youtubeDownloadItems) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .appFont(size: 12, weight: .semibold)
                            .foregroundStyle(Color.grooveTextPrimary)
                            .lineLimit(2)

                        HStack(spacing: 8) {
                            phaseLabel(item.phase)
                            if let progress = item.progress, item.phase == .downloading {
                                ProgressView(value: progress)
                                    .frame(maxWidth: 120)
                            }
                        }

                        if let error = item.errorMessage {
                            Text(error)
                                .appFont(size: 11)
                                .foregroundStyle(.red)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.grooveSurface)
        .task {
            ytdlpAvailable = await player.isYouTubeDownloadAvailable()
        }
    }

    @ViewBuilder
    private func phaseLabel(_ phase: YouTubeDownloadPhase) -> some View {
        switch phase {
        case .queued:
            Text("Queued")
                .appFont(size: 11)
                .foregroundStyle(Color.grooveTextSecondary)
        case .downloading:
            Text("Downloading")
                .appFont(size: 11)
                .foregroundStyle(Color.grooveOrange)
        case .completed:
            Label("Done", systemImage: "checkmark.circle.fill")
                .appFont(size: 11)
                .foregroundStyle(.green)
        case .skipped:
            Label("Skipped", systemImage: "arrow.uturn.right.circle")
                .appFont(size: 11)
                .foregroundStyle(Color.grooveTextSecondary)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .appFont(size: 11)
                .foregroundStyle(.red)
        }
    }
}

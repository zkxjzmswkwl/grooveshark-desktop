import AppKit
import SwiftUI

struct UserSettingsView: View {
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case library = "Library"
        case lastFM = "Last.fm"
        case sharing = "Sharing"

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerViewModel
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 16) {
                tabPicker
                activeTabContent
            }
            .padding(18)
            .background(Color(red: 0.91, green: 0.91, blue: 0.89))

            footer
        }
        .frame(width: 420)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear {
            // Avoid auto-selecting username text when the settings sheet opens.
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 6) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .appFont(size: 12, weight: .semibold)
                        .foregroundStyle(selectedTab == tab ? .white : .black.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selectedTab == tab ? Color.grooveOrange : Color.white.opacity(0.95))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.black.opacity(0.22), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.58))
        )
    }

    @ViewBuilder
    private var activeTabContent: some View {
        switch selectedTab {
        case .general:
            generalTabContent
        case .library:
            libraryTabContent
        case .lastFM:
            lastFMTabContent
        case .sharing:
            sharingTabContent
        }
    }

    private var generalTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingControl(for: "username")
            settingControl(for: "volume")
            settingControl(for: "fontScale")
            Text("Changes save automatically and are restored when the app starts.")
                .appFont(size: 11)
                .foregroundStyle(.black.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var libraryTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingControl(for: "libraryGrouping")
            settingControl(for: "librarySortOption")

            Divider()

            Button {
                player.rescanLibraryFromDisk()
            } label: {
                Label("Rescan Library From Disk", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .appFont(size: 12, weight: .semibold)
            .foregroundStyle(.black.opacity(0.74))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))
        }
    }

    private var lastFMTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingControl(for: "lastFMScrobblingEnabled")
            settingControl(for: "lastFMAPIKey")
            settingControl(for: "lastFMAPISecret")
            settingControl(for: "lastFMSessionKey")

            Divider()

            Text("Authorize from here: enter API key and shared secret, then click Connect Last.fm.")
                .appFont(size: 11)
                .foregroundStyle(.black.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                player.beginLastFMAuthorization()
            } label: {
                Label(player.isAuthorizingLastFM ? "Connecting Last.fm..." : "Connect Last.fm", systemImage: "link")
            }
            .buttonStyle(.plain)
            .appFont(size: 12, weight: .semibold)
            .foregroundStyle(.black.opacity(0.74))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))
            .disabled(!player.canBeginLastFMAuthorization || player.isAuthorizingLastFM)
        }
    }

    private var sharingTabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingControl(for: "librarySharingPort")

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(player.librarySharingStatus)
                        .appFont(size: 11)
                        .foregroundStyle(.black.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)

                    if !player.librarySharingAddress.isEmpty {
                        HStack(spacing: 8) {
                            Text(player.librarySharingAddress)
                                .appMonospacedDigitFont(size: 11)
                                .foregroundStyle(.black.opacity(0.72))
                                .textSelection(.enabled)
                            Spacer()
                            Button("Copy") {
                                player.copyLibrarySharingAddressToClipboard()
                            }
                            .buttonStyle(.plain)
                            .appFont(size: 11, weight: .semibold)
                            .foregroundStyle(.black.opacity(0.74))
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        player.isSharingLibrary ? player.stopLibrarySharing() : player.startLibrarySharing()
                    } label: {
                        Label(player.isSharingLibrary ? "Stop Sharing" : "Start Sharing", systemImage: player.isSharingLibrary ? "dot.radiowaves.left.and.right" : "network")
                    }
                    .buttonStyle(.plain)
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(.black.opacity(0.74))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))
                    .disabled(!player.isSharingLibrary && !player.canShareLibrary)

                    Button {
                        player.promptToDownloadSharedLibrary()
                    } label: {
                        Label(player.isDownloadingSharedLibrary ? "Downloading..." : "Download from Peer", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(.black.opacity(0.74))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))
                    .disabled(player.isDownloadingSharedLibrary)
                }

                transferSummaryCard(
                    title: "Downloading From Peer",
                    snapshot: player.downloadTransferSnapshot,
                    currentEmptyMessage: player.isDownloadingSharedLibrary ? "Preparing transfer..." : "No active download",
                    completedEmptyMessage: "No tracks downloaded yet",
                    upcomingEmptyMessage: "Nothing queued"
                )

                transferSummaryCard(
                    title: "Sharing To Peers",
                    snapshot: player.sharingTransferSnapshot,
                    currentEmptyMessage: player.isSharingLibrary ? "Waiting for peer requests..." : "Sharing is off",
                    completedEmptyMessage: "No tracks served yet",
                    upcomingEmptyMessage: "No tracks available to share"
                )

                Text("Share only on trusted networks. Anyone with this address can browse and download your indexed tracks.")
                    .appFont(size: 11)
                    .foregroundStyle(.black.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func transferSummaryCard(
        title: String,
        snapshot: LibraryTransferQueueSnapshot,
        currentEmptyMessage: String,
        completedEmptyMessage: String,
        upcomingEmptyMessage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .appFont(size: 12, weight: .bold)
                .foregroundStyle(.black.opacity(0.72))

            transferLane(
                heading: "Downloaded/Served",
                tracks: snapshot.completed,
                emptyMessage: completedEmptyMessage,
                icon: "checkmark.circle.fill",
                iconColor: Color.green
            )

            transferLane(
                heading: "Downloading/Serving Now",
                tracks: snapshot.current,
                emptyMessage: currentEmptyMessage,
                icon: "arrow.triangle.2.circlepath",
                iconColor: Color.grooveOrange
            )

            transferLane(
                heading: "Queued Next",
                tracks: snapshot.upcoming,
                emptyMessage: upcomingEmptyMessage,
                icon: "clock.fill",
                iconColor: Color.blue
            )
        }
        .padding(10)
        .background(Color.white.opacity(0.8))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.15), lineWidth: 1))
    }

    private func transferLane(
        heading: String,
        tracks: [SharedLibraryTrack],
        emptyMessage: String,
        icon: String,
        iconColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text("\(heading) (\(tracks.count))")
                    .appFont(size: 11, weight: .bold)
                    .foregroundStyle(.black.opacity(0.68))
            }

            if tracks.isEmpty {
                Text(emptyMessage)
                    .appFont(size: 11)
                    .foregroundStyle(.black.opacity(0.48))
            } else {
                ForEach(Array(tracks.prefix(5))) { track in
                    Text(trackLabel(track))
                        .appFont(size: 11)
                        .foregroundStyle(.black.opacity(0.64))
                        .lineLimit(1)
                }
                if tracks.count > 5 {
                    Text("+\(tracks.count - 5) more")
                        .appFont(size: 11)
                        .foregroundStyle(.black.opacity(0.48))
                }
            }
        }
    }

    private func trackLabel(_ track: SharedLibraryTrack) -> String {
        let trimmedArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedArtist.isEmpty || trimmedArtist == "Unknown Artist" {
            return track.relativePath
        }
        return "\(track.artist) - \(track.title)"
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .appFont(size: 17, weight: .bold)
                .foregroundStyle(.white)
            Spacer()
            Text("User preferences")
                .appFont(size: 11)
                .foregroundStyle(.white.opacity(0.65))
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
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.plain)
            .appFont(size: 12, weight: .bold)
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

    @ViewBuilder
    private func settingControl(for field: UserSettingField) -> some View {
        switch field.control {
        case let .dropdown(value, options):
            dropdownSetting(field, value: value, options: options)
        case let .text(value):
            textSetting(field, value: value)
        case let .slider(value, range, display):
            sliderSetting(field, value: value, range: range, display: display)
        case let .checkbox(value):
            checkboxSetting(field, value: value)
        }
    }

    @ViewBuilder
    private func settingControl(for fieldID: String) -> some View {
        if let field = UserSettings.fields.first(where: { $0.id == fieldID }) {
            settingControl(for: field)
        } else {
            EmptyView()
        }
    }

    private func dropdownSetting(
        _ field: UserSettingField,
        value: UserSettingValue<String>,
        options: [UserSettingDropdownOption]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            settingLabel(field.label)

            Picker(
                field.label,
                selection: player.binding(for: value)
            ) {
                ForEach(options) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func textSetting(_ field: UserSettingField, value: UserSettingValue<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            settingLabel(field.label)

            TextField(
                field.label,
                text: player.binding(for: value)
            )
            .textFieldStyle(.plain)
            .appFont(size: 13)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.white)
            .foregroundStyle(.black)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.24), lineWidth: 1))
        }
    }

    private func sliderSetting(
        _ field: UserSettingField,
        value: UserSettingValue<Double>,
        range: ClosedRange<Double>,
        display: UserSettingValueDisplay
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                settingLabel(field.label)
                Spacer()
                Text(display.format(value.get(player.currentUserSettings)))
                    .appMonospacedDigitFont(size: 11)
                    .foregroundStyle(.black.opacity(0.55))
            }

            Slider(
                value: player.binding(for: value),
                in: range
            )
            .tint(Color.grooveOrange)
        }
    }

    private func checkboxSetting(_ field: UserSettingField, value: UserSettingValue<Bool>) -> some View {
        Toggle(
            field.label,
            isOn: player.binding(for: value)
        )
        .toggleStyle(.checkbox)
        .appFont(size: 12, weight: .bold)
        .foregroundStyle(.black.opacity(0.68))
    }

    private func settingLabel(_ title: String) -> some View {
        Text(title)
            .appFont(size: 12, weight: .bold)
            .foregroundStyle(.black.opacity(0.68))
    }
}

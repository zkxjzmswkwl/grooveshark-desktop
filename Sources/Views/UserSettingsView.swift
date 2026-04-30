import SwiftUI

struct UserSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 16) {
                ForEach(UserSettings.fields) { field in
                    settingControl(for: field)
                }

                Divider()

                Button {
                    player.rescanLibraryFromDisk()
                } label: {
                    Label("Rescan Library From Disk", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black.opacity(0.74))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 1))

                Text("Changes save automatically and are restored when the app starts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.black.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .background(Color(red: 0.91, green: 0.91, blue: 0.89))

            footer
        }
        .frame(width: 420)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Text("User preferences")
                .font(.system(size: 11))
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
            .font(.system(size: 13))
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
                    .font(.system(size: 11).monospacedDigit())
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
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(.black.opacity(0.68))
    }

    private func settingLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.black.opacity(0.68))
    }
}

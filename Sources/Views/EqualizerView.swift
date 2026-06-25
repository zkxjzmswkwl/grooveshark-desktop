import SwiftUI

struct EqualizerView: View {
    @EnvironmentObject private var player: PlayerViewModel

    private let sliderTravel: CGFloat = 150
    private let columnWidth: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            enableRow
            presetRow
            preampRow

            Divider()

            graphicEqualizer
                .opacity(player.equalizer.isEnabled ? 1 : 0.45)
                .disabled(!player.equalizer.isEnabled)

            HStack {
                Button {
                    player.resetEqualizer()
                } label: {
                    Label("Reset to Flat", systemImage: "arrow.counterclockwise")
                        .appFont(size: 12, weight: .semibold)
                        .foregroundStyle(Color.grooveTextPrimary.opacity(0.90))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Color.grooveSurfaceRaised)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.grooveBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Preset: \(player.equalizer.presetName)")
                    .appFont(size: 11, weight: .semibold)
                    .foregroundStyle(Color.grooveTextSecondary)
            }

            Text("Adjust each frequency band between -12 dB and +12 dB. Changes apply to playback instantly and are saved automatically.")
                .appFont(size: 11)
                .foregroundStyle(Color.grooveTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var enableRow: some View {
        Toggle(
            "Enable equalizer",
            isOn: Binding(
                get: { player.equalizer.isEnabled },
                set: { player.setEqualizerEnabled($0) }
            )
        )
        .toggleStyle(.checkbox)
        .appFont(size: 12, weight: .bold)
        .foregroundStyle(Color.grooveTextPrimary.opacity(0.88))
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preset")
                .appFont(size: 12, weight: .bold)
                .foregroundStyle(Color.grooveTextPrimary.opacity(0.88))

            Picker(
                "Preset",
                selection: Binding(
                    get: { EqualizerPreset(rawValue: player.equalizer.presetName) ?? .flat },
                    set: { player.applyEqualizerPreset($0) }
                )
            ) {
                ForEach(EqualizerPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!player.equalizer.isEnabled)
        }
    }

    private var preampRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Preamp")
                    .appFont(size: 12, weight: .bold)
                    .foregroundStyle(Color.grooveTextPrimary.opacity(0.88))
                Spacer()
                Text(gainLabel(player.equalizer.preamp))
                    .appMonospacedDigitFont(size: 11)
                    .foregroundStyle(Color.grooveTextSecondary)
            }

            Slider(
                value: Binding(
                    get: { Double(player.equalizer.preamp) },
                    set: { player.setEqualizerPreamp(Float($0)) }
                ),
                in: Double(EqualizerSettings.preampRange.lowerBound)...Double(EqualizerSettings.preampRange.upperBound)
            )
            .tint(Color.grooveOrange)
            .disabled(!player.equalizer.isEnabled)
        }
    }

    private var graphicEqualizer: some View {
        HStack(alignment: .top, spacing: 0) {
            gainScale

            ForEach(Array(player.equalizer.bands.enumerated()), id: \.element.id) { index, band in
                bandColumn(index: index, band: band)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var gainScale: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("+12")
            Spacer()
            Text("0")
            Spacer()
            Text("-12")
        }
        .appMonospacedDigitFont(size: 9)
        .foregroundStyle(Color.grooveTextSecondary)
        .frame(width: 22, height: sliderTravel)
        .padding(.trailing, 4)
    }

    private func bandColumn(index: Int, band: EqualizerBand) -> some View {
        VStack(spacing: 6) {
            Text(gainLabel(band.gain))
                .appMonospacedDigitFont(size: 9, weight: .semibold)
                .foregroundStyle(abs(band.gain) < 0.05 ? Color.grooveTextSecondary : Color.grooveOrange)

            verticalSlider(index: index, gain: band.gain)

            Text(frequencyLabel(band.frequency))
                .appFont(size: 9, weight: .semibold)
                .foregroundStyle(Color.grooveTextSecondary)
                .fixedSize()
        }
    }

    private func verticalSlider(index: Int, gain: Float) -> some View {
        Slider(
            value: Binding(
                get: { Double(gain) },
                set: { player.setEqualizerBandGain(Float($0), atBandIndex: index) }
            ),
            in: Double(EqualizerSettings.gainRange.lowerBound)...Double(EqualizerSettings.gainRange.upperBound)
        )
        .controlSize(.small)
        .tint(Color.grooveOrange)
        .frame(width: sliderTravel)
        .rotationEffect(.degrees(-90))
        .frame(width: columnWidth, height: sliderTravel)
    }

    private func gainLabel(_ value: Float) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded > 0 {
            return String(format: "+%.0f", rounded)
        }
        return String(format: "%.0f", rounded)
    }

    private func frequencyLabel(_ frequency: Float) -> String {
        if frequency >= 1000 {
            let kilohertz = frequency / 1000
            if kilohertz == kilohertz.rounded() {
                return String(format: "%.0fk", kilohertz)
            }
            return String(format: "%.1fk", kilohertz)
        }
        return String(format: "%.0f", frequency)
    }
}

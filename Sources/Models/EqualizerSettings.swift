import Foundation

/// A single parametric band of the graphic equalizer.
struct EqualizerBand: Codable, Equatable, Identifiable {
    let frequency: Float
    var gain: Float

    var id: Float { frequency }
}

/// Built-in equalizer curves. The gain arrays line up with `EqualizerSettings.frequencies`.
enum EqualizerPreset: String, CaseIterable, Identifiable {
    case flat = "Flat"
    case bassBoost = "Bass Boost"
    case bassReducer = "Bass Reducer"
    case trebleBoost = "Treble Boost"
    case vocal = "Vocal"
    case rock = "Rock"
    case pop = "Pop"
    case jazz = "Jazz"
    case classical = "Classical"
    case electronic = "Electronic"
    case loudness = "Loudness"

    var id: String { rawValue }

    /// Label used when the band gains do not match any built-in preset.
    static let customName = "Custom"

    /// Gain in dB per band, ordered low to high frequency.
    var gains: [Float] {
        switch self {
        case .flat:        return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bassBoost:   return [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
        case .bassReducer: return [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]
        case .trebleBoost: return [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]
        case .vocal:       return [-2, -2, -1, 1, 3, 4, 4, 3, 1, 0]
        case .rock:        return [5, 4, 2, 0, -1, -1, 1, 3, 4, 5]
        case .pop:         return [-1, 0, 2, 4, 4, 3, 1, 0, -1, -1]
        case .jazz:        return [4, 3, 1, 2, -1, -1, 0, 1, 3, 4]
        case .classical:   return [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]
        case .electronic:  return [5, 4, 1, 0, -2, 2, 1, 1, 4, 5]
        case .loudness:    return [6, 4, 0, 0, -2, 0, 0, -2, 3, 6]
        }
    }

    /// Finds a preset whose curve matches `gains`, or nil if the curve is custom.
    static func matching(gains: [Float]) -> EqualizerPreset? {
        allCases.first { preset in
            let presetGains = preset.gains
            guard presetGains.count == gains.count else { return false }
            return zip(presetGains, gains).allSatisfy { abs($0 - $1) < 0.01 }
        }
    }
}

/// User-configurable equalizer state, persisted as part of `UserSettings`.
struct EqualizerSettings: Codable, Equatable {
    /// ISO-style 10-band center frequencies (Hz), low to high.
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let gainRange: ClosedRange<Float> = -12...12
    static let preampRange: ClosedRange<Float> = -12...12

    var isEnabled: Bool
    var preamp: Float
    var bands: [EqualizerBand]
    var presetName: String

    var gains: [Float] { bands.map(\.gain) }

    static func makeBands(gains: [Float]) -> [EqualizerBand] {
        frequencies.enumerated().map { index, frequency in
            EqualizerBand(frequency: frequency, gain: index < gains.count ? gains[index] : 0)
        }
    }

    static let `default` = EqualizerSettings(
        isEnabled: false,
        preamp: 0,
        bands: makeBands(gains: EqualizerPreset.flat.gains),
        presetName: EqualizerPreset.flat.rawValue
    )

    private static func clampGain(_ value: Float) -> Float {
        min(max(value, gainRange.lowerBound), gainRange.upperBound)
    }

    private static func clampPreamp(_ value: Float) -> Float {
        min(max(value, preampRange.lowerBound), preampRange.upperBound)
    }

    /// Recomputes `presetName` from the current band gains.
    mutating func refreshPresetName() {
        presetName = EqualizerPreset.matching(gains: gains)?.rawValue ?? EqualizerPreset.customName
    }

    mutating func setGain(_ gain: Float, atBandIndex index: Int) {
        guard bands.indices.contains(index) else { return }
        bands[index].gain = Self.clampGain(gain)
        refreshPresetName()
    }

    mutating func setPreamp(_ value: Float) {
        preamp = Self.clampPreamp(value)
    }

    mutating func apply(preset: EqualizerPreset) {
        bands = Self.makeBands(gains: preset.gains)
        presetName = preset.rawValue
    }

    /// Repairs band count/frequencies after decoding older or malformed data.
    mutating func normalize() {
        if bands.count != Self.frequencies.count
            || zip(bands, Self.frequencies).contains(where: { $0.frequency != $1 }) {
            bands = Self.makeBands(gains: gains)
        }
        for index in bands.indices {
            bands[index].gain = Self.clampGain(bands[index].gain)
        }
        preamp = Self.clampPreamp(preamp)
        refreshPresetName()
    }
}

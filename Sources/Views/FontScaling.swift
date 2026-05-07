import SwiftUI

private struct AppFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var appFontScale: CGFloat {
        get { self[AppFontScaleKey.self] }
        set { self[AppFontScaleKey.self] = newValue }
    }
}

private struct AppSystemFontModifier: ViewModifier {
    @Environment(\.appFontScale) private var appFontScale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigits: Bool

    func body(content: Content) -> some View {
        let resolvedSize = max(1, size * appFontScale)
        let baseFont = Font.system(size: resolvedSize, weight: weight, design: design)
        if monospacedDigits {
            content.font(baseFont.monospacedDigit())
        } else {
            content.font(baseFont)
        }
    }
}

extension View {
    func appFontScale(_ scale: CGFloat) -> some View {
        environment(\.appFontScale, max(0.8, min(1.8, scale)))
    }

    func appFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(
            AppSystemFontModifier(
                size: size,
                weight: weight,
                design: design,
                monospacedDigits: false
            )
        )
    }

    func appMonospacedDigitFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(
            AppSystemFontModifier(
                size: size,
                weight: weight,
                design: design,
                monospacedDigits: true
            )
        )
    }
}

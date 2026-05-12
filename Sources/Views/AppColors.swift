import SwiftUI

extension Color {
    static let grooveOrange = Color(red: 0.94, green: 0.39, blue: 0.00)
    static let grooveWindow = adaptive(light: (0.80, 0.82, 0.84), dark: (0.08, 0.08, 0.09))
    static let grooveSurface = adaptive(light: (0.91, 0.91, 0.89), dark: (0.11, 0.11, 0.12))
    static let grooveSurfaceRaised = adaptive(light: (1.00, 1.00, 1.00), dark: (0.15, 0.15, 0.16))
    static let grooveSurfaceSecondary = adaptive(light: (0.93, 0.93, 0.93), dark: (0.13, 0.13, 0.14))
    static let grooveRowAlternate = adaptive(light: (0.965, 0.965, 0.965), dark: (0.12, 0.12, 0.13))
    static let grooveTextPrimary = adaptive(light: (0.10, 0.10, 0.10), dark: (0.92, 0.92, 0.92))
    static let grooveTextSecondary = adaptive(light: (0.34, 0.34, 0.34), dark: (0.72, 0.72, 0.72))
    static let grooveBorder = adaptive(light: (0.20, 0.20, 0.20), dark: (0.78, 0.78, 0.78), lightAlpha: 0.22, darkAlpha: 0.18)

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat),
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            if match == .darkAqua {
                return NSColor(
                    calibratedRed: dark.0,
                    green: dark.1,
                    blue: dark.2,
                    alpha: darkAlpha
                )
            }
            return NSColor(
                calibratedRed: light.0,
                green: light.1,
                blue: light.2,
                alpha: lightAlpha
            )
        })
    }
}

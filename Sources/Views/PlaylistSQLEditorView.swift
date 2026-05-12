import AppKit
import SwiftUI

struct PlaylistSQLEditorView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @State private var script = """
    -- Example commands:
    NEW PLAYLIST('PlaylistName')
    INSERT Library.ByArtist('Audioslave') INTO Playlist('PlaylistName')
    """
    @State private var output = "Ready."

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Playlist SQL Editor")
                    .appFont(size: 14, weight: .bold)
                Spacer()
                Button("Run Script") {
                    output = player.executePlaylistScript(script)
                }
                .buttonStyle(.borderedProminent)
                Button("Clear Output") {
                    output = "Ready."
                }
                .buttonStyle(.bordered)
            }

            SQLCodeEditor(text: $script)
                .frame(minHeight: 280)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.grooveBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text("Output")
                    .appFont(size: 12, weight: .bold)
                    .foregroundStyle(Color.grooveTextSecondary)
                ScrollView {
                    Text(output)
                        .appMonospacedDigitFont(size: 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .foregroundStyle(Color.grooveTextPrimary)
                        .padding(8)
                }
                .frame(minHeight: 110)
                .background(Color.grooveSurfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.grooveBorder, lineWidth: 1))
            }
        }
        .padding(14)
        .background(Color.grooveSurface)
        .preferredColorScheme(player.darkModeEnabled ? .dark : .light)
    }
}

private struct SQLCodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.delegate = context.coordinator
        textView.string = text
        textView.textColor = NSColor.white
        textView.insertionPointColor = NSColor.white
        textView.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        scroll.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.highlight()
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            highlight()
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let currentString = textView.string
            let selectedRange = textView.selectedRange()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.white,
            ]
            let attributed = NSMutableAttributedString(string: currentString, attributes: attributes)

            applyRegex(#"\b(NEW|PLAYLIST|INSERT|LIBRARY|BYARTIST|INTO)\b"#, color: NSColor.systemOrange, to: attributed)
            applyRegex(#"'[^']*'"#, color: NSColor.systemTeal, to: attributed)
            applyRegex(#"--.*$"#, color: NSColor.systemGray, options: [.anchorsMatchLines], to: attributed)

            storage.setAttributedString(attributed)
            textView.setSelectedRange(selectedRange)
            textView.typingAttributes = attributes
        }

        private func applyRegex(
            _ pattern: String,
            color: NSColor,
            options: NSRegularExpression.Options = [.caseInsensitive],
            to attributed: NSMutableAttributedString
        ) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let range = NSRange(location: 0, length: attributed.length)
            for match in regex.matches(in: attributed.string, options: [], range: range) {
                attributed.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
    }
}

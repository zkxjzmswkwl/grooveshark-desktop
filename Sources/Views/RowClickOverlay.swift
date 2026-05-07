import AppKit
import SwiftUI

struct RowClickOverlay: NSViewRepresentable {
    let onSingleClick: (Bool) -> Void
    let onDoubleClick: () -> Void
    let onSecondaryClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        view.onSecondaryClick = onSecondaryClick
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
        nsView.onSecondaryClick = onSecondaryClick
    }

    final class ClickView: NSView {
        var onSingleClick: ((Bool) -> Void)?
        var onDoubleClick: (() -> Void)?
        var onSecondaryClick: ((CGPoint) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.type == .leftMouseDown, event.modifierFlags.contains(.control) {
                onSecondaryClick?(event.locationInWindow)
                return
            }
            if event.clickCount >= 2 {
                onDoubleClick?()
                return
            }
            onSingleClick?(event.modifierFlags.contains(.command))
        }

        override func rightMouseDown(with event: NSEvent) {
            onSecondaryClick?(event.locationInWindow)
        }
    }
}

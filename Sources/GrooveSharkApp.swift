import AppKit
import AVFoundation
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

@main
enum GrooveSharkLauncher {
    @MainActor
    private static let delegate = DesktopAppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
private final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    private let player = PlayerViewModel()
    private var window: NSWindow?
    @objc private func openSettingsFromMenu(_ sender: Any?) {
        player.isShowingSettings = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()

        let contentView = PlayerView()
            .environmentObject(player)
            .frame(minWidth: 980, minHeight: 620)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "GrooveShark"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func configureMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettingsFromMenu(_:)),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Quit \(appName)",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )

        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}

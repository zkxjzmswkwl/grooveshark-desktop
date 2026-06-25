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
    private var sqlWindow: NSWindow?
    private var chatWindow: NSWindow?
    @objc private func openSettingsFromMenu(_ sender: Any?) {
        player.isShowingSettings = true
    }
    @objc private func openPlaylistSQLEditorFromMenu(_ sender: Any?) {
        if let sqlWindow {
            sqlWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = PlaylistSQLEditorView()
            .environmentObject(player)
            .frame(minWidth: 700, minHeight: 520)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Playlist SQL Editor"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.sqlWindow = window
    }

    @objc private func openChatFromMenu(_ sender: Any?) {
        if let chatWindow {
            chatWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = ChatView()
            .environmentObject(player)
            .frame(minWidth: 480, minHeight: 420)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Chat — #grooveshark"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.chatWindow = window
    }

    @objc private func openYouTubeDownloadFromMenu(_ sender: Any?) {
        player.isShowingYouTubeDownload = true
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

        let sqlItem = NSMenuItem(
            title: "Playlist SQL Editor...",
            action: #selector(openPlaylistSQLEditorFromMenu(_:)),
            keyEquivalent: "l"
        )
        sqlItem.keyEquivalentModifierMask = [.command, .shift]
        sqlItem.target = self
        appMenu.addItem(sqlItem)

        let chatItem = NSMenuItem(
            title: "Chat...",
            action: #selector(openChatFromMenu(_:)),
            keyEquivalent: "c"
        )
        chatItem.keyEquivalentModifierMask = [.command, .shift]
        chatItem.target = self
        appMenu.addItem(chatItem)

        let youtubeItem = NSMenuItem(
            title: "Download from YouTube...",
            action: #selector(openYouTubeDownloadFromMenu(_:)),
            keyEquivalent: "y"
        )
        youtubeItem.keyEquivalentModifierMask = [.command, .shift]
        youtubeItem.target = self
        appMenu.addItem(youtubeItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Quit \(appName)",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )

        appMenuItem.submenu = appMenu
        appMenuItem.submenu?.title = appName

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = standardEditMenu()
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = standardWindowMenu()
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenuItem.submenu
    }

    private func standardEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(
            withTitle: "Paste and Match Style",
            action: #selector(NSTextView.pasteAsPlainText(_:)),
            keyEquivalent: "v"
        ).keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        return menu
    }

    private func standardWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }
}

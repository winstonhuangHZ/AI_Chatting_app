import AppKit
import SwiftUI

/// AppKit application delegate. Sets up the shared stores, the main window
/// hosting SwiftUI content, and a minimal menu with Settings / Quit.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Shared state

    /// Persists API relay profiles.
    let configStore = ConfigStore()

    /// Persists chat sessions.
    let sessionStore = SessionStore()

    /// Drives the chat UI.
    var chatViewModel: ChatViewModel!

    /// Drives the settings UI.
    var appSettingViewModel: AppSettingViewModel!

    /// Main window.
    private var window: NSWindow?

    /// Settings window.
    private var settingsWindow: NSWindow?

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        chatViewModel = ChatViewModel(
            sessionStore: sessionStore,
            configStore: configStore
        )
        appSettingViewModel = AppSettingViewModel(configStore: configStore)

        // Listen for the gear-button notification from the chat top bar.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettingsAction),
            name: .showSettingsNotification,
            object: nil
        )

        setupMenu()
        createMainWindow()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-opens the main window when the user clicks the Dock icon.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Main window

    /// The main window reference (lazily created).
    private var mainWindow: NSWindow? {
        if window == nil { createMainWindow() }
        return window
    }

    private func createMainWindow() {
        let contentView = ContentView()
            .environmentObject(configStore)
            .environmentObject(sessionStore)
            .environmentObject(chatViewModel)

        let hosting = NSHostingView(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Chat"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        window.contentView = hosting
        window.center()
        window.setFrameAutosaveName("AIChatMainWindow")
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    // MARK: - Settings window

    private func showSettings() {
        if let settingsWindow = settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
            .environmentObject(configStore)
            .environmentObject(appSettingViewModel)
            .frame(width: 520, height: 440)

        let hosting = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About AI Chat",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(showSettingsAction),
            keyEquivalent: ","
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Hide AI Chat",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit AI Chat",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            withTitle: "New Chat",
            action: #selector(newChatAction),
            keyEquivalent: "n"
        )
        fileMenuItem.submenu = fileMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu actions

    @objc private func showSettingsAction() {
        showSettings()
    }

    @objc private func newChatAction() {
        chatViewModel.createNewChat()
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
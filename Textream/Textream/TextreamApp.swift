//
//  TextreamApp.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI
import Carbon

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let openAbout = Notification.Name("openAbout")
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var localToggleMonitor: Any?
    private var shortcutObserver: NSObjectProtocol?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        let launchedByURL: Bool
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            launchedByURL = event.eventClass == kInternetEventClass
        } else {
            launchedByURL = false
        }
        if launchedByURL {
            TextreamService.shared.launchedExternally = true
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = TextreamService.shared
        NSUpdateDynamicServices()

        if TextreamService.shared.launchedExternally {
            TextreamService.shared.hideMainWindow()
        }

        // Silent update check on launch
        UpdateChecker.shared.checkForUpdates(silent: true)

        // Start browser server if enabled
        TextreamService.shared.updateBrowserServer()

        // Start director server if enabled
        TextreamService.shared.updateDirectorServer()

        // Set window delegate to intercept close, disable tabs and fullscreen
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is NSPanel) {
                window.delegate = self
                window.tabbingMode = .disallowed
                window.collectionBehavior.remove(.fullScreenPrimary)
                window.collectionBehavior.insert(.fullScreenNone)
            }
            self.removeUnwantedMenus()
            self.installToggleShortcutMonitor()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeToggleShortcutMonitor()
    }

    private func removeUnwantedMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // Remove View and Window menus (keep Edit for copy/paste)
        let menusToRemove = ["View", "Window"]
        for title in menusToRemove {
            if let index = mainMenu.items.firstIndex(where: { $0.title == title }) {
                mainMenu.removeItem(at: index)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if TextreamService.shared.hasUnsavedChanges {
            guard TextreamService.shared.confirmDiscardIfNeeded() else { return false }
        }
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if TextreamService.shared.launchedExternally {
            TextreamService.shared.launchedExternally = false
            NSApp.setActivationPolicy(.regular)
        }
        if !flag {
            // Show existing window instead of letting SwiftUI create a duplicate
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.pathExtension == "textream" {
                TextreamService.shared.openFileAtURL(url)
                // Show the main window for file opens
                for window in NSApp.windows where !(window is NSPanel) {
                    window.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            } else {
                let wasExternal = TextreamService.shared.launchedExternally
                TextreamService.shared.launchedExternally = true
                if !wasExternal {
                    NSApp.setActivationPolicy(.accessory)
                }
                TextreamService.shared.hideMainWindow()
                TextreamService.shared.handleURL(url)
            }
        }
    }

    private func installToggleShortcutMonitor() {
        removeToggleShortcutMonitor()

        installSystemHotKey()

        localToggleMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if NotchSettings.shared.appToggleShortcut.matches(event) {
                self.toggleTextreamVisibility()
                return nil
            }
            return event
        }

        shortcutObserver = NotificationCenter.default.addObserver(
            forName: AppToggleShortcut.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.installToggleShortcutMonitor()
        }
    }

    private func removeToggleShortcutMonitor() {
        if let localToggleMonitor {
            NSEvent.removeMonitor(localToggleMonitor)
        }
        if let shortcutObserver {
            NotificationCenter.default.removeObserver(shortcutObserver)
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
        }
        localToggleMonitor = nil
        shortcutObserver = nil
        hotKeyRef = nil
        hotKeyHandlerRef = nil
    }

    private func installSystemHotKey() {
        let shortcut = NotchSettings.shared.appToggleShortcut

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                appDelegate.toggleTextreamVisibility()
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )

        var hotKeyID = EventHotKeyID(signature: OSType(0x54585452), id: 1) // TXTR
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            print("Could not register global shortcut \(shortcut.label): \(status)")
        }
    }

    func toggleTextreamVisibility() {
        if TextreamService.shared.togglePrompterVisibility() {
            return
        }

        let mainWindows = NSApp.windows.filter { !($0 is NSPanel) }
        let hasVisibleMainWindow = mainWindows.contains { $0.isVisible }

        if NSApp.isHidden || !hasVisibleMainWindow {
            NSApp.unhide(nil)
            NSApp.setActivationPolicy(.regular)
            if let window = mainWindows.first {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.hide(nil)
        }
    }
}

@main
struct TextreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    if url.pathExtension == "textream" {
                        TextreamService.shared.openFileAtURL(url)
                    } else {
                        TextreamService.shared.handleURL(url)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Textream") {
                    NotificationCenter.default.post(name: .openAbout, object: nil)
                }
                Divider()
                Button("Check for Updates…") {
                    UpdateChecker.shared.checkForUpdates()
                }
            }
            CommandGroup(after: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appVisibility) {
                Button("Toggle Prompter Visibility") {
                    (NSApp.delegate as? AppDelegate)?.toggleTextreamVisibility()
                }

                Button("Hide Others") {
                    NSApp.hideOtherApplications(nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .option])

                Button("Show All") {
                    NSApp.unhideAllApplications(nil)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open File or Presentation…") {
                    TextreamService.shared.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Save") {
                    TextreamService.shared.saveFile()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save As…") {
                    TextreamService.shared.saveFileAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .windowArrangement) { }
            CommandGroup(replacing: .help) {
                Button("Textream Help") {
                    if let url = URL(string: "https://github.com/1temporel/textream") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

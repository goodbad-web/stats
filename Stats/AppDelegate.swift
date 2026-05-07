//
//  AppDelegate.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 28.05.2019.
//  Copyright © 2019 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

import Kit
import UserNotifications

import CPU
import RAM
import Disk
import Net
import Battery
import Sensors
import GPU
import Bluetooth
import Clock
import OSLog

let updater = Updater(github: "exelban/stats", url: "https://api.mac-stats.com/release/latest")
private let appLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "eu.exelban.Stats", category: "App")
@MainActor
var modules: [Module] = [
    CPU(),
    GPU(),
    RAM(),
    Disk(),
    Sensors(),
    Network(),
    Battery(),
    Bluetooth(),
    Clock()
]

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    internal let settingsWindow: SettingsWindow = SettingsWindow()
    internal let updateWindow: UpdateWindow = UpdateWindow()
    internal let setupWindow: SetupWindow = SetupWindow()
    internal let supportWindow: SupportWindow = SupportWindow()
    internal let updateActivity = NSBackgroundActivityScheduler(identifier: "eu.exelban.Stats.updateCheck")
    internal let supportActivity = NSBackgroundActivityScheduler(identifier: "eu.exelban.Stats.support")
    internal var clickInNotification: Bool = false
    internal var menuBarItem: NSStatusItem? = nil
    internal var combinedView: CombinedView = CombinedView()
    
    private var globalMonitor: Any? = nil
    private var localMonitor: Any? = nil
    
    internal var pauseState: Bool {
        Store.shared.bool(key: "pause", defaultValue: false)
    }
    
    private var startTS: Date?
    
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let startingPoint = Date()
        
        Task { @MainActor in
            self.parseArguments()
            self.parseVersion()
            SMCHelper.shared.checkForUpdate()
            self.setup {
                modules.reversed().forEach{ $0.mount() }
                self.settingsWindow.setModules()
            }
            self.defaultValues()
            self.icon()
            self.setupMainMenu()
            
            NotificationCenter.default.addObserver(self, selector: #selector(listenForAppPause), name: .pause, object: nil)
            self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                self?.handleKeyEvent(event)
            }
            self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                self?.handleKeyEvent(event)
                return event
            }
            
            appLogger.info("Stats started in \(String(describing: (startingPoint.timeIntervalSinceNow * -1).rounded(toPlaces: 4))) seconds")
            self.startTS = Date()
        }
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        Task {
            await SMCHelper.shared.resetFanControl()
        }
        modules.forEach{ $0.terminate() }
        Remote.shared.terminate()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = self.globalMonitor {
            NSEvent.removeMonitor(monitor)
            self.globalMonitor = nil
        }
        if let monitor = self.localMonitor {
            NSEvent.removeMonitor(monitor)
            self.localMonitor = nil
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if self.clickInNotification {
            self.clickInNotification = false
            return true
        }
        guard let startTS = self.startTS, Date().timeIntervalSince(startTS) > 2 else { return false }
        
        if flag {
            self.settingsWindow.makeKeyAndOrderFront(self)
        } else {
            self.settingsWindow.setIsVisible(true)
        }
        
        return true
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            self.clickInNotification = true
            
            if let uri = response.notification.request.content.userInfo["url"] as? String {
                appLogger.debug("Downloading new version of app…")
                if let url = URL(string: uri) {
                    updater.download(url, completion: { path in
                        updater.install(path: path) { error in
                            if let error {
                                appLogger.error("Update installation failed: \(error, privacy: .public)")
                                showAlert("Error update Stats", error, .critical)
                            }
                        }
                    })
                }
            }
            
            completionHandler()
        }
    }
    
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Stats", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: localizedString("Check for update"), action: #selector(self.checkForNewVersionMenu), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: localizedString("Settings"), action: #selector(self.openSettings), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Stats", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Stats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        
        let fileMenu = NSMenu(title: localizedString("File"))
        fileMenu.addItem(withTitle: localizedString("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        
        let editMenu = NSMenu(title: localizedString("Edit"))
        editMenu.addItem(withTitle: localizedString("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: localizedString("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: localizedString("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: localizedString("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: localizedString("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: localizedString("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        
        let windowMenu = NSMenu(title: localizedString("Window"))
        windowMenu.addItem(withTitle: localizedString("Minimize"), action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: localizedString("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: localizedString("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        
        let helpMenu = NSMenu(title: localizedString("Help"))
        helpMenu.addItem(withTitle: localizedString("Report a bug"), action: #selector(self.reportBugMenu), keyEquivalent: "")
        helpMenu.addItem(withTitle: "GitHub", action: #selector(self.openGitHubMenu), keyEquivalent: "")
        let helpMenuItem = NSMenuItem()
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        
        NSApp.mainMenu = mainMenu
    }
    
    @objc private func checkForNewVersionMenu() {
        Task { @MainActor in
            self.checkForNewVersion()
        }
    }
    
    @objc private func reportBugMenu() {
        NSWorkspace.shared.open(URL(string: "https://github.com/exelban/stats/issues/new?template=bug_report.md")!)
    }
    
    @objc private func openGitHubMenu() {
        NSWorkspace.shared.open(URL(string: "https://github.com/exelban/stats")!)
    }
}


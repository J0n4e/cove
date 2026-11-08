import SwiftUI
import AppKit

@main
struct CoveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var emby = Emby()
    @AppStorage("accent") private var accent = "red"
    @AppStorage("bg") private var bg = "black"
    @AppStorage("theme") private var theme = "apple"
    init() {
        Self.importEmbyFlixSettings()
        Self.scrubEmbyFlixTokens()
        NSApplication.shared.setActivationPolicy(.regular)
        Self.applyIcon()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    /// Dock icon, shown exactly as drawn (newer macOS redraws .icns icons in its own style). The same icon
    /// for both themes (Classic used to switch to AppIconClassic). Loaded from the SwiftPM resource bundle;
    /// Bundle.module crashes if that bundle is missing. The .icns from Info.plist still serves Finder.
    static func applyIcon() {
        let name = "AppIcon"
        if let res = Bundle.main.url(forResource: "Cove_Cove", withExtension: "bundle"),
           let url = Bundle(url: res)?.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = img
        }
    }

    /// Cove used to be EmbyFlix, a separate app with its own preferences. The first time Cove starts it copies
    /// those over (settings, saved servers and sign-ins), so nobody has to set it up again.
    static func importEmbyFlixSettings() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "importedEmbyFlix") else { return }
        d.set(true, forKey: "importedEmbyFlix")
        guard let old = d.persistentDomain(forName: "EmbyFlix"), !old.isEmpty else { return }
        for (key, value) in old where d.object(forKey: key) == nil { d.set(value, forKey: key) }
    }

    /// The EmbyFlix preferences still held a copy of the sign-ins after the import: remove it (Cove keeps its own copy). Runs at every launch, does nothing once it's gone.
    static func scrubEmbyFlixTokens() {
        let d = UserDefaults.standard
        guard var old = d.persistentDomain(forName: "EmbyFlix"), old["token"] != nil || old["servers"] != nil else { return }
        old["token"] = nil; old["servers"] = nil
        d.setPersistentDomain(old, forName: "EmbyFlix")
    }

    var body: some Scene {
        WindowGroup {
            // Classic = the original Cove screens (v1.9.2), Apple TV = the Apple TV screens; switching swaps them all
            Group { if theme == "apple" { RootView() } else { ClassicRootView() } }
                .id(theme)
                .environmentObject(emby)
                .environment(\.appBG, Theme.bg(bg))
                .tint(Theme.accent(accent))
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 650)
                .task { await Updater.shared.checkOnLaunch() }
        }
        .commands {
            // Cove → Settings… (⌘,), as in the Apple TV app
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    if theme == "apple" { NavState.shared.showSettings = true } else { ClassicNavState.shared.showSettings = true }
                }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await Updater.shared.check(interactive: true) } }
            }
        }
        // Videos play in their own window, like the Apple TV app
        Window("Player", id: "player") {
            PlayerWindow()
                .environmentObject(emby)
                .environment(\.appBG, Theme.bg(bg))
                .tint(Theme.accent(accent))
                .preferredColorScheme(.dark)
                .frame(minWidth: 640, minHeight: 360)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 760)
    }
}

/// "v0.5Beta" style version from the app bundle (set by make-app.sh), or "dev" when run from Xcode / swift run.
enum AppVersion {
    static var label: String {
        let i = Bundle.main.infoDictionary
        if let v = i?["CoveVersion"] as? String, !v.isEmpty { return pretty(v) }
        return "dev"
    }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
    /// "v0.4Beta" -> "v0.4 Beta"
    static func pretty(_ v: String) -> String {
        v.replacingOccurrences(of: #"(\d)(Beta|Alpha|RC)"#, with: "$1 $2", options: .regularExpression)
    }
}

/// Closing the window quits the app. Otherwise it kept running with no window, and clicking the Dock
/// icon didn't bring a window back.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

import AppKit

/// Developer aid: `Poptro --snapshot <dir> [--english] [--dark]` renders every
/// settings tab to a PNG in-process (no Screen Recording permission needed) and quits.
@MainActor
enum SnapshotTool {
    static func run(directory: URL, controller: SettingsWindowController) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for tab in SettingsTab.allCases {
            controller.show(tab: tab)
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let window = controller.window, let frameView = window.contentView?.superview else { continue }
            let bounds = frameView.bounds
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            frameView.cacheDisplay(in: bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: directory.appendingPathComponent("settings-\(tab.rawValue)-\(name(tab)).png"))
            }
        }
        if CommandLine.arguments.contains("--live-language") {
            controller.show(tab: .general)
            let store = AppEnvironment.shared.settings
            store.preferences.interfaceLanguage = store.preferences.interfaceLanguage == .chinese ? .english : .chinese
            try? await Task.sleep(nanoseconds: 900_000_000)
            if let frameView = controller.window?.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("live-language.png"))
            }
        }
        NSApp.terminate(nil)
    }

    /// Renders the translation panel after `delay` seconds and quits.
    static func panel(_ panel: FloatingTranslationPanel, to url: URL, delay: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        if let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        NSApp.terminate(nil)
    }

    private static func name(_ tab: SettingsTab) -> String {
        switch tab {
        case .general: return "general"
        case .shortcuts: return "shortcuts"
        case .services: return "services"
        case .advanced: return "advanced"
        case .about: return "about"
        }
    }
}

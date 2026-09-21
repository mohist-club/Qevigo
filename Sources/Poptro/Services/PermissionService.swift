import AppKit
import ApplicationServices

enum PermissionService {
    /// Silent check. Never shows a system prompt.
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt. Only call from an explicit user action.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static var runningLocation: String { Bundle.main.bundleURL.path }
}

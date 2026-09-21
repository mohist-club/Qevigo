import AppKit
import ApplicationServices

@MainActor
final class TextCaptureService {
    /// Selected text: Accessibility first, then a simulated Command-C with the
    /// clipboard restored afterwards. Returns nil when nothing is selected.
    func captureSelectedText() async -> String? {
        if let text = accessibilitySelection(), !text.isEmpty { return text }
        guard PermissionService.isAccessibilityTrusted else { return nil }
        return await copyFallback()
    }

    private func accessibilitySelection() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var selected: AnyObject?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success else {
            return nil
        }
        return selected as? String
    }

    private func copyFallback() async -> String? {
        let pasteboard = NSPasteboard.general
        let previousCount = pasteboard.changeCount
        let backup: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []

        simulateCommandC()

        // Apps take a variable time to answer Command-C; poll instead of a fixed sleep.
        var text: String?
        for _ in 0..<14 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if pasteboard.changeCount != previousCount {
                text = pasteboard.string(forType: .string)
                break
            }
        }

        if pasteboard.changeCount != previousCount {
            pasteboard.clearContents()
            if !backup.isEmpty { pasteboard.writeObjects(backup) }
        }
        return text
    }

    private func simulateCommandC() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let keyC: CGKeyCode = 0x08
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}

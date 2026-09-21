import Foundation
import KeyboardShortcuts
import QevigoCore

extension KeyboardShortcuts.Name {
    /// Control-Option-T by default; Command-G would shadow "Find Next" in every app.
    static let translateSelection = Self("translateSelection", default: .init(.t, modifiers: [.control, .option]))
}

extension Notification.Name {
    /// Posted with `object: true` when a shortcut field starts recording and
    /// `false` when it stops, so live global hotkeys don't fire while recording.
    static let qevigoShortcutRecording = Notification.Name("QevigoShortcutRecording")
}

@MainActor
final class HotkeyService {
    /// Re-registers every global hotkey from scratch.
    func sync(translateEnabled: Bool, bindings: [LaunchBinding], onTranslate: @escaping () -> Void) {
        KeyboardShortcuts.removeAllHandlers()
        if translateEnabled {
            KeyboardShortcuts.onKeyUp(for: .translateSelection, action: onTranslate)
        }
        for binding in bindings where binding.isEnabled {
            KeyboardShortcuts.onKeyUp(for: KeyboardShortcuts.Name(binding.hotkeyName)) { ActionLauncher.execute(binding) }
        }
    }

    func suspend() {
        KeyboardShortcuts.removeAllHandlers()
    }
}

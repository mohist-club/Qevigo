import AppKit
import KeyboardShortcuts
import QevigoCore
import SwiftUI

/// Click-to-record shortcut control. It deliberately avoids
/// `KeyboardShortcuts.Recorder`, whose localized resource bundle lookup can
/// abort inside hand-assembled app bundles; the hotkey engine itself is used.
struct ShortcutField: NSViewRepresentable {
    let name: KeyboardShortcuts.Name
    var width: CGFloat = 200
    var onChange: () -> Void = {}

    func makeNSView(context: Context) -> ShortcutCaptureButton {
        let button = ShortcutCaptureButton()
        button.name = name
        button.onChange = onChange
        button.refresh()
        return button
    }

    func updateNSView(_ button: ShortcutCaptureButton, context: Context) {
        button.name = name
        button.onChange = onChange
        button.widthConstraint.constant = width
        if !button.isRecording { button.refresh() }
    }
}

final class ShortcutCaptureButton: NSButton {
    var name: KeyboardShortcuts.Name?
    var onChange: () -> Void = {}
    private(set) var isRecording = false
    private(set) var widthConstraint: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(beginRecording)
        widthConstraint = widthAnchor.constraint(equalToConstant: 200)
        widthConstraint.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    func refresh() {
        let text = name.flatMap(KeyboardShortcuts.getShortcut(for:)).map { String(describing: $0) }
        attributedTitle = NSAttributedString(
            string: text ?? tr("点击录制", "Click to Record"),
            attributes: [.foregroundColor: text == nil ? NSColor.secondaryLabelColor : NSColor.labelColor]
        )
    }

    @objc private func beginRecording() {
        isRecording = true
        NotificationCenter.default.post(name: .qevigoShortcutRecording, object: true)
        attributedTitle = NSAttributedString(
            string: tr("请按下快捷键…", "Press shortcut…"),
            attributes: [.foregroundColor: NSColor.controlAccentColor]
        )
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        capture(event)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, isRecording { stopRecording() }
        return result
    }

    private func capture(_ event: NSEvent) {
        guard let name else { return }
        switch event.keyCode {
        case 53: // Escape cancels
            finish()
            return
        case 51, 117: // Delete clears
            KeyboardShortcuts.setShortcut(nil, for: name)
            onChange()
            finish()
            return
        default: break
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function])
        let isFunctionKey = (96...111).contains(event.keyCode) || (122...126).contains(event.keyCode)
        guard !modifiers.isEmpty || isFunctionKey, let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
            NSSound.beep()
            return
        }
        KeyboardShortcuts.setShortcut(shortcut, for: name)
        onChange()
        finish()
    }

    private func finish() {
        stopRecording()
        window?.makeFirstResponder(nil)
    }

    private func stopRecording() {
        isRecording = false
        NotificationCenter.default.post(name: .qevigoShortcutRecording, object: false)
        refresh()
    }
}

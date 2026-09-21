import AppKit
import SwiftUI

/// macOS re-applies the "always show scroll bars" preference after the view is
/// mounted, so the overlay style is forced at the property level.
private final class OverlayTextScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        super.scrollerStyle = .overlay
        autohidesScrollers = true
    }
}

/// NSTextView bakes the resolved text color at write time; re-resolve it when
/// the window switches between light and dark.
private final class AppearanceAwareTextView: NSTextView {
    var foregroundOpacity: CGFloat = 0.90

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshForegroundColor()
    }

    func refreshForegroundColor() {
        var color = NSColor.labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.withAlphaComponent(foregroundOpacity)
        }
        textColor = color
        insertionPointColor = color
        textStorage?.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: string.utf16.count))
        var attributes = typingAttributes
        attributes[.foregroundColor] = color
        typingAttributes = attributes
    }

    func applyTypography(font: NSFont, lineSpacing: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        self.font = font
        defaultParagraphStyle = style
        textStorage?.addAttributes(
            [.font: font, .paragraphStyle: style],
            range: NSRange(location: 0, length: string.utf16.count)
        )
        typingAttributes = [.font: font, .paragraphStyle: style]
        refreshForegroundColor()
    }
}

private func makeScrollView(for textView: NSTextView) -> NSScrollView {
    let scrollView = OverlayTextScrollView()
    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.verticalScroller?.controlSize = .mini
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    return scrollView
}

/// Return submits, Shift-Return inserts a newline.
struct SubmitTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 16)
    var foregroundOpacity: CGFloat = 0.90
    var lineSpacing: CGFloat = 4
    var onSubmit: () -> Void
    var onTextViewReady: (NSTextView) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = AppearanceAwareTextView()
        textView.foregroundOpacity = foregroundOpacity
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.applyTypography(font: font, lineSpacing: lineSpacing)
        context.coordinator.textView = textView
        onTextViewReady(textView)
        return makeScrollView(for: textView)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? AppearanceAwareTextView else { return }
        textView.foregroundOpacity = foregroundOpacity
        if textView.string != text { textView.string = text }
        textView.applyTypography(font: font, lineSpacing: lineSpacing)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SubmitTextEditor
        weak var textView: NSTextView?

        init(_ parent: SubmitTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let returns: Set<String> = ["insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertParagraphSeparator:"]
            guard returns.contains(NSStringFromSelector(selector)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            parent.onSubmit()
            return true
        }
    }
}

struct ReadOnlyTextView: NSViewRepresentable {
    let text: String
    var font: NSFont = .systemFont(ofSize: 16)
    var foregroundOpacity: CGFloat = 0.90
    var lineSpacing: CGFloat = 4

    func makeNSView(context: Context) -> NSScrollView {
        let textView = AppearanceAwareTextView()
        textView.foregroundOpacity = foregroundOpacity
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.applyTypography(font: font, lineSpacing: lineSpacing)
        return makeScrollView(for: textView)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? AppearanceAwareTextView else { return }
        textView.foregroundOpacity = foregroundOpacity
        if textView.string != text { textView.string = text }
        textView.applyTypography(font: font, lineSpacing: lineSpacing)
    }
}

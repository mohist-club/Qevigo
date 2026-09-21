import AppKit
import PoptroCore
import SwiftUI

struct PanelActions {
    var translate: () -> Void = {}
    var clear: () -> Void = {}
    var selectProvider: (ProviderID) -> Void = { _ in }
    var pickSourceLanguage: (String) -> Void = { _ in }
    var useAutomaticSource: () -> Void = {}
    var pickTargetLanguage: (String) -> Void = { _ in }
    var swapLanguages: () -> Void = {}
    var openGoogleAI: () -> Void = {}
    var copySource: () -> Void = {}
    var copyTranslation: () -> Void = {}
    var textViewReady: (NSTextView) -> Void = { _ in }
}

private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

private final class DragHandleView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragHandleView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

private struct WindowBackground: View {
    let cornerRadius: CGFloat
    let transparency: Double
    let glassEnabled: Bool

    private var tintOpacity: Double { max(0.08, (1 - transparency) * 0.72) }

    @ViewBuilder
    var body: some View {
        if !glassEnabled {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(
                .regular.tint(Color(nsColor: .windowBackgroundColor).opacity(tintOpacity)),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            VisualEffectBackground(material: .hudWindow)
                .overlay(Color(nsColor: .windowBackgroundColor).opacity(max(0.03, tintOpacity * 0.55)))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

private extension View {
    func neutralSurface(cornerRadius: CGFloat = 9, emphasized: Bool = false) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(emphasized ? 0.72 : 0.50))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(emphasized ? 0.13 : 0.085), lineWidth: 0.7)
        )
    }
}

private struct SelectorLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 34)
        .contentShape(Rectangle())
        .neutralSurface(cornerRadius: 9)
    }
}

struct TranslationPanelView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: SettingsStore
    let actions: PanelActions

    static let cornerRadius: CGFloat = 22
    private let readingFont = NSFont.systemFont(ofSize: 16)

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().opacity(0.62)
            languageBar
            Divider().opacity(0.62)
            content
            Divider().opacity(0.62)
            statusBar
        }
        .background(WindowBackground(
            cornerRadius: Self.cornerRadius,
            transparency: store.preferences.glassTransparency,
            glassEnabled: store.preferences.glassEffectEnabled
        ))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 0.7)
        )
        .background(
            Button("") { actions.copyTranslation() }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
        )
        .id(store.preferences.interfaceLanguage)
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "command")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
                .neutralSurface(cornerRadius: 7)
                .accessibilityHidden(true)
            Text("Poptro").font(.system(size: 13, weight: .semibold))

            Spacer(minLength: 10)

            Button { state.isPinned.toggle() } label: {
                Image(systemName: state.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(state.isPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 30, height: 30)
                    .neutralSurface(cornerRadius: 9, emphasized: state.isPinned)
            }
            .buttonStyle(.plain)
            .help(state.isPinned ? tr("取消锁定窗口", "Unpin Window") : tr("锁定窗口，失去焦点时不自动关闭", "Pin Window: stay open when focus is lost"))

            Button(action: actions.openGoogleAI) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    Text(tr("在 Google AI 中查看", "View in Google AI"))
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .neutralSurface(cornerRadius: 9, emphasized: true)
            }
            .buttonStyle(.plain)
            .disabled(state.trimmedSource.isEmpty)
            .help(tr("将原文发送到 Google AI 模式", "Send source text to Google AI Mode"))
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(WindowDragHandle())
        .background(Color.primary.opacity(0.022))
    }

    // MARK: Language bar

    private var languageBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(tr("原文", "Source")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Menu {
                    Button(tr("自动检测", "Auto Detect")) { actions.useAutomaticSource() }
                    Divider()
                    ForEach(Languages.all) { language in
                        Button(language.localizedName) { actions.pickSourceLanguage(language.code) }
                    }
                } label: {
                    SelectorLabel(title: Languages.name(for: state.sourceLanguageCode))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 150)
                Spacer(minLength: 4)
                iconButton("speaker.wave.2", help: tr("朗读原文", "Speak Source")) {
                    Speech.shared.speak(state.sourceText, languageCode: state.sourceLanguageCode)
                }
                iconButton("doc.on.doc", help: tr("复制原文", "Copy Source"), action: actions.copySource)
            }
            .frame(maxWidth: .infinity)

            Button(action: actions.swapLanguages) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 36, height: 32)
                    .neutralSurface(cornerRadius: 9, emphasized: true)
            }
            .buttonStyle(.plain)
            .disabled(state.sourceText.isEmpty || state.translatedText.isEmpty || state.isLoading)
            .help(tr("互换语言和文本", "Swap Languages and Text"))

            HStack(spacing: 8) {
                Text(tr("译文", "Translation")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Menu {
                    ForEach(Languages.all) { language in
                        Button(language.localizedName) { actions.pickTargetLanguage(language.code) }
                    }
                } label: {
                    SelectorLabel(title: Languages.name(for: state.targetLanguageCode))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 150)
                Spacer(minLength: 4)
                iconButton("speaker.wave.2", help: tr("朗读译文", "Speak Translation")) {
                    Speech.shared.speak(state.translatedText, languageCode: state.targetLanguageCode)
                }
                iconButton("doc.on.doc", help: tr("复制译文", "Copy Translation"), action: actions.copyTranslation)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(Color.primary.opacity(0.025))
    }

    // MARK: Content

    private var content: some View {
        HStack(spacing: 0) {
            pane {
                SubmitTextEditor(
                    text: $state.sourceText, font: readingFont, onSubmit: actions.translate,
                    onTextViewReady: actions.textViewReady
                )
            }
            Divider().opacity(0.62)
            pane { resultContent }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(store.preferences.glassEffectEnabled ? 0.30 : 0.12))
    }

    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
    }

    @ViewBuilder
    private var resultContent: some View {
        if let error = state.errorMessage, state.translatedText.isEmpty {
            Text(error)
                .font(.system(size: 14))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if state.isLoading && state.translatedText.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(loadingText).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if state.translatedText.isEmpty {
            Text(tr("输入原文后按 Return 翻译", "Enter source text, then press Return"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ReadOnlyTextView(text: state.translatedText, font: readingFont)
                if let error = state.errorMessage {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var loadingText: String {
        if let active = state.activeProvider {
            return tr("正在通过 \(active.displayName) 翻译…", "Translating with \(active.displayName)…")
        }
        return tr("翻译中…", "Translating…")
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            providerMenu
            if let notice = state.failoverNotice {
                Label(notice, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(notice)
            }
            Spacer(minLength: 12)
            keyedButton(tr("复制翻译", "Copy Translation"), keys: ["⌘", "↩︎"], emphasized: true, action: actions.copyTranslation)
                .disabled(state.translatedText.isEmpty)
            keyedButton(tr("重置", "Reset"), keys: ["⌘", "⌫"], emphasized: false, action: actions.clear)
                .disabled(state.sourceText.isEmpty && state.translatedText.isEmpty)
                .help(tr("清空原文和译文（Command-Delete）", "Clear source and translation (Command-Delete)"))
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(Color.primary.opacity(0.66))
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(Color.primary.opacity(0.035))
    }

    private var providerMenu: some View {
        Menu {
            ForEach(state.availableProviders) { provider in
                Button {
                    actions.selectProvider(provider)
                } label: {
                    if provider == state.selectedProvider {
                        Label(provider.displayName, systemImage: "checkmark")
                    } else {
                        Text(provider.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: state.availableProviders.isEmpty ? "gearshape" : (state.selectedProvider?.symbol ?? "gearshape"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(providerTitle).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .neutralSurface(cornerRadius: 8)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(state.availableProviders.isEmpty)
        .help(tr("切换已配置的翻译服务", "Switch Configured Translation Service"))
    }

    private var providerTitle: String {
        guard !state.availableProviders.isEmpty else { return tr("未配置服务", "No Configured Service") }
        return (state.selectedProvider ?? state.availableProviders[0]).displayName
    }

    // MARK: Small pieces

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func keyedButton(_ title: String, keys: [String], emphasized: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                HStack(spacing: 3) { ForEach(keys, id: \.self, content: keycap) }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .neutralSurface(cornerRadius: 8, emphasized: emphasized)
        }
        .buttonStyle(.plain)
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9.5, weight: .medium))
            .frame(minWidth: 17, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.6))
    }
}

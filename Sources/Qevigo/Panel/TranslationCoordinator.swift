import AppKit
import QevigoCore

/// The single entry point of a translation: capture text, open the panel, run
/// the router, and keep the panel in sync. Starting a new request cancels the
/// previous one, so a stale result can never overwrite a newer one.
@MainActor
final class TranslationCoordinator {
    private let store: SettingsStore
    private let service: TranslationService
    private let capture = TextCaptureService()
    private var panel: FloatingTranslationPanel?
    private var task: Task<Void, Never>?
    private var isCapturing = false

    init(store: SettingsStore, service: TranslationService) {
        self.store = store
        self.service = service
    }

    var isPanelVisible: Bool { panel?.isVisible ?? false }

    func trigger() {
        guard !isCapturing else { return }
        isCapturing = true
        let mouse = NSEvent.mouseLocation
        Task {
            let captured = await capture.captureSelectedText()
            isCapturing = false
            open(with: captured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", near: mouse)
        }
    }

    /// Opens the panel with fixed text, bypassing text capture (dev snapshots).
    @discardableResult
    func openDemo(text: String) -> FloatingTranslationPanel? {
        open(with: text, near: NSPoint(x: 400, y: 800))
        return panel
    }

    private func open(with text: String, near mouse: NSPoint) {
        task?.cancel()
        panel?.close()

        let panel = makePanel()
        self.panel = panel
        panel.state.sourceIsAutomatic = true
        panel.state.sourceText = text

        if text.isEmpty {
            panel.state.isManualMode = true
            panel.show(near: nil)
            panel.focusInput()
        } else {
            panel.state.isManualMode = false
            panel.show(near: mouse)
            translate(in: panel, target: LanguageDetector.defaultTargetCode(for: text, settings: store.translation))
        }
    }

    private func makePanel() -> FloatingTranslationPanel {
        let panel = FloatingTranslationPanel(store: store) { [unowned self] panel in
            var actions = PanelActions()
            actions.translate = { [weak self, weak panel] in
                guard let self, let panel, !panel.state.trimmedSource.isEmpty else { return }
                self.translate(
                    in: panel,
                    target: LanguageDetector.defaultTargetCode(for: panel.state.trimmedSource, settings: self.store.translation)
                )
            }
            actions.clear = { [weak panel] in panel?.clearAll() }
            actions.selectProvider = { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.select($0, in: panel)
            }
            actions.pickTargetLanguage = { [weak self, weak panel] code in
                guard let self, let panel else { return }
                self.translate(in: panel, target: code)
            }
            actions.pickSourceLanguage = { [weak panel] code in
                panel?.state.sourceLanguageCode = code
                panel?.state.sourceIsAutomatic = false
            }
            actions.useAutomaticSource = { [weak self, weak panel] in
                guard let self, let panel else { return }
                panel.state.sourceIsAutomatic = true
                if !panel.state.trimmedSource.isEmpty {
                    self.translate(in: panel, target: LanguageDetector.defaultTargetCode(for: panel.state.trimmedSource, settings: self.store.translation))
                }
            }
            actions.swapLanguages = { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.swap(in: panel)
            }
            actions.openGoogleAI = { [weak panel] in
                guard let panel else { return }
                Self.openGoogleAI(text: panel.state.trimmedSource, targetCode: panel.state.targetLanguageCode)
            }
            actions.copySource = { [weak panel] in Self.copy(panel?.state.sourceText) }
            actions.copyTranslation = { [weak panel] in Self.copy(panel?.state.translatedText) }
            return actions
        }

        panel.onClear = { [weak self] in self?.task?.cancel() }
        let available = store.availableProviders
        panel.state.availableProviders = available
        panel.state.selectedProvider = store.effectiveProvider
        return panel
    }

    private func select(_ provider: ProviderID, in panel: FloatingTranslationPanel) {
        guard panel.state.availableProviders.contains(provider) else { return }
        store.translation.defaultProvider = provider
        panel.state.selectedProvider = provider
        if !panel.state.trimmedSource.isEmpty {
            translate(in: panel, target: panel.state.targetLanguageCode)
        }
    }

    private func translate(in panel: FloatingTranslationPanel, target: String) {
        let text = panel.state.trimmedSource
        guard !text.isEmpty else { return }

        task?.cancel()
        let state = panel.state
        state.targetLanguageCode = target
        if state.sourceIsAutomatic {
            let detected = LanguageDetector.detectedCode(text)
            state.sourceLanguageCode = detected.isEmpty ? store.translation.secondaryLanguageCode : detected
        }
        state.translatedText = ""
        state.errorMessage = nil
        state.failoverNotice = nil
        state.activeProvider = nil
        state.isLoading = true

        guard let provider = store.effectiveProvider else {
            state.isLoading = false
            state.errorMessage = tr(
                "还没有可用的翻译服务。请在设置 → 翻译服务中启用并填写 API Key。",
                "No translation service is available yet. Enable one and add its API key in Settings → Services."
            )
            return
        }

        let settings = store.translation
        let stream = service.translate(text: text, targetLanguageCode: target, settings: settings, selected: provider)
        task = Task { [weak state] in
            do {
                for try await event in stream {
                    guard let state else { return }
                    switch event {
                    case .attempting(let id):
                        state.activeProvider = id
                    case .token(let token):
                        state.translatedText += token
                    case .fellBack(let from, let error, let next):
                        if let next {
                            state.failoverNotice = tr(
                                "\(from.displayName) \(error.reason)，已切换到 \(next.displayName)",
                                "\(from.displayName): \(error.reason.lowercased()). Switched to \(next.displayName)"
                            )
                        }
                    case .completed(let id):
                        state.activeProvider = id
                    }
                }
                state?.isLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard let state else { return }
                state.isLoading = false
                state.errorMessage = error.localizedDescription
            }
        }
    }

    /// Swaps both sides without a new request: the translation becomes the
    /// source and vice versa.
    private func swap(in panel: FloatingTranslationPanel) {
        let state = panel.state
        let source = state.trimmedSource
        let translated = state.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !translated.isEmpty, !state.isLoading else { return }
        let oldSource = state.sourceLanguageCode
        state.sourceText = translated
        state.translatedText = source
        state.sourceLanguageCode = state.targetLanguageCode
        state.targetLanguageCode = oldSource
        state.sourceIsAutomatic = false
        state.errorMessage = nil
    }

    private static func copy(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func openGoogleAI(text: String, targetCode: String) {
        guard !text.isEmpty else { return }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [
            URLQueryItem(name: "udm", value: "50"),
            URLQueryItem(name: "q", value: "请将下面的内容翻译为\(Languages.chineseName(for: targetCode))：\n\(text)")
        ]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }
}

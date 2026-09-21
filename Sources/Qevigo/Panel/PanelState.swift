import Foundation
import QevigoCore

@MainActor
final class PanelState: ObservableObject {
    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var targetLanguageCode = "EN-US"
    @Published var sourceLanguageCode = "EN-US"
    @Published var sourceIsAutomatic = true
    @Published var selectedProvider: ProviderID?
    @Published var availableProviders: [ProviderID] = []
    /// The service currently answering, or the one that answered.
    @Published var activeProvider: ProviderID?
    /// Shown when the router switched services, e.g. "Groq is rate limited; switched to Cerebras".
    @Published var failoverNotice: String?
    @Published var isPinned = false

    var isManualMode = false

    var trimmedSource: String { sourceText.trimmingCharacters(in: .whitespacesAndNewlines) }
}

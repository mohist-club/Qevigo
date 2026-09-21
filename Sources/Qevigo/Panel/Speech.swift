import AVFoundation

@MainActor
final class Speech {
    static let shared = Speech()
    private let synthesizer = AVSpeechSynthesizer()
    private init() {}

    func speak(_ text: String, languageCode: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.voiceTag(for: languageCode))
        synthesizer.speak(utterance)
    }

    private static func voiceTag(for code: String) -> String {
        switch code {
        case "ZH": return "zh-CN"
        case "JA": return "ja-JP"
        case "KO": return "ko-KR"
        case "EN-GB": return "en-GB"
        case "FR": return "fr-FR"
        case "DE": return "de-DE"
        case "ES": return "es-ES"
        case "IT": return "it-IT"
        case "RU": return "ru-RU"
        case "PT-BR": return "pt-BR"
        case "PT-PT": return "pt-PT"
        case "VI": return "vi-VN"
        case "TH": return "th-TH"
        case "ID": return "id-ID"
        case "NL": return "nl-NL"
        case "PL": return "pl-PL"
        case "TR": return "tr-TR"
        case "AR": return "ar-SA"
        default: return "en-US"
        }
    }
}

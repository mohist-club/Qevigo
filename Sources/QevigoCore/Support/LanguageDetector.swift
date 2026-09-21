import Foundation
import NaturalLanguage

public enum LanguageDetector {
    /// Detects the dominant language with Apple's NaturalLanguage framework and
    /// maps it to a `Languages` code. Returns "" when unknown or unsupported.
    public static func detectedCode(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage else { return "" }
        return code(for: language)
    }

    /// If the text is already in the primary language, translate to the
    /// secondary one; anything else (including "unknown") goes to the primary.
    public static func defaultTargetCode(for text: String, settings: TranslationSettings) -> String {
        let detected = detectedCode(text)
        if !detected.isEmpty, detected == settings.primaryLanguageCode {
            return settings.secondaryLanguageCode
        }
        return settings.primaryLanguageCode
    }

    static func code(for language: NLLanguage) -> String {
        switch language {
        case .simplifiedChinese, .traditionalChinese: return "ZH"
        case .english: return "EN-US"
        case .japanese: return "JA"
        case .korean: return "KO"
        case .french: return "FR"
        case .german: return "DE"
        case .spanish: return "ES"
        case .italian: return "IT"
        case .portuguese: return "PT-BR"
        case .russian: return "RU"
        case .dutch: return "NL"
        case .polish: return "PL"
        case .turkish: return "TR"
        case .vietnamese: return "VI"
        case .thai: return "TH"
        case .indonesian: return "ID"
        case .malay: return "MS"
        case .arabic: return "AR"
        case .hebrew: return "HE"
        case .hindi: return "HI"
        case .bengali: return "BN"
        case .urdu: return "UR"
        case .persian: return "FA"
        case .greek: return "EL"
        case .swedish: return "SV"
        case .danish: return "DA"
        case .finnish: return "FI"
        case .norwegian: return "NB"
        case .czech: return "CS"
        case .slovak: return "SK"
        case .hungarian: return "HU"
        case .romanian: return "RO"
        case .bulgarian: return "BG"
        case .ukrainian: return "UK"
        case .croatian: return "HR"
        case .catalan: return "CA"
        case .icelandic: return "IS"
        case .khmer: return "KM"
        case .burmese: return "MY"
        case .lao: return "LO"
        case .mongolian: return "MN"
        case .tamil: return "TA"
        case .telugu: return "TE"
        case .kannada: return "KN"
        case .malayalam: return "ML"
        case .marathi: return "MR"
        case .gujarati: return "GU"
        case .punjabi: return "PA"
        case .sinhalese: return "SI"
        case .tibetan: return "BO"
        case .armenian: return "HY"
        case .georgian: return "KA"
        case .amharic: return "AM"
        case .kazakh: return "KK"
        default: return ""
        }
    }
}

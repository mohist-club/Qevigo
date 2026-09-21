import Foundation

public struct Language: Hashable, Identifiable, Sendable {
    public let code: String
    public let chinese: String
    public let english: String

    public var id: String { code }

    public var localizedName: String { tr(chinese, english) }
}

public enum Languages {
    public static let all: [Language] = [
        .init(code: "ZH", chinese: "中文(简体)", english: "Chinese (Simplified)"),
        .init(code: "EN-US", chinese: "英语(美式)", english: "English (US)"),
        .init(code: "EN-GB", chinese: "英语(英式)", english: "English (UK)"),
        .init(code: "JA", chinese: "日语", english: "Japanese"),
        .init(code: "KO", chinese: "韩语", english: "Korean"),
        .init(code: "FR", chinese: "法语", english: "French"),
        .init(code: "DE", chinese: "德语", english: "German"),
        .init(code: "ES", chinese: "西班牙语", english: "Spanish"),
        .init(code: "IT", chinese: "意大利语", english: "Italian"),
        .init(code: "PT-BR", chinese: "葡萄牙语(巴西)", english: "Portuguese (Brazil)"),
        .init(code: "PT-PT", chinese: "葡萄牙语(葡萄牙)", english: "Portuguese (Portugal)"),
        .init(code: "RU", chinese: "俄语", english: "Russian"),
        .init(code: "NL", chinese: "荷兰语", english: "Dutch"),
        .init(code: "PL", chinese: "波兰语", english: "Polish"),
        .init(code: "TR", chinese: "土耳其语", english: "Turkish"),
        .init(code: "VI", chinese: "越南语", english: "Vietnamese"),
        .init(code: "TH", chinese: "泰语", english: "Thai"),
        .init(code: "ID", chinese: "印尼语", english: "Indonesian"),
        .init(code: "MS", chinese: "马来语", english: "Malay"),
        .init(code: "AR", chinese: "阿拉伯语", english: "Arabic"),
        .init(code: "HE", chinese: "希伯来语", english: "Hebrew"),
        .init(code: "HI", chinese: "印地语", english: "Hindi"),
        .init(code: "BN", chinese: "孟加拉语", english: "Bengali"),
        .init(code: "UR", chinese: "乌尔都语", english: "Urdu"),
        .init(code: "FA", chinese: "波斯语", english: "Persian"),
        .init(code: "EL", chinese: "希腊语", english: "Greek"),
        .init(code: "SV", chinese: "瑞典语", english: "Swedish"),
        .init(code: "DA", chinese: "丹麦语", english: "Danish"),
        .init(code: "FI", chinese: "芬兰语", english: "Finnish"),
        .init(code: "NB", chinese: "挪威语", english: "Norwegian"),
        .init(code: "CS", chinese: "捷克语", english: "Czech"),
        .init(code: "SK", chinese: "斯洛伐克语", english: "Slovak"),
        .init(code: "HU", chinese: "匈牙利语", english: "Hungarian"),
        .init(code: "RO", chinese: "罗马尼亚语", english: "Romanian"),
        .init(code: "BG", chinese: "保加利亚语", english: "Bulgarian"),
        .init(code: "UK", chinese: "乌克兰语", english: "Ukrainian"),
        .init(code: "HR", chinese: "克罗地亚语", english: "Croatian"),
        .init(code: "SL", chinese: "斯洛文尼亚语", english: "Slovenian"),
        .init(code: "ET", chinese: "爱沙尼亚语", english: "Estonian"),
        .init(code: "LV", chinese: "拉脱维亚语", english: "Latvian"),
        .init(code: "LT", chinese: "立陶宛语", english: "Lithuanian"),
        .init(code: "CA", chinese: "加泰罗尼亚语", english: "Catalan"),
        .init(code: "IS", chinese: "冰岛语", english: "Icelandic"),
        .init(code: "KM", chinese: "高棉语", english: "Khmer"),
        .init(code: "MY", chinese: "缅甸语", english: "Burmese"),
        .init(code: "LO", chinese: "老挝语", english: "Lao"),
        .init(code: "MN", chinese: "蒙古语", english: "Mongolian"),
        .init(code: "TA", chinese: "泰米尔语", english: "Tamil"),
        .init(code: "TE", chinese: "泰卢固语", english: "Telugu"),
        .init(code: "KN", chinese: "卡纳达语", english: "Kannada"),
        .init(code: "ML", chinese: "马拉雅拉姆语", english: "Malayalam"),
        .init(code: "MR", chinese: "马拉地语", english: "Marathi"),
        .init(code: "GU", chinese: "古吉拉特语", english: "Gujarati"),
        .init(code: "PA", chinese: "旁遮普语", english: "Punjabi"),
        .init(code: "SI", chinese: "僧伽罗语", english: "Sinhala"),
        .init(code: "BO", chinese: "藏语", english: "Tibetan"),
        .init(code: "HY", chinese: "亚美尼亚语", english: "Armenian"),
        .init(code: "KA", chinese: "格鲁吉亚语", english: "Georgian"),
        .init(code: "AM", chinese: "阿姆哈拉语", english: "Amharic"),
        .init(code: "KK", chinese: "哈萨克语", english: "Kazakh")
    ]

    private static let byCode = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })

    public static func find(_ code: String) -> Language? { byCode[code] }

    public static func name(for code: String) -> String { byCode[code]?.localizedName ?? code }

    public static func chineseName(for code: String) -> String { byCode[code]?.chinese ?? code }

    /// Target languages DeepL accepts. DeepL silently guesses for unknown codes,
    /// so we reject them up front instead of showing garbage.
    public static let deepLTargets: Set<String> = [
        "ZH", "EN-US", "EN-GB", "JA", "KO", "FR", "DE", "ES", "IT", "PT-BR", "PT-PT",
        "RU", "NL", "PL", "TR", "VI", "ID", "AR", "EL", "SV", "DA", "FI", "NB",
        "CS", "SK", "HU", "RO", "BG", "UK", "ET", "LV", "LT", "SL"
    ]

    /// Language name used inside prompts. Always English so every model
    /// understands it regardless of the UI language.
    public static func promptName(for code: String) -> String { byCode[code]?.english ?? code }
}

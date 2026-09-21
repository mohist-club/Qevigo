import Foundation

public enum PromptBuilder {
    /// Style and format rules only. The direction ("translate into X") is added
    /// per request so it can never contradict this text.
    public static let defaultSystemPrompt = """
    你是一个专业翻译引擎。只输出翻译结果,不要任何解释、不要加引号、不要重复原文。
    - 如果输入只是一个单词或短语:给出最常用、最贴切的译文;若该词有多个常见含义,用"; "分隔列出最多3个,不加编号。
    - 如果输入是完整句子或长文:保持原意准确、语句通顺自然,符合目标语言的表达习惯,不要逐字直译。
    - 保留原文中的专业术语、人名、品牌名、代码片段、数字和单位格式,不要擅自转换单位。
    - 保留原文的段落结构和换行。
    """

    public static func systemPrompt(base: String, targetLanguageCode: String) -> String {
        let target = Languages.promptName(for: targetLanguageCode)
        return base + "\n\nThis request: whatever the source language is, translate into \"\(target)\" and output only the translation."
    }
}

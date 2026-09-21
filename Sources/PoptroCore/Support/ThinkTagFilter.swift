import Foundation

/// Removes `<think>…</think>` reasoning blocks from a token stream. Several
/// open models (Qwen3, DeepSeek-R1 distills) emit them inline, and they must not
/// end up in the translation. Tags can be split across chunks, so the filter
/// buffers a possible partial tag.
public struct ThinkTagFilter {
    private var pending = ""
    private var isInsideThink = false
    private static let open = "<think>"
    private static let close = "</think>"

    public init() {}

    public mutating func push(_ chunk: String) -> String {
        pending += chunk
        var output = ""
        while true {
            let marker = isInsideThink ? Self.close : Self.open
            if let range = pending.range(of: marker) {
                if !isInsideThink { output += pending[..<range.lowerBound] }
                pending = String(pending[range.upperBound...])
                isInsideThink.toggle()
                if !isInsideThink { pending = String(pending.drop(while: { $0 == "\n" })) }
                continue
            }
            // Keep a tail that could be the start of the marker.
            let keep = Self.partialSuffixLength(of: pending, marker: marker)
            let safeEnd = pending.index(pending.endIndex, offsetBy: -keep)
            if !isInsideThink { output += pending[..<safeEnd] }
            pending = String(pending[safeEnd...])
            return output
        }
    }

    public mutating func finish() -> String {
        defer { pending = "" }
        return isInsideThink ? "" : pending
    }

    private static func partialSuffixLength(of text: String, marker: String) -> Int {
        let maxLength = min(text.count, marker.count - 1)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) where marker.hasPrefix(text.suffix(length)) {
            return length
        }
        return 0
    }
}

import Foundation

/// Where the floating translation window was last placed.
public struct PanelFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Size is only reused once the user resized the window by hand.
    public var wasManuallyResized: Bool

    public init(x: Double, y: Double, width: Double, height: Double, wasManuallyResized: Bool) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.wasManuallyResized = wasManuallyResized
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 400
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 340
        wasManuallyResized = try c.decodeIfPresent(Bool.self, forKey: .wasManuallyResized) ?? false
    }
}

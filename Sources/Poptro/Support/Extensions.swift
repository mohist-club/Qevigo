import AppKit
import PoptroCore

extension AppearanceMode {
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
}

extension ProviderID {
    var descriptor: ProviderDescriptor { ProviderCatalog.descriptor(for: self) }
    var displayName: String { descriptor.displayName }
    var symbol: String { descriptor.symbol }
}

extension Notification.Name {
    static let poptroOpenSettings = Notification.Name("PoptroOpenSettings")
}

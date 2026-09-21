import Foundation

enum AppInfo {
    static let name = "Qevigo"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static let originalProject = URL(string: "https://github.com/mohist-club/Poptro")!
    static let issuesURL = URL(string: "https://github.com/mohist-club/Qevigo/issues")!
}

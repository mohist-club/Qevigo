import Foundation

enum AppInfo {
    static let name = "Qevigo"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static let author = "Wayne"
    static let authorURL = URL(string: "https://moaclab.com/u/wayne")!
    static let repositoryURL = URL(string: "https://github.com/mohist-club/Qevigo")!
    static let issuesURL = URL(string: "https://github.com/mohist-club/Qevigo/issues")!
}

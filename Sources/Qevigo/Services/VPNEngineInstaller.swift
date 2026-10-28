import CryptoKit
import Foundation
import QevigoCore

/// Downloads the self-contained openvpn engine so a VPN works on a Mac with
/// neither Homebrew nor another VPN client. The download is refused unless it
/// matches the digest pinned in this app, and it is checked once more by
/// running it, so a file that is not openvpn never becomes the engine.
@MainActor
final class VPNEngineInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case verifying
        case installed(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    var isWorking: Bool {
        switch state {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    func install(_ engine: OpenVPN.Engine = OpenVPN.downloadableEngine) async {
        state = .downloading(0)
        do {
            let data = try await download(engine.url)
            state = .verifying
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == engine.sha256 else {
                // Either the download was damaged or the file is not the one
                // this version of Qevigo was built to trust.
                throw Failure(tr(
                    "下载内容校验失败，已丢弃。请稍后重试。",
                    "The download did not match the expected checksum and was discarded. Try again later."
                ))
            }
            let path = try write(data)
            guard await runsAsOpenVPN(path) else {
                try? FileManager.default.removeItem(atPath: path)
                throw Failure(tr("下载的文件无法运行。", "The downloaded file could not be run."))
            }
            state = .installed(path)
        } catch let failure as Failure {
            state = .failed(failure.message)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func download(_ url: URL) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw Failure(tr("下载失败，请检查网络。", "Download failed; check your connection."))
        }
        let expected = http.expectedContentLength
        var data = Data()
        data.reserveCapacity(expected > 0 ? Int(expected) : 4_000_000)
        for try await byte in bytes {
            data.append(byte)
            if expected > 0, data.count % 65_536 == 0 {
                state = .downloading(Double(data.count) / Double(expected))
            }
        }
        return data
    }

    private func write(_ data: Data) throws -> String {
        let manager = FileManager.default
        let path = OpenVPN.managedBinaryPath
        let directory = (path as NSString).deletingLastPathComponent
        try manager.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        // Replacing a running binary in place would be refused, so write beside it.
        let staged = path + ".new"
        try? manager.removeItem(atPath: staged)
        try data.write(to: URL(fileURLWithPath: staged), options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged)
        try? manager.removeItem(atPath: path)
        try manager.moveItem(atPath: staged, toPath: path)
        return path
    }

    private func runsAsOpenVPN(_ path: String) async -> Bool {
        guard let output = try? await ActionLauncher.runSpec(OpenVPN.versionSpec(binary: path)) else { return false }
        return OpenVPN.isOpenVPNVersionOutput(output)
    }
}

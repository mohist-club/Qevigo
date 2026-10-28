import AppKit
import QevigoCore
import SwiftUI

/// Live numbers for the tunnel, sampled only while the menu is open.
@MainActor
final class VPNStatusModel: ObservableObject {
    @Published private(set) var name = ""
    @Published private(set) var isConnected = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var traffic: TunnelTraffic?
    @Published private(set) var downRate: Double = 0
    @Published private(set) var upRate: Double = 0
    @Published private(set) var location: ExitLocation?
    @Published private(set) var isLookingUpLocation = false

    private var binding: LaunchBinding?
    private var interface: String?
    private var lastSample: (traffic: TunnelTraffic, at: Date)?
    private var ticker: Task<Void, Never>?
    /// Identifies one connection, so the exit address is looked up once per tunnel.
    private var lookedUpConnection: String?

    func start(binding: LaunchBinding) {
        self.binding = binding
        name = binding.name
        refresh()
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.refresh()
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        lastSample = nil
    }

    private func refresh() {
        guard let binding else { return }
        let config = binding.payload
        let connected = OpenVPN.isConnected(config: config)
        isConnected = connected
        guard connected else {
            interface = nil
            traffic = nil
            location = nil
            lookedUpConnection = nil
            downRate = 0
            upRate = 0
            return
        }

        let pidPath = OpenVPN.pidPath(forConfig: config)
        let started = (try? FileManager.default.attributesOfItem(atPath: pidPath)[.modificationDate] as? Date) ?? nil
        duration = started.map { Date().timeIntervalSince($0) } ?? 0

        if interface == nil, let log = try? String(contentsOfFile: OpenVPN.logPath(forConfig: config), encoding: .utf8) {
            interface = VPNStatistics.tunnelInterface(log: log)
        }
        guard let interface else { return }

        if let output = try? shell("/usr/sbin/netstat", ["-ib"]),
           let sample = VPNStatistics.traffic(netstat: output, interface: interface) {
            if let last = lastSample {
                let rate = VPNStatistics.rate(from: last.traffic, to: sample, seconds: Date().timeIntervalSince(last.at))
                downRate = rate.down
                upRate = rate.up
            }
            lastSample = (sample, Date())
            traffic = sample
        }

        // One lookup per connection: it leaves the machine, so it is not repeated.
        let connectionID = interface + (started.map { "\($0.timeIntervalSince1970)" } ?? "")
        if lookedUpConnection != connectionID {
            lookedUpConnection = connectionID
            Task { await lookUpLocation() }
        }
    }

    private func lookUpLocation() async {
        isLookingUpLocation = true
        defer { isLookingUpLocation = false }
        var request = URLRequest(url: ExitLocation.lookupURL)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }
        location = ExitLocation.parse(data)
    }

    private func shell(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// The VPN summary at the top of the menu bar menu.
struct VPNStatusView: View {
    @ObservedObject var model: VPNStatusModel
    var onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isConnected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(model.name).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 6)
                Text(model.isConnected ? VPNStatistics.formatDuration(model.duration) : tr("未连接", "Not connected"))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if model.isConnected {
                exitRow
                HStack(spacing: 14) {
                    rate(symbol: "arrow.down", value: model.downRate, total: model.traffic?.received)
                    rate(symbol: "arrow.up", value: model.upRate, total: model.traffic?.sent)
                }
            }

            Button(model.isConnected ? tr("断开", "Disconnect") : tr("连接", "Connect"), action: onToggle)
                .controlSize(.small)
                .padding(.top, 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: 260, alignment: .leading)
    }

    @ViewBuilder
    private var exitRow: some View {
        if let location = model.location {
            HStack(spacing: 6) {
                if let flag = location.flag { Text(flag).font(.system(size: 13)) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(location.ip).font(.system(size: 12)).monospacedDigit().textSelection(.enabled)
                    if !location.place.isEmpty {
                        Text(location.place).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            Text(model.isLookingUpLocation ? tr("正在查询出口 IP…", "Looking up exit IP…") : tr("出口 IP 未知", "Exit IP unknown"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func rate(symbol: String, value: Double, total: UInt64?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(VPNStatistics.formatRate(bytesPerSecond: value))
                    .font(.system(size: 11)).monospacedDigit()
                if let total {
                    Text(VPNStatistics.formatBytes(total))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }
}

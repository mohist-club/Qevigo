import Foundation

/// What the menu bar shows about a live tunnel. Everything here is derived
/// from files and counters the system already keeps, so nothing extra has to
/// run while a VPN is connected.
public struct TunnelTraffic: Equatable, Sendable {
    public let received: UInt64
    public let sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received
        self.sent = sent
    }
}

public enum VPNStatistics {
    /// openvpn names the interface it took in its log.
    public static func tunnelInterface(log: String) -> String? {
        // "Opened utun device utun6", and the older "utun device [utun6] opened".
        for line in log.split(whereSeparator: \.isNewline).reversed() {
            if let range = line.range(of: #"utun\d+"#, options: .regularExpression) {
                guard line.contains("Opened") || line.contains("opened") else { continue }
                return String(line[range])
            }
        }
        return nil
    }

    /// How the byte counters are read.
    ///
    /// `-n` is not optional: without it netstat resolves every address it
    /// prints through DNS, which on a machine with a tunnel up took five
    /// seconds a call — and the menu bar samples this while it is open.
    public static let trafficCommand = (executable: "/usr/sbin/netstat", arguments: ["-ibn"])

    /// Byte counters for one interface, from `netstat -ibn`.
    ///
    /// Columns are counted from the end — Ipkts Ierrs Ibytes Opkts Oerrs
    /// Obytes Coll — because the Address column is empty for a tunnel but
    /// holds a MAC address for ethernet, so the fields do not line up.
    public static func traffic(netstat output: String, interface: String) -> TunnelTraffic? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 10, fields[0] == interface, fields[2].hasPrefix("<Link") else { continue }
            guard let received = UInt64(fields[fields.count - 5]),
                  let sent = UInt64(fields[fields.count - 2]) else { continue }
            return TunnelTraffic(received: received, sent: sent)
        }
        return nil
    }

    /// "1.2 GB", "340 KB". Uses the same units as the Finder.
    public static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    public static func formatRate(bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1 else { return "0 KB/s" }
        return formatBytes(UInt64(bytesPerSecond)) + "/s"
    }

    /// "1:05:03" while connected for over an hour, "12:34" below that.
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Bytes per second between two samples.
    public static func rate(from previous: TunnelTraffic, to current: TunnelTraffic, seconds: TimeInterval) -> (down: Double, up: Double) {
        guard seconds > 0 else { return (0, 0) }
        // Counters reset when the interface is recreated.
        let received = current.received >= previous.received ? current.received - previous.received : current.received
        let sent = current.sent >= previous.sent ? current.sent - previous.sent : current.sent
        return (Double(received) / seconds, Double(sent) / seconds)
    }
}

/// Where the traffic comes out, as reported by ipinfo.io.
public struct ExitLocation: Equatable, Sendable {
    public let ip: String
    public let city: String?
    public let region: String?
    public let country: String?
    public let organisation: String?

    public init(ip: String, city: String? = nil, region: String? = nil, country: String? = nil, organisation: String? = nil) {
        self.ip = ip
        self.city = city
        self.region = region
        self.country = country
        self.organisation = organisation
    }

    /// "Singapore, SG" — the most specific place the service knew.
    public var place: String {
        let parts = [city, region].compactMap { $0 }.filter { !$0.isEmpty }
        let name = parts.first.map { city == region ? $0 : parts.joined(separator: ", ") }
        return [name, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// 🇸🇬 from "SG", so the menu can show the country at a glance.
    public var flag: String? {
        guard let country, country.count == 2 else { return nil }
        let base: UInt32 = 127_397
        var flag = ""
        for scalar in country.uppercased().unicodeScalars {
            guard let converted = UnicodeScalar(base + scalar.value) else { return nil }
            flag.unicodeScalars.append(converted)
        }
        return flag
    }

    public static func parse(_ data: Data) -> ExitLocation? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = json["ip"] as? String, !ip.isEmpty else { return nil }
        return ExitLocation(
            ip: ip,
            city: json["city"] as? String,
            region: json["region"] as? String,
            country: json["country"] as? String,
            organisation: json["org"] as? String
        )
    }

    public static let lookupURL = URL(string: "https://ipinfo.io/json")!
}

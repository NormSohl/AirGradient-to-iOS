import Foundation

/// A monitor the app knows about, and how to reach it.
///
/// Two sources, deliberately one type: a local device on the LAN, or one
/// location on an AirGradient cloud account. Everything downstream — tiles,
/// charts, history — works the same either way, and only `AirGradientClient`
/// cares which it is.
struct Monitor: Codable, Hashable, Identifiable {
    enum Source: Codable, Hashable {
        /// `host` is a bare hostname or IP — `airgradient_ecda3b1a2b3c.local`
        /// or `192.168.1.42`. No scheme, no path; the client builds those.
        case local(host: String)
        /// `locationId` as reported by the cloud for this token's account.
        case cloud(locationId: Int)
        /// Generated readings, no device. See `DemoSource`.
        case demo
    }

    var id: UUID = UUID()
    var name: String
    var source: Source

    /// Filled in from the first successful reading, then kept, so the detail
    /// page can still say what the device is while it is unreachable.
    var serial: String?
    var model: String?
    var firmware: String?

    var isLocal: Bool { if case .local = source { return true }; return false }
    /// Deliberately not `isLocal`: the demo has no device to calibrate, so the
    /// local controls must stay hidden for it.
    var isDemo: Bool { source == .demo }

    var subtitle: String {
        switch source {
        case .local(let host): host
        case .cloud: "AirGradient cloud"
        case .demo: "Sample data — no device"
        }
    }
}

/// User preferences. Small enough that one `@AppStorage`-backed blob beats a
/// key per field, and it is passed explicitly into `Metric.value(from:)` so the
/// formatting rules have no hidden global to read.
struct Settings: Codable, Hashable {
    var fahrenheit: Bool = false
    /// Prefer AirGradient's corrected PM2.5 / temperature / humidity where the
    /// firmware reports them.
    var useCompensated: Bool = true
    /// Seconds between polls while the app is in the foreground. The device
    /// samples about every 2 s; anything faster than 5 s is just heat.
    var refreshInterval: Double = 10
    /// Long-term API token from dashboard.airgradient.com. Empty = local only.
    var cloudToken: String = ""

    static let refreshChoices: [Double] = [5, 10, 30, 60, 300]

    static func refreshLabel(_ v: Double) -> String {
        v < 60 ? "\(Int(v))s" : "\(Int(v / 60)) min"
    }
}

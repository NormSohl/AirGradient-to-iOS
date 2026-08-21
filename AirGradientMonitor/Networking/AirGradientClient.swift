import Foundation

enum AirGradientError: LocalizedError {
    case badURL
    case http(Int)
    case noCloudToken
    case locationMissing(Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .badURL: "That address isn't a valid hostname or IP."
        case .http(let code):
            switch code {
            case 401, 403: "The cloud rejected the API token."
            case 404: "The monitor answered, but not with measurements — check the firmware version (3.0.10+ serves /measures/current)."
            default: "The monitor answered with HTTP \(code)."
            }
        case .noCloudToken: "No AirGradient API token set. Add one in Settings."
        case .locationMissing(let id): "Location \(id) is not in this account any more."
        case .transport(let why): why
        }
    }
}

/// Talks to both AirGradient surfaces.
///
/// An `actor` because the cloud path caches one fetch across every cloud
/// monitor: `/locations/measures/current` returns *all* of an account's
/// locations in one response, so polling five cloud monitors must not be five
/// round trips — and without serialised access, five concurrent refreshes would
/// each miss the cache and fire anyway.
actor AirGradientClient {
    static let shared = AirGradientClient()

    private let session: URLSession
    private var cloudCache: (fetched: Date, byLocation: [Int: Reading])?
    /// How long one cloud fetch is reused. The cloud aggregates in ~5 min
    /// buckets, so re-asking every 10 s buys nothing but rate-limit risk.
    private let cloudCacheTTL: TimeInterval = 60

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            // A monitor that has dropped off the WiFi must fail fast: this
            // timeout is what the refresh loop's cadence actually depends on.
            cfg.timeoutIntervalForRequest = 6
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Reading

    func reading(for monitor: Monitor, token: String) async throws -> Reading {
        switch monitor.source {
        case .local(let host):
            return try await localReading(host: host)
        case .cloud(let locationId):
            let all = try await cloudReadings(token: token)
            guard let r = all[locationId] else { throw AirGradientError.locationMissing(locationId) }
            return r
        case .demo:
            // MonitorsModel answers demo monitors without coming here, but a
            // client that lies about a source it was handed is worse than one
            // extra line.
            return DemoSource.reading(at: Date())
        }
    }

    func localReading(host: String) async throws -> Reading {
        guard let url = Self.localURL(host: host, path: "/measures/current") else {
            throw AirGradientError.badURL
        }
        let data = try await get(url)
        return try JSONDecoder().decode(Reading.self, from: data)
    }

    /// Every location on the account, keyed by `locationId`.
    func cloudReadings(token: String, force: Bool = false) async throws -> [Int: Reading] {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw AirGradientError.noCloudToken }

        if !force, let c = cloudCache, Date().timeIntervalSince(c.fetched) < cloudCacheTTL {
            return c.byLocation
        }

        var comps = URLComponents(string: "https://api.airgradient.com/public/api/v1/locations/measures/current")!
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comps.url else { throw AirGradientError.badURL }

        let data = try await get(url)
        let readings = try JSONDecoder().decode([Reading].self, from: data)
        var byLocation: [Int: Reading] = [:]
        for r in readings { if let id = r.locationId { byLocation[id] = r } }
        cloudCache = (Date(), byLocation)
        return byLocation
    }

    /// Discovery for the cloud: what locations does this token see?
    func cloudLocations(token: String) async throws -> [(id: Int, name: String)] {
        let all = try await cloudReadings(token: token, force: true)
        return all
            .map { (id: $0.key, name: $0.value.locationName ?? "Location \($0.key)") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Local configuration

    /// `PUT /config` on a local device. Only ever called with a body the user
    /// asked for from the device page; the endpoint can also change the device's
    /// cloud-vs-local control mode, which this app never touches.
    func putConfig(host: String, body: [String: Bool]) async throws {
        guard let url = Self.localURL(host: host, path: "/config") else { throw AirGradientError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // JSONEncoder, not JSONSerialization: a Swift Bool round-trips through
        // NSNumber there, and the device expects `true`, not `1`.
        req.httpBody = try JSONEncoder().encode(body)
        _ = try await perform(req)
    }

    // MARK: - Plumbing

    /// Accepts what a person would actually type — `192.168.1.42`,
    /// `airgradient_abc123.local`, or a full `http://…` URL pasted out of a
    /// browser — and normalises it. A bare `.local` name needs no scheme typed.
    static func localURL(host: String, path: String) -> URL? {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        if let parsed = URLComponents(string: h), let parsedHost = parsed.host, parsed.scheme != nil {
            h = parsedHost + (parsed.port.map { ":\($0)" } ?? "")
        }
        h = h.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !h.contains(" ") else { return nil }
        return URL(string: "http://\(h)\(path)")
    }

    private func get(_ url: URL) async throws -> Data {
        try await perform(URLRequest(url: url))
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw AirGradientError.http(http.statusCode)
            }
            return data
        } catch let e as AirGradientError {
            throw e
        } catch let e as URLError {
            throw AirGradientError.transport(Self.describe(e))
        }
    }

    private static func describe(_ e: URLError) -> String {
        switch e.code {
        case .timedOut: "The monitor didn't answer in time."
        case .cannotFindHost: "Can't find that monitor on the network."
        case .cannotConnectToHost: "The monitor refused the connection."
        case .notConnectedToInternet: "This iPhone isn't on a network."
        case .networkConnectionLost: "The network connection dropped."
        default: e.localizedDescription
        }
    }
}

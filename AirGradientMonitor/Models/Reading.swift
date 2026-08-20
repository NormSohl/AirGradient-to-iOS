import Foundation

/// One sample from an AirGradient monitor.
///
/// Decodes both shapes the hardware/cloud speak:
///   * the local server  — `GET http://airgradient_<serial>.local/measures/current`
///   * the cloud API v1  — `GET /public/api/v1/locations/measures/current?token=…`
///
/// Every measurement is optional on purpose. The two AirGradient models report
/// different sensor sets (Open Air has no PM 5.0/10 particle counts, the ONE has
/// no compensated temp/humidity of its own), firmware versions add fields over
/// time, and a sensor that has not warmed up yet reports nothing rather than
/// zero. A missing value must render as "—", never as 0, or a dead CO2 sensor
/// looks like the cleanest air in the building.
struct Reading: Codable, Hashable, Identifiable {
    var id: Date { timestamp }

    /// When this app received the sample. The device does not stamp its own
    /// readings (it has no RTC); the cloud does, and `timestamp` is overwritten
    /// with the cloud's value when one is present.
    var timestamp: Date = Date()

    // Particulate matter, µg/m³.
    var pm01: Double?
    var pm02: Double?
    var pm10: Double?
    /// PM2.5 after AirGradient's humidity correction (firmware 3.1.4+).
    var pm02Compensated: Double?

    /// Particles ≥0.3 µm per dL.
    var pm003Count: Double?

    /// CO2, ppm.
    var rco2: Double?

    /// Temperature, °C (always Celsius on the wire, whatever the device display
    /// is set to).
    var atmp: Double?
    var atmpCompensated: Double?

    /// Relative humidity, %.
    var rhum: Double?
    var rhumCompensated: Double?

    /// Sensirion indices: 1…500, where 100 is "typical for this room over the
    /// last day". Not a concentration — see `Metric.tvoc` for how it is banded.
    var tvocIndex: Double?
    var noxIndex: Double?
    var tvocRaw: Double?
    var noxRaw: Double?

    /// WiFi RSSI, dBm.
    var wifi: Double?

    var serialno: String?
    var firmware: String?
    var model: String?

    /// Cloud-only: the location this reading belongs to.
    var locationId: Int?
    var locationName: String?

    enum CodingKeys: String, CodingKey {
        case pm01, pm02, pm10, pm02Compensated, pm003Count
        case rco2, atmp, atmpCompensated, rhum, rhumCompensated
        case tvocIndex, noxIndex, tvocRaw, noxRaw
        case wifi, serialno, firmware, model
        case locationId, locationName
        // Cloud spellings of fields the local server names differently.
        case firmwareVersion
        case tvoc
        case timestamp
        case pm003_count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        pm01 = c.number(.pm01)
        pm02 = c.number(.pm02)
        pm10 = c.number(.pm10)
        pm02Compensated = c.number(.pm02Compensated)
        pm003Count = c.number(.pm003Count) ?? c.number(.pm003_count)
        rco2 = c.number(.rco2)
        atmp = c.number(.atmp)
        atmpCompensated = c.number(.atmpCompensated)
        rhum = c.number(.rhum)
        rhumCompensated = c.number(.rhumCompensated)
        tvocIndex = c.number(.tvocIndex) ?? c.number(.tvoc)
        noxIndex = c.number(.noxIndex)
        tvocRaw = c.number(.tvocRaw)
        noxRaw = c.number(.noxRaw)
        wifi = c.number(.wifi)

        serialno = try c.decodeIfPresent(String.self, forKey: .serialno)
        if let fw = try c.decodeIfPresent(String.self, forKey: .firmware) {
            firmware = fw
        } else {
            firmware = try c.decodeIfPresent(String.self, forKey: .firmwareVersion)
        }
        model = try c.decodeIfPresent(String.self, forKey: .model)

        locationId = try c.decodeIfPresent(Int.self, forKey: .locationId)
        locationName = try c.decodeIfPresent(String.self, forKey: .locationName)

        // The cloud stamps "2026-08-20T17:04:00.000Z"; the local server sends
        // no timestamp at all, in which case "now" is the honest answer.
        if let raw = try c.decodeIfPresent(String.self, forKey: .timestamp),
           let parsed = Reading.isoParse(raw) {
            timestamp = parsed
        } else {
            timestamp = Date()
        }
    }

    init(timestamp: Date = Date()) {
        self.timestamp = timestamp
    }

    /// Written explicitly rather than synthesised: `CodingKeys` carries the
    /// cloud's alternate spellings (`tvoc`, `firmwareVersion`, `pm003_count`),
    /// which have no stored property of their own, so there is nothing for the
    /// compiler to synthesise an encoder from. Encoding is only used for the
    /// on-disk history, so it always writes the canonical local-server names.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Reading.isoWithFraction.string(from: timestamp), forKey: .timestamp)
        try c.encodeIfPresent(pm01, forKey: .pm01)
        try c.encodeIfPresent(pm02, forKey: .pm02)
        try c.encodeIfPresent(pm10, forKey: .pm10)
        try c.encodeIfPresent(pm02Compensated, forKey: .pm02Compensated)
        try c.encodeIfPresent(pm003Count, forKey: .pm003Count)
        try c.encodeIfPresent(rco2, forKey: .rco2)
        try c.encodeIfPresent(atmp, forKey: .atmp)
        try c.encodeIfPresent(atmpCompensated, forKey: .atmpCompensated)
        try c.encodeIfPresent(rhum, forKey: .rhum)
        try c.encodeIfPresent(rhumCompensated, forKey: .rhumCompensated)
        try c.encodeIfPresent(tvocIndex, forKey: .tvocIndex)
        try c.encodeIfPresent(noxIndex, forKey: .noxIndex)
        try c.encodeIfPresent(tvocRaw, forKey: .tvocRaw)
        try c.encodeIfPresent(noxRaw, forKey: .noxRaw)
        try c.encodeIfPresent(wifi, forKey: .wifi)
        try c.encodeIfPresent(serialno, forKey: .serialno)
        try c.encodeIfPresent(firmware, forKey: .firmware)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(locationId, forKey: .locationId)
        try c.encodeIfPresent(locationName, forKey: .locationName)
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func isoParse(_ s: String) -> Date? {
        isoWithFraction.date(from: s) ?? isoPlain.date(from: s)
    }
}

private extension KeyedDecodingContainer where K == Reading.CodingKeys {
    /// AirGradient sends numbers as JSON numbers, but the cloud has been seen
    /// quoting some of them, and both send `null` for a sensor that has no
    /// value yet. Accept all three rather than failing the whole decode — one
    /// odd field must not cost the other twenty.
    func number(_ key: K) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }
}

import SwiftUI

/// Where a reading sits on its own scale. Drives colour everywhere in the app,
/// so a bad number looks bad on the dashboard tile, in the detail card and on
/// the chart without each of them re-deciding.
enum QualityBand: Int, Comparable, CaseIterable {
    case good = 0, moderate, unhealthySensitive, unhealthy, veryUnhealthy, hazardous

    static func < (a: QualityBand, b: QualityBand) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .good: "Good"
        case .moderate: "Moderate"
        case .unhealthySensitive: "Unhealthy for sensitive groups"
        case .unhealthy: "Unhealthy"
        case .veryUnhealthy: "Very unhealthy"
        case .hazardous: "Hazardous"
        }
    }

    var shortLabel: String {
        switch self {
        case .good: "Good"
        case .moderate: "Moderate"
        case .unhealthySensitive: "Sensitive"
        case .unhealthy: "Unhealthy"
        case .veryUnhealthy: "Very bad"
        case .hazardous: "Hazardous"
        }
    }

    /// The EPA AQI palette, darkened enough to hold white text and to stay
    /// distinguishable in dark mode. Deliberately not `.green`/`.yellow`/`.red`
    /// straight from SwiftUI — system yellow on white is unreadable.
    var color: Color {
        switch self {
        case .good: Color(red: 0.13, green: 0.62, blue: 0.35)
        case .moderate: Color(red: 0.85, green: 0.65, blue: 0.10)
        case .unhealthySensitive: Color(red: 0.90, green: 0.46, blue: 0.13)
        case .unhealthy: Color(red: 0.84, green: 0.22, blue: 0.22)
        case .veryUnhealthy: Color(red: 0.55, green: 0.20, blue: 0.60)
        case .hazardous: Color(red: 0.50, green: 0.13, blue: 0.18)
        }
    }
}

/// One displayable quantity: how to pull it out of a `Reading`, how to format
/// it, and how to judge it.
enum Metric: String, CaseIterable, Identifiable {
    case aqi, pm25, pm10, pm01, co2, temperature, humidity, tvoc, nox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aqi: "AQI"
        case .pm25: "PM2.5"
        case .pm10: "PM10"
        case .pm01: "PM1"
        case .co2: "CO₂"
        case .temperature: "Temperature"
        case .humidity: "Humidity"
        case .tvoc: "VOC index"
        case .nox: "NOx index"
        }
    }

    var symbol: String {
        switch self {
        case .aqi: "gauge.medium"
        case .pm25, .pm10, .pm01: "aqi.medium"
        case .co2: "carbon.dioxide.cloud"
        case .temperature: "thermometer.medium"
        case .humidity: "humidity"
        case .tvoc: "aqi.low"
        case .nox: "wind"
        }
    }

    /// Unit shown next to the value. Temperature is the one that depends on a
    /// setting, so it is resolved by the caller through `unit(for:)`.
    func unit(fahrenheit: Bool) -> String {
        switch self {
        case .aqi: ""
        case .pm25, .pm10, .pm01: "µg/m³"
        case .co2: "ppm"
        case .temperature: fahrenheit ? "°F" : "°C"
        case .humidity: "%"
        case .tvoc, .nox: ""
        }
    }

    /// Pull this metric out of a reading, in display units.
    ///
    /// `compensated` selects AirGradient's corrected PM2.5 / temp / humidity
    /// where the firmware provides them; it falls back to the raw value rather
    /// than showing nothing, because older firmware sends only the raw field.
    func value(from r: Reading, settings: Settings) -> Double? {
        switch self {
        case .aqi:
            return AQI.overall(
                pm25: Metric.pm25.value(from: r, settings: settings),
                pm10: Metric.pm10.value(from: r, settings: settings)
            )
        case .pm25:
            let v = settings.useCompensated ? (r.pm02Compensated ?? r.pm02) : r.pm02
            return v
        case .pm10: return r.pm10
        case .pm01: return r.pm01
        case .co2: return r.rco2
        case .temperature:
            guard let c = settings.useCompensated ? (r.atmpCompensated ?? r.atmp) : r.atmp else { return nil }
            return settings.fahrenheit ? c * 9 / 5 + 32 : c
        case .humidity: return settings.useCompensated ? (r.rhumCompensated ?? r.rhum) : r.rhum
        case .tvoc: return r.tvocIndex
        case .nox: return r.noxIndex
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .aqi: String(format: "%.0f", v)
        case .pm25, .pm10, .pm01: v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)
        case .co2, .tvoc, .nox: String(format: "%.0f", v)
        case .temperature: String(format: "%.1f", v)
        case .humidity: String(format: "%.0f", v)
        }
    }

    /// `value` is in display units, so temperature has to come back to Celsius
    /// before it can be judged — otherwise 72 °F reads as a fever.
    func band(_ value: Double, fahrenheit: Bool = false) -> QualityBand {
        switch self {
        case .aqi: return AQI.band(aqi: value)
        case .pm25: return AQI.band(pm25: value)
        case .pm10: return AQI.band(pm10: value)
        case .pm01: return AQI.band(pm25: value) // no EPA scale for PM1; PM2.5's is the closest honest proxy
        case .co2: return AQI.band(co2: value)
        case .tvoc, .nox: return AQI.bandSensirionIndex(value)
        case .temperature:
            let c = fahrenheit ? (value - 32) * 5 / 9 : value
            return AQI.band(temperatureC: c)
        case .humidity: return AQI.band(humidity: value)
        }
    }
}

enum AQI {
    /// US EPA PM2.5 breakpoints, 2024 revision (the "Good" ceiling moved from
    /// 12.0 to 9.0 µg/m³ — an app still using 12 calls half a wildfire day fine).
    private static let pm25Breakpoints: [(lo: Double, hi: Double, aqiLo: Double, aqiHi: Double)] = [
        (0.0, 9.0, 0, 50),
        (9.1, 35.4, 51, 100),
        (35.5, 55.4, 101, 150),
        (55.5, 125.4, 151, 200),
        (125.5, 225.4, 201, 300),
        (225.5, 325.4, 301, 500),
    ]

    private static let pm10Breakpoints: [(lo: Double, hi: Double, aqiLo: Double, aqiHi: Double)] = [
        (0, 54, 0, 50),
        (55, 154, 51, 100),
        (155, 254, 101, 150),
        (255, 354, 151, 200),
        (355, 424, 201, 300),
        (425, 604, 301, 500),
    ]

    /// Piecewise-linear AQI from a PM2.5 concentration, µg/m³.
    ///
    /// The concentration is truncated first — to 0.1 for PM2.5, to 1 for PM10 —
    /// because that is what the EPA's own procedure does, and because the
    /// breakpoint table has deliberate gaps (9.0 then 9.1) that a raw sensor
    /// value can land inside.
    static func aqi(pm25: Double) -> Double {
        interpolate((pm25 * 10).rounded(.down) / 10, pm25Breakpoints)
    }

    static func aqi(pm10: Double) -> Double {
        interpolate(pm10.rounded(.down), pm10Breakpoints)
    }

    private static func interpolate(_ c: Double, _ table: [(lo: Double, hi: Double, aqiLo: Double, aqiHi: Double)]) -> Double {
        guard c > 0 else { return 0 }
        for b in table where c <= b.hi {
            let lo = max(b.lo, 0)
            guard b.hi > lo else { return b.aqiHi }
            return (b.aqiHi - b.aqiLo) * (c - lo) / (b.hi - lo) + b.aqiLo
        }
        return 500
    }

    static func band(aqi: Double) -> QualityBand {
        switch aqi {
        case ..<51: .good
        case ..<101: .moderate
        case ..<151: .unhealthySensitive
        case ..<201: .unhealthy
        case ..<301: .veryUnhealthy
        default: .hazardous
        }
    }

    static func band(pm25: Double) -> QualityBand { band(aqi: aqi(pm25: pm25)) }
    static func band(pm10: Double) -> QualityBand { band(aqi: aqi(pm10: pm10)) }

    /// The AQI actually reported by AirNow et al.: the worst of the sub-indices
    /// for whichever pollutants are being measured, not an average of them —
    /// one bad pollutant is what you breathe, not diluted by a clean one.
    /// Either input may be missing (Open Air's PM10 warms up separately from
    /// its PM2.5, and older firmware may send neither), so this is `nil` only
    /// when both are.
    static func overall(pm25: Double?, pm10: Double?) -> Double? {
        let subindices = [pm25.map(aqi(pm25:)), pm10.map(aqi(pm10:))].compactMap { $0 }
        return subindices.max()
    }

    /// Indoor CO2 bands, matching how AirGradient's own LED bar is documented:
    /// outdoor air is ~420 ppm, 1000 is the classic ventilation threshold, and
    /// above 2000 people measurably lose concentration.
    static func band(co2: Double) -> QualityBand {
        switch co2 {
        case ..<800: .good
        case ..<1000: .moderate
        case ..<1500: .unhealthySensitive
        case ..<2000: .unhealthy
        case ..<3000: .veryUnhealthy
        default: .hazardous
        }
    }

    /// Sensirion VOC/NOx index. 100 is "the running average for this room", so
    /// the scale is relative — a steady 100 is normal, not a warning.
    static func bandSensirionIndex(_ v: Double) -> QualityBand {
        switch v {
        case ..<101: .good
        case ..<151: .moderate
        case ..<201: .unhealthySensitive
        case ..<301: .unhealthy
        case ..<401: .veryUnhealthy
        default: .hazardous
        }
    }

    /// Comfort, not health: these only ever tint a card, and never claim a
    /// temperature is "hazardous".
    static func band(temperatureC c: Double) -> QualityBand {
        if (18...25).contains(c) { return .good }
        if (15...28).contains(c) { return .moderate }
        return .unhealthySensitive
    }

    static func band(humidity h: Double) -> QualityBand {
        if (30...60).contains(h) { return .good }
        if (20...70).contains(h) { return .moderate }
        return .unhealthySensitive
    }
}

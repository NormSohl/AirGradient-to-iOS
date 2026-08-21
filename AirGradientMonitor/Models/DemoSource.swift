import Foundation

/// Synthetic readings for a monitor that isn't there.
///
/// This exists for App Review. A reviewer has no AirGradient hardware, so
/// without it the app they receive shows an empty state, finds nothing on the
/// network, and reads as incomplete — Guideline 2.1 — however well it works in
/// a house with a monitor in it. It is equally the way anyone can see what the
/// app does before buying a device.
///
/// The numbers are generated from the clock, not recorded, so the demo is the
/// same story whenever it is opened: a room that is fine overnight, stuffy by
/// morning, and briefly smoky around dinner. That last part is deliberate —
/// the band colouring and the AQI wording only mean anything if something
/// crosses a threshold, and a demo that is green all day demonstrates nothing.
enum DemoSource {
    static let name = "Demo monitor"

    static var monitor: Monitor {
        Monitor(name: name, source: .demo, serial: "demo", model: "I-9PSL", firmware: "3.6.2")
    }

    /// Deterministic pseudo-noise in -1...1, keyed to the minute so a reading
    /// re-generated for the same instant is identical. Nothing here may use
    /// `random()`: the chart would jitter every time the view redrew.
    private static func wobble(_ date: Date, salt: Int) -> Double {
        var h = UInt64(bitPattern: Int64(date.timeIntervalSinceReferenceDate / 60)) &+ UInt64(salt &* 2_654_435_761)
        h ^= h >> 33; h = h &* 0xff51afd7ed558ccd
        h ^= h >> 33; h = h &* 0xc4ceb9fe1a85ec53
        h ^= h >> 33
        return Double(h % 2000) / 1000.0 - 1.0
    }

    /// Hours since local midnight, fractional.
    private static func hourOfDay(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    /// A plausible room at a given moment.
    static func reading(at date: Date) -> Reading {
        let hour = hourOfDay(date)

        // CO2: climbs through the night in a closed bedroom, falls once the
        // house is up and doors start opening.
        let occupied = hour < 7 || hour > 21
        let nightRamp = hour < 7 ? (hour + 3) / 10 : (hour - 21) / 10
        var co2 = 480 + (occupied ? 620 * max(0, min(1, nightRamp)) : 90 * sin((hour - 7) / 14 * .pi))
        co2 += wobble(date, salt: 1) * 25

        // PM2.5: low all day, with a cooking spike around dinner. This is the
        // part that pushes a tile into amber and colours the chart.
        let cooking = exp(-pow(hour - 18.4, 2) / 0.5) * 34
        var pm25 = 1.8 + cooking + wobble(date, salt: 2) * 0.9
        pm25 = max(0, pm25)

        // Temperature drifts a couple of degrees over the day; humidity runs
        // against it, as it does in a real room.
        let temp = 21.4 + 1.9 * sin((hour - 9) / 24 * 2 * .pi) + wobble(date, salt: 3) * 0.25
        let humidity = 47 - 5 * sin((hour - 9) / 24 * 2 * .pi) + wobble(date, salt: 4) * 1.2

        // Sensirion indices: 100 is "normal for this room", so VOC sits near it
        // and lifts with the cooking rather than tracking particles exactly.
        let voc = 96 + cooking * 2.4 + wobble(date, salt: 5) * 9
        let nox = 1 + max(0, cooking * 0.35) + max(0, wobble(date, salt: 6)) * 2

        var r = Reading(timestamp: date)
        r.pm01 = (pm25 * 0.72).rounded(to: 0.1)
        r.pm02 = pm25.rounded(to: 0.1)
        r.pm02Compensated = (pm25 * 0.94 + 0.3).rounded(to: 0.1)
        r.pm10 = (pm25 * 1.18 + 0.4).rounded(to: 0.1)
        r.pm003Count = (pm25 * 11 + 6).rounded()
        r.rco2 = co2.rounded()
        r.atmp = temp.rounded(to: 0.1)
        r.atmpCompensated = temp.rounded(to: 0.1)
        r.rhum = humidity.rounded()
        r.rhumCompensated = humidity.rounded()
        r.tvocIndex = voc.rounded()
        r.noxIndex = nox.rounded()
        r.tvocRaw = (30000 + voc * 12).rounded()
        r.noxRaw = (16000 + nox * 30).rounded()
        r.wifi = -52 + (wobble(date, salt: 7) * 6).rounded()
        r.serialno = "demo"
        r.model = "I-9PSL"
        r.firmware = "3.6.2"
        return r
    }

    /// Two days of back-history, so the charts have something to say the
    /// instant the demo is added rather than after an hour of watching.
    ///
    /// The step stays under `HistorySection`'s gap threshold on purpose —
    /// sampled any sparser, every point would read as a break in recording and
    /// the demo would draw as confetti.
    static func backfill(now: Date = Date()) -> [Reading] {
        let step: TimeInterval = 120
        let start = now.addingTimeInterval(-48 * 3600)
        return stride(from: start.timeIntervalSinceReferenceDate,
                      through: now.timeIntervalSinceReferenceDate,
                      by: step)
            .map { reading(at: Date(timeIntervalSinceReferenceDate: $0)) }
    }
}

private extension Double {
    func rounded(to unit: Double) -> Double { (self / unit).rounded() * unit }
}

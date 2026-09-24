import Foundation

// A plain executable rather than an XCTest target: the project uses
// file-system-synchronized groups (objectVersion 77), and hand-editing the
// pbxproj to add a test target is a worse risk than this is a limitation.
// `Tests/run.sh` compiles the model layer together with this file for macOS and
// runs it. No simulator, no scheme, no Xcode.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if !condition {
        failures += 1
        let d = detail()
        print("  FAIL  \(what)" + (d.isEmpty ? "" : "  — \(d)"))
    }
}

func section(_ name: String) { print("\n\(name)") }

func fixture(_ name: String) -> Data {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return try! Data(contentsOf: here.appendingPathComponent("Fixtures/\(name)"))
}

// MARK: - Decoding real payloads

section("Reading — real public monitors (world/locations/measures/current)")
do {
    let data = fixture("world-current.json")
    let raw = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    let readings = try! JSONDecoder().decode([Reading].self, from: data)

    check(readings.count == raw.count, "every record decodes", "\(readings.count) of \(raw.count)")

    // The rule the whole app rests on: a sensor that reported nothing must not
    // become a zero. These are real monitors, so the nulls are real too.
    var nullFields = 0, invented = 0
    for (r, j) in zip(readings, raw) {
        func compare(_ key: String, _ value: Double?) {
            let isNull = j[key] is NSNull || j[key] == nil
            if isNull {
                nullFields += 1
                if value != nil { invented += 1 }
            }
        }
        compare("rco2", r.rco2)
        compare("pm02", r.pm02)
        compare("atmp", r.atmp)
        // tvocIndex is deliberately excluded: it falls back to `tvoc` by
        // design, so a null there legitimately becomes a value. Asserted
        // explicitly below rather than swept into this rule.
    }
    check(nullFields > 100, "the corpus actually contains nulls", "\(nullFields) null fields")
    check(invented == 0, "no null is decoded as a value", "\(invented) invented")

    // Unknown keys (offline, heatindex, timezone, placeId …) must not break it.
    let extras = Set(raw.flatMap { $0.keys }).subtracting([
        "pm01","pm02","pm10","pm003Count","rco2","atmp","rhum","tvoc","tvocIndex",
        "noxIndex","wifi","timestamp","model","firmwareVersion","locationId","locationName",
    ])
    check(!extras.isEmpty, "corpus has fields we don't model", "\(extras.count): \(extras.sorted().prefix(4).joined(separator: ", "))…")

    // tvocIndex must win over tvoc: both are present on real records, and tvoc
    // is the raw ppb value, often null.
    var bothPresent = 0
    for (r, j) in zip(readings, raw) {
        if let idx = j["tvocIndex"] as? Double, j["tvoc"] is Double {
            bothPresent += 1
            check(r.tvocIndex == idx, "tvocIndex wins over tvoc", "got \(r.tvocIndex ?? -1), expected \(idx)")
        }
    }
    check(bothPresent > 10, "corpus exercises the tvoc/tvocIndex overlap", "\(bothPresent) records")

    // …and where the index is missing but the raw value is not, the fallback
    // fires. This is the one place a null is allowed to become a number.
    var fellBack = 0
    for (r, j) in zip(readings, raw) {
        let indexNull = j["tvocIndex"] is NSNull || j["tvocIndex"] == nil
        if indexNull, let rawTvoc = j["tvoc"] as? Double {
            fellBack += 1
            check(r.tvocIndex == rawTvoc, "tvoc fills in for a missing tvocIndex")
        } else if indexNull {
            check(r.tvocIndex == nil, "no tvocIndex and no tvoc stays nil")
        }
    }
    check(fellBack > 5, "corpus exercises the fallback", "\(fellBack) records")
}

section("Reading — cloud history (locations/{id}/measures/past)")
do {
    let data = fixture("cloud-past.json")
    let raw = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    let readings = try! JSONDecoder().decode([Reading].self, from: data)
    check(readings.count == raw.count, "every historical record decodes")

    // The bug that shipped: the cloud says _corrected where the local server
    // says Compensated, so every corrected value silently decoded as nil and
    // the tiles quietly fell back to raw.
    let withCorrected = zip(readings, raw).filter { $0.1["pm02_corrected"] is Double }
    check(!withCorrected.isEmpty, "fixture carries _corrected fields", "\(withCorrected.count)")
    for (r, j) in withCorrected.prefix(30) {
        check(r.pm02Compensated == (j["pm02_corrected"] as? Double), "pm02_corrected → pm02Compensated")
        check(r.atmpCompensated == (j["atmp_corrected"] as? Double), "atmp_corrected → atmpCompensated")
        check(r.rhumCompensated == (j["rhum_corrected"] as? Double), "rhum_corrected → rhumCompensated")
    }

    // The cloud stamps an ISO timestamp; the local server sends none.
    let stamped = readings.filter { $0.timestamp.timeIntervalSince1970 > 1_600_000_000 }
    check(stamped.count == readings.count, "timestamps parse", "\(stamped.count) of \(readings.count)")
    let ordered = zip(readings, readings.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }
    check(ordered, "history is chronological")
}

section("Reading — local server (/measures/current)")
do {
    let data = fixture("local-current.json")
    let r = try! JSONDecoder().decode(Reading.self, from: data)
    let j = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    check(r.pm02 == j["pm02"] as? Double, "pm02 decodes")
    check(r.pm02Compensated == j["pm02Compensated"] as? Double, "local spelling still works")
    check(r.rco2 == j["rco2"] as? Double, "rco2 decodes")
    check(r.firmware == j["firmware"] as? String, "firmware decodes")
    // No timestamp on the wire: "now" is the honest answer, not 1970.
    check(abs(r.timestamp.timeIntervalSinceNow) < 5, "missing timestamp becomes now")
}

// MARK: - Banding

section("AQI banding")
do {
    check(AQI.band(pm25: 9.0) == .good, "PM2.5 9.0 is the top of Good")
    check(AQI.band(pm25: 9.1) == .moderate, "PM2.5 9.1 is Moderate")
    check(AQI.band(pm25: 9.04) == .good, "PM2.5 truncates to 0.1 before banding")
    check(AQI.band(pm25: 0) == .good, "PM2.5 zero is Good, not missing")
    check(AQI.band(pm25: 300) == .hazardous, "PM2.5 300 is Hazardous")

    check(AQI.band(co2: 799) == .good, "CO2 799 Good")
    check(AQI.band(co2: 800) == .moderate, "CO2 800 Moderate")

    // Sensirion indices are relative: 100 is this room's own baseline.
    check(AQI.bandSensirionIndex(100) == .good, "VOC index 100 is normal")
    check(AQI.bandSensirionIndex(101) == .moderate, "VOC index 101 tips over")

    // Temperature is judged in Celsius whatever the display units.
    let settings = Settings()
    var f = settings; f.fahrenheit = true
    check(Metric.temperature.band(72, fahrenheit: true) == Metric.temperature.band(22.2, fahrenheit: false),
          "72F and 22.2C band the same")

    // Overall AQI is the worse of the PM2.5 and PM10 sub-indices, not their
    // average or the first one that happens to be present.
    check(AQI.overall(pm25: 9.0, pm10: 54) == AQI.aqi(pm25: 9.0), "PM2.5 and PM10 agree at 50")
    check(AQI.overall(pm25: 9.0, pm10: 154) == AQI.aqi(pm10: 154), "worse PM10 sub-index wins")
    check(AQI.overall(pm25: 35.4, pm10: 55) == AQI.aqi(pm25: 35.4), "worse PM2.5 sub-index wins")
    check(AQI.overall(pm25: 9.0, pm10: nil) == AQI.aqi(pm25: 9.0), "falls back to PM2.5 alone")
    check(AQI.overall(pm25: nil, pm10: 54) == AQI.aqi(pm10: 54), "falls back to PM10 alone")
    check(AQI.overall(pm25: nil, pm10: nil) == nil, "nil only when both inputs are nil")

    var r = Reading()
    r.pm02 = 9.0
    r.pm10 = 154
    check(Metric.aqi.value(from: r, settings: settings) == AQI.aqi(pm10: 154),
          "Metric.aqi reads both PM fields off a Reading")
    check(Metric.aqi.band(Metric.aqi.value(from: r, settings: settings)!) == .moderate,
          "the combined AQI value bands like any other AQI number")
}

// MARK: - Series shaping

section("SeriesShaping.segments")
do {
    let t0 = Date()
    func s(_ offsets: [TimeInterval]) -> [SeriesShaping.Sample] {
        offsets.map { SeriesShaping.Sample(date: t0.addingTimeInterval($0), band: .good) }
    }
    let minute = s([0, 60, 120, 180])
    check(Set(SeriesShaping.segments(minute, expectedSpacing: 60, fineWindow: 48*3600, now: t0)).count == 1,
          "steady 1/min is one segment")

    let hole = s([0, 60, 6000, 6060])
    let seg = SeriesShaping.segments(hole, expectedSpacing: 60, fineWindow: 48*3600, now: t0)
    check(Set(seg).count == 2, "a 98-minute hole breaks the line", "\(seg)")

    // The bug: cloud buckets are five minutes apart by design.
    let cloud = s([0, 300, 600, 900, 1200])
    check(Set(SeriesShaping.segments(cloud, expectedSpacing: 60, fineWindow: 48*3600, now: t0)).count == 5,
          "cloud spacing shatters under the local rule (this is why the rule asks the source)")
    check(Set(SeriesShaping.segments(cloud, expectedSpacing: 300, fineWindow: 48*3600, now: t0)).count == 1,
          "cloud spacing is one segment under the cloud rule")

    // Rolled-up hourly points are an hour apart on purpose.
    let old: [TimeInterval] = [-50*3600, -49*3600, -48*3600]
    let oldSamples = old.map {
        SeriesShaping.Sample(date: t0.addingTimeInterval($0), band: .good)
    }
    check(Set(SeriesShaping.segments(oldSamples, expectedSpacing: 60, fineWindow: 48*3600, now: t0)).count == 1,
          "hourly rollups are not gaps")
}

section("SeriesShaping.bandRuns")
do {
    let t0 = Date()
    func sample(_ i: Int, _ band: QualityBand) -> SeriesShaping.Sample {
        SeriesShaping.Sample(date: t0.addingTimeInterval(Double(i) * 300), band: band)
    }

    // The regression that matters: a short, tall spike inside a long calm
    // stretch must keep its own colour. Folding it away by span fraction is
    // what painted a half-hour VOC spike of 490 green across a week.
    var week = (0..<2000).map { sample($0, .good) }
    for i in 900..<912 { week[i] = sample(i, .unhealthy) }   // ~1 hour of 2016
    let runs = SeriesShaping.bandRuns(week)
    check(runs.contains { $0.band == .unhealthy }, "a 1-hour spike in a week keeps its colour")
    if let spike = runs.first(where: { $0.band == .unhealthy }) {
        check(spike.start > 0.4 && spike.end < 0.5, "the spike is in the right place", "\(spike.start)…\(spike.end)")
    }

    // Single-sample dithering across a boundary should still be folded away.
    var noisy = (0..<400).map { sample($0, .good) }
    for i in stride(from: 10, to: 390, by: 2) { noisy[i] = sample(i, .moderate) }
    let noisyRuns = SeriesShaping.bandRuns(noisy)
    check(noisyRuns.count < 20, "single-sample dithering folds away", "\(noisyRuns.count) runs")

    // Runs are ordered and cover 0...1 without going backwards.
    let ordered = zip(runs, runs.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-9 }
    check(ordered, "runs are monotonic")
    check(runs.first?.start == 0 && abs((runs.last?.end ?? 0) - 1) < 1e-9, "runs span the series")

    check(SeriesShaping.bandRuns([]).isEmpty, "empty series yields no runs")
    check(SeriesShaping.bandRuns([sample(0, .good)]).count == 1, "a single sample is one run")
}

// MARK: - Chart ranges

section("HistoryRange")
do {
    // The bug this replaced: ticks sized from the data, capped at one a day, so
    // a month of history drew thirty unreadable slots. Every range must land
    // on a readable tick count at both widths, wherever "now" falls.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let base = cal.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 13))!
    for range in HistoryRange.allCases {
        for compact in [false, true] {
            let step = range.axisStride(compact: compact)
            var counts: [Int] = []
            // A span of "nows", including across a DST change (Mar 8).
            for offsetHours in stride(from: 0, to: 24 * 40, by: 7) {
                let now = base.addingTimeInterval(TimeInterval(offsetHours) * 3600)
                let start = now.addingTimeInterval(-range.duration)
                var tick = cal.dateInterval(of: step.component == .weekOfYear ? .weekOfYear : step.component,
                                            for: start)!.start
                var n = 0
                while tick <= now {
                    if tick >= start { n += 1 }
                    tick = cal.date(byAdding: step.component, value: step.count, to: tick)!
                }
                counts.append(n)
            }
            let lo = counts.min()!, hi = counts.max()!
            check(lo >= 3 && hi <= 13, "\(range.title) \(compact ? "compact" : "regular") tick count readable",
                  "\(lo)…\(hi) ticks")
        }
    }

    check(HistoryRange.year.duration >= 365 * 24 * 3600, "Year reaches back as far as retention keeps")
}

// MARK: - Cloud history

section("CloudHistoryPlan")
do {
    let now = Date(timeIntervalSinceReferenceDate: 811_000_000 + 1234)   // deliberately mid-hour
    let apiLimit: TimeInterval = 10 * 24 * 3600
    let earliest = CloudHistoryPlan.hourStart(now.addingTimeInterval(-CloudHistoryPlan.reach))
    func onHour(_ d: Date) -> Bool { d.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) == 0 }
    func contiguous(_ s: [DateInterval]) -> Bool { zip(s, s.dropFirst()).allSatisfy { $0.end == $1.start } }

    let fresh = CloudHistoryPlan.catchUp(newest: nil, now: now)
    check(fresh.count == 1 && onHour(fresh[0].start) && fresh[0].end == now,
          "nothing stored: one slice, on the hour, up to now")

    let newest = now.addingTimeInterval(-20 * 60)
    let steady = CloudHistoryPlan.catchUp(newest: newest, now: now)
    check(steady.count == 1 && steady[0].start == CloudHistoryPlan.hourStart(newest).addingTimeInterval(-3600),
          "caught up: refetch from an hour before the newest point", "\(steady)")
    check(steady[0].duration <= 3 * 3600, "caught up: a refresh is a couple of hours, not a week",
          "\(steady[0].duration / 3600) h")

    // Away for 25 days: the hole is filled going forward, in legal slices.
    let away = CloudHistoryPlan.catchUp(newest: now.addingTimeInterval(-25 * 24 * 3600), now: now)
    check(away.count == 3 && contiguous(away) && away.last?.end == now,
          "after an absence: contiguous slices up to now", "\(away.count) slices")
    check(away.allSatisfy { $0.duration <= apiLimit }, "no slice exceeds the API's 10-day limit")

    let ancient = CloudHistoryPlan.catchUp(newest: now.addingTimeInterval(-800 * 24 * 3600), now: now)
    check(ancient.first?.start == earliest, "catch-up never reaches past a year")

    // Walk a whole backfill.
    var floor = fresh[0].start
    var walked: [DateInterval] = []
    while let slice = CloudHistoryPlan.backfill(floor: floor, now: now), walked.count < 100 {
        walked.append(slice)
        floor = slice.start
    }
    check(walked.count <= 42, "a year of backfill is ~40 requests", "\(walked.count)")
    check(zip(walked, walked.dropFirst()).allSatisfy { $0.start == $1.end }, "backfill slices are contiguous")
    check(walked.allSatisfy { $0.duration <= apiLimit && $0.duration > 0 }, "backfill slices are legal widths")
    check(walked.allSatisfy { onHour($0.start) && onHour($0.end) }, "backfill boundaries fall on the hour")
    check(floor == earliest, "backfill stops at exactly a year")
    check(CloudHistoryPlan.backfill(floor: .distantPast, now: now) == nil, "a finished backfill stays finished")
}

section("HistoryStore.merge")
MainActor.assumeIsolated {
    let store = HistoryStore()
    let id = UUID()
    defer { store.forget(id) }
    let now = Date()
    let base = CloudHistoryPlan.hourStart(now.addingTimeInterval(-10 * 24 * 3600))

    // Ten days back is past the 48 h fine window, so this is stored hourly.
    func reading(_ t: Date, _ pm: Double) -> Reading { var r = Reading(timestamp: t); r.pm02 = pm; return r }
    let hourly = (0..<6).map { reading(base.addingTimeInterval(Double($0) * 3600), 100) }
    store.merge(hourly, covering: DateInterval(start: base, duration: 6 * 3600), for: id)
    check(store.history(for: id).count == 6, "hourly history stored as-is")

    // Re-fetch hours 2 and 3 as 5-minute buckets with a different value.
    let span = DateInterval(start: base.addingTimeInterval(2 * 3600), duration: 2 * 3600)
    let buckets = stride(from: 0.0, to: span.duration, by: 300).map { reading(span.start.addingTimeInterval($0), 5) }
    store.merge(buckets, covering: span, for: id)
    let after = store.history(for: id)
    let values = after.map { $0.pm02 ?? -1 }
    check(values == [100, 100, 5, 5, 100, 100],
          "a fetched hour replaces the stored average instead of averaging into it", "\(values)")
    check(Set(after.map(\.timestamp)).count == after.count, "no hour appears twice")

    // Merging recent buckets leaves old history alone.
    let recent = DateInterval(start: CloudHistoryPlan.hourStart(now.addingTimeInterval(-3600)), end: now)
    store.merge([reading(recent.start, 7)], covering: recent, for: id)
    check(store.history(for: id).count == 7 && store.history(for: id).last?.pm02 == 7,
          "a catch-up slice adds to the history, never replaces all of it")
}

// MARK: - Demo data

section("DemoSource")
do {
    let t = Date(timeIntervalSince1970: 1_770_000_000)
    check(DemoSource.reading(at: t).rco2 == DemoSource.reading(at: t).rco2, "same instant, same reading")

    let back = DemoSource.backfill(now: t)
    check(back.count > 1000, "backfill covers two days", "\(back.count)")
    let spacing = Set(zip(back, back.dropFirst()).map { Int($1.timestamp.timeIntervalSince($0.timestamp)) })
    check(spacing == [120], "backfill spacing is 120s", "\(spacing)")
    check(spacing.allSatisfy { Double($0) <= SeriesShaping.localSpacing * 3 },
          "backfill stays under the gap threshold, or the demo draws as confetti")

    // The demo has to show colour, or it demonstrates nothing.
    let day = stride(from: 0.0, to: 24 * 3600, by: 300).map {
        DemoSource.reading(at: t.addingTimeInterval($0))
    }
    let settings = Settings()
    let bands = Set(day.compactMap { r -> QualityBand? in
        Metric.pm25.value(from: r, settings: settings).map { Metric.pm25.band($0) }
    })
    check(bands.count > 1, "the demo day crosses a PM2.5 band", "\(bands)")
}

// MARK: - Cloud request shaping

section("AirGradientClient")
do {
    var c = DateComponents()
    c.year = 2026; c.month = 8; c.day = 21; c.hour = 0; c.minute = 0; c.second = 0
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let d = cal.date(from: c)!
    // Basic ISO 8601. The extended format 404s, and finding that out cost an hour.
    check(AirGradientClient.basicISO(d) == "20260821T000000Z", "basic ISO 8601 date format",
          AirGradientClient.basicISO(d))
}

// MARK: -

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("ok")

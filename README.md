# AirGradient-to-iOS

Poll data from a local AirGradient device and persist and display in an iOS
app. iPad first, but works on iPhone.

A native SwiftUI app for [AirGradient](https://www.airgradient.com) air-quality
monitors — AirGradient ONE (indoor) and Open Air (outdoor). It reads the
monitor's **local HTTP API** over your own WiFi, so it works with no account, no
cloud round trip, and no internet connection at all. An AirGradient cloud token
is optional, and only needed for monitors that aren't on the same network as
the device running the app.

## Layout

Built iPad-first around a `NavigationSplitView`: the monitor list stays on
screen in the sidebar — each row carrying enough (name, band colour, PM2.5,
liveness) to answer "is anything wrong" without selecting it — next to a
full-size detail pane. That is the point on a tablet parked on a shelf showing
air quality all day. On iPhone the same hierarchy collapses to push navigation
for free, so there is one view tree rather than two size-class branches to keep
in step. Tile size and chart height widen in the regular size class; nothing
else forks.

## What it does

- **Overview grid** of every monitor, each tile headlined by PM2.5 and its US EPA
  AQI band, with CO₂, temperature and humidity underneath.
- **Detail page** per monitor: all eight metrics (PM1 / PM2.5 / PM10, CO₂,
  temperature, humidity, VOC index, NOx index), a trend chart, device
  identification, and a guarded CO₂ forced-calibration button.
- **Discovery** over Bonjour, plus manual entry by IP or `.local` hostname —
  which is checked against the device before it is saved, so a typo is caught
  while you're standing next to the monitor rather than showing up later as a
  tile that never has data.
- **Cloud locations** from an AirGradient API token, for monitors elsewhere.
- **Recorded history** and charts. The monitors keep no history of their own
  (`/measures/current` is exactly what it says), so the app samples about one
  point a minute while it is open and stores that on the phone. The chart has
  gaps whenever the app was closed — that's real, not a bug.

## Building

Requires Xcode 16 or later (the project uses file-system-synchronized groups,
`objectVersion = 77`) and iOS 17 as the deployment target.

```sh
open AirGradientMonitor.xcodeproj
```

Then set your own team and bundle identifier before running on a device:

- Target → Signing & Capabilities → **Team**
- `PRODUCT_BUNDLE_IDENTIFIER` is `com.example.AirGradientMonitor`; change it to
  something in a namespace you own.

The Simulator will build and run, but it cannot see Bonjour services on the LAN
the way a device can, and it has no local-network permission prompt — test
discovery on a real iPhone, or add a monitor by IP address.

## The APIs it speaks

**Local** ([docs](https://github.com/airgradienthq/arduino/blob/master/docs/local-server.md)),
firmware 3.0.10+:

| Request | Used for |
| --- | --- |
| `GET http://airgradient_<serial>.local/measures/current` | every reading |
| `PUT /config` `{"co2CalibrationRequested":true}` | the calibrate button |

**Cloud** (optional), long-term token from
[dashboard.airgradient.com](https://dashboard.airgradient.com):

| Request | Used for |
| --- | --- |
| `GET https://api.airgradient.com/public/api/v1/locations/measures/current?token=…` | all locations on the account |

One cloud fetch covers every cloud monitor and is cached for 60 s inside
`AirGradientClient`, because that endpoint returns the whole account in one
response and the cloud aggregates in ~5-minute buckets anyway.

## Two Info.plist entries are load-bearing

- `NSLocalNetworkUsageDescription` **and** `NSBonjourServices` (both
  `_airgradient._tcp` and `_http._tcp`). Missing either, `NWBrowser` fails with
  no callback — identical, from the UI, to "no monitors found".
- `NSAppTransportSecurity` → `NSAllowsLocalNetworking`. The monitors serve plain
  HTTP with no certificate; without this every local request fails. The
  exception covers `.local` names and private addresses only — the cloud API is
  still held to HTTPS.

## Layout

```
AirGradientMonitor/
  Models/       Reading (decodes both API shapes), Metric + AQI banding, Monitor, Settings
  Networking/   AirGradientClient (actor), MonitorDiscovery (Bonjour)
  Store/        MonitorsModel (state + polling loop), HistoryStore (on-disk samples)
  Views/        Dashboard, MonitorDetail, HistorySection, AddMonitor, Settings
```

## Things worth knowing before changing it

- **A missing measurement renders as "—", never 0.** Sensor sets differ per
  model and per firmware, and a sensor that hasn't warmed up reports nothing. A
  dead CO₂ sensor showing `0 ppm` would look like the cleanest air in the
  building.
- **PM2.5 uses the EPA's 2024 breakpoints** (the "Good" ceiling is 9.0 µg/m³,
  not the old 12.0). An app still on the old table calls half a wildfire day
  fine.
- **`Reading` is decoded leniently on purpose** — numbers arrive as JSON
  numbers, occasionally as strings, and as `null` for an unavailable sensor. One
  odd field must not cost the other twenty.
- **The VOC and NOx numbers are Sensirion *indices*, not concentrations.** 100
  means "typical for this room over the last day", so a steady 100 is normal and
  the banding treats it that way.

## Not built (deliberately)

Home-screen widgets, Live Activities, notification thresholds, and the cloud's
historical `measures/past` endpoint. Each is a real feature, none is needed to
answer "what is the air like right now", and the last one needs an account to
even test against.

## License

MIT. See [LICENSE](LICENSE).

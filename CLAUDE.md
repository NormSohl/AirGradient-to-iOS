# CLAUDE.md

Guidance for Claude Code working in this repository. Auto-loaded at session
start. Records decisions made while the app was written, so they don't have to
be re-derived — or worse, "fixed" back into the bug they were the fix for.

## Project overview

A native SwiftUI iOS/iPadOS app for [AirGradient](https://www.airgradient.com)
air-quality monitors (AirGradient ONE indoor, Open Air outdoor). It polls a
monitor's **local HTTP API** over the LAN, so it works with no account and no
internet. The AirGradient cloud API is an optional second source, for monitors
that aren't on the same network as the device running the app.

**iPad first, iPhone for free.** See *Layout* below — this is the repo's stated
purpose, not a nice-to-have.

There is no backend, no database, no third-party package. Everything is
Foundation, SwiftUI, Swift Charts and Network.framework.

## Build status — READ THIS FIRST

**This code has never been compiled.** It was written in a Linux container with
no Swift toolchain; verification was limited to delimiter balance and reading.
The first `xcodebuild` on a Mac is genuinely the first one.

```sh
xcodebuild -scheme AirGradientMonitor \
  -destination "platform=iOS Simulator,name=$(xcrun simctl list devicetypes | grep -o 'iPad Pro 13-inch.*' | head -1)" build
```

Requires **Xcode 16+** (the project uses file-system-synchronized groups,
`objectVersion = 77`, so adding a Swift file needs no project edit) and targets
**iOS 17**. `SWIFT_VERSION` is 5.0 — Swift 6 strict concurrency is *not* on, and
turning it on will surface a batch of actor-isolation warnings that are
deliberately unaddressed.

Before running on hardware: set a real `DEVELOPMENT_TEAM` and change
`PRODUCT_BUNDLE_IDENTIFIER` from `com.example.AirGradientMonitor`.

When fixing first-compile errors, fix the *compile* error. Several things here
look wrong at a glance and are not — each one has a comment saying why, and the
reasons are repeated below.

## Layout

`DashboardView` is a `NavigationSplitView`: monitor list in the sidebar, detail
pane beside it. On iPhone the same hierarchy collapses to push navigation, so
there is **one view tree**, not two size-class branches to keep in step. Only
two things fork on `horizontalSizeClass` — tile minimum width and chart height.

- The tile grid is a **sidebar destination** ("All monitors"), not the app root,
  so on iPad it keeps its place instead of being something you back out to.
- **Launch selection is iPad-only.** In the collapsed layout a non-nil selection
  *is* a pushed view, so pre-selecting on iPhone would launch the app one screen
  deep behind a back button.
- **Removal is handled in exactly one place**: `DashboardView` watches
  `model.monitors` and moves its selection off a monitor that stopped existing.
  That pops the view when collapsed and swaps the pane when not. Do not add a
  `dismiss()` in `MonitorDetailView` — that was tried; it is a second,
  conflicting mechanism, and a detail pane in the regular layout is not
  something that can be dismissed at all.

## The APIs it speaks

**Local** ([reference](https://github.com/airgradienthq/arduino/blob/master/docs/local-server.md)),
firmware 3.0.10+: `GET http://airgradient_<serial>.local/measures/current` for
every reading, `PUT /config` `{"co2CalibrationRequested":true}` for the one
control the app exposes.

**Cloud** (optional): `GET https://api.airgradient.com/public/api/v1/locations/measures/current?token=…`
returns *every* location on the account in one response. `AirGradientClient` is
an `actor` specifically so that one fetch is shared and cached (60 s) across all
cloud monitors — polling five of them must not be five round trips, and without
serialised access five concurrent refreshes would each miss the cache and fire.

The cloud path has **never been exercised** — the network where this was written
blocks `api.airgradient.com`. It is written from published docs. The local path
is the one the app is built around.

## Files

```
AirGradientMonitor/
  Models/       Reading (decodes both API shapes), Metric + AQI banding, Monitor, Settings
  Networking/   AirGradientClient (actor), MonitorDiscovery (Bonjour via NWBrowser)
  Store/        MonitorsModel (@Observable state + polling loop), HistoryStore (on-disk samples)
  Views/        DashboardView (split view + tiles), MonitorDetailView, HistorySection,
                AddMonitorView, SettingsView, CardBackground
```

## Load-bearing decisions

- **A missing measurement renders "—", never 0.** Every field on `Reading` is
  optional on purpose: the two models report different sensor sets, firmware
  versions add fields, and a sensor that hasn't warmed up reports nothing. A
  dead CO₂ sensor showing `0 ppm` would look like the cleanest air in the
  building. Never default a measurement to zero to simplify a call site.
- **`Reading` decodes leniently.** Values arrive as JSON numbers, occasionally
  as strings, and as `null` for an unavailable sensor. `KeyedDecodingContainer.number`
  accepts all three. One odd field must not fail the whole decode and cost the
  other twenty.
- **`Reading.encode(to:)` is written by hand and must stay that way.**
  `CodingKeys` carries the cloud's alternate spellings (`tvoc`,
  `firmwareVersion`, `pm003_count`), which have no stored property, so there is
  nothing for the compiler to synthesise an encoder from. Encoding is only used
  for the on-disk history, so it writes the canonical local-server names.
- **PM2.5 uses the EPA's 2024 breakpoints** — "Good" ends at 9.0 µg/m³, not the
  old 12.0. An app still on the old table calls half a wildfire day fine.
  Concentrations are truncated (0.1 for PM2.5, 1 for PM10) before interpolation
  because that is the EPA's own procedure, and because the table has deliberate
  gaps (9.0 then 9.1) a raw sensor value can land inside.
- **VOC and NOx are Sensirion *indices*, not concentrations.** 100 means
  "typical for this room over the last day", so a steady 100 is normal and the
  banding treats it as such. Do not band them like a pollutant concentration.
- **Temperature is judged in Celsius.** `Metric.band(_:fahrenheit:)` converts
  back before comparing, or 72 °F reads as a fever. The wire format is always
  Celsius regardless of what the device's own display is set to.
- **`historyVersion` is not redundant.** `HistoryStore` is a plain class behind
  a `let`, so nothing about it is observable; a chart reading it would never be
  told a point was appended. `MonitorsModel.historyVersion` is the observable
  dependency the chart registers. Deleting it makes the chart silently stop
  updating — it will still *look* fine on first draw.
- **`MonitorsModel.settings` has no `didSet`.** `@Observable` rewrites stored
  properties into accessors, so a property observer there does not compile.
  Persistence is driven explicitly by `settingsChanged()`, called from
  `SettingsView.onChange`.
- **Polling runs only while the app is foregrounded** (`scenePhase` in
  `AirGradientMonitorApp`), and `stopPolling()` is what flushes the history to
  disk. A background poll would be refused once suspended anyway.
- **History is app-recorded, ~1 sample/minute, capped at 1500.** The monitors
  keep none of their own — `/measures/current` is exactly what it says. So the
  chart has real gaps whenever the app was closed, and the empty state says so
  outright rather than looking broken. Don't "fix" the gaps.
- **A manually typed address is probed before it is saved.** A monitor added
  from a typo is indistinguishable from one that is merely offline, and the
  difference matters to someone standing next to a working device.

## Info.plist — two entries are load-bearing

- **`NSLocalNetworkUsageDescription` *and* `NSBonjourServices`** (both
  `_airgradient._tcp` and `_http._tcp`). Missing either, `NWBrowser` fails with
  **no callback at all** — from the UI that is indistinguishable from "no
  monitors found", which is the worst possible way for this to break.
- **`NSAppTransportSecurity` → `NSAllowsLocalNetworking`.** The monitors serve
  plain HTTP with no certificate. Without this every local request fails. The
  exception covers `.local` names and private addresses only; the cloud API is
  still held to HTTPS.

`GENERATE_INFOPLIST_FILE` is `NO` and `INFOPLIST_FILE` points at the checked-in
`Info.plist`, because neither the Bonjour array nor the ATS dictionary can be
expressed as `INFOPLIST_KEY_*` build settings. Don't switch to the generated
plist without moving those.

## Testing notes

- **The Simulator cannot see Bonjour services on the LAN** the way a device can,
  and never shows the local-network permission prompt. Test discovery on real
  hardware, or add a monitor by IP address.
- With no monitor to hand, `AirGradientClient` takes an injected `URLSession`,
  which is the seam for a stubbed protocol.
- `xcrun simctl io booted screenshot` is how to actually *look* at the iPad
  layout — the split view's collapse/expand behaviour (rotation mid-selection,
  Slide Over) is where `NavigationSplitView` most often surprises, and it cannot
  be checked by reading.

## Not built, deliberately

Home-screen widgets, Live Activities, notification thresholds, and the cloud's
historical `measures/past` endpoint. Each is a real feature; none is needed to
answer "what is the air like right now", and the last needs an account to even
test against.

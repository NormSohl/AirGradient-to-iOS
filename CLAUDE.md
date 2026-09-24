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

**Compiles clean and runs.** First compiled 2026-08-20, Xcode 16.2 against the
iOS 18.2 SDK: zero errors, zero warnings. Launched on an iPad Pro 13-inch (M4)
and an iPhone 16 Pro, both iOS 18.3.1 — the split view collapses correctly on
the phone, with no phantom pushed screen.

Also runs on hardware: installed and launched on an iPad Pro 11-inch (M4)
running **iPadOS 26.6**, from Xcode 16.2. An OS that far ahead of the toolchain
is not the problem it looks like — `devicectl` opens a CoreDevice tunnel and
installs fine, and the device shows up as an eligible `xcodebuild` destination.

Confirmed against a real AirGradient monitor on the LAN: Bonjour discovery, the
local-network permission prompt, `/measures/current`, the lenient `Reading`
decode and the AQI banding all worked first try.

The cloud path is exercised too, against a real account: locations list, current
readings, and `measures/past` history all work. Nothing in the app is now
unrun — what remains untested is long-run `HistoryStore` behaviour, covered by
the harness under *Testing notes* rather than by a year of actual running.

```sh
xcodebuild -scheme AirGradientMonitor \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build
```

**A matching simulator *runtime* is required, not just a matching Xcode.**
`actool` refuses to compile `Assets.xcassets` unless an installed simulator
runtime matches the SDK version, and it does this even when the destination is
`--platform iphoneos` — so an out-of-date runtime set fails the *device* build
too, with an error that confusingly names the simulator. The tell is
`xcodebuild -showdestinations` listing no eligible destinations at all, then the
build dying at `CompileAssetCatalog`. Fix it with `xcodebuild -downloadPlatform
iOS`; there is nothing to change in this project.

Requires **Xcode 16+** (the project uses file-system-synchronized groups,
`objectVersion = 77`, so adding a Swift file needs no project edit) and targets
**iOS 17**. `SWIFT_VERSION` is 5.0 — Swift 6 strict concurrency is *not* on, and
turning it on will surface a batch of actor-isolation warnings that are
deliberately unaddressed.

The app is named **Aetherfield**; the target and scheme are still
`AirGradientMonitor`, which no user ever sees.

**Signing identity lives in `Signing.xcconfig`, not the project file.** That
tracked file holds placeholder defaults that build for the Simulator as-is, and
ends with `#include? "Signing.local.xcconfig"` — the `?` makes it optional, so a
clone without one still builds. Real values go in `Signing.local.xcconfig`,
which is gitignored. Do not put `DEVELOPMENT_TEAM` back into `project.pbxproj`.

A plain (non-optional) `baseConfigurationReference` to a gitignored file is a
**hard error** — "Unable to open base configuration reference file" — not a
warning, so the tracked-defaults-plus-optional-include shape is the point, not
decoration.

Deploying to a *new* device needs it registered with the developer account
first. `xcodebuild -allowProvisioningUpdates` does not reliably do this from the
command line — it fails with "isn't registered in your developer account", and
an install that gets as far as `0xe8008012 (This provisioning profile cannot be
installed on this device)` means the same thing. Opening the project in Xcode
and hitting Run registers the device and reissues the profile in one step;
after that the CLI works again.

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
- **Neither the launch pre-selection nor the removal fallback may select
  `.overview` while `monitors` is empty.** `OverviewGrid` over an empty array
  draws an empty `LazyVGrid` — a blank pane, not an empty state — and the
  sidebar hides its "All monitors" row in that state, so the selection points at
  a row that isn't there. Both sites are guarded on `!monitors.isEmpty` so the
  detail pane falls through to the `case nil` "No monitors yet" view with its
  Add button. Dropping either guard makes a fresh install open on a blank
  screen, which is how this shipped until it was seen on a simulator.
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

**Verified against a live account, not inferred.** Two things the docs did not
make obvious, both of which cost time:

- The token is a **query parameter and nothing else**. Sending it as a Bearer
  header returns `422 {"param":"token","msg":"Invalid value"}`.
- The cloud spells corrected measurements `pm02_corrected` / `atmp_corrected` /
  `rhum_corrected`, where the local server says `…Compensated`. `Reading` reads
  both. It also sends `pm003Count` in the same camelCase the local server uses —
  an earlier guess of `pm003_count` here was simply wrong.

`GET /locations/{id}/measures/past?from=…&to=…` returns 5-minute buckets with
exactly the field names `measures/current` uses, so `Reading` decodes history
unchanged. **The dates are ISO 8601 *basic* format** — `20260821T000000Z`, no
dashes or colons; the extended format 404s. Do not try to discover these paths by
probing: the auth middleware answers before routing, so a wrong path with a bad
token returns 401, not 404. The spec at
`https://api.airgradient.com/public/docs/api/v1/swagger.json` is the authority.

The cloud also returns `pm01_corrected`, `pm10_corrected` and `rco2_corrected`,
which have no local equivalent and are deliberately unused: adopting them would
make cloud and local monitors report different numbers for the same metric.

## Files

```
AirGradientMonitor/
  Models/       Reading (decodes both API shapes), Metric + AQI banding, Monitor, Settings,
                SeriesShaping (gap + band-run logic, kept testable), HistoryRange, DemoSource
  Networking/   AirGradientClient (actor), MonitorDiscovery (Bonjour via NWBrowser)
  Store/        MonitorsModel (@Observable state + polling loop), HistoryStore (on-disk samples)
  Views/        DashboardView (split view + tiles), MonitorDetailView, HistorySection,
                AddMonitorView, SettingsView, CardBackground
Tests/          run.sh + main.swift + Fixtures/ (real API responses)
docs/           manual.html (also the privacy policy), app-store-listing.md
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
- **History comes from the monitor's own source.** Local monitors are recorded
  by this app and have real gaps; cloud monitors are drawn from AirGradient's
  continuous record, fetched wholesale by `HistoryStore.replace(_:for:)` and
  refetched at most every 10 minutes. A cloud monitor deliberately does **not**
  accumulate app-observed samples — mixing them would sprinkle app-timed points
  through a fetched series at slightly different timestamps.
- **Anything judging sample spacing must ask the source.** Local samples are a
  minute apart, cloud buckets five. `HistorySection.expectedSpacing` exists
  because the gap rule, written for local cadence, broke every cloud point into
  its own segment.
- **Band colouring folds away short runs by *sample count*, never by a fraction
  of the visible span.** Scaled to the span, a week-wide chart swallowed every
  excursion under ~2.6 h — which is precisely the sharp, tall spikes worth
  seeing — and painted them the colour of the calm either side.
- **The chart's x axis spans the chosen range (Day/Week/Month/Year), not the
  data.** Each range has one fixed tick layout in `HistoryRange`; history that
  doesn't reach back that far shows as empty space. Ticks sized from the data
  topped out at one per day, so once retention grew to a year a month of it
  drew thirty cramped, clipped slots. The band gradient's stops stay relative
  to the *data* span — Swift Charts maps a mark's gradient over the mark, not
  the plot, which was checked on a simulator with data covering 60 of 365 days.
  Cloud monitors are offered Day and Week only, since a week is all that is
  fetched.
- **History is app-recorded for local monitors, ~1 sample/minute, and ages in
  tiers.** The monitors
  keep none of their own — `/measures/current` is exactly what it says. So the
  chart has real gaps whenever the app was closed, and the empty state says so
  outright rather than looking broken. Don't "fix" the gaps.
- **Retention is time-based, not a sample count.** Samples keep minute
  resolution for 48 h, then average into one point per hour, and drop past a
  year: ~11,600 samples, about 0.9 MB. The flat 1500-sample cap this replaced
  was 25 hours of history no matter how long the app ran, which defeats the
  point of leaving an iPad on a shelf. `compact(_:now:)` is idempotent, so
  re-running it never re-averages an already-rolled hour.
- **Averaging an absent sensor must yield nil, not 0.** Same rule as the tiles,
  and easier to get wrong here: an hour where CO₂ reported nothing has to stay
  nil through the roll-up, or the chart grows a plunge to zero that never
  happened.
- **Compaction is rate-limited to once every 10 minutes, and history is
  flushed every 5.** Both exist for the kiosk case. Compacting on every append
  costs ~27 ms of main-actor time a year in, once a minute, behind a display
  someone is always looking at; rate-limiting takes it to ~0.6 ms. And `flush()`
  on `scenePhase` never fires on a device that never backgrounds, so without the
  periodic write a power cut loses everything since launch. The periodic write
  encodes off the main actor; `flush()` stays synchronous because a detached
  write may not survive suspension.
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

- **The Simulator *can* browse Bonjour on the LAN** — it shares the Mac's
  network stack, and `AddMonitorView` listed a real monitor there. An earlier
  note here claimed otherwise and sent people to fetch hardware for no reason.
  What the Simulator genuinely cannot show is the **local-network permission
  prompt**, which only appears on a device; that part still needs real hardware.
- **The demo monitor makes the Simulator a complete test rig.** `DemoSource`
  needs no network at all, so the whole UI — tiles, bands, charts, gaps — can be
  exercised without a device on the desk.
- With no monitor to hand, `AirGradientClient` takes an injected `URLSession`,
  which is the seam for a stubbed protocol.
- **There is a test suite: `./Tests/run.sh`.** It compiles the model layer for
  macOS and runs assertions — no simulator, no scheme, no XCTest target (the
  project uses file-system-synchronized groups, and hand-editing the pbxproj to
  add one is a worse risk than this is a limitation). Run it before committing
  anything in `Models/`, `Store/` or `Networking/`.
- **The fixtures are real API responses, not invented ones.** `world-current.json`
  is 250 public monitors from AirGradient's open `world/locations/measures/current`
  endpoint (no token needed), carrying 82 distinct null patterns, mixed int/float
  types, and fields this app does not model. `cloud-past.json` and
  `local-current.json` are real too, with anything locating a home stripped.
  Every decode bug found so far came from a real payload disagreeing with the
  docs; no synthetic fixture would have contained them.
- **Both bugs that shipped today are covered.** Reverting the `_corrected`
  decoding fails four checks; restoring the span-fraction run folding fails
  "a 1-hour spike in a week keeps its colour". A test that does not fail when
  the bug returns is decoration.
- **Retention logic is testable without waiting a year.** Compile `Reading.swift`
  and `HistoryStore.swift` together with a small `@main` harness for macOS
  (`xcrun swiftc -O -o t Reading.swift HistoryStore.swift t.swift`) and feed it
  synthetic timestamps. That is how the tier boundaries, hour alignment, nil
  preservation and per-append cost above were actually measured.
- `xcrun simctl io booted screenshot` is how to actually *look* at the iPad
  layout — the split view's collapse/expand behaviour (rotation mid-selection,
  Slide Over) is where `NavigationSplitView` most often surprises, and it cannot
  be checked by reading.

## Demo mode

`DemoSource` generates readings from the clock and `MonitorsModel.addDemoMonitor()`
installs a monitor backed by them, with two days of history already recorded.

- **It exists for App Review first.** A reviewer has no AirGradient hardware, so
  without it the app they receive shows an empty state, finds nothing, and reads
  as incomplete under Guideline 2.1. It is offered from both empty states (the
  detail pane's and the sidebar's — a phone only ever sees the latter first) and
  from the bottom of *Add monitor*.
- **The numbers are deterministic, never random.** They are a pure function of
  the timestamp, so a chart redraw cannot make the past jitter.
- **The day has a story in it**: CO₂ climbing overnight into a warning band, and
  a PM2.5 spike at dinner that reaches ~34 µg/m³. Band colouring and the AQI
  wording demonstrate nothing if everything is green, so the demo must not be.
- **Backfill spacing (120 s) must stay under `HistorySection`'s gap threshold.**
  Sampled any sparser, every point reads as a break in recording and the demo
  draws as confetti.
- **`Monitor.isDemo` is not `isLocal`**, so the local controls stay hidden —
  there is no device to send a calibration request to.

## Not built, deliberately

Home-screen widgets, Live Activities, and notification thresholds. Each is a
real feature; none is needed to answer "what is the air like right now".

`measures/past` **is** built now — see *The APIs it speaks*.

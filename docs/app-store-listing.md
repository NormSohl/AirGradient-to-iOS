# App Store Connect — listing copy

Paste-ready. Character limits noted; counts verified.

---

## Name (30 max)

```
Aetherfield
```

## Subtitle (30 max)

```
Air quality for AirGradient
```

Alternative, if you'd rather not lean on the brand:

```
Air quality, on your network
```

## Promotional text (170 max, editable without review)

```
Reads your AirGradient monitor directly over Wi-Fi. No account, no subscription, nothing sent anywhere. A year of trends on your iPad, and a sample mode to try it first.
```

---

## Description (4000 max)

```
Aetherfield shows what your AirGradient monitor is measuring, right now and over time.

It talks to the monitor directly over your own Wi-Fi. No account, no subscription, no cloud service in the middle — and nothing about your home leaves your home.

LOCAL FIRST

Monitors on your network are found automatically, or you can add one by address. Readings arrive within seconds of being measured, and keep working when your internet doesn't.

An AirGradient cloud account is optional, and only needed for monitors somewhere else — a second house, an office, an outdoor unit on another network.

WHAT IT SHOWS

• PM2.5, PM10 and PM1 particulate levels
• CO2, as a measure of how well a room is ventilated
• Temperature and humidity
• VOC and NOx indices
• Particle counts, Wi-Fi signal, firmware and model

Every measurement is rated in plain language, using the US EPA's 2024 air-quality breakpoints — so "Good" for PM2.5 ends at 9.0 µg/m³, not the older 12.0.

BUILT FOR A TABLET

An iPad on a shelf makes a good permanent display, so that is what this was designed around: the monitor list stays beside a full-size detail pane, rather than being something you back out of. On iPhone the same layout collapses to standard navigation.

HISTORY THAT TELLS THE TRUTH

The monitors keep no history of their own, so this app records it. Tap any measurement to chart it. The line is coloured by air quality along its length, so you can see when the air went bad and for how long — not just what it is now.

Gaps are shown as gaps. Where the app wasn't running, the line breaks rather than drawing a trend nobody measured. Local history keeps minute-by-minute detail for two days, then hourly points for a year. Cloud monitors draw on AirGradient's own continuous record instead.

TRY IT WITHOUT A MONITOR

Tap "Add sample data" for a made-up monitor with two days of history. Nothing is contacted. It is the whole app, working, before you buy anything.

PRIVACY

No account. No analytics. No tracking. No advertising. No server belonging to this app. Readings stay on your device, local monitors are contacted directly over your network, and if you add a cloud token it is sent only to AirGradient.

REQUIREMENTS

An AirGradient ONE or Open Air monitor running firmware 3.0.10 or later, on the same Wi-Fi network. Aetherfield is an independent app and is not affiliated with AirGradient.
```

---

## Keywords (100 max, comma-separated, no spaces)

```
AirGradient,PM2.5,CO2,VOC,AQI,particulate,sensor,indoor,ventilation,humidity,monitor
```

Avoid repeating words already in the name or subtitle — Apple indexes those anyway.

---

## URLs

| Field | Value |
|---|---|
| Support URL | `https://YOURSITE/manual.html` |
| Privacy Policy URL | `https://YOURSITE/manual.html#privacy` |
| Marketing URL | optional — leave blank |

---

## App Review notes

```
This app is a client for AirGradient air-quality monitors, which are physical
devices on the user's local Wi-Fi network. No such hardware is required to
review it.

TO EVALUATE WITHOUT HARDWARE:
On first launch, tap "Try sample data" on the empty state (or "+" > "Add sample
data"). This adds a monitor backed by generated readings, with two days of
history, so the full interface — tiles, air-quality ratings, history charts,
settings — can be exercised. Nothing is contacted over the network.

ABOUT THE LOCAL NETWORK PERMISSION:
The app requests local network access to discover monitors via Bonjour
(_airgradient._tcp). Declining it does not affect the sample data path.

NO ACCOUNT IS REQUIRED. The optional AirGradient cloud token in Settings is only
for monitors on other networks and is not needed to review the app.
```

---

## Privacy nutrition labels

Answer **"No, we do not collect data from this app"** — accurate. The app has no
analytics, no accounts, no third-party SDKs, and no backend. The optional cloud
token is stored on device and sent only to AirGradient's API on the user's behalf.

---

## Also set before submitting

- `ITSAppUsesNonExemptEncryption = false` in `Info.plist`, to stop the export
  compliance question on every build. (HTTPS to AirGradient is exempt.)
- Screenshots: iPad 13" and iPhone 6.9" are the required sizes. The sample-data
  monitor is the easiest way to produce clean ones with a full chart.
- Age rating: 4+.
- Category: Utilities. Health & Fitness is a plausible secondary, but invites
  scrutiny about medical claims — Utilities is the quieter choice.

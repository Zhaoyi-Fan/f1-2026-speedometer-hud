# F1 2026 Speedometer HUD

**A broadcast-style speedometer for Assetto Corsa that shows what the 2026 TV graphics hide:
battery, MGU-K power, Straight Mode, Overtake and Boost. Built for the VRC Formula Alpha 2026
(Pro). Follows the camera car, works in replays. 中文说明: [README.zh-CN.md](README.zh-CN.md)**

![demo](docs/demo.gif)

---

## Why

The 2026 regulations turned Formula 1 into an energy race: 350 kW of electric power, a 4 MJ
usable battery, up to 8.5 MJ of harvesting per lap, Straight Mode instead of DRS, Overtake mode
and a Boost button. The official 2026 broadcast graphics removed the battery bar and never showed
Straight Mode or Overtake state, so a viewer cannot see the one thing the drivers are managing
all lap long.

This app is a Custom Shaders Patch (CSP) Lua app that draws the familiar MultiViewer-style
speedometer dial and adds everything the 2026 cars expose. It reads the car's private telemetry
at runtime, records it into your replays, and can follow whichever car the camera is on, AI
included. It never modifies a car or track file, so it is safe for leagues with checksums.

## What you get

**The dial** (MultiViewer geometry and colours, drawn procedurally): blue speed arc, green
throttle arc, red brake arc, speed, RPM and gear. Where the DRS badge used to be there are three
badges for the 2026 systems:

| Badge | Dark | Colour states |
| --- | --- | --- |
| `SM` Straight Mode | not available | white = available, press to pre-latch · blue = pre-latched, engages at the zone · yellow = available but already inside the zone · green = wings in Straight Mode position |
| `OT` Overtake | not available | white outline = granted, waiting for the activation line · green = active this lap |
| `BOOST` | off | magenta while the Boost button is held / toggled |

**Two bars beside the dial** (optional): left = usable battery with % and MJ, right = energy
harvested this lap against the lap limit.

**The energy panel** (optional, one key to hide):

- Battery: usable energy as a bar, `%` and `MJ / 4 MJ`.
- MGU-K: live power, green when deploying and red when harvesting, with a tick at the current
  power cap. The cap label reads `cap 200 kW` in a power-reduction zone, `cap 0 kW` when
  deployment is blocked and `clip -350 kW` while the car super-clips (forced harvesting at full
  throttle).
- Lap energy: deployed MJ and harvested MJ against the lap harvesting limit (8.5 MJ, 9.0 MJ on an
  Overtake lap), as numbers and a bar.
- Strategy: `STRAT n`, the current deployment-map split, and the PU mode name.
- Status chips: SM state, OT state, Boost, Charge mode, PL / PLP (power-limited states), pit limiter.

Everything follows the **camera-focused car**, so in a replay you can jump from car to car and see
each driver's energy picture. A bindable button locks the HUD to your own car.

![badge states](docs/dial-states.png)

## The 2026 systems in one minute

- **Straight Mode (SM, "X-mode")**: front and rear wing flaps open for low drag. Every car may
  use it in every designated zone, every lap, no gap condition. VRC's implementation: press the
  button (the DRS button by default) at 200 km/h or more before the zone to pre-latch, the wings
  open at the zone start at full throttle above 150 km/h, and they close when you brake or drop
  below 90 % throttle.
- **Overtake (OT)**: electrical, not aero. Cross the detection line within 1 s of the car ahead and
  on the following lap the MGU-K keeps its full 350 kW up to 337 km/h instead of tapering from
  290 km/h, plus 0.5 MJ of extra harvesting. Always on in practice and qualifying.
- **Boost**: a manual override that pushes the MGU-K to the current power cap regardless of the
  deployment map. It decides how fast you spend the battery; OT decides how high the cap is.
- **PL / PLP**: the regulation constraints on power changes (200 kW minimum at full throttle for
  1 s, at most 150 kW of reduction, limited ramp rates) as "power limited" and "pending" states.

## Requirements

- Assetto Corsa with Custom Shaders Patch. The VRC Formula Alpha 2026 needs CSP
  0.3.0-preview542 or newer; the app needs nothing beyond that (built and tested on build 4116).
- **VRC Formula Alpha 2026, Pro (CSP) version** (`vrc_formula_alpha_2026_csp`). The energy data
  comes from that car's telemetry bus. With any other car the dial still works and the energy
  panel shows `--`.
- No DLLs, no SimHub, no Python, no extra files. Two files in one folder.

## Install

**Option A, release zip.** Download `f1-2026-speedometer-hud-v0.9.0.zip` from the
[latest release](../../releases/latest) and extract it into your Assetto Corsa root folder (the
one with `acs.exe`). You should end up with
`assettocorsa\apps\lua\f1_2026_speedometer_hud\manifest.ini`. Dropping the zip onto Content Manager
also works.

**Option B, from source.** Clone the repository and run `tools\deploy.ps1` (PowerShell), optionally
with `-AcRoot "D:\path\to\assettocorsa"`.

Then in game: open the CSP apps sidebar and enable **F1 2026 Speedometer HUD**. The HUD window
has no background; hover it to get the title bar and drag it where you want it.

## Using it

- Open the app's settings (gear icon on the HUD's floating title bar).
- **Display**: scale, show the energy panel, show the side bars, follow the camera-focused car,
  lock to the player car, dial font (default Bahnschrift), Chinese label font (default Microsoft
  YaHei UI).
- **Language**: English or 简体中文, switches instantly. Broadcast abbreviations (SM, OT, BOOST, PL,
  PLP, STRAT, PU, MGU-K, KMH, RPM, GEAR) stay in English in both languages, as on Chinese F1
  broadcasts.
- **Bindings**: two buttons you can bind to keys or wheel buttons, "toggle energy panel" and "lock
  to player car".
- **Replay**: record the energy data of every car into replays (on by default).
- **Diagnostics**: data-source line under the panel, a diagnostics file, and a "log mode" checkbox
  that reveals the raw decoded values.

## Replays

Assetto Corsa's own replay does not store battery or ERS data, and a Lua app cannot read the car's
private replay stream. The app therefore records its own stream while you drive: 22 car slots,
11 bytes per car, every second replay frame, roughly 13 MB per hour of session inside the replay
file. Replays saved while the app was running play back with the full energy panel for every car,
live sessions and in-session replays included. Replays recorded without the app show the dial plus
the Straight Mode badge (the wing flaps are part of AC's own replay); everything else reads `--`.
Anyone with the app installed sees the data in a replay you recorded.

## Settings reference

| Setting | Default | Notes |
| --- | --- | --- |
| Scale | 1.00 | 0.5 to 2.5 |
| Show energy panel | on | also a bindable button |
| Show battery / regen bars beside the dial | on | |
| Follow camera-focused car | on | falls back to the player car when no car is focused |
| Lock to player car | off | also a bindable button |
| Font / Chinese label font | Bahnschrift / Microsoft YaHei UI | any installed DirectWrite font |
| Language | English | 简体中文 available |
| Record energy data into replays | on | |
| Show data source on the panel + run probes | on | small grey line under the panel |
| Write diagnostics to the CSP log every 5 s | on | `[F1-2026-HUD]` lines |
| Show technical readout (log mode) | off | raw values in the settings window |

## Data sources and league safety

Live: speed, RPM, gear, throttle, brake, battery state and STRAT come from CSP's car state; the
2026-specific channels (MGU-K power and cap, lap deploy / regen and the regen limit, deployment
split, PU mode, Overtake, Boost, Charge, PL / PLP, Straight Mode latch and activation) come from
the VRC car's telemetry bus, read at runtime through CSP's shared storage. No file of the car or
track is read from disk or modified, so checksums are unaffected. Details, channel names and the
replay layout: [docs/DATA-CONTRACT.md](docs/DATA-CONTRACT.md).

## Troubleshooting

- **"waiting for the CAN map" for a long time**: the car publishes its telemetry map a few seconds
  after the session starts (about 15 s after a race launch). If it never arrives, check that you
  are in the Pro (CSP) version of the car and that there is **no unpacked `data` folder** next to
  `data.acd` in `content\cars\vrc_formula_alpha_2026_csp`. The car's physics script refuses to run
  with an unpacked data folder, the car will not start, and every telemetry consumer stays empty.
  Delete the folder.
- **Panel shows `--`**: the focused car is not an FA26 Pro, or you are watching a replay recorded
  without the app.
- **Chinese labels look wrong**: set a different Chinese label font in the settings.
- **Diagnostics**: `Documents\Assetto Corsa\logs\f1_2026_speedometer_hud_diag.log` accumulates
  across launches; the CSP log gets the same lines tagged `[F1-2026-HUD]`.

## Limitations and ideas

- Cars with index 22 or higher are not recorded into replays.
- FA26 only for now. A fallback for DRS-era cars, a zone-distance strip, per-lap energy history
  and a cap-source label are on the list.

## Credits and disclaimer

- Car, physics and telemetry bus: [VRC Modding Team](https://www.virtual-racing-cars.com/)'s
  Formula Alpha 2026.
- The dial layout and colours reproduce the look of the MultiViewer-style speedometer overlays
  used by the community for earlier cars; no assets from those apps are included.
- Runs on [Custom Shaders Patch](https://acstuff.club/patch/).
- Not affiliated with Formula One, the FIA, Kunos or VRC. "F1" is used descriptively.

## License

MIT, see [LICENSE](LICENSE).

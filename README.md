# F1 2026 Speedometer HUD

[简体中文](README.zh-CN.md)

A broadcast-style speedometer for Assetto Corsa, with energy readouts for the VRC Formula Alpha
2026 Pro. Shows speed, driver inputs, battery charge, MGU-K power and the status of Straight Mode,
Overtake and Boost. The HUD follows the camera car and can display energy data saved in replays.

![demo](docs/demo.gif)

The app runs in Custom Shaders Patch (CSP). It combines a MultiViewer-style dial with the car's
energy telemetry, so you can monitor deployment and harvesting while driving or watching a replay.
It supports AI cars as well as the player's car and does not modify car or track files.

## Display

**Dial:** speed, RPM and gear, with a blue speed arc, green throttle arc and red brake arc.
The layout and colours follow the MultiViewer style and are drawn in code. Three indicators show
the 2026 systems:

| Indicator | Dark | Colour states |
| --- | --- | --- |
| `SM` Straight Mode | not available | white = available, press to pre-latch · blue = pre-latched, engages at the zone · yellow = available but already inside the zone · green = wings in Straight Mode position |
| `OT` Overtake | not available | white outline = granted, waiting for the activation line · green = active this lap |
| `BOOST` | off | magenta while the Boost button is held / toggled |

**Side bars:** usable battery charge on the left, shown as a percentage and in MJ; energy harvested
this lap on the right, shown against the lap limit. These bars can be hidden independently of the
energy panel.

**Energy panel:** can be shown or hidden in settings or with a bound key or wheel button.

- Battery: usable energy as a bar, `%` and `MJ / 4 MJ`.
- MGU-K: live power, green when deploying and red when harvesting, with a tick at the current
  power cap. The cap label reads `cap 200 kW` in a power-reduction zone, `cap 0 kW` when
  deployment is blocked and `clip -350 kW` while the car super-clips (forced harvesting at full
  throttle).
- Lap energy: deployed and harvested energy in MJ, with a bar showing progress towards the
  harvesting limit reported by the car. The limit varies by track and session; Overtake adds 0.5 MJ.
- Strategy: `STRAT n`, the current deployment-map split, and the PU mode name.
- Status chips: SM state, OT state, Boost, Charge mode, PL / PLP (power-limited states), pit limiter.

By default, the HUD follows the **camera-focused car**. You can switch between cars in a replay
to view their recorded data, or bind a button to keep the HUD on your own car.

![badge states](docs/dial-states.png)

## 2026 regulations

The following describes how these systems work in the VRC Formula Alpha 2026 Pro.

- **Straight Mode (SM, "X-mode")** opens the front and rear wing flaps to reduce drag. It is
  available to every car in the designated zones, without a gap requirement. Before entering a
  zone, press the button (DRS by default) at 200 km/h or more to pre-latch it. The wings open at
  the zone start at full throttle above 150 km/h, then close when you brake or drop below 90%
  throttle.
- **Overtake (OT)** changes the MGU-K power limit. Crossing the detection line within 1 s of
  the car ahead grants Overtake for the following lap: full 350 kW is available up to 337 km/h,
  rather than tapering from 290 km/h, and the harvesting allowance increases by 0.5 MJ. Overtake
  is always active in practice and qualifying.
- **Boost** overrides the deployment map and requests the current MGU-K power cap. It remains
  subject to the available battery energy and power limits, including those set by Overtake.
- **PL / PLP** indicate active and pending power limits. These relate to rules governing power
  changes, including a 200 kW minimum at full throttle for 1 s, a maximum reduction of 150 kW
  and limits on the rate of change.

## Requirements

- Assetto Corsa with Custom Shaders Patch. The VRC Formula Alpha 2026 needs CSP
  0.3.0-preview542 or newer. The app was developed and tested on build 4116.
- **VRC Formula Alpha 2026, Pro (CSP) version** (`vrc_formula_alpha_2026_csp`). The energy data
  comes from that car's telemetry bus. With any other car the dial still works and the energy
  panel shows `--`.
- The app consists of a Lua script and a manifest. No separate DLL, SimHub or Python installation
  is required.

## Install

**Release zip:** download `f1-2026-speedometer-hud-v0.9.0.zip` from the
[v0.9.0 release](https://github.com/Zhaoyi-Fan/f1-2026-speedometer-hud/releases/tag/v0.9.0)
and extract it into your Assetto Corsa root folder (the
one with `acs.exe`). You should end up with
`assettocorsa\apps\lua\f1_2026_speedometer_hud\manifest.ini`. Dropping the zip onto Content Manager
also works.

**From source:** clone the repository and run `tools\deploy.ps1` (PowerShell), optionally
with `-AcRoot "D:\path\to\assettocorsa"`.

Then in game: open the CSP apps sidebar and enable **F1 2026 Speedometer HUD**. The HUD window
has no background; hover it to get the title bar and drag it where you want it.

## Usage

- Open the app's settings (gear icon on the HUD's floating title bar).
- **Display**: scale, show the energy panel, show the side bars, follow the camera-focused car,
  lock to the player car, dial font (default Bahnschrift), Chinese label font (default Microsoft
  YaHei UI).
- **Language**: switch between English and 简体中文. Abbreviations such as SM, OT, BOOST, PL,
  PLP, STRAT, PU, MGU-K, KMH, RPM and GEAR remain the same in both languages.
- **Bindings**: two buttons you can bind to keys or wheel buttons, "toggle energy panel" and "lock
  to player car".
- **Replay**: save energy data for up to 22 cars in replays (on by default).
- **Diagnostics**: data-source line under the panel, a diagnostics file, and a "log mode" checkbox
  that reveals the raw decoded values.

## Replays

Assetto Corsa's standard replay data does not include battery charge or ERS telemetry. This HUD
records a separate energy stream while it runs, with recording enabled. The stream supports
22 cars and stores 11 bytes per car every second replay frame, adding roughly 13 MB per hour
to the replay file.

When that data is present, the HUD can show the recorded energy readings in saved and in-session
replays. Other users with the app installed can also view the data in a shared replay.

Older replays, or those recorded without the app's energy stream, still show speed, inputs and
the Straight Mode wing state. The remaining energy readings show `--`.

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
| Record energy data into replays | on | up to 22 cars |
| Show data source on the panel + run probes | on | small grey line under the panel |
| Write diagnostics to the CSP log every 5 s | on | `[F1-2026-HUD]` lines |
| Show technical readout (log mode) | off | raw values in the settings window |

## Data sources

In live sessions, speed, RPM, gear, throttle, brake, battery state and STRAT come from CSP's car state. The
2026-specific channels (MGU-K power and cap, lap deploy / regen and the regen limit, deployment
split, PU mode, Overtake, Boost, Charge, PL / PLP, Straight Mode latch and activation) come from
the VRC car's telemetry bus, read at runtime through CSP's shared storage. No file of the car or
track is read from disk or modified, so checksums are unaffected. Details, channel names and the
replay format are documented in [docs/DATA-CONTRACT.md](docs/DATA-CONTRACT.md).

## Troubleshooting

- **"waiting for the CAN map" for a long time**: the car publishes its telemetry map a few seconds
  after the session starts (about 15 s after a race launch). If it never arrives, check that you
  are in the Pro (CSP) version of the car and that there is **no unpacked `data` folder** next to
  `data.acd` in `content\cars\vrc_formula_alpha_2026_csp`. The car's physics script refuses to run
  with an unpacked data folder, preventing the car from starting and the HUD from receiving data.
  Move that folder out of the car directory and restart the session.
- **Panel shows `--`**: the focused car is not an FA26 Pro, or the replay has no recorded energy data.
- **Chinese labels look wrong**: set a different Chinese label font in the settings.
- **Diagnostics**: `Documents\Assetto Corsa\logs\f1_2026_speedometer_hud_diag.log` accumulates
  across launches; the CSP log gets the same lines tagged `[F1-2026-HUD]`.

## Limitations and planned features

- Replays record up to 22 cars, with indices 0–21. Cars with index 22 or higher are not recorded.
- Energy telemetry currently supports the FA26 Pro. The basic dial also works with other cars.
- Planned additions include DRS indicators for older cars, distance to the next zone, per-lap
  energy history and a label explaining the current power cap.

## Credits and disclaimer

- Car, physics and telemetry bus: [VRC Modding Team](https://www.virtual-racing-cars.com/)'s
  Formula Alpha 2026.
- The dial layout and colours are based on the community's MultiViewer-style speedometer
  overlays. No assets from those apps are included.
- Runs on [Custom Shaders Patch](https://acstuff.club/patch/).
- Not affiliated with Formula One, the FIA, Kunos or VRC. "F1" is used descriptively.

## License

MIT, see [LICENSE](LICENSE).

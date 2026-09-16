# Data contract

This document describes version 0.9.37 (the Straight Mode latch's engaged state in the Pro stream,
on top of 0.9.36's word BOOST inside the glyph while the command is held,
on top of 0.9.35's standard-FA26 deployment request and the in-dial battery glyph of 0.9.3; the Pro adapter, the validity rules and both replay-stream layouts
are unchanged from 0.9.2) and the immutable v0.9.1 Pro replay contract. What each version changed is
listed in [CHANGELOG.md](../CHANGELOG.md).
Reference runtime: CSP build 4116. Actual validation and outstanding in-game checks are recorded
in [COMPATIBILITY.md](COMPATIBILITY.md).

## Sources per mode

| Mode | Dial (speed, RPM, gear, throttle, brake) | State and energy |
| --- | --- | --- |
| Live, FA26 Pro | `ac.getCar(i)` | VRC telemetry bus (below); battery = `car.kersCharge`; STRAT = `car.mgukDelivery + 1` |
| Live, exact native FA26 | `ac.getCar(i)` | Validated native fields below; compact panel |
| Live, conventional car | `ac.getCar(i)` | Native DRS only; no energy panel |
| Replay, exact Pro | AC's own replay | Original Pro stream; H / I only when that stream is absent |
| Replay, exact native FA26 | AC's own replay | Native-state stream, independently valid fields; no unverified native false/zero fallback |
| Replay, exact FA25 CSP | AC's own replay | Native-state DRS recording if present; tested native history is unreliable |
| Replay, other conventional car | AC's own replay | Native DRS requires separate model/field verification; currently unknown/dark |

The car index is the camera-focused car (`sim.focusedCar`, then `sim.closelyFocusedCar`, then 0),
or 0 when "lock to player car" is on.

Exact IDs are `vrc_formula_alpha_2026_csp` (Pro), `vrc_formula_alpha_2026` (native FA26)
and `vrc_formula_alpha_2025_csp` (the conventional model receiving supplemental DRS recording).
Unrecognised IDs use the conventional layout; prefixes, model year and track names are not
evidence of Pro CAN compatibility. There is no capability expansion for other 2026 mods.

Every snapshot is cleared before reading. `valid[field]` distinguishes usable false/zero from
missing values; `supported[field]` can distinguish known absence from unknown capability.
`full` identifies the Pro data path only and must never gate every field in the UI.
Live native values require physics availability, matching car index, appropriate capability,
type and range. `physicsAvailable` alone does not validate replay fields. Missing or disconnected
cars, unavailable getters and mismatched indices are handled without retaining the previous view.

## Pedal arcs and recovery display

The throttle and brake arcs draw `car.gas` and `car.brake` from the current update, and the native
FA26 recovery chip draws the current `recovering` state. Nothing is smoothed, delayed or held.

`car.gas` is AC's physics throttle after gearbox assists, not the driver's pedal. Replays store
both values per car frame, but CSP exposes only the physics value, interpolated between 15 ms
replay frames. The arc therefore shows two assists:

- the automatic gearbox cuts the throttle to 0 for one or two replay frames on each upshift
  (`[AUTO_SHIFTER] GAS_CUTOFF_TIME`); manual upshifts do not cut it;
- auto-blip raises the throttle to about 94 % for 75–90 ms on each downshift while the pedal is
  released, which also interrupts native recovery for that time.

This is intended: the dial reports what the car's throttle actually did.

The periodic diagnostics line reports `replayGaps=<count>@<frame>`: holes of up to 10 replay
frames in recorded native history during forward playback. The count restarts tracking after
replay jumps, backward or large forward steps and car changes. Recordings made with the current
writer report 0. The counter never affects drawing.

## Battery glyph

The glyph in the dial draws the current update only. Nothing is smoothed, delayed or held, apart
from the one decorative easing declared at the end of this section.

- **Charge**: fill length and the percentage come from `kersCharge` (Pro and native FA26). The fill
  is anchored to the wall opposite the terminal, whose side is a display setting. With the terminal on
  the right (the default since 0.9.38) that is the left wall, so deploying moves the fill edge to the
  left and harvesting to the right; the bolt sits beside the terminal and the percentage at the left
  end. With the terminal on the left (the only layout before 0.9.38) the whole glyph is drawn as the
  mirror image about the dial's vertical axis, so the edge moves the other way; text is placed, never
  reversed. The side changes positions only, never a state, colour, brightness or value. At or below 10 % the fill and digits turn amber; red is
  never used for a level. While the Boost command is held the percentage gives way to the word
  `BOOST` (the badge's own placement, centred on the body), and an unknown charge then reads `BOOST`
  rather than `--`; at or below 9 % the number returns beside the word, still amber, and the word
  moves between the bolt and it. The fill is drawn in every case, so the level is always readable as
  a length.
- **Body**: magenta while the manual Boost command is valid and true (`isHybridBoostActive` on the
  Pro, `kersButtonPressed` on the native FA26), otherwise the track colour. This is the former
  `BOOST` badge's rule; the badge itself returns when the glyph is switched off. On a magenta body
  the bolt is drawn white so it stays visible; the ring keeps the flow hue.
- **Ring, terminal and bolt (Pro)**: the sign of `rearMotorPowerKW` beyond a ±5 kW deadband decides
  the state: red below −5 kW (harvesting, including super-clipping at full throttle), green above
  +5 kW (deploying), magenta above +5 kW while Boost is active. The intensity is
  `|rearMotorPowerKW| / 350` of the same update: ring alpha 0.35 + 0.65 × i, ring width 2 + i units,
  halo alpha proportional to i². `mgukMaxPower` is never used, because it reads 0 or −350 during
  super-clipping live and is clamped to 0 in replays. Overtake, Charge mode, PL / PLP and the pit
  limiter never colour the ring; they remain chips in the panel.
- **Native FA26**: green while `deployInput` is valid and above a 0.02 deadband, at that same value
  as the intensity (magenta instead while the Boost command is valid and true); otherwise red at a
  fixed intensity of 0.6 while `recovering` is valid and true. The deployment request is tested
  first, because it is the input the car is acting on in this update, while recovery is a status it
  can also hold off throttle; the two can only overlap at a trailing throttle. Neither intensity is
  a power: the request is a share of the car's own full deployment and the recovery value is a
  declared constant, so the two are separate scales and neither is comparable with `|kW| / 350`.
  Without a valid request the ring falls back to the recovery rule alone, exactly as 0.9.3 drew it.
  The button colours the body only. The live deadband (0.02) is finer than the recorded step (1/14),
  so a request between the two lights the ring live and reads as zero in the replay of the same
  frame; each side draws what it holds, and neither holds nor smooths anything.
- **Unknown or invalid**: while `kw` is invalid (Pro live before the CAN map appears, replay slots
  without the app stream) the ring is idle white; while `soc` is invalid the glyph shows `--` with
  no fill and no bolt. Nothing is retained from the previous update. Conventional cars draw no glyph.
- **Easing** (setting, on by default): the ring brightness, width and halo may approach the current
  intensity with a 120 ms time constant, advanced by `sim.dt` (following replay speed). It is
  evaluated on every drawn update: idle frames ease it down to 0, an unknown flow clears it at once,
  a paused replay (`sim.dt` 0) draws the shown frame's raw intensity, and a car change or a stretch
  without drawing (hidden window) restarts it from the raw value, so a new flow never inherits an
  earlier brightness. The state and hue are never eased: a state the data reports is drawn in that
  same update, and invalid data clears it immediately. With the setting off, the raw intensity is
  drawn.

## VRC telemetry bus

Only the exact Pro adapter reads the channel map published with `ac.store('<carID>_CAN', …)`: a stringified
table whose `inputs` entry maps channel names to `{ index, isBoolean }`. The app parses it once per
session and reads `ac.getCarPhysics(i).scriptControllerInputs[index]` for the selected car,
including AI cars. Channel indices come from the map. It becomes available a few seconds after
the car starts (about 15 s after a race launch).

Channels used:

| Channel | Meaning | Notes |
| --- | --- | --- |
| `rearMotorPowerKW` | MGU-K power, kW, signed | deploy > 0, harvest < 0, ±350 |
| `mgukMaxPower` | live MGU-K cap, kW | 250 / 200 / 150 / 100 in curves and zones; 0 = deployment blocked; −350 = super-clipping |
| `kersDeployMJ`, `kersRegenMJ` | energy deployed / harvested this lap, MJ | reset at the start/finish line |
| `kersRegenLimitMJ` | lap harvesting limit, MJ | 8.0 or 8.5 by track and session; +0.5 while Overtake is active |
| `kersChargeESOC` | energy store state of charge, MJ | equals 4 + 4 × `kersCharge`: the 4 MJ usable window sits on a 4 MJ floor of an 8 MJ store; the app shows ESOC − 4 |
| `deploymentSplit` | current split of the deployment map | 1-based |
| `puMode` | PU mode | 1-based: RACE, AD1, AD2, FS, FW, IN, ES, Q, K2, K2+, SLO, SC, T4, RS |
| `isOvertakeActive`, `isOvertakeActivePending` | Overtake mode | pending = granted, before the activation line |
| `isHybridBoostActive` | Boost button | manual max-deployment override |
| `isHybridAntiActive` | Charge mode | |
| `isPowerLimited`, `isPowerLimitedPending` | PL / PLP states | regulation constraints on power changes |
| `drsLatch` | Straight Mode latch | 0 off, 1 available (white LEDs), 2 pre-latched (blue), 3 available inside the zone (yellow), 4 engaged. Values 0-7 are accepted and recorded; before 0.9.37 the reader accepted only 0-3, so every frame with the mode engaged was dropped from the replay |
| `drsMode` | Straight Mode active | |
| `isEngineRunning`, `isPitLimiterActive` | | |

Native CSP fields used: `speedKmh`, `rpm`, `gear`, `gas`, `brake`, `kersCharge` (state of charge,
0..1), `mgukDelivery` (STRAT − 1), `extraH` / `extraI` (Straight Mode front / rear wing actuators).

## Straight Mode badge logic

When the wings are open (`drsMode` or either extra switch), the indicator is green. Otherwise,
latch 2 is blue, latch 1 is white and latch 3 is yellow; all other values leave it dark.
The latch colours are suppressed below 1 km/h; a valid open wing retains the previous active
precedence. Each source must be valid. Recorded false takes precedence over the native switches;
native H / I is used only when the Pro stream is absent, never on FA25 or native FA26.

## Native FA26 and conventional DRS

| Field | Source | Meaning and validation |
| --- | --- | --- |
| Battery | `kersCharge`, range 0–1, with `kersPresent` | Percentage only; no Pro MJ conversion |
| Manual BOOST | `kersButtonPressed`, with `kersHasButtonOverride` and `kersPresent` | Manual command; never inferred from `kersInput` or power |
| Deployment request | `kersInput`, range 0–1, with `kersPresent` | The share of full deployment the selected map requests at the current throttle and speed. Colours the glyph ring green and sets its brightness. Never a kW measurement, never a BOOST substitute, and a value outside 0–1 is rejected rather than reinterpreted |
| Deployment | `mgukDelivery`, `mgukDeliveryCount`, `ac.getMGUKDeliveryName(carIndex, programIndex)` | Native name; verified contract indices 0–3 = LOW / MEDIUM / HIGH / NODEPLOY |
| Recovery | `kersCharging`, with `kersPresent` | Native recovery state, corroborated by live SoC increases; not net battery power or Pro Charge / Anti |
| DRS capability | `drsPresent` | Known false forces available/active false during trusted live reading |
| Availability | `drsAvailable` | Separate from actual activation and does not imply a track-rule implementation by the HUD |
| Activation | `drsActive` | Native FA26 SM or conventional DRS; rear-wing movement and live transitions verified for native FA26 |

Native FA26 SM has only off / available / on states. It does not reuse the Pro blue/yellow latch
states or H / I. OT is unsupported and dark. Its recovery, SM, battery, BOOST and deployment
paths were validated from private in-game sampling in September 2026; the source does not include
those samples or any commercial car files. The car's observed tail-wing opening is not a claim
of independently verified front-wing actuation.

Sampled FA25 native replay `drsActive` stayed false and `drsAvailable` stayed true while live
samples changed. Old native FA26 saved replays similarly lost battery, BOOST and deployment
history; in-session preview could freeze the last live values. The replay reader therefore
does not trust these defaults, even if `physicsAvailable` is true. Other conventional cars
are not automatically given extra recording or declared verified by those FA25 results.

## Original Pro replay stream (unchanged)

The app uses `ac.ReplayStream` to record energy data every second replay frame during live
sessions, when recording is enabled. There are 22 car slots at 11 bytes per car (242 bytes per
recorded frame). Field names are part of the stream identity and must remain unchanged for
replay compatibility.

| Field | Type | Encoding |
| --- | --- | --- |
| `f26soc` | uint8 | SoC × 250 |
| `f26kw` | int8 | kW / 3 |
| `f26deploy`, `f26regen`, `f26regenLimit` | uint8 | MJ × 20 |
| `f26esoc` | uint8 | MJ × 10 |
| `f26cap` | uint8 | kW / 2 |
| `f26flags` | uint16 | bit 0 OT active, 1 OT pending, 2 boost, 3 charge, 4 PL, 5 PLP, 6-7 SM latch bits 0-1, 8 SM active, 9 wing F, 10 wing R, 11 engine running, 12 pit limiter, 13 SM latch bit 2 (0.9.37), 15 slot recorded |
| `f26pack` | uint16 | bits 0-3 STRAT − 1, 4-8 split, 9-12 PU mode |

If bit 15 is unset, the slot is missing. The old stream has no per-field validity bitmap, so
new live recording writes that bit only when all fields required by this old encoding exist.
Partial live Pro data can still be displayed field by field. Historical recorded slots retain
their original interpretation; old writer defaults cannot be retrospectively corrected.

The original unsigned `f26cap` clamps negative live caps to zero. This existing limitation is
preserved for byte compatibility: a historical zero cap cannot distinguish blocked deployment
from a negative super-clipping cap. Live signed cap display remains intact.

## Native-state stream, schema 1

This is an independent stream: **22 slots × 6 bytes = 132 bytes**, divisor **1**. Its identity
is the exact layout below. The Pro layout is never enlarged or reused for native cars.

| Field | Array element | Encoding |
| --- | --- | --- |
| `f26n1owner` | uint16 | Native FA26 `0xA600 + index + 1`; exact FA25 CSP `0xA500 + index + 1`; 0 = absent |
| `f26n1valid` | uint8 | bit 0 SoC, 1 BOOST, 2 strategy, 3 recovery, 4 DRS present, 5 available, 6 active |
| `f26n1state` | uint8 | bit 0 BOOST, 1 recovery, 2 DRS present, 3 available, 4 active |
| `f26n1soc` | uint8 | SoC × 250, nearest integer, range 0–250; max error 0.2 percentage points |
| `f26n1strategy` | uint8 | bits 0-3: 0 LOW, 1 MEDIUM, 2 HIGH, 3 NODEPLOY. bits 4-7 (0.9.35): 0 = no deployment request recorded, 1-15 = nearest integer of request × 14, plus 1, so the request carries its own validity and needs no bit in `f26n1valid`; steps of 1/14, max error 0.036 of the request, and a request below 0.036 records as zero |

Each field is an array of length 22. The 0.9.35 addition deliberately stays inside this layout: the
slot count, the byte count, the divisor and every validity bit are those of schema 1, so recordings
made before 0.9.35 restore field for field. A reader older than 0.9.35 validates the strategy byte as
0-3 only, so any frame that carries a deployment request reads as an unavailable strategy there --
in practice that is every recorded frame of a car whose request is readable -- while the state of
charge, BOOST, recovery and DRS fields of the same slot still restore; readers from 0.9.35 on accept the whole byte range of `f26n1valid` and
`f26n1state` and ignore bits they do not know, rather than discarding the slot.

The owner embeds the schema/car family and slot; playback
requires an exact expected owner for the selected car ID and index. A valid false or zero is
authoritative; native defaults never overwrite it. Strategy is recorded only when the native
API name matches the four-name contract. A different name can display live but is not silently
recorded as a different strategy. FA25 slots only use the DRS subset.

Integers are intentional: the official SDK struct builder gives these raw integer items no
`replayType`, and its replay interpolation map only includes items having that metadata. Packed
booleans and strategy indices must not be converted to interpolated float or normalized fields.
See the primary SDK [struct definitions](https://github.com/ac-custom-shaders-patch/acc-lua-sdk/blob/main/common/ac_struct_item.lua)
and [stream implementation](https://github.com/ac-custom-shaders-patch/acc-lua-sdk/blob/main/lib_replaystream.lua).
Actual CSP saved-file timing and seek boundaries are still subject to in-game acceptance.

During live updates, the current car snapshot is prepared before updating its shared stream
slot. Valid-to-valid updates do not first publish an empty slot. Fields that become invalid
have their validity revoked before payload clearing; disabled recording, departed cars and
slots beyond the current grid are still cleared. In replay mode
the buffers belong to CSP and are never written. The reader keeps no previous-frame value cache:
pause and reverse seeking read the current provided slot, and zero/unrecorded frames stay missing.
Indices 22 and above can display live data but are not recorded. Neither stream patches existing
replay files. Initialising a stream with recording disabled can still add an empty replay block;
zero file-size overhead is not promised.

## Files the app writes

- Settings: CSP app storage (`Documents\Assetto Corsa\cfg\extension\state\lua\app\`).
- Diagnostics: `Documents\Assetto Corsa\logs\f1_2026_speedometer_hud_diag.log`, last 600 lines,
  accumulating across launches; the same lines go to `custom_shaders_patch.log` tagged `[F1-2026-HUD]`.
- Product state streams inside newly saved replays when enabled; no extra file is required to view them.

The launch line of the diagnostics file is written at start-up independently of the periodic
diagnostics checkbox.

No car or track file is read from disk or modified.

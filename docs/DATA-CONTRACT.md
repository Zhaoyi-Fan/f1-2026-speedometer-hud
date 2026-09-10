# Data contract

What the app reads, what it records, and what the values mean. Everything here was verified in-game
on the VRC Formula Alpha 2026 (Pro) V1.0 with CSP build 4116 (September 2026).

## Sources per mode

| Mode | Dial (speed, RPM, gear, throttle, brake) | Energy panel |
| --- | --- | --- |
| Live, FA26 Pro | `ac.getCar(i)` | VRC telemetry bus (below); battery = `car.kersCharge`; STRAT = `car.mgukDelivery + 1` |
| Live, other car | `ac.getCar(i)` | `--` |
| Replay recorded with the app running | AC's own replay | the app's replay stream (below) |
| Replay recorded without the app | AC's own replay | `--`; the SM badge still works from the wing extra switches H / I, which AC records |

The car index is the camera-focused car (`sim.focusedCar`, then `sim.closelyFocusedCar`, then 0),
or 0 when "lock to player car" is on.

## VRC telemetry bus

The car's physics script publishes a channel map with `ac.store('<carID>_CAN', …)`: a stringified
table whose `inputs` entry maps channel names to `{ index, isBoolean }`. The app parses it once per
session and reads `ac.getCarPhysics(i).scriptControllerInputs[index]` for any car, AI included.
Index numbers are never hard-coded. The map appears a few seconds after the car boots (about 15 s
after a race launch).

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
| `drsLatch` | Straight Mode latch | 1 available (white LEDs), 2 pre-latched (blue), 3 available inside the zone (yellow) |
| `drsMode` | Straight Mode active | |
| `isEngineRunning`, `isPitLimiterActive` | | |

Native CSP fields used: `speedKmh`, `rpm`, `gear`, `gas`, `brake`, `kersCharge` (state of charge,
0..1), `mgukDelivery` (STRAT − 1), `extraH` / `extraI` (Straight Mode front / rear wing actuators).

## Straight Mode badge logic

Wings open (`drsMode` or either extra switch) → green. Otherwise latch 2 → blue, latch 1 → white,
latch 3 → yellow, else dark. Below 1 km/h the badge is dark, as on the steering wheel LEDs.

## Replay stream

`ac.ReplayStream`, recorded every second replay frame while live, 22 car slots, 11 bytes per car
(242 bytes per frame). Field names are part of the stream identity and must not change.

| Field | Type | Encoding |
| --- | --- | --- |
| `f26soc` | uint8 | SoC × 250 |
| `f26kw` | int8 | kW / 3 |
| `f26deploy`, `f26regen`, `f26regenLimit` | uint8 | MJ × 20 |
| `f26esoc` | uint8 | MJ × 10 |
| `f26cap` | uint8 | kW / 2 |
| `f26flags` | uint16 | bit 0 OT active, 1 OT pending, 2 boost, 3 charge, 4 PL, 5 PLP, 6-7 SM latch, 8 SM active, 9 wing F, 10 wing R, 11 engine running, 12 pit limiter, 15 slot recorded |
| `f26pack` | uint16 | bits 0-3 STRAT − 1, 4-8 split, 9-12 PU mode |

A slot without bit 15 reads as "no data" (`--`), never as garbage. Cars with index 22 or higher are
not recorded. Assetto Corsa's own replay does not contain `kersCharge` or `kersInput`; extra
switches are recorded, which is why the SM badge works in any replay.

## Files the app writes

- Settings: CSP app storage (`Documents\Assetto Corsa\cfg\extension\state\lua\app\`).
- Diagnostics: `Documents\Assetto Corsa\logs\f1_2026_speedometer_hud_diag.log`, last 600 lines,
  accumulating across launches; the same lines go to `custom_shaders_patch.log` tagged `[F1-2026-HUD]`.

No car or track file is read from disk or modified.

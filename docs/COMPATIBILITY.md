# Compatibility and validation — version 0.9.39

Updated 2026-09-16. Runtime reference: CSP build 4116. Version 0.9.3 replaced the side bars with a
battery glyph inside the dial; version 0.9.35 reads one further native field on the standard FA26,
its deployment request, and gives that car's panel a second chip; version 0.9.36 writes the word BOOST
inside the glyph while that command is held; version 0.9.37 stops the Pro stream dropping every frame
in which Straight Mode is engaged; version 0.9.38 turns the glyph to face right by default and adds
a display setting for the terminal side; version 0.9.39 removes the standard FA26's `OT` badge,
widens its `SM` badge to the whole row and draws its available state yellow, and records the DRS state
of every car with a native DRS component under a generic car family. The Pro adapter, the validity
rules and both replay-stream layouts are those of 0.9.2, so the checks below still apply to them; the
standard-FA26 rows carry their own new pending item, because the samples behind them predate that field. The 0.9.1 ZIP is
the earlier Pro-only build.

## Support matrix

| Scenario | Behaviour | Checked | Still pending in game |
| --- | --- | --- | --- |
| Exact FA26 Pro, live | SM / OT / BOOST badges, full energy panel, Pro replay recording; partial data stays field-valid | Live evidence from 0.9.1 and earlier; offline regression; the 0.9.2 adapter read the car's real channel map (122 channels, all 18 used channels present) and passed a read / record / replay round-trip on it | A live session on the 0.9.2 adapter, including AI cars and a new Pro recording |
| Exact FA26 Pro, old replays | Same stream names, types, 22 slots, 242 bytes, divisor 2; H / I wing fallback while the stream is absent. Recordings from 0.9.2 to 0.9.36 have no data at all in the frames where Straight Mode was engaged, and cannot be repaired | Layout and codec tests; 0.9.2 in game played a replay recorded on 2026-09-10 through the Pro stream: 130 periodic samples with changing values, `replayGaps` 0, no Lua errors | — |
| Standard FA26, live | `SM` across the badge row (off dark, available yellow, open green), manual BOOST, battery %, four native strategies, recovery state and the deployment request of the selected map; no `OT` badge, the car has no Overtake Mode | 2,913 live samples across two sessions; rear-wing opening and brake charging observed in game. On Silverstone's 2026 layout the native availability rose at each zone's start and fell at its end or on the brake, with no change at the overtake detection or activation line (2,801 samples, one car). Those samples predate the deployment request and the 0.9.39 badge row | The deployment request against the car's own behaviour: nothing requested in `NODEPLOY`, below the maps' low-speed threshold or at the top of the speed range, and a request proportional to the throttle in between; the 0.9.39 badge row in game; availability in a race with other cars |
| Standard FA26, new replays | Separate 132-byte native-state stream with per-field validity and owner; since 0.9.35 the deployment request travels in free bits of the existing strategy byte, with no change to the layout | A recording made after the writer correction holds 7,307 consecutive valid samples with no interior gaps; an end-to-end playback check draws the recorded values on all 7,306 recorded frames; in-game viewing reported `replayGaps` 0 in 22 periodic samples | — |
| Standard FA26, old replays | Base dial only; unavailable history stays unknown | Old files sampled: native energy and control fields missing despite visible wing movement | — |
| Pedal arcs and recovery chip around shifts | Drawn as reported: automatic-upshift cut and downshift auto-blip visible, manual upshifts steady; the Pro's power-driven ring does not follow the upshift cut, while the standard FA26's request-driven ring does, because the request is proportional to that same throttle | Same end-to-end and in-game checks as the row above; see [KNOWN-ISSUES.md](KNOWN-ISSUES.md) | — |
| Exact FA25 CSP, live | One centred DRS indicator, no Pro panel, no H / I interpretation | Live samples with active / available transitions; offline UI regression | — |
| Exact FA25 CSP, old replays | DRS unknown and dark without a valid record | Native replay samples stayed at fixed false / true values; not treated as a real closed wing. AC's replay data holds the open wing, but CSP does not pass it on: about 12,000 FA25 playback samples never reported it open | — |
| Exact FA25 CSP, new replays | The native-state stream carries only its DRS fields | Synthetic round-trip | A new in-game recording |
| Other conventional cars, live | Native live DRS; since 0.9.39 its state is recorded under the generic family while the car reports a DRS component | Generic adapter tests; synthetic record / playback: open and closed wing, wrong slot, other families, no component, no physics, no car ID, departed car | A new in-game recording on such a car |
| Other conventional cars, replays | DRS from the app's generic record; without one, unknown and dark | Native playback is not history on any sampled car: on the standard FA26, 278 samples whose replay data shows the wing open all reported it closed. A 0.9.38 reader leaves generic slots unread and reads the standard FA26 and FA25 slots exactly as 0.9.39 does, in both directions (one-off check against the 0.9.38 source, 102 assertions) | Playback of a 0.9.39 recording on such a car |
| Cars without DRS | Same DRS label, always dark | Known-absent and conflicting-input tests | A game screenshot |
| Mixed camera, pause, reverse seek, missing data | The current snapshot is rebuilt every update; no previous-car or future-value cache | Synthetic routing and state tests | Mixed-grid acceptance |
| Battery glyph, Pro and standard FA26 | Body = Boost button, reading `BOOST` while it is held (the single-digit charge returns beside the word); ring and terminal = the flow of the current update (red harvest, green deploy, magenta Boost); bolt = the same hue, white on the magenta Boost body; fill anchored to the wall opposite the terminal (on the right by default; the left-hand setting draws the mirror image, the look before 0.9.38), amber when the displayed figure is 10 % or less; `--` without fill or bolt when the charge is invalid. Brightness comes from `|kW| / 350` on the Pro, and on the standard FA26 from the deployment request, or a fixed value while it reports recovery | Offline UI checks of every state, the 5 kW deadband and the request deadband, unknown power, invalid charge, the fill anchor, the 10 % boundary, the bolt colours and winding, the native deploy / Boost / recovery precedence, the `BOOST` word with and without the single-digit number, the two terminal sides as mirror images (twelve states at three scales compared shape by shape; the bolt moved, not flipped), the left side drawing exactly what 0.9.37 drew (1,536 rendered states compared draw call by draw call), and the brightness easing (raw when off or at `sim.dt` 0, decaying through idle frames, cleared by an invalid update, restarted on a car change or after undrawn updates). A lap with the automatic gearbox showed no flicker of the Pro's ring at the upshift throttle cut. Both terminal sides were viewed in game on a Pro replay before the right-facing glyph became the default | A Pro session with harvesting, deploying, Boost and super-clipping; readability of the digits, bolt and ring at any scale; the right-facing glyph on the standard FA26 and in a live session |
| Chinese / English, scale, panel and glyph | Pro dial and panel, compact standard-FA26 panel, plain dial for other cars; the `BOOST` badge returns when the glyph is off; the glyph on either terminal side | 144 UI combinations (both terminal sides) and drawing bounds | Actual font rendering at each scale |

## What the standard-FA26 evidence means

The sampled standard FA26 has a dynamic battery, all four deployment indices, manual BOOST and
native DRS transitions. The deployment request added in 0.9.35 is the value the selected delivery
map asks for at the current throttle and speed, so the green ring shows what the car asks the
MGU-K for, not what the MGU-K delivers; the car publishes no power channel to check it against. In-game observation confirmed rear-wing opening after the DRS control and
battery recovery under braking, including occasional lift-off recovery. Sustained
`kersCharging = true` correlates strongly with a rising state of charge, but it is a recovery-state
flag, not a net-power measurement or a guarantee of increasing charge on every frame.

The live tests used a 2026 Silverstone layout; other tracks and rule combinations are not claimed.
No track or car physics was changed. Old native replay defaults are treated as missing; their
existence does not imply that every native car uses the same storage or that old replays can be
repaired. The FA25 supplemental recording decision followed analysis of its own live and replay
samples. Version 0.9.39 extends the same DRS recording to every car that reports a native DRS
component, after a byte-level comparison showed that AC's replay data stores each car's open wing (and
its KERS button and recovery flags) while CSP playback returns only the recovery flag, on the standard
FA26 and the FA25 CSP alike. The recording copies what the car reports live; it does not validate what
DRS means on any particular car.

## Reproducible offline checks

Run `tools/test.ps1 -MoonSharpDll <path-to-existing-MoonSharp-DLL> -TestFile tests/test_hud_data.lua`
and repeat with `tests/test_hud_ui.lua`. The runner uses x86 PowerShell; no DLL is shipped.
The fixtures are synthetic. Private sampling files, commercial vehicle files, replay files, local
backups and machine logs are excluded from the repository.

- Data tests (652 checks): exact classification, callable CSP API tables, 242 / 132-byte layouts,
  codecs, partial validity, zero / false, wrong owner or slot, missing frames, dropped cars,
  recording off, replay write protection, camera changes and range limits, the deployment
  request's validation, evidence gate, round trip through the shared strategy byte and both
  cross-version directions, and the generic DRS family (recording and playback of open and closed
  wings, the DRS-only subset even over another family's bits, wrong slot, the other two families,
  cars without DRS or without an ID, unavailable physics and unreadable cars in the gap count, a
  partial or physics-less Pro, mixed grids, departed cars and family switches that revoke validity first).
- UI tests (11,331 checks): execute the real main Lua with a stub data adapter and a drawing
  recorder. They validate content, geometry, scale and language combinations, partial Pro data
  and the canvas origin, the badge rows (the Pro's SM | OT pair, the standard FA26's full-width SM
  without OT, and its dark / yellow / green states at speed and at rest, with unverified flags kept
  dark), the battery glyph's states (harvest / deploy / Boost / idle / unknown /
  invalid, the Boost body, the fill anchored opposite the terminal, the amber low-charge rule, the
  native car's fixed-intensity red and its request-driven green, the conventional car's absence, the
  brightness easing and its pause behaviour), the two terminal sides as shape-by-shape mirror images
  with the right one as default and fallback, and the terminal choice in the settings window; check
  that the pedal arcs and recovery chip draw each update's values through an upshift cut and an
  auto-blip (three vehicle kinds, live and replay); and cover the `replayGaps` diagnostic.
- 0.9.39 one-off checks, not part of the suites: 20 deliberate code mutations of the new badge and
  recording logic were each caught by these tests; 1,536 rendered states compared draw call by draw
  call with 0.9.38 show the Pro and conventional dials unchanged and the standard FA26 changed only in
  its badge row; and the 0.9.38 and 0.9.39 stream readers were run against each other's recordings.
- Deployment script: tested against a fake AC root in PowerShell 7 and Windows PowerShell 5.1,
  including per-file backups, hashes, unrelated-file retention, rollback, modified-file rejection
  and game-running rejection.

These offline checks do not simulate CSP's binary compression and storage, actual replay frame
selection, Windows font metrics or the rendered game. Periodic diagnostics do not validate every
frame or seek boundary.

## History: the 2026-09-13 investigation

Three findings came out of the first in-game runs of the multi-car build:

1. **Blank frames.** The first native-stream writer cleared a slot before rewriting it, and the CSP
   recording thread could capture that empty state: one 141 s recording held 41 isolated all-zero
   records. The writer now prepares each sample before publishing it and never clears a slot that
   stays valid; the next recording had no interior gaps. Existing files are not patched, and the
   `replayGaps` diagnostic reports such holes during playback.
2. **Throttle and recovery transients around gear shifts.** They are AC's own gearbox assists
   (automatic-upshift throttle cut, downshift auto-blip) seen through `car.gas`, which follows the
   physics throttle rather than the pedal. A 100 ms smoothing pass and an 80 ms delayed shift
   filter were tried and withdrawn; the arcs and the recovery chip are drawn exactly as reported.
3. **Verification method.** An end-to-end check now feeds a recording frame by frame through the
   production replay reader and the main HUD and compares every drawn value with the recorded one.

Details and the remaining open items are in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

# Compatibility and validation — version 0.10.0

Updated 2026-09-15. Runtime reference: CSP build 4116. Version 0.10.0 replaces the side bars with a
battery glyph inside the dial; the adapters, validity rules and replay streams are those of 0.9.2,
so the checks below still apply to them. The 0.9.1 ZIP is the earlier Pro-only build.

## Support matrix

| Scenario | Behaviour | Checked | Still pending in game |
| --- | --- | --- | --- |
| Exact FA26 Pro, live | SM / OT / BOOST badges, full energy panel, Pro replay recording; partial data stays field-valid | Live evidence from 0.9.1 and earlier; offline regression; the 0.9.2 adapter read the car's real channel map (122 channels, all 18 used channels present) and passed a read / record / replay round-trip on it | A live session on the 0.9.2 adapter, including AI cars and a new Pro recording |
| Exact FA26 Pro, old replays | Same stream names, types, 22 slots, 242 bytes, divisor 2; H / I wing fallback while the stream is absent | Layout and codec tests; 0.9.2 in game played a replay recorded on 2026-09-10 through the Pro stream: 130 periodic samples with changing values, `replayGaps` 0, no Lua errors | — |
| Standard FA26, live | SM off / available / active, manual BOOST, battery %, four native strategies, recovery state; OT dark | 2,913 live samples across two sessions; rear-wing opening and brake charging observed in game | — |
| Standard FA26, new replays | Separate 132-byte native-state stream with per-field validity and owner | A recording made after the writer correction holds 7,307 consecutive valid samples with no interior gaps; an end-to-end playback check draws the recorded values on all 7,306 recorded frames; in-game viewing reported `replayGaps` 0 in 22 periodic samples | — |
| Standard FA26, old replays | Base dial only; unavailable history stays unknown | Old files sampled: native energy and control fields missing despite visible wing movement | — |
| Pedal arcs and recovery chip around shifts | Drawn as reported: automatic-upshift cut and downshift auto-blip visible, manual upshifts steady | Same end-to-end and in-game checks as the row above; see [KNOWN-ISSUES.md](KNOWN-ISSUES.md) | — |
| Exact FA25 CSP, live | One centred DRS indicator, no Pro panel, no H / I interpretation | Live samples with active / available transitions; offline UI regression | — |
| Exact FA25 CSP, old replays | DRS unknown and dark without a valid record | Native replay samples stayed at fixed false / true values; not treated as a real closed wing | — |
| Exact FA25 CSP, new replays | The native-state stream carries only its DRS fields | Synthetic round-trip | A new in-game recording |
| Other conventional cars | Native live DRS; no supplemental recording | Generic adapter tests | Native replay reliability, per car |
| Cars without DRS | Same DRS label, always dark | Known-absent and conflicting-input tests | A game screenshot |
| Mixed camera, pause, reverse seek, missing data | The current snapshot is rebuilt every update; no previous-car or future-value cache | Synthetic routing and state tests | Mixed-grid acceptance |
| Battery glyph, Pro and standard FA26 | Body = Boost button; ring and terminal = MGU-K flow of the current update (red harvest, green deploy, magenta Boost), brightness from `|kW| / 350`; bolt = the same hue, white on the magenta Boost body; fill anchored to the right wall, amber when the displayed figure is 10 % or less; standard FA26 red at a fixed brightness and never green; `--` without fill or bolt when the charge is invalid | Offline UI checks of every state, the 5 kW deadband, unknown power, invalid charge, the fill anchor, the 10 % boundary, the bolt colours and winding, and the brightness easing (raw when off or at `sim.dt` 0, decaying through idle frames, cleared by an invalid update, restarted on a car change or after undrawn updates) | A Pro session with harvesting, deploying, Boost and super-clipping; one lap with the automatic gearbox (see KNOWN-ISSUES); readability of the digits, bolt and ring at the user's scale |
| Chinese / English, scale, panel and glyph | Pro dial and panel, compact standard-FA26 panel, plain dial for other cars; the `BOOST` badge returns when the glyph is off | 72 UI combinations and drawing bounds | Actual font rendering at each scale |

## What the standard-FA26 evidence means

The sampled standard FA26 has a dynamic battery, all four deployment indices, manual BOOST and
native DRS transitions. In-game observation confirmed rear-wing opening after the DRS control and
battery recovery under braking, including occasional lift-off recovery. Sustained
`kersCharging = true` correlates strongly with a rising state of charge, but it is a recovery-state
flag, not a net-power measurement or a guarantee of increasing charge on every frame.

The live tests used a 2026 Silverstone layout; other tracks and rule combinations are not claimed.
No track or car physics was changed. Old native replay defaults are treated as missing; their
existence does not imply that every native car uses the same storage or that old replays can be
repaired. The FA25 supplemental recording decision followed analysis of its own live and replay
samples and is not extended to other conventional cars.

## Reproducible offline checks

Run `tools/test.ps1 -MoonSharpDll <path-to-existing-MoonSharp-DLL> -TestFile tests/test_hud_data.lua`
and repeat with `tests/test_hud_ui.lua`. The runner uses x86 PowerShell; no DLL is shipped.
The fixtures are synthetic. Private sampling files, commercial vehicle files, replay files, local
backups and machine logs are excluded from the repository.

- Data tests (519 checks): exact classification, callable CSP API tables, 242 / 132-byte layouts,
  codecs, partial validity, zero / false, wrong owner or slot, missing frames, dropped cars,
  recording off, replay write protection, camera changes and range limits.
- UI tests (5,602 checks): execute the real main Lua with a stub data adapter and a drawing
  recorder. They validate content, geometry, scale and language combinations, partial Pro data
  and the canvas origin, the battery glyph's states (harvest / deploy / Boost / idle / unknown /
  invalid, the Boost body, the right-anchored fill, the amber low-charge rule, the native car's
  fixed-intensity red, the conventional car's absence, the brightness easing and its pause
  behaviour), check that the pedal arcs and recovery chip draw each update's values through an
  upshift cut and an auto-blip (three vehicle kinds, live and replay), and cover the `replayGaps`
  diagnostic.
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

# Compatibility and validation — version 0.9.2

Updated 2026-09-13. Runtime reference: CSP build 4116. The 0.9.1 ZIP is the earlier Pro-only build.

Current checkpoint: the shift-adjacent throttle-arc and recovery flicker is AC's own gearbox-assist
throttle behaviour. It is shown as recorded by design, and the earlier display smoothing is
removed. A post-fix recording plays back with no blank frames in an end-to-end check. Viewing
that recording in game with this build showed no remaining issue, and all periodic diagnostics
reported `replayGaps` 0. See [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

## Evidence and current support

| Scenario | Implemented result | Validation status |
| --- | --- | --- |
| Exact FA26 Pro live | Original SM / OT / BOOST and energy layout; partial data kept field-valid | Prior live evidence retained; offline regression passed; installed revision live smoke pending |
| Old Pro stream | Same names, types, 22 slots, 242 bytes, divisor 2 | Exact layout/codec tests passed; installed revision read changing old Pro data in 11 periodic samples; stable playback observed in game |
| Native FA26 live | SM off / available / active, manual BOOST, battery %, four native strategies, recovery state; OT dark | 2,913 real live samples across two sessions; rear-wing opening and brake charging observed in game |
| Native FA26 new stream | Per-field valid state and owner; separate 132-byte stream | Fresh recording after writer correction has 7,307 consecutive valid samples, no interior gaps; all fields dynamic |
| Pedal arcs and recovery chip around gear shifts | Drawn as reported: automatic upshift cut and downshift auto-blip visible, manual upshifts steady | Production reader and main Lua on a post-fix recording: all 7,306 recorded frames draw the recorded values, 0 blank frames; in-game viewing: no remaining issue, `replayGaps` 0 in 22 periodic samples |
| Native FA26 old saved replay | Base dial remains; unavailable history stays unknown | Old and newly saved pre-update files sampled; native energy/control fields missing despite visual wing movement |
| Exact FA25 CSP live | One centered DRS, no Pro panel, no H / I interpretation | Live samples contain active/available transitions; offline UI regression passed |
| Exact FA25 CSP old replay | DRS unknown/dark without valid record | Multiple native replay samples fixed false/true; not claimed to be real closed state |
| Exact FA25 CSP new stream | Supplement only its DRS fields | Synthetic round-trip passed; new in-game recording pending |
| Other conventional cars | Native live DRS; no blanket supplemental recording | Generic adapter tests; specific native replay reliability remains unverified |
| No DRS car | Same DRS label, always dark | Known-absent and conflicting-input tests passed; actual game screenshot pending |
| Mixed camera, pause, reverse seek, no data | Rebuild current snapshot; no previous-car or future-value cache | Synthetic routing/state tests passed; mixed-grid game acceptance pending |
| Chinese/English, scale, panel/bars | Existing Pro dial and compact native display, legacy dial only | 72 UI combinations and drawing bounds passed; actual font/render acceptance pending |
| Probe retirement | Production app contains no probe import or CSV writer | Source/installation checks and subsequent runtime inventory passed; all 33 historical CSV files retained, none newly generated |

## What the native evidence means

The sampled ordinary FA26 has dynamic battery, all four deployment indices, manual BOOST and
native DRS transitions. In-game observation confirmed tail-wing opening after the DRS control and
battery recovery under braking. Sustained `kersCharging=true` strongly correlates with increasing
SoC, but is a recovery-state flag, not a net-power measurement or a guarantee of increasing charge
on every frame. Acceptance of the installed revision also showed occasional lift-off recovery with
rising battery charge.

The live test used a 2026 Silverstone layout. It is not claimed to validate the official GP
layout or every track/rules combination. No track or car physics was changed.

Old native replay defaults are treated as missing. Their existence does not imply all native
cars use the same storage or that all old replays can be fixed. The exact FA25 supplemental
recording decision followed analysis of its existing live/replay samples.

## Reproducible offline checks

Run `tools/test.ps1 -MoonSharpDll <path-to-existing-MoonSharp-DLL> -TestFile tests/test_hud_data.lua`
and repeat with `tests/test_hud_ui.lua`. The runner uses x86 PowerShell; no DLL is shipped.
The fixtures are synthetic. Private sampling CSV files, commercial vehicle files, replay files, local
backups and machine logs are excluded from the repository.

- Data tests: exact classification, callable CSP API tables, 242/132-byte layouts, codecs,
  partial validity, zero/false, wrong owner/slot, missing frames, dropped cars, recording off,
  replay write protection, camera changes and range limits.
- UI tests: execute the real main Lua with a stub data adapter and drawing recorder. Validate
  content, geometry, scale and language combinations, partial Pro data and canvas origin. Also
  check that the pedal arcs and recovery chip draw each update's values through an upshift cut and
  an auto-blip (three vehicle kinds, live and replay), and cover the `replayGaps` diagnostic.
- Deployment: tested against a fake AC root in PowerShell 7 and Windows PowerShell 5.1,
  including per-file backups, hashes, unrelated-file retention, probe retirement, rollback,
  modified-file rejection and game-running rejection.

These offline checks do not simulate CSP's binary compression/storage, actual replay frame
selection, Windows font metrics or the rendered game. A fresh ordinary FA26 recording and
saved-file playback subsequently confirmed the native stream in CSP: 55 periodic live/replay
samples had the five required fields valid, including all four strategy names and changing
SM, BOOST, battery and recovery. Periodic logs do not validate every frame or seek boundary.

In-game viewing showed stable Pro playback and brief flashes in ordinary FA26 around gear shifts,
affecting recovery, arcs and vertical bars. Independent decoding of the saved native stream
found 41 isolated all-zero frames between valid records, beyond its initial 51 empty frames.
Real main-Lua rendering tests reproduce the battery/recovery disappearance on those empty
frames; with unchanged base telemetry, the dial arcs and background remain unchanged.

The writer has been changed to prepare data before publishing and to avoid clearing valid
slots before each update. This removes an unnecessary empty interval in the writer; the exact
C++ sampling interleaving is not directly observed. A fresh recording after this correction
contains 7,362 frames: 55 initial unrecorded frames followed by 7,307 consecutive records with
correct owner and all seven validity bits set. There are no interior empty, partial or malformed
records. All four strategy names, active/inactive BOOST, SM and recovery, and battery from
42% to 100% occur. Live rejection counters remain zero. This confirms removal of the recorded
gap symptom in the new sample; throttle/recovery transients were still visible afterwards.
Existing saved holes remain missing; no history patching or missing-frame hold was added.
The existing five-second diagnostics now count rejected native recording snapshots to help
distinguish real source unavailability from a recording problem. No new CSV probe is used.

After this fix, throttle and recovery transients remained visible in ordinary FA26.
Existing high-gas upshift samples show eight unbraked ordinary `1 → 0 → 1` throttle sequences;
none was captured in 408 comparable Pro upshift samples. These 10 Hz samples do not prove
Pro never cuts throttle or recover the physical pedal position. The problematic run turned out
to use automatic shifting, while a later manual-shift run looked stable
before display smoothing was installed. Shift-assist settings were not captured in the existing
CSV or native stream, so these samples cannot establish a controlled Pro/native or automatic/manual
comparison. Automatic shifting is a relevant lead, not a confirmed cause. The new native recovery
record contains ten valid 60–90 ms off intervals and seven 15 ms on pulses, with no data gaps.

Light display smoothing was tried next: an ordinary-only response softened the throttle arc and
debounced the recovery chip, while the canonical snapshot and recorded bytes stayed raw. It was
installed after the manual/automatic finding; the earlier manual-shift improvement came from the
writer correction alone. Some flicker remained, and that round ended without isolating the
replay, assist mode or affected element.

### Shift-transient root cause and final display decision (later on 2026-09-13)

Decoding the saved replays' car frames showed that each frame stores the physics throttle and
the driver's pedal separately. Lua's `car.gas` follows the physics value: in 42 of 42 probe
samples where the two differ it matched the physics byte and never the pedal byte, interpolated
between frames. With the automatic gearbox, every upshift cuts that value to 0 for one or two
frames; auto-blip raises it to about 94 % for 75–90 ms on every downshift, interrupting native
recovery for the same time. The Pro samples above were manual-shift sessions, which is why they
had no upshift cuts; they do contain downshift blips.

The last "still flickers" check after smoothing was made partly on a replay recorded before the
writer correction, whose empty records blank the battery bar independently of shifts. The
earlier smoothing reduced flash amplitude but not frequency (43 → 41 perceptible flashes).

An 80 ms delayed shift filter was built and verified offline, then withdrawn. It also hid the
downshift auto-blips, which should stay visible like the audible engine blip, and it delayed both
pedal arcs. The smoothing and recovery debounce were removed as well: the pedal arcs
and recovery chip are drawn exactly as reported. Upshift cuts therefore remain visible with the
automatic gearbox and do not occur with manual shifting.

Blank frames are covered by an end-to-end playback check of the production replay reader and main
HUD, fed frame by frame with a post-fix recording's native stream and car inputs. All 7,306 recorded
frames draw the recorded battery value, strategy, recovery chip, SM and BOOST badges and throttle
arc. There are no blank frames after the first record, and the new `replayGaps` diagnostic reports
0. The same check flags the 41 holes of the pre-fix recording and reports `replayGaps` 41.

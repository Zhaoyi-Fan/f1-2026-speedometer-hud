# Known issues — version 0.10.0

Updated 2026-09-15 for version 0.10.0 (in-dial battery glyph; adapters and replay streams as in 0.9.2).
See [COMPATIBILITY.md](COMPATIBILITY.md) for validation scope.

## Battery ring around automatic upshifts: not yet sampled

The automatic gearbox cuts the physics throttle for one or two frames on each upshift (next
section). Whether `rearMotorPowerKW` also dips below −5 kW during that cut, which would colour the
battery ring red for those frames, has not been sampled: every Pro session recorded so far used
manual shifts. If it does, the ring shows it as reported, like the throttle arc.

## Throttle arc and recovery chip flicker around gear shifts: by design

**Explained; shown as recorded by design.**

The HUD draws `car.gas`, which is AC's physics throttle after gearbox assists. Each replay car
frame stores this value next to the driver's pedal value, but CSP exposes only the physics value.
In 42 of 42 probe samples where the two stored values differ, Lua's `car.gas` followed the
physics value.

- **Upshift with the automatic gearbox**: the physics throttle drops to 0 for one or two 15 ms
  frames while the pedal stays pressed, so the green arc collapses briefly. The cut happened on
  every automatic upshift in the sampled replays. Manual upshifts have no cut: across a manual
  ordinary FA26 session and two Pro sessions, 0 of 146 upshifts had one.
  Automatic upshifts occur at a fixed speed per gear (for example 186–187 km/h for 3→4 in one
  replay), while the manual ones scatter.
- **Downshift with auto-blip**: the physics throttle rises to about 94 % for 75–90 ms while the
  pedal is released, and native recovery pauses for the same time. This matches the engine blip
  a driver hears and is kept.

Tried on 2026-09-13 and removed:

- a 100 ms throttle smoothing with a recovery debounce, which reduced the size of the flashes but
  not their number (43 → 41 in one replay);
- an 80 ms delayed shift filter, which removed them but also hid the downshift blips.

The pedal arcs and recovery chip are now drawn exactly as reported.

## Blank frames in replays saved with the first native-stream writer

The first compatibility writer cleared replay slots before rewriting them. The CSP recording
thread could capture that empty state, leaving isolated all-zero records (41 in one 141 s test
replay, unrelated to shifts). The battery bar, strategy and state badges show missing data on
those frames. The corrected writer prepares data before publishing.

An end-to-end check fed a post-fix recording frame by frame through the production replay reader
and main HUD. Every drawn battery value, strategy, recovery chip, SM and BOOST badge and throttle
arc matched the recorded value on all 7,306 recorded frames, with 0 blank frames. The same check
finds all 41 blank frames in the pre-fix recording. Existing pre-fix replays are not patched.
The `replayGaps` diagnostic reports such holes during playback.

## Other open acceptance items

Listed in COMPATIBILITY.md: a live Pro session on the 0.9.2 adapter (including AI cars and a new
Pro recording), the battery glyph's first in-game look (digits over the fill, bolt, ring and halo
at the user's scale), exact FA25 supplemental replay recording, mixed-camera behavior, no-DRS
rendering and actual fonts/scales.

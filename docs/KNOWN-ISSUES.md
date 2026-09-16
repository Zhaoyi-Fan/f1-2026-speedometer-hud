# Known issues — version 0.9.35

Updated 2026-09-16 for version 0.9.35 (the standard FA26's deployment request, on 0.9.3's in-dial
battery glyph; replay-stream layouts as in 0.9.2).
See [COMPATIBILITY.md](COMPATIBILITY.md) for validation scope.

## Battery ring around automatic upshifts: sampled, no flicker

**Observed, not proved.** The automatic gearbox cuts the physics throttle for one or two frames on
each upshift (next section), and the open question was whether `rearMotorPowerKW` dips below the
−5 kW deadband during that cut and turns the ring red for those frames. A session driven with the
automatic gearbox on 2026-09-16 showed no such flicker: the throttle arc collapses on each upshift
while the ring holds its state. This is an observation of the drawn result, not a measurement that
the reported power stayed inside the deadband.

## The standard FA26's green ring: what is normal

The ring follows the deployment request of the car's own delivery map, so several idle states are
the car behaving correctly rather than a missing reading:

- `NODEPLOY` requests nothing at any speed, so the ring is never green while that map is selected;
  it still turns red whenever the car reports recovery;
- the maps request nothing below a low speed threshold, so slow corner exits and standing starts
  deploy nothing at full throttle, and nothing at the very top of the speed range either;
- the request is proportional to the throttle, so it follows the same gearbox assists as the
  throttle arc: the automatic upshift cut darkens it briefly and the downshift auto-blip can light
  it for 75–90 ms inside a braking zone. Like the arc, this is drawn as reported;
- the maps do not rank by how much they request: one can ask for a smaller share than another at
  the same throttle and speed and trade it for a wider speed range, so the ring is legitimately
  dimmer in one map than in another. The brightness is the request, not a ranking;
- a replay stores the request in steps of 1/14, while the live ring lights from 0.02 up. A request
  between those two figures therefore reads as a faint green ring live and as an idle ring in the
  replay of the same lap. Both draw exactly what they hold; nothing is held or smoothed;
- the request is a command. Whether the car keeps requesting energy it cannot deliver — an empty
  battery, the pit limiter engaged — is the car's behaviour, and the ring reports the request
  either way. The charge percentage inside the glyph is the reading to trust for what is left.

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
Pro recording), the standard FA26's deployment request against its four maps and the speed
thresholds above, exact FA25 supplemental replay recording, mixed-camera behaviour, no-DRS
rendering and actual fonts at any scale.

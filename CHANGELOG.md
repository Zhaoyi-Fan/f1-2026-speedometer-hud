# Changelog

Development and in-game testing used the VRC Formula Alpha 2026 Pro with CSP build 4116.

## At a glance

| Version | In one line |
| --- | --- |
| 0.9.39 | **Changed:** the glyph's percentage sits beside the terminal and the bolt at the other end; the standard FA26 loses its always-dark `OT` badge, and its `SM` spans the row and turns yellow when available; **New:** DRS replay recording for every car with native DRS |
| 0.9.38 | **Changed:** the battery glyph faces right, like a common battery icon; a new setting turns it back to the left |
| 0.9.37 | **Fix:** the Pro's whole energy frame was missing from replays whenever Straight Mode was engaged |
| 0.9.36 | **New:** the glyph reads `BOOST` while the command is held; a single-digit charge stays visible beside it |
| 0.9.35 | **New:** the standard FA26 shows its own deployment — green ring, a `Deploying` chip, recorded into replays |
| 0.9.3 | **Changed:** a battery glyph inside the dial replaces the two side bars |
| 0.9.25 | **Changed:** documentation and packaging only |
| 0.9.2 | **New:** a display per vehicle, and replay recording for the standard FA26 and the FA25 |
| 0.9.1 | **Changed:** 0–360 km/h scale, curved arc labels, heavier dial lettering |
| 0.9.0 | First public pre-release |
| 0.8 | **New:** the `BOOST` badge under `SM` / `OT` |
| 0.7 | **Changed:** raw values moved behind a log-mode setting |
| 0.6 | **New:** English and 简体中文 |
| 0.5 | **New:** side bars for charge and lap harvest |
| 0.4 | **Changed:** the battery reads usable energy |
| 0.3 | **New:** negative MGU-K caps drawn as super-clipping |
| 0.2 | **Changed:** 1-based PU names, opaque arc tracks, a persistent diagnostics file |
| 0.1 | First build |

## 0.9.39 — 2026-09-16

Puts the battery glyph's percentage next to its terminal, shows the standard FA26 only the systems it
has, and records DRS for every car that has one. The Pro stream and both stream layouts are those of
0.9.38.

- The glyph's percentage now sits beside the terminal and the bolt at the other end, on both sides:
  bolt, then percentage, with the terminal on the right (the default); percentage, then bolt, with it
  on the left. A single-digit charge under Boost reads bolt, `BOOST`, number on the right-facing glyph
  and number, `BOOST`, bolt on the left-facing one. The two sides are still mirror images.
- The bolt now stands on the light fill for most of the charge range, so it is drawn like the digits:
  a one-unit black outline replaces its small down-right shadow, and an opaque core in the body colour
  under it keeps its translucent flow colour looking the same over the fill as over the empty body.
  Its colours and states are unchanged.
- The standard FA26 has no Overtake Mode. It is VRC's version for Assetto Corsa without CSP, so none of
  the Pro's scripted systems exist on it, and the game itself ignores the track's overtake zone. The
  `OT` badge, which could never light on this car, is gone, and `SM` now spans the badge row.
- That car's Straight Mode is the game's own DRS. It reports "available" only once the car is inside a
  zone and has no pre-latch, so the badge now shows that state in yellow, the Pro's "available,
  already in the zone" colour, instead of white, the Pro's "press to pre-latch" prompt. Off stays dark
  and open stays green.
- Every car that reports a native DRS component now records its DRS state (component, availability,
  open wing) into replays, under a new car-family code in the existing native-state stream. Until now
  only the exact FA25 CSP was recorded, so other cars showed DRS dark in every replay. AC's replay data
  does keep the open wing, but CSP does not give it back to apps during playback, so the app records it
  itself. Cars without DRS take no slot, and the Pro keeps its own stream.
- Compatibility: the stream layout is unchanged. Versions up to 0.9.38 do not know the new family code
  and leave those slots unread, so a 0.9.39 recording shows those cars' DRS as unavailable there. The
  standard FA26 and FA25 slots restore exactly as before in both directions. Replays recorded before
  0.9.39 hold no DRS history for other cars.
- The README now opens with a short description of the app. Its demo GIF, recorded with this version,
  and its illustration show the new glyph layout; the illustration also shows the standard FA26's
  badge row.

## 0.9.38 — 2026-09-16

Turns the battery glyph round to face the way most battery icons do, and makes the side a setting.
The adapters and both replay streams are those of 0.9.37.

- The glyph now faces right by default: the terminal closes the slot on the right, the fill is
  anchored to the left wall and drains towards it (deploying moves its edge to the left, harvesting to
  the right), the bolt sits beside the terminal and the percentage is left-aligned at the other end. A
  single-digit charge under Boost reads number, `BOOST`, bolt.
- New setting "Battery terminal: Left / Right", directly under "Battery glyph in the dial". Left
  restores the glyph of 0.9.3 to 0.9.37 exactly, including a fill edge that moves the same way as the
  panel's MGU-K bar. Hovering the setting explains the difference. A stored value the app does not
  recognise draws the default right-facing glyph.
- The two sides are mirror images about the dial's vertical axis, and only positions change: colours,
  states, brightness, the word `BOOST`, the low-charge rule and the data behind them are identical, the
  text is never reversed, and the bolt keeps its shape and its shadow. The slot and the throttle and
  brake track caps beside it are symmetric about that axis, so both sides keep the same clearances.
- The energy panel is not affected. With the default right-facing glyph, the fill edge moves the
  opposite way to the panel's MGU-K bar, which keeps deployment on its right.

## 0.9.37 — 2026-09-16

Fixes a recording defect that has been in the app since 0.9.2: whenever Straight Mode was engaged, the
FA26 Pro's whole energy frame was dropped from the replay, so a saved lap showed `--` for battery,
MGU-K, lap energy and strategy for as long as the wings were open.

- The Straight Mode latch reports 4 while the mode is engaged, one step beyond the 0-3 the reader
  accepted, and the latch is one of the fields the original stream requires before it will write a
  frame. The reader now accepts 0-7, and the flag word carries the extra step in its free bit 13, so
  the frame records normally and the engaged state is stored as itself for the first time.
  - Recordings made before 0.9.2 are unaffected: that writer clamped the value to 3 and always wrote
    the frame, which is why replays from that era play back complete.
  - Recordings made by 0.9.2 to 0.9.36 cannot be repaired; the frames were never written.
  - A reader older than 0.9.37 sees an engaged latch as 0, so its Straight Mode badge falls back to
    the wing and mode flags, which are recorded separately and already turn it green.
- The periodic diagnostics line now reports skipped Pro frames and the field that caused the last one
  (`proSkip=<count>:<field>@<car>`). The old stream has no per-field validity, so one missing field
  still costs a whole frame; from now on it says so instead of failing silently.

## 0.9.36 — 2026-09-16

Brings the word `BOOST` back, inside the glyph. Everything else, including the adapters and both
replay streams, is exactly as in 0.9.35.

- While the Boost command is held, the battery glyph writes `BOOST` across its body in place of the
  charge percentage, as the badge it replaced did. The magenta body, the ring, the terminal and the
  bolt are unchanged, and the fill still shows the level, so the charge remains readable as a length
  while the word is up.
- One exception: once the displayed charge is down to a single digit, the number comes back beside
  the word, in its amber low-charge colour, because that is the reading that matters while the car
  asks for maximum deployment. The word then sits between the bolt and the number.
- An unknown charge under Boost reads `BOOST` rather than `--`.
- Releasing the command restores the percentage in the same update; nothing is held or faded.

## 0.9.35 — 2026-09-16

Adds the standard FA26's own deployment to the 0.9.3 battery glyph. The FA26 Pro display, the Pro
adapter and both replay-stream layouts are exactly those of 0.9.3.

- The standard FA26 now shows when it is deploying. The glyph's ring turns green while the car's
  delivery controller requests energy, with the brightness taken from that request (`kersInput`, the
  share of full deployment the selected map asks for at the current throttle and speed), magenta
  instead while the Boost button is held, and red at 0.9.3's fixed brightness while the car reports
  recovery. Where 0.9.3 drew the ring red or idle only, it can now also be green.
  - The request is a command, not a measured power. The green and the red are separate declared
    scales: they cannot be compared with each other, nor with the Pro's `|kW| / 350`.
  - A request of zero, the `NODEPLOY` map, very low speed and the top of the speed range leave the
    ring without green; recovery still turns it red. That is the car behaving normally, not a
    missing reading.
  - The request follows the physics throttle, so it shows the same gearbox assists as the throttle
    arc: the automatic-upshift cut interrupts it and the downshift auto-blip can raise it inside a
    braking zone. Drawn as reported, like the arc ([known issues](docs/KNOWN-ISSUES.md)).
- The compact standard-FA26 panel now has two chips, `Deploying` and `Recovering`, in the glyph's
  green and red, where 0.9.3 had a single recovery chip. An unavailable state still reads `--`.
- Replays record the request in four free bits of the byte that already carried the strategy index,
  so the native stream keeps the 22 slots, 132 bytes, divisor and validity bits of 0.9.2's schema 1.
  Recordings made before 0.9.35 restore exactly as they did. In the other direction, versions before
  0.9.35 accept that byte only as a plain strategy index, so the strategy of a standard FA26 reads as
  unavailable there; every other field of the same slot still restores.
- `OT` remains dark on the standard FA26, which has no overtake channel; only the Pro reports one.
- The periodic diagnostics line for the standard FA26 gains the request, the drawn glyph state and a
  probe of the car's own native KERS properties.
- A lap with the automatic gearbox answered an open question from 0.9.3: the Pro's power-driven ring
  does not flicker at the upshift throttle cut, although the throttle arc still shows the cut itself.

## 0.9.3 — 2026-09-15

- Replaced the two side bars (usable battery on the left, lap harvest on the right) with a battery
  glyph inside the dial, in the slot of the former `BOOST` badge. The dial is 340 units wide for
  every car, so the energy panel sits closer to it (up to 98 units for the Pro with the bars on, 62
  for the standard FA26, unchanged if the bars were off); drag the window once if needed.
  - Terminal on the left and the charge fill anchored to the right wall: deploying moves the fill
    edge to the right and harvesting to the left, like the panel's MGU-K bar. The percentage sits
    inside the body.
  - The ring and terminal show the MGU-K flow of the current update: red while harvesting
    (including super-clipping at full throttle), green while deploying, magenta while Boost is
    deploying. The bolt takes the same hue, but is white on a magenta body so it stays visible.
    Brightness, ring width and a small halo follow `|kW| / 350`, optionally eased with a 120 ms
    time constant (on by default); the state and hue are never eased.
  - The body turns magenta whenever the Boost button is active, exactly as the badge did, so Boost
    held into a braking zone reads as a magenta body with a red ring.
  - The fill is neutral; when the displayed figure is 10 % or less the fill and digits turn amber.
    Red is never a charge level.
  - Native FA26: red ring at a fixed brightness while recovering, magenta body from the button,
    never green. Conventional cars draw no glyph.
- New settings: "Battery glyph in the dial" (off restores the `BOOST` badge) and "Ease the battery
  ring brightness (120 ms, decorative)". The side-bars setting is gone. The panel's battery bar and
  the native panel's recovery chip now use the glyph's colours.
- Lap harvest against its limit is shown only in the energy panel.
- The periodic Pro diagnostics line gains `bat=<state>/<intensity>`.

## 0.9.25 — 2026-09-14

Documentation and packaging update; the app behaves exactly as 0.9.2 apart from the version number.

- README: the standard FA26's Straight Mode and recovery indicators are described as shipped
  features (both were validated in game before 0.9.2).
- Removed the development-probe option from the source deployment script and its mentions in the
  docs; the script manages only the three app files. Rollback manifests written by the 0.9.2
  script with a probe entry need that script version.
- Rewrote the compatibility notes as a support matrix of in-game and pending checks, and recorded
  two new results: 0.9.2 played an old Pro replay in game with no gaps, and the Pro live adapter
  was checked offline against the car's real channel map. A live Pro session on this adapter is
  still pending.

## 0.9.2 — 2026-09-13

- Kept the v0.9.1 dial and made the display follow the exact car being watched:
  - **FA26 Pro** keeps the SM / OT / BOOST badges and the energy panel.
  - The **standard VRC Formula Alpha 2026** gets a compact panel with battery %, deployment mode
    (LOW / MEDIUM / HIGH / NODEPLOY) and recovery state, plus manual BOOST and Straight Mode.
    OT is unsupported and stays dark.
  - **Conventional cars** show one centred DRS indicator, always dark on cars without DRS.
  - The H / I Straight Mode wing mapping now applies to Pro only.
- Missing data now shows as missing instead of a false zero. Camera changes and seeks no longer
  carry over another car's state.
- New replays record the standard FA26's battery, deployment, BOOST, recovery and DRS state, and
  the FA25 CSP's DRS state, in a separate 132-byte stream. The FA26 Pro replay stream is
  unchanged, so existing Pro replays still play back.
- The periodic diagnostics now report short gaps in replayed data (`replayGaps`).
- The source deployment script now backs up, installs and verifies only the app's own files, and
  can roll back an installation. Adapter/replay and UI tests were added.
- The throttle arc shows AC's physics throttle: with the automatic gearbox it dips briefly on
  upshifts, and downshift auto-blips raise it. Manual upshifts stay steady. See
  [known issues](docs/KNOWN-ISSUES.md) and [compatibility notes](docs/COMPATIBILITY.md).

## 0.9.1 — 2026-09-12

- Changed the outer arc to 0–360 km/h, with 14-unit speed labels every 60 km/h and 180 at the top.
  Above 360 km/h the arc stays full while the central readout continues to show the actual speed.
- Added 14-unit curved `THROTTLE` and `BRAKE` labels, visible over both inactive tracks and active fills.
- Set `KMH` and `RPM` labels to 16 units and `GEAR` to 14 units.
- Gave the arc lettering, speed labels, `KMH`, `RPM` and `GEAR` a slightly heavier medium font weight.
- Centred `GEAR` and the current gear together using their measured text widths.

## 0.9.0 — 2026-09-10 (first public pre-release)

- Narrowed the SM, OT and BOOST indicators to 96 design units to prevent overlap with the ends
  of the throttle and brake arcs at any scale.

## 0.8 — 2026-09-10

- Added a `BOOST` indicator below `SM` / `OT`, shown in magenta while Boost is active. The energy
  panel uses the same colour. Moved the dial's numbers up slightly to make room.

## 0.7 — 2026-09-10

- Moved the raw diagnostic values behind the "Show technical readout (log mode)" setting,
  which is off by default.

## 0.6 — 2026-09-10

- Added English and 简体中文, with changes applied immediately and the choice saved between sessions.
  Abbreviations remain the same in both languages.
- Added a separate font setting for Chinese labels, defaulting to Microsoft YaHei UI. Numbers
  continue to use the dial font.

## 0.5 — 2026-09-10

- Added side bars for usable battery charge (left) and energy harvested this lap against the limit
  (right). Both remain visible when the energy panel is hidden.

## 0.4 — 2026-09-10

- Changed the battery readout to show usable energy (`92%  3.68 / 4 MJ`).

## 0.3 — 2026-09-10

- Added a marker on the harvesting side for negative MGU-K caps, labelled `clip -350 kW`
  during super-clipping.

## 0.2 — 2026-09-10

- Corrected PU mode names to use the car's 1-based indexing.
- Made arc backgrounds opaque to remove dark patches at their rounded ends.
- Kept the power cap label visible at zero (`cap 0 kW`).
- Added a diagnostics file in `Documents\Assetto Corsa\logs` that retains entries between sessions.

## 0.1 — 2026-09-08

- Initial version with a MultiViewer-style dial, SM / OT indicators, energy panel, camera-car
  tracking, energy recording for up to 22 cars, key bindings and diagnostics.

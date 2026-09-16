# Changelog

Development and in-game testing used the VRC Formula Alpha 2026 Pro with CSP build 4116.

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

# Changelog

Development and in-game testing used the VRC Formula Alpha 2026 Pro with CSP build 4116.

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

# Changelog

All versions were built and verified in-game on the VRC Formula Alpha 2026 (Pro) with CSP build 4116.

## 0.9.0 — 2026-09-10 (first public pre-release)

- Badge cluster on the dial narrowed to 96 design units (SM, OT, BOOST) so it clears the throttle and
  brake track caps at every scale.

## 0.8 — 2026-09-10

- `BOOST` pill under the `SM` / `OT` badges on the dial, magenta while the Boost button is active;
  the panel's Boost chip uses the same colour. Digit stack moved up slightly to make room.

## 0.7 — 2026-09-10

- Technical readout in the settings window hidden behind "Show technical readout (log mode)",
  off by default.

## 0.6 — 2026-09-10

- Language toggle: English / 简体中文, instant, persisted. Broadcast abbreviations stay in English.
- Chinese label font setting (default Microsoft YaHei UI); digits keep the dial font.

## 0.5 — 2026-09-10

- Two vertical bars beside the dial: usable battery (left) and lap regen against the limit (right),
  visible even with the energy panel hidden.

## 0.4 — 2026-09-10

- Battery readout shows usable energy (`92%  3.68 / 4 MJ`) instead of the raw energy-store value.

## 0.3 — 2026-09-10

- MGU-K cap tick drawn for negative caps on the harvest side, labelled `clip -350 kW`
  (super-clipping).

## 0.2 — 2026-09-10

- PU mode names 1-based, matching the car's own dash table.
- Opaque arc tracks (the translucent ones showed dark blobs at the round caps).
- Cap label always shown, including `cap 0 kW`.
- Persistent diagnostics file in `Documents\Assetto Corsa\logs`, accumulating across launches.

## 0.1 — 2026-09-08

- First build: MultiViewer-style dial, SM / OT badges, energy panel, camera-focused car, own replay
  stream for every car, settings window with bindable buttons and diagnostics.

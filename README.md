# VPlayer (Flutter)

Flutter rewrite of [VPlayer](../VPlayer) (originally Expo/React Native). A
local-first media player for **iPad and Android tablets** (phones supported
too) that does two things:

- hosts a local HTTP server so you can upload videos from a browser on the
  same Wi-Fi
- plays those videos on the device with resume, subtitles, gestures, and a
  lockable player UI

No cloud, no accounts. Everything lives in the app's sandbox.

## Features

- Browser upload page (drag & drop, folders, multi-file, parallel uploads)
  with a full library manager: folders, rename, move, delete, search, sort
- Chunked upload protocol (1 MiB chunks, sequential, per-chunk retry —
  in-progress uploads don't survive a server restart)
- Library with generated thumbnails, watch-progress pie badges, `[new]`
  badges, swipe-to-delete, multi-select
- Player: media_kit (libmpv) — mp4/mov/m4v/webm/mkv
  - resume from saved position (near-end rule: restart last 10 s)
  - `.srt` subtitles auto-matched by filename
  - gestures: single tap = controls, 1-finger double tap = play/pause,
    2-finger double tap = lock/unlock
  - scrub preview thumbnails, playback rate 0.5–2.0, ±10 s seek
  - auto-advance to next video in folder
- Tablets (iPad + Android ≥600dp) run landscape-first; phones portrait with
  landscape player

## Run

```bash
flutter pub get
flutter test                      # 59 unit/integration tests
flutter run -d <device>
```

iOS simulator quickstart:

```bash
open -a Simulator
flutter run -d "iPad Test"        # or any iPad/iPhone simulator
```

Android: `flutter run` on any emulator/device. To reach the upload server on
an emulator from your host browser: `adb forward tcp:8081 tcp:8081`.

## Using the upload server

1. Open the **Upload** tab; the server starts automatically on port `8081`.
2. Open the shown URL (e.g. `http://192.168.x.x:8081`) in a browser on the
   same network.
3. Drag files/folders onto the page. Finished uploads appear in **Library**.

## Docs

- [AGENTS.md](AGENTS.md) — architecture, protocol spec, invariants, gotchas
  (start here if you're working on the code)
- Original product spec: `../VPlayer/docs/swiftui-rebuild-spec.md`

# AGENTS.md — VPlayer Flutter

Working notes for anyone (human or agent) picking up this codebase. Read this
before making changes.

## What this is

A Flutter rewrite of the Expo/React Native app at `../VPlayer`. The rewrite
targets **iPad + Android tablets** (phones still work). Feature parity was the
goal; the browser upload protocol is preserved byte-for-byte so the original
HTML upload page could be ported nearly verbatim.

- Language/stack: Dart/Flutter 3.44 (Dart 3.12), Cupertino (iOS-style) widgets
- State: **Riverpod** (`flutter_riverpod`)
- Player: **media_kit** (libmpv) — robust mkv/webm + frame screenshots
- HTTP server: **shelf** + **shelf_multipart** via `dart:io` (no native module)
- Persistence: plain JSON files in the app documents directory

## Layout

```
lib/
  main.dart              bootstrap: MediaKit init, documents dir, ProviderScope
  app.dart               CupertinoApp, tabs (Library/Upload/Settings), bootstrap,
                         orientation + tablet detection, wakelock, lifecycle
  theme.dart             VColors palette (cream #efe7db / teal #1f6f68) + theme
  models/
    library_item.dart    LibraryItem (folder|video|subtitle|file)
    upload_activity.dart UploadActivity, ActiveUploadRow, UploadStatus
  services/              (pure Dart, no Flutter deps except thumbnail/media_kit)
    video_library.dart   filesystem: list/sanitize/sort/create/rename/move/delete
    playback_state_store.dart   playback-state.json, serialized write queue
    clamped_int_setting_store.dart  generic clamped-int JSON store (cache + queue)
    upload_settings_store.dart  upload-settings.json (maxParallelUploads 1-5)
    subtitle_settings_store.dart subtitle-settings.json (subtitleFontSize 24-48)
    subtitle_service.dart       SRT parse + active-cue lookup
    thumbnail_service.dart      headless media_kit player -> jpg cache
    upload_server.dart          shelf server + all endpoints + chunk sessions
    upload_page.dart            embedded browser HTML (ported from original)
    format.dart                 bytes/date/duration/port formatting
  providers/
    app_providers.dart   all Riverpod providers + controllers (see below)
  screens/
    library_screen.dart  list, empty state, selection mode, clear-playback
    upload_screen.dart   server status, port field, activity
    settings_screen.dart concurrency picker, subtitle-size picker
    player_screen.dart   fullscreen player: controls, gestures, scrub, subtitles
  widgets/
    video_card.dart      row: thumbnail, badges, swipe-to-delete
    setting_picker_screen.dart  shared iOS-style int-options drill-down picker
test/                    59 tests: library, subtitles, playback store,
                         subtitle settings, server, tablet layout
```

## Riverpod providers (`lib/providers/app_providers.dart`)

- `documentsPathProvider` — **overridden in `main.dart`** with the real docs
  path. Everything downstream depends on it.
- Service singletons: `videoLibraryProvider`, `playbackStateStoreProvider`,
  `uploadSettingsStoreProvider`, `subtitleSettingsStoreProvider`,
  `thumbnailServiceProvider`, `uploadServerProvider`.
- `libraryProvider` (`LibraryController` / `LibraryState`) — current folder
  items + playback map + loading + revision counter. `.refresh([path])` walks
  up if a folder vanished.
- `selectionProvider` — multi-select mode + selected paths; auto-exits at zero.
- `serverProvider` (`ServerController` / `ServerState`) — running state,
  active port, LAN IP, current `UploadActivity`. Owns server start/adopt/stop,
  network refresh, and 2 s IP polling while IP unknown.
- `thumbnailProvider` (`ThumbnailController`) — path→jpg map; worker pool
  (concurrency 3, 3 attempts) hydrating on demand.
- `uploadSettingsProvider` — maxParallelUploads (1–5, default 3).
- `subtitleFontSizeProvider` — subtitle font size (24–48 pt, default 36).
- `selectedVideoPathProvider` — which video the player screen opens.

## Storage layout (app documents dir)

```
videos/                media, subtitles, and user folders (the library root)
uploads-tmp/           in-progress upload temp files (wiped on server start)
thumbnails/            <djb2hash>.jpg cached library thumbnails
playback-state.json    { "<abs video path>": {positionSeconds, durationSeconds?,
                          hasStartedPlayback?, updatedAt} }
upload-settings.json   { "maxParallelUploads": 1..5 }
subtitle-settings.json { "subtitleFontSize": 24..48 }
```

- Allowed video ext: `.mp4 .mov .m4v .webm .mkv`; subtitles: `.srt`; anything
  else is a `file` (listed, not playable).
- Playback state is keyed by **absolute path**, so rename/move/delete
  intentionally drops progress + thumbnail (server cleans these up when the
  path changes).
- Thumbnail cache key = DJB2-xor hash of `path|size|modified|10|240|240`, so
  re-uploads/renames invalidate naturally.

## Upload HTTP protocol (do NOT change without updating `upload_page.dart`)

Server binds `0.0.0.0:8081`. The ported browser page in `upload_page.dart`
speaks exactly this; keep them in lockstep.

| Method | Path | Notes |
|---|---|---|
| GET | `/` | HTML upload page |
| GET | `/health` | `{ok, port, activeUploads}` — used for adopt probe |
| POST | `/upload/init` | `{fileName, relativePath?, totalSize, mimeType?}` → `{uploadId, fileName, relativePath, chunkSize}`. `fileName` may be omitted when `relativePath` is given. |
| POST | `/upload/chunk` | multipart `file` field + headers `x-upload-id/x-chunk-index/x-total-chunks/x-total-size` → `{ok, receivedBytes, totalBytes}`. Non-multipart bodies fall back to the raw request body. |
| POST | `/upload/complete` | `{uploadId}` → moves temp→final, refreshes library |
| POST | `/upload/cancel` | `{uploadId}` — idempotent; emits a `cancelled` activity status |
| GET | `/library/list?path=` | `{path, items[]}` |
| POST | `/library/folder` | `{parentPath?, name}` |
| POST | `/library/delete` | `{relativePath, entryType, currentPath?}` |
| POST | `/library/rename` | `{relativePath, entryType, currentPath?, name}` |
| POST | `/library/move` | `{currentPath?, destinationPath?, items[]}` |

Chunk rules: 1 MiB (`chunkSize`), **strictly sequential per file**, cumulative
bytes ≤ declared size, temp file per session in `uploads-tmp/`, moved to final
on complete (overwrites existing file of same name). The server enforces these
too: each chunk must be ≤ `chunkSize`, and `x-total-chunks` is pinned to the
session on the first chunk (a later chunk that changes it is rejected). Sessions
live in memory only — `uploads-tmp/` is wiped on server start, so an in-progress
upload does not survive a restart (retryable per chunk, not resumable).

### Two hard-won server gotchas (both fixed, keep them)

1. **Always fully drain the multipart `parts` stream.** `break`-ing after the
   first part leaves the request body undrained, and `dart:io` then closes the
   socket without a response → browser shows "Failed to fetch" for any body
   >~768 KB (i.e. every real 1 MiB chunk). Code keeps the `file` part's bytes
   but iterates to the end. See `_handleChunk` + regression test
   "handles full-size 1 MiB chunks".
2. **Chunk handling is idempotent.** Browsers transparently retry a POST when a
   keep-alive connection drops after processing. A chunk with
   `index < expectedChunkIndex` is re-acknowledged instead of erroring with
   "Unexpected chunk order". See regression test in `upload_server_test.dart`.

## Player parity details (`lib/screens/player_screen.dart`)

Matched from the original RN implementation:

- Landscape lock on entry; restore tablet-landscape / phone-portrait on exit.
- Resume at saved position; if <10 s remain, resume at `duration - 10`.
- Persist throttle: only when |Δ| ≥ 2 s, except forced (close/next/scrub/
  end/background).
- Controls auto-hide after 2500 ms while playing & not scrubbing.
- Gestures via raw `Listener` (pointer counting) because Flutter's
  `GestureDetector` can't do 2-finger double-tap: single tap toggles controls,
  1-finger double tap play/pause, 2-finger double tap lock/unlock. 250 ms
  double-tap window.
- Scrub preview: single-flight, latest-wins queue, 0.05 s dedupe, via
  `player.screenshot()` after seek.
- Playback-rate control (0.5×–2.0×, ±0.1 steps) exposed in the controls.
- Lifecycle: on any non-resumed `AppLifecycleState` (inactive/paused/hidden) →
  pause + save + unlock + show controls; on resume stay paused. `inactive`
  counts (e.g. a Control Center pull pauses playback), not just full
  background.
- Auto-advance to next video in the current folder on completion.

## Tablet / orientation logic

- `isTabletDimensions(Size)` — pure rule: `shortestSide >= 600` (dp).
- `isTabletLayout` (getter) — reads the **physical display** via
  `platformDispatcher.displays`, not `MediaQuery`, so it's stable regardless
  of current orientation lock / window size and is safe from a disposing
  context.
- iPad requires `UIRequiresFullScreen=true` in `ios/Runner/Info.plist` or iOS
  ignores the Flutter orientation preference.

## Platform config

- Android `AndroidManifest.xml`: INTERNET / ACCESS_NETWORK_STATE /
  ACCESS_WIFI_STATE / WAKE_LOCK perms + `usesCleartextTraffic="true"` (plain
  HTTP server). Bundle id `com.f2pgod.vplayer`.
- iOS `Info.plist`: `NSLocalNetworkUsageDescription`,
  `NSAllowsLocalNetworking`, `UIRequiresFullScreen`, iPhone+iPad orientations,
  `TARGETED_DEVICE_FAMILY=1,2`.
- iOS server only runs while foregrounded (iOS suspends sockets in
  background) — matches the spec's "no background daemon".

## Testing / verifying

```bash
dart analyze          # must be clean
flutter test          # 59 tests
```

`test/upload_server_test.dart` spins up the real shelf server on an ephemeral
port and drives the full chunk protocol over HTTP — the best smoke test for
server changes.

Manual end-to-end against a running app/simulator (server on 8081):

```bash
curl -s http://127.0.0.1:8081/health
# then upload via the browser page, or script /upload/init + /upload/chunk
```

## Known follow-ups / non-goals

- App icons/splash are still Flutter defaults; the original `assets/` icons
  weren't ported.
- No native import (Files/Share/AirDrop) — browser upload is the path, per the
  original spec.
- No macOS desktop target configured (would need `media_kit_libs_macos_video`
  + entitlements).
- Debug APK is large (~190 MB) because of bundled libmpv; release builds are
  much smaller after split-per-abi / tree-shaking.

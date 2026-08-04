# Dynamic Island for macOS

A right-anchored, always-on-top island overlay for the Mac — Spotify now-playing,
a drag-and-drop staging vault, and a folder tree that mirrors a real directory on
disk. Drag things in, drag them back out into any app.

Native Swift (AppKit + SwiftUI), built with SwiftPM. **No Xcode required** — the
Command Line Tools are enough.

```bash
./build.sh && open build/DynamicIsland.app
```

---

## What it does

**Now playing.** Track, artist, artwork, scrubber, and transport for Spotify. It
rides Spotify's own `PlaybackStateChanged` broadcast rather than polling, so the
steady-state cost is zero IPC.

**A staging vault.** Drop text, images, or files onto the pill and they're held in
a temporary vault. Quick-copy one back to the clipboard, file it into a folder, or
**drag it straight back out** into a message, a mail draft, or a Finder window.

**A mirrored folder.** Folders created in the island are real directories on disk,
watched with FSEvents. A folder made in Finder shows up in the island through the
identical path — there's no second copy of the state to drift.

**Live status.** Click to expand and the island grows a header with the clock,
battery, Wi-Fi signal, and indicators for camera, microphone, and calls.

**Movable.** Drag the pill anywhere on screen. It remembers where you put it, and
picks its growth direction so it always opens *into* the screen.

## Requirements

- macOS 14 or later
- Swift 6 toolchain (Xcode Command Line Tools is enough — `xcode-select --install`)
- Spotify, for the now-playing panel

## Interaction

| Action | Result |
|---|---|
| Move the pointer over it | Nothing — the island never reacts to hover |
| **Click the island** | Expands to the full card with the status header |
| Click the header, or anywhere outside | Collapses |
| Drag the pill (or the header) | Moves the island; position is remembered |
| Waveform / tray tabs | Switch between the media and vault faces |
| Drag anything onto the island | Stages it in the vault |
| Drag onto a folder row | Writes straight through to that directory |
| **Drag a staged item off the island** | Copies it into whatever app you drop on |
| Hover a staged item | Quick-copy, file into the destination, or discard |
| Right-click a folder | Reveal in Finder, set as destination, move to Trash |

Deletion goes to Trash, never `unlink` — mirrored folders are real user data.

## Configuration

The mirrored directory defaults to `~/Documents/IslandVault`. Change it from the
status-bar menu (*Choose Mirror Folder…*), the folder-gear icon in the vault
header, or `~/Library/Application Support/DynamicIsland/config.json`. Switching
tears down the FSEvents stream and rebinds to the new root live.

Staged blobs live in `~/Library/Application Support/DynamicIsland/Vault/`. Dropped
files are **copied**, never moved, so dragging out of Finder is non-destructive.

## Permissions

Only one prompt matters: **Automation → Spotify**, for artwork and transport
control. Everything else — the recording indicator, the network and battery
readouts, click-outside-to-collapse — uses APIs that need no grant at all. Details
and graceful-degradation behaviour in [docs/PERMISSIONS.md](docs/PERMISSIONS.md).

## Development

```bash
DI_DEBUG=1 DI_OPEN=1 ./build/DynamicIsland.app/Contents/MacOS/DynamicIsland
```

`DI_DEBUG=1` traces to stdout; `DI_OPEN=1` pins the island open at launch, so
working on the expanded states isn't a matter of holding the pointer still with
one hand. From the bundled app, stream the log instead:

```bash
log stream --predicate 'subsystem == "com.qwerty.dynamicisland"'
```

## Docs

- [Architecture](docs/ARCHITECTURE.md) — module map, state machine, animation
  physics, rendering strategy, and the reasoning behind the awkward parts
- [Performance](docs/PERFORMANCE.md) — where the frame drops came from, what fixed
  them, and how the numbers were measured
- [Permissions](docs/PERMISSIONS.md) — what's asked for, when, and what breaks
  without it

## Licence

MIT — see [LICENSE](LICENSE).

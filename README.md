# Dynamic Island for macOS

An island that lives in your MacBook's notch. Nearly invisible until you click it,
then it opens into Spotify now-playing, a drag-and-drop staging vault, a folder
tree mirroring a real directory, and a voice assistant on ⌃⌥Space.

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

**Voice, on ⌃⌥Space.** Say *"setup design review at 6pm to 7:30pm"* and it lands
on your calendar. Say *"open vault IPM"* and the Obsidian vault opens. Speech is
transcribed **on-device** — nothing spoken leaves the Mac.

**Notch-resident.** Idle, it's a sliver below the cutout you'd never notice. The
notch itself can't be drawn into — there are no pixels behind the camera housing —
so the island renders just below and around it in the same black, and reads as the
notch growing.

## Requirements

- macOS 14 or later. A notched Mac is ideal; without one the island hangs from
  the top edge instead
- Swift 6 toolchain (Xcode Command Line Tools is enough — `xcode-select --install`)
- Spotify, for the now-playing panel
- Obsidian, for "open vault …"
- A calendar account in **System Settings → Internet Accounts** for dictated
  events to reach Google. Without one they save to a local calendar, and the
  island says so rather than implying they synced

## Interaction

| Action | Result |
|---|---|
| Move the pointer over it | Nothing — the island never reacts to hover |
| **Click the island** | Expands to the full card with the status header |
| Click the header, or anywhere outside | Collapses |
| **⌃⌥Space** | Voice assistant: dictate a calendar event or open a vault |
| Waveform / tray tabs | Switch between the media and vault faces |
| Drag anything onto the island | Stages it in the vault |
| Drag onto a folder row | Writes straight through to that directory |
| **Drag a staged item off the island** | Copies it into whatever app you drop on |
| Hover a staged item | Quick-copy, file into the destination, or discard |
| Right-click a folder | Reveal in Finder, set as destination, move to Trash |

Deletion goes to Trash, never `unlink` — mirrored folders are real user data.

## Voice commands

Press **⌃⌥Space**, speak, then stop — it submits on ~1.4s of silence, or press the
chord again to submit immediately.

### Calendar

```
Setup event titled <name> at 4pm to 5pm on 8th August 2026
Setup task titled <name> at 4pm to 5pm
Setup <name> at 6pm to 7:30pm
Schedule <name> tomorrow at 9am
Remind me to <name> at 4pm
```

`event`, `task`, `titled`, `called` and `named` are all optional filler — they're
stripped from the title. Anything left over becomes the event name.

The time phrase is parsed by `NSDataDetector`, so most natural forms work:
`at 4pm to 5pm`, `tomorrow at 9am`, `next Tuesday at 2pm`, `on 8th August 2026`.
Give a start with no end and you get one hour.

A bare time that has already passed rolls to tomorrow — "at 4pm" said at 6pm means
tomorrow. Name an actual date and it is taken literally, even if it is in the past.

### Obsidian

```
Open vault IPM
Open the Me vault
Launch obsidian vault prototype 1
```

Matched against your real vault list, tolerant of dictation: "I P M" finds `IPM`,
"prototype one" finds `prototype 1`. If nothing scores well enough it says so
rather than opening the wrong vault.

### Quick create

```
Create a google doc          →  docs.new
Create a google document
Make a spreadsheet           →  sheets.new
Create a presentation        →  slides.new
Create a google meet         →  meet.new
Start a meeting
```

These hit Google's instant-create URLs, so they need no API key or OAuth — just a
browser already signed in. They only trigger when the phrase contains **no time**:
"setup doc review at 4pm" is an event that happens to say "doc", not a request for
a document.

## Configuration

The mirrored directory defaults to `~/Documents/IslandVault`. Change it from the
status-bar menu (*Choose Mirror Folder…*), the folder-gear icon in the vault
header, or `~/Library/Application Support/DynamicIsland/config.json`. Switching
tears down the FSEvents stream and rebinds to the new root live.

Staged blobs live in `~/Library/Application Support/DynamicIsland/Vault/`. Dropped
files are **copied**, never moved, so dragging out of Finder is non-destructive.

### Where dictated events go

Run the built-in check — it reports every calendar it can see and which one it
would write to:

```bash
open -n build/DynamicIsland.app --env DI_CALENDAR_CHECK=1
# report is printed and also written to /tmp/di-calendar-check.txt
```

Launch it with `open`, not by exec'ing the binary: running it from a shell makes
the *terminal* the TCC responsible process, so macOS evaluates the terminal's
calendar permission and answers "denied" without ever prompting.

Selection order is config override → Calendar.app's own default (if it syncs) →
the account's primary calendar → any synced calendar → local. To force a specific
one, set `calendarTitle` in `~/Library/Application Support/DynamicIsland/config.json`:

```json
{ "calendarTitle": "you@gmail.com" }
```

Worth setting explicitly if you have both iCloud and Google connected — Calendar.app's
default may well be the iCloud one.

## Permissions

Four, and each is asked for only when the feature is first used:

| Permission | For | If denied |
|---|---|---|
| Automation → Spotify | Artwork, play/pause/skip | Metadata still arrives; transport goes dead |
| Microphone | Voice capture | Voice assistant unavailable |
| Speech Recognition | On-device transcription | Voice assistant unavailable |
| Calendars | Dictated events | Events can't be created |

Notably **not** needed: Accessibility or Input Monitoring. The ⌃⌥Space hotkey uses
Carbon's `RegisterEventHotKey`, which needs no grant — a bare ⌃⌥ chord would have,
which is why a key is part of the shortcut. The recording indicator, battery and
network readouts, and click-outside-to-collapse are all grant-free too.

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

- [Architecture](docs/ARCHITECTURE.md) — module map, notch layout, state machine,
  animation physics, and the voice pipeline
- [Performance](docs/PERFORMANCE.md) — where the frame drops came from, what fixed
  them, and how the numbers were measured
- [Permissions](docs/PERMISSIONS.md) — what's asked for, when, and what breaks
  without it

## Licence

MIT — see [LICENSE](LICENSE).

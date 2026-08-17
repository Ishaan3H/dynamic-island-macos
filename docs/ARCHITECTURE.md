# Architecture

How the island is put together, and why the non-obvious parts are the way
they are. Performance work lives in [PERFORMANCE.md](PERFORMANCE.md);
permissions in [PERMISSIONS.md](PERMISSIONS.md).

---

### Stack choice

The brief left the stack open with a note to prioritise low resource usage and
transparent always-on-top positioning. That settles it in favour of native Swift:

| | Native (AppKit/SwiftUI) | Electron / Tauri |
|---|---|---|
| Idle RSS | ~35–50 MB | ~120 MB+ (Electron) |
| Transparent click-through overlay above the menu bar | `NSPanel` + 4 properties | Needs platform plumbing; click-through is a known rough edge |
| Camera/mic state, FSEvents, Apple Events | Direct framework calls | Native bridge per feature |
| Animation | Core Animation, GPU-composited | DOM/compositor, more overhead per frame |

Everything the island does is a system-integration task, so a web layer would be
pure overhead sitting between the UI and the APIs it exists to call.

### Module map

```
Sources/DynamicIsland/
├── main.swift                   NSApplication bootstrap (.accessory policy)
├── AppDelegate.swift            Status-bar menu, dynamicisland:// URL handler
├── Core/
│   ├── IslandModel.swift        State machine — the only place mode is decided
│   ├── IslandAnimation.swift    Spring physics, per-transition curves
│   ├── Geometry.swift           Per-mode sizes, radii, screen anchoring
│   ├── Config.swift             Persisted settings (mirror root)
│   └── Log.swift                os_log + optional stdout echo
├── Window/
│   ├── IslandPanel.swift        NSPanel + hit-test-passthrough hosting view
│   └── IslandWindowController.swift   Placement, screen-change handling
├── Services/
│   ├── SpotifyService.swift     Distributed notifications + AppleScript
│   ├── FolderMirror.swift       FSEvents watcher + folder operations
│   ├── VaultStore.swift         Staged item storage
│   ├── SystemStatusService.swift    Clock, battery, network
│   ├── ThumbnailCache.swift     Off-thread downsampled image decode
│   ├── DeviceActivityMonitor.swift  Camera/mic live state
│   └── CallMonitor.swift        Call events
└── UI/
    ├── IslandRootView.swift     Shell, mode switch, collapsed pill
    ├── StatusHeaderView.swift   Clock / battery / Wi-Fi / activity strip
    ├── NowPlayingView.swift     Media card, transport, drop zone, alert
    ├── VaultView.swift          Staged items + mirrored folder tree
    └── Theme.swift              Colours and shared components
```

### Dimensions

| State | Size | Trigger |
|---|---|---|
| `collapsed` | 260 × 44 | idle |
| `expanded` · media face | 384 × **185** | **click** — status header + song |
| `expanded` · vault face | 384 × **424** | tray tab |
| `dropTarget` | 384 × 200 | a drag held over the *collapsed* island |
| `alert` | 384 × 96 | incoming/active call |

The collapsed pill is 260 × 44 (up from 196 × 34). At 44 pt the corner radius is
22, so the horizontal padding is set to 16 pt to clear the corner arc — content
sits on a consistent optical margin instead of crowding the rounded ends.

**The expanded island is sized per face.** A media card has no business reserving
room for a folder tree it isn't showing, so the two faces get different heights —
185 pt for the song, 424 pt for the vault, rather than one 486 pt box with dead
space under whichever is smaller.

Those numbers are *computed*, not typed in: `IslandGeometry` declares the layout
constants (`headerHeight`, `tabRowHeight`, `mediaArtwork`, `stagedListHeight`, …),
the views lay out from them, and the heights are summed from the same values. Edit
a constant and the window follows. The alternative — hand-tuned sizes next to
hand-written layout — drifts the first time anyone changes a padding.

One consequence worth knowing: every section in the vault face has a pinned
height, including a single fixed slot shared by the destination crumb and the
new-folder text field. Without that, starting to name a folder would grow the
island mid-interaction.

### Data flow

Services publish; `IslandModel.resolveMode()` is the single decision point:

```
alert  >  dropTarget  >  expanded (click)  >  collapsed
```

**Pointer position is not an input.** There is no hover state anywhere in the
app — moving the cursor near, over, or across the island never changes what it
shows. It opens because you clicked it, or because something genuinely demands
the space: a call, or a drag being held over it. `IslandFace` selects *what* the
opened island displays; `IslandMode` only decides how large it is and why.

Keeping that priority ladder in one function is deliberate — the alternative
(each view deciding when to show itself) is how these overlays end up flickering
between states.

### Interaction model

| Gesture | Result |
|---|---|
| Move the pointer over it | **Nothing.** The island does not react to hover at all |
| **Click anywhere non-interactive** | Expand to the full card with status header |
| Click a button (play, tab, folder) | That button acts; the island does not toggle |
| Click the status header | Collapse |
| Click anywhere outside the island | Collapse |
| **Drag the pill (or the header)** | Move the island anywhere on screen |
| **Drag an item out of the vault** | Drops into any app — Messages, Mail, Finder |

Buttons consume their own hits before the shell's tap gesture sees them, so
pressing play never also toggles the expansion. Click-outside works through a
`NSEvent.addGlobalMonitorForEvents` monitor — global monitors only receive events
destined for *other* applications, which is exactly the semantics wanted, and
mouse-event monitors need no Accessibility grant (key events would).

Two things are load-bearing for click-to-open, and both fail silently:

- **`acceptsFirstMouse` must return `true`.** AppKit swallows the first click into
  a non-key window to bring it forward, delivering nothing to the view. This panel
  never activates the app, so *every* click is a first click — the default of
  `false` means the island can never be opened at all.
- **The hit rect must be computed for a flipped view.** See below.

Verified end to end with synthetic events (`CGEventSource` → `.cghidEventTap`):
a pointer sweep across the pill produces zero mode changes; click → expand;
header click → collapse; outside click → collapse.

### Placement

The island is draggable anywhere on screen. Grab the pill when it's closed, or
the status header when it's open — the header doubles as a title bar, so rows
below it keep their own drag-*out* gesture. `minimumDistance: 4` is what keeps the
move gesture from swallowing clicks: under the threshold SwiftUI resolves a tap
and the island opens; past it, the island moves. Position persists in
`config.json`; **Reset Position** in the status-bar menu returns it to the
top-right.

**The growth corner follows the position.** A fixed top-right anchor stops working
the moment the island can live elsewhere — near the left edge it must grow
*right*, or the expanded card runs off screen. `IslandAnchor` picks the nearest
corner, so the island always opens into the screen. Because the pill's own frame
is the invariant, re-anchoring moves nothing visible; only the invisible canvas
shifts around it. The flip is still deferred while the island is open, since there
it *would* jump the card across the pill.

Two things about the drag are worth not re-deriving:

- **The offset comes from `NSEvent.mouseLocation`, not the gesture's
  `translation`.** SwiftUI measures translation relative to the view, and moving
  the island moves that view — each frame's window move cancels part of the next
  frame's reported translation. Measured: the island travelled `(-450, -290)` for
  a cursor delta of `(-900, -636)`, almost exactly half speed. Screen coordinates
  are immune. (`translation` is still used once, to recover the true gesture
  origin — the first callback arrives only after `minimumDistance`, and at that
  instant nothing has moved yet.)
- **Only the pill is clamped mid-drag; the canvas is clamped on release.**
  Clamping the whole canvas during the gesture would stop the island well short of
  the bottom-left corner, because the anchor still points the old way until the
  drag ends.

### Animation physics

`Core/IslandAnimation.swift`. Every curve is a damped harmonic oscillator
(`mẍ + cẋ + kx = 0`), parameterised as SwiftUI's `response` / `dampingFraction`:

```
response = 2π / ω₀     ω₀ = √(k/m)     ζ = c / (2√(km))
peak overshoot = exp(-πζ / √(1-ζ²))
```

| Transition | response | ζ | Overshoot |
|---|---|---|---|
| Expand | 0.42 | 0.68 | ~5.4% — one soft bounce |
| Collapse | 0.30 | 0.90 | ~0.2% — visually none |
| Morph (media ⇄ vault) | 0.36 | 0.80 | ~1.5% |
| Alert | 0.34 | 0.62 | ~8% — snaps in hard |
| Content crossfade | easeOut 0.20 s | — | — |

The asymmetry is the point. iOS's Dynamic Island opens with a visible overshoot —
it reads as the panel having mass — and closes almost without one, because a
wobble on the way out looks like a bug rather than physicality. Content is eased
rather than sprung and is *shorter* than the shape change, so the frame settles
first and the text lands into it instead of overshooting its own container.

`IslandSpring.transition(from:to:)` picks the curve; `recomputeMode()` is the only
caller. Views deliberately carry no `.animation(_:value:)` modifier for the mode —
that would animate the same property twice.

### Rendering strategy

**The panel never resizes.** It is permanently the size of the largest state
(384×486); the pill animates *inside* it, anchored top-trailing.

Resizing an `NSWindow` on every transition is the obvious approach and it is
wrong twice over: the AppKit frame animation fights SwiftUI's own layout
animation (visible jitter), and resizing mid-drag moves the drop target out from
under the cursor, cancelling the drag session.

The cost is that a fixed 384×486 window would blanket the corner of the screen in
dead clicks. `IslandHostingView` pays it back by overriding `hitTest(_:)` to
return `nil` outside the currently drawn pill, so everything else is genuinely
click-through. There is no `NSTrackingArea` — with hover gone there is nothing to
track, and without one the app receives no mouse-moved traffic at all while idle.

⚠️ **`NSHostingView` is a flipped view** (origin top-left), unlike a plain
`NSView`. `currentPillRect()` originally computed the pill's y as
`bounds.maxY - height`, which is correct for unflipped AppKit and puts the hit
region at the *bottom* of the 486 pt canvas — hundreds of points below the pill.
The symptom was not "clicks don't work" but something much more confusing: an
invisible strip below the island caught hovers and clicks, while the pill itself
was inert. If you change this rect, test it; the geometry looks right on paper
either way.

The hit region **grows on the leading edge and shrinks only after the spring
settles** (`IslandWindowController.apply(mode:)`). Shrinking immediately would drop
the pointer outside the tracking area while the pill was still visually large
underneath it, which reads as the island collapsing out from under the cursor.

Three more things keep frames cheap:

- **The shadow is cast by a bare `RoundedRectangle` behind the content**, not by
  the content itself. Shadowing a composited subtree forces SwiftUI to rasterise
  it every frame to derive the blur's alpha mask; shadowing a plain filled shape
  lets Core Animation use a `shadowPath` and stay on the GPU.
- **`AppKit`'s own window shadow is off** (`hasShadow = false`) for the same
  reason — it is derived from the window's alpha channel and recomputed whenever
  that changes, i.e. on every frame of an animating pill.
- **Layer-backed with `.onSetNeedsDisplay`** and `needsDisplayOnBoundsChange =
  false`, so a bounds change does not invalidate the canvas.

### Feature notes

**Now Playing.** `MRMediaRemoteGetNowPlayingInfo` is the usual route to
system-wide media state, and it is gated behind a private entitlement as of macOS
15.4 — it returns nothing to third-party apps. Spotify's own integration is
better anyway: it broadcasts `com.spotify.client.PlaybackStateChanged` with the
full track payload, so steady-state polling is **zero**. AppleScript runs only on
track change (artwork URL) and on transport commands. `NowPlayingSource` is a
protocol, so a MediaRemote backend can drop in behind it if the app is ever
signed with that entitlement.

**Dragging out.** The island works in both directions: drop a screenshot on it,
open a message, click the island, drag the item from the vault into the compose
field. Staged items and mirrored files/folders both vend an
`NSItemProvider(contentsOf:)`, which registers the file's real UTType and vends
its bytes — that is what makes the drop land as an *attachment* in Mail or
Messages and a real copied file in Finder, rather than a path string.

Two details make this work rather than almost-work:

- **Blobs are stored as `Vault/<uuid>/<real name>`,** not `<uuid>-<real name>`.
  The uniquifier has to live somewhere, and in the filename it becomes the name
  the file carries when it lands in someone's inbox. A containing directory keeps
  names both unique and clean. (`url(for:)` resolves either shape, so older flat
  indexes still load.)
- **An open island does not morph into the drop zone.** `resolveMode()` only
  returns `.dropTarget` when collapsed. Once open, the vault is already showing
  with per-folder targets that are more useful than a catch-all — and swapping the
  content out mid-drag would yank away the very row the drag started from. The
  shell's border turns accent-coloured instead.

**File mirroring.** One-way authoritative: the directory on disk is the single
source of truth and the island renders a live projection. Creating a folder in the
UI performs a real `createDirectory`; FSEvents reports it back and refreshes the
tree. A folder made in Finder appears in the island through the identical path, so
there is no second copy of the state to drift. One kernel-backed FSEvents stream
covers the whole subtree; events are coalesced with a 120 ms debounce and the
projection is depth-capped at 3.

**Recording indicator.** Reads `kCMIODevicePropertyDeviceIsRunningSomewhere`
(CoreMediaIO) and `kAudioDevicePropertyDeviceIsRunningSomewhere` (CoreAudio) —
whether *any* process has the device open. No stream is ever opened, so no Camera
or Microphone grant is needed, and both are push-based via listener blocks.

**Calls — read this before trusting it.** macOS has no public API for "a call is
ringing". FaceTime posts no observable notification, CallKit is iOS-only, and the
incoming-call banner lives in Notification Center's private SQLite store
(`~/Library/Group Containers/group.com.apple.usernoted/db2/db`), which needs Full
Disk Access, is undocumented, and reshapes between releases. So `CallMonitor` uses
two honest signals instead:

1. **External push (reliable)** — `dynamicisland://call?name=Ada&app=FaceTime&phase=incoming`,
   fireable from Shortcuts, Hammerspoon, or a companion iOS shortcut. Use this if
   you want real incoming-call banners. `phase=ended` clears it.
2. **Conferencing heuristic (best-effort)** — a known call app running *and* the
   mic live implies an active call. Reliable for in-call state, needs no extra
   permissions.

Screen recording is deliberately not detected: macOS exposes no public query for
"is another process capturing the display", and the private paths are fragile and
entitlement-gated. The system's own indicator remains the source of truth.

---

---

## Living in the notch

**You cannot draw inside the notch.** There are no pixels behind the camera
housing. Notch-resident apps render a black shape immediately *below and around*
the cutout; because it is the same black, the eye reads it as the notch itself
growing. That is the whole trick.

`NotchMetrics.of(_:)` derives the geometry rather than hardcoding it —
`safeAreaInsets.top` gives the height and the gap between `auxiliaryTopLeftArea`
and `auxiliaryTopRightArea` gives the width. On this machine: **179 × 32 pt,
centred at x = 735**. On a Mac without a notch both auxiliary areas are `nil`, and
it falls back to the menu bar height so the same layout maths still works.

Consequences that shape the code:

- Every expanded state reserves `notch.height` of clearance at the top
  (`NotchClearance`), because that band is invisible. Content starts below it.
- `NotchShape` is square along the top and rounded only along the bottom. A
  uniformly rounded rectangle would round nothing visible while opening a hairline
  gap where the shape meets the bezel.
- The idle state is a **13 pt lip** below the cutout — the only part ever seen.
  Live indicators appear as small dots on it, so the island can signal activity
  without growing.
- Position is fixed: centred on `screen.frame.midX`, flush with the top. The
  drag-to-reposition and anchor-flipping machinery an earlier right-anchored
  version needed is gone.

## Voice pipeline

⌃⌥Space → capture → parse → act → report. Four collaborators, orchestrated by
`VoiceAssistant`, which is kept out of `IslandModel` because it owns a multi-step
async lifecycle of its own. The island only observes *which phase* to render.

**`HotkeyService`** — Carbon `RegisterEventHotKey`. Chosen over an `NSEvent` global
monitor specifically because it requires no Accessibility grant.

**`SpeechService`** — `AVAudioEngine` tap feeding
`SFSpeechAudioBufferRecognitionRequest`, forced on-device. Capture ends on 1.4 s of
silence so there is no "stop" gesture to learn, with a 15 s hard ceiling so a stuck
stream cannot hold the microphone open.

**`VoiceIntentParser`** — `NSDataDetector` for dates rather than hand-rolled regex.
It already understands the target phrasing, verified:

```
"Setup xyz at 6pm to 7:30pm"
  -> title "xyz", 18:00 -> 19:30   (duration 5400s came from the detector)
"remind me to call mom at 4pm"
  -> title "call mom", tomorrow 16:00   (4pm today had passed, so it rolled forward)
```

The title is whatever survives after the matched time phrase and the leading
command verb are stripped, which is why the filler-word sets matter more than they
look. A start time with no end gets a one-hour default.

**`ObsidianService`** — reads Obsidian's own `obsidian.json` registry, so matching
happens against *real* vault names instead of trusting the transcript. This is what
makes dictation survivable; normalising away case, spacing and punctuation then
scoring by prefix/substring/edit-distance gives:

```
"I P M"          -> IPM           (dictation split the letters)
"prototype one"  -> prototype 1   (spoken number)
"xyz"            -> no match      (refuses rather than guessing wrong)
```

The 0.55 score floor is deliberate: opening the wrong vault is worse than saying
you didn't understand.

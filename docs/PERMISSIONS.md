# System permissions

What the app asks for, when, and how it behaves when told no.

---

## 2. System permissions

| Permission | Needed for | When it prompts | Degrades to |
|---|---|---|---|
| **Automation → Spotify** (`NSAppleEventsUsageDescription`) | Album artwork URL, play/pause/skip, initial state read | First AppleScript send | Track metadata still arrives via distributed notification; artwork and transport go dead. The card shows an "Allow Automation" button that deep-links to the right pane. |
| **Files and Folders** (or Full Disk Access) | Reading/creating inside the mirror root when it lives in Documents/Desktop/Downloads | First access to a protected location | Mirror shows empty; folder creation fails. Pick a path outside protected areas to avoid it entirely. |
| **Camera / Microphone** | *Not required.* Keys are declared for completeness only | Should not prompt | — |
| **Location** | *Not requested.* Only the Wi-Fi **network name** needs it — signal strength does not | Never | Header shows signal bars without an SSID. Verified: `rssiValue()` returns real data (−60 dBm) unauthorised; `ssid()` returns `nil`. |
| **Accessibility / Screen Recording** | *Not required.* Global **mouse** monitors (used for click-outside-to-collapse) are exempt; only key-event monitors need Accessibility | — | — |

Notes:

- The app is **not sandboxed**, so the user-chosen mirror root works without
  security-scoped bookmarks. Sandboxing it later means adding
  `com.apple.security.files.user-selected.read-write` and persisting a bookmark
  across launches.
- `build.sh` ad-hoc signs the bundle. This matters: TCC keys grants to the code
  signature, so an unsigned build would forget its Automation grant on every
  rebuild.
- If Automation was denied once, macOS will not re-prompt. Reset with:
  ```bash
  tccutil reset AppleEvents com.qwerty.dynamicisland
  ```

---

---

## Voice assistant

Three more grants, each requested only the first time the feature runs.

| Permission | Needed for | If denied |
|---|---|---|
| **Microphone** | Capturing what you say | Voice unavailable; the panel offers a button to the right settings pane |
| **Speech Recognition** | Turning it into text | Same |
| **Calendars** (full access on macOS 14+) | Writing dictated events | Event creation fails with the reason shown |

### What is *not* required

**No Accessibility / Input Monitoring.** The ⌃⌥Space hotkey goes through Carbon's
`RegisterEventHotKey`, which needs no grant at all — verified returning `noErr`.
This is the reason the shortcut includes a key rather than being the bare ⌃⌥ chord
originally wanted: detecting a modifier-only combination requires a global
keyboard monitor or an event tap, and both are gated behind Accessibility.

### Where dictated events actually go

`CalendarService.preferredCalendar()` prefers a writable calendar on a **synced**
source (CalDAV or Exchange — Google appears as CalDAV) over a local one, because
an event that silently lands in an on-device calendar never reaches the user's
phone. When only a local calendar exists, `isLocalOnly` is true and the
confirmation says *"local calendar only"* rather than implying it synced.

This means there is a genuine prerequisite: **the Google account must be connected
in System Settings → Internet Accounts.** The alternative — talking to the Google
Calendar API directly — would mean an OAuth client, a consent screen, a client
secret stored on disk, and refresh-token handling, all to reach a calendar the
system already holds a live connection to.

### Privacy note on speech

`requiresOnDeviceRecognition` is set explicitly whenever the recognizer reports
`supportsOnDeviceRecognition` (true on this Mac). Left to default, `SFSpeechRecognizer`
may send audio to Apple's servers — not an acceptable default for a command that
might name a private vault or a meeting.

---

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

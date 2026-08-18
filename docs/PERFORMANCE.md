# Performance

Where the frame drops actually came from, what fixed them, and how the
numbers were measured — including two measurement mistakes that produced
confidently wrong results before the harness was fixed.

---

### Observation graph — where the lag actually was

The first version bridged every service's `objectWillChange` into `IslandModel`
so views could reach services through `model.spotify.…`. That one convenience was
the whole performance problem: a single filesystem event, or the 1 Hz scrubber
tick, invalidated the entire view tree — and the staged-item rows called
`NSImage(contentsOf:)` inside `body`, so each invalidation meant twenty
synchronous disk reads and full-size decodes on the main thread.

Three changes, in order of impact:

1. **No fan-out.** Each service is injected into the environment separately and
   observed only by the views that read it. A scrubber tick now redraws a progress
   bar. `IslandRootView` reads only `model.mode`, so service updates never touch
   the shell.
2. **`ThumbnailCache`** decodes off-thread via
   `CGImageSourceCreateThumbnailAtIndex`, straight to the drawn size — a 28 pt
   thumbnail no longer decodes a 1024² bitmap — and caches the result. `body` only
   ever does a cache lookup.
3. **Split sections.** `StagedSection` and `MirrorSection` observe different
   services, so an FSEvent redraws the folder list without touching the staged
   rows. An unused `@EnvironmentObject` is a live subscription, not a free
   reference — declaring one you don't read costs you redraws.

All file I/O moved off the main thread too: `VaultStore` and `FolderMirror`
copy, write, and delete on their own queues and hand back completions. Dropping a
multi-gigabyte file is an array insert as far as the UI is concerned.

Timers are gated on visibility (`isVisible`): collapsed, the island schedules **no
wakeups at all**. The clock is aligned to the next minute boundary rather than
ticking at 1 Hz, since the header shows H:MM and 59 of 60 wakeups would redraw
nothing. Battery is push-based (`IOPSNotificationCreateRunLoopSource`), as is
network reachability (`NWPathMonitor`). Wi-Fi RSSI is the single genuine poll —
CoreWLAN has no signal-change callback — at 0.2 Hz, and only while the header is
on screen.

#### Measured

`tools/bench.py`: island expanded with 20 staged images, a directory under
sustained churn (20 filesystem mutations/second), CPU-time delta over a fixed
12-second window, 7 runs, median.

| Build | Median CPU | Range | RSS |
|---|---|---|---|
| Before | 15.15% | 10.82 – 18.39 | 54 MB |
| Before, with only the new file listener | 7.08% | 6.66 – 7.16 | 59 MB |
| After (all changes) | **4.08%** | 3.91 – 4.75 | 55 MB |

Roughly **3.7× less CPU**, split about 2.1× from the file-listener rate limit and
1.7× from the rendering and observation work.

Two caveats worth stating plainly. This is an adversarial workload — no real user
writes 20 files a second — so treat it as a stress ratio, not a typical figure.
And CPU time is not frame timing: it is strong evidence the main thread has room,
but the "locked at 60 FPS" claim in the brief is not something these numbers
prove. Verifying that needs Instruments' Core Animation FPS gauge on a real
display, which is worth doing before shipping.

Measurement notes, because two earlier attempts produced numbers that were simply
wrong: `ps -o %cpu` reports an average over the process's *entire lifetime*, not
current utilisation, so sampling it repeatedly just converges on startup cost;
and a `pkill -f` pattern that matched only one of the two build paths silently
leaked instances between runs, inflating everything after the first. The harness
now takes CPU-time deltas and asserts exactly one live instance per run.

#### One bug this benchmark caught

Raising the FSEvents debounce from 120 ms to 250 ms looked like a clean win —
CPU fell to 0.25%. It was not a win: the file listener had stopped working. The
stream's own latency spaces event batches ~150 ms apart during sustained writes,
so every batch cancelled the pending work item before it could fire, and the tree
never refreshed until all activity stopped. The low CPU was the symptom.

A shorter debounce fails the other way — at 120 ms it fires in the gaps between
batches and coalesces nothing, giving every batch its own full tree walk (45
events produced 46 rescans).

`FolderMirror` now uses a **leading-edge throttle** instead: the first event in a
quiet period scans immediately, and anything arriving inside the window folds into
one scan pinned to the *next allowed slot* rather than pushed further out. That
bounds both the scan rate and the staleness at `minScanInterval` (350 ms).
Verified at 44 events → 21 rescans over 6.5 s of churn (~3.2/s, as designed), with
the final projection matching disk exactly.

If you tune that constant, re-check the rescan count, not just the CPU number.

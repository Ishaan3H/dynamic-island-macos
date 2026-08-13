#!/usr/bin/env python3
"""
Measures DynamicIsland CPU correctly.

`ps -o %cpu` is an average over the process's whole lifetime, so sampling it
repeatedly yields correlated values that drift toward the startup cost. This
takes the delta of cumulative CPU *time* across a fixed wall-clock window
instead, which is the true average utilisation for that window.

Churn runs in this same process (no per-iteration subprocess spawn) so the
measurement isn't dominated by the harness.

Usage: tools/bench.py <path-to-binary> <label> [runs]
"""
import os, re, shutil, subprocess, sys, threading, time, uuid, json, pathlib

APP = sys.argv[1]
LABEL = sys.argv[2]
RUNS = int(sys.argv[3]) if len(sys.argv) > 3 else 5

HOME = pathlib.Path.home()
VAULT = HOME / "Documents" / "IslandVault"
SUPPORT = HOME / "Library" / "Application Support" / "DynamicIsland"
WARMUP = 2.5
WINDOW = 12.0

SRC_PNG = None
for root in ["/System/Library/Frameworks", "/System/Library/CoreServices"]:
    for dirpath, _, files in os.walk(root):
        for f in files:
            if f.endswith(".png"):
                p = os.path.join(dirpath, f)
                if os.path.getsize(p) > 20_000:
                    SRC_PNG = p
                    break
        if SRC_PNG: break
    if SRC_PNG: break


def cputime(pid):
    """Cumulative CPU seconds for pid."""
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    parts = out.split(":")
    try:
        if len(parts) == 3:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
        return int(parts[0]) * 60 + float(parts[1])
    except ValueError:
        return None


def seed(n=20):
    blobs = SUPPORT / "Vault"
    blobs.mkdir(parents=True, exist_ok=True)
    index = []
    for i in range(n):
        uid = str(uuid.uuid4())
        shutil.copy(SRC_PNG, blobs / f"{uid}.png")
        index.append({"id": uid, "kind": "image", "title": f"Shot {i}",
                      "createdAt": time.time() - 978307200, "filename": f"{uid}.png"})
    (SUPPORT / "vault-index.json").write_text(json.dumps(index))


def churn(stop):
    """Continuous filesystem mutation -> continuous FSEvents."""
    i = 0
    while not stop.is_set():
        d = VAULT / f"dir{i % 8}"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"file{i}.txt").write_text(f"payload {i}")
        old = d / f"file{i - 3}.txt"
        if old.exists():
            old.unlink()
        i += 1
        time.sleep(0.05)


def one_run():
    # Match the executable name, not a path fragment: the two builds live at
    # different paths and a path-based pattern silently leaks instances.
    subprocess.run(["pkill", "-x", "DynamicIsland"], capture_output=True)
    time.sleep(0.5)
    shutil.rmtree(VAULT, ignore_errors=True)
    shutil.rmtree(SUPPORT, ignore_errors=True)
    VAULT.mkdir(parents=True, exist_ok=True)
    seed()

    env = dict(os.environ, DI_OPEN="1")
    proc = subprocess.Popen([APP], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(WARMUP)

    live = subprocess.run(["pgrep", "-x", "DynamicIsland"],
                          capture_output=True, text=True).stdout.split()
    if len(live) != 1 or str(proc.pid) not in live:
        print(f"    ! expected 1 instance, found {len(live)} - discarding", flush=True)
        proc.kill(); return None

    stop = threading.Event()
    t = threading.Thread(target=churn, args=(stop,), daemon=True)
    t.start()

    t0 = cputime(proc.pid)
    w0 = time.monotonic()
    time.sleep(WINDOW)
    t1 = cputime(proc.pid)
    w1 = time.monotonic()

    rss = subprocess.run(["ps", "-o", "rss=", "-p", str(proc.pid)],
                         capture_output=True, text=True).stdout.strip()
    stop.set(); t.join(timeout=2)
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()

    if t0 is None or t1 is None or t1 < t0:
        return None
    return (t1 - t0) / (w1 - w0) * 100.0, int(rss or 0) / 1024.0


results, mems = [], []
for r in range(RUNS):
    out = one_run()
    if out:
        results.append(out[0]); mems.append(out[1])
        print(f"  run {r+1}: {out[0]:5.2f}% CPU, {out[1]:.0f} MB", flush=True)

shutil.rmtree(VAULT, ignore_errors=True)
shutil.rmtree(SUPPORT, ignore_errors=True)

if results:
    s = sorted(results)
    med = s[len(s)//2]
    print(f"[{LABEL}] median {med:.2f}% CPU  "
          f"(min {min(s):.2f} / max {max(s):.2f})  "
          f"RSS median {sorted(mems)[len(mems)//2]:.0f} MB  n={len(s)}")

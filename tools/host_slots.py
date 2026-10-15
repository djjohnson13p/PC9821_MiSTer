#!/usr/bin/env python3
"""A lane's Quartus ceiling on a shared host: ONE place every launcher checks.

    tools/host_slots.py acquire DIR N LABEL [--pid PID]   # blocks; prints the slot file
    tools/host_slots.py release SLOTFILE [--token T]   # T: the slot's token, read at acquire
    tools/host_slots.py status DIR [--mine SUBSTR]

DIR holds at most N slot files (slot00 .. slot<N-1>); a launcher takes one BEFORE it starts
anything (copying a tree, a container) and gives it back when its job has exited, so a job
that has not reached its container yet still counts - counting containers alone races, because
a fit spends a minute copying and configuring before its container exists. Taking a slot is an
O_EXCL create under an flock, and a slot whose recorded pid is dead is reclaimed. A slot records
its job's directory (--path); a running lane container (--mine: its mount source contains the
substring) whose mount is under no held slot's path - a job started before the slots existed, or
by a launcher that bypassed them - counts AS WELL: the lane's total is held slots + uncovered
containers, so nothing that runs is ever left out of the ceiling.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        with open(f"/proc/{pid}/stat") as h:
            return h.read().split(") ", 1)[1][0] != "Z"
    except OSError:
        return True


def lane_container_mounts(mine: str) -> list[str] | None:
    """The mount sources of the lane's running containers (None: cannot tell)."""
    if not mine:
        return []
    runtime = os.environ.get("CONTAINER_RUNTIME", "podman")
    try:
        ids = subprocess.run([runtime, "ps", "-q"], capture_output=True, text=True,
                             timeout=60).stdout.split()
        if not ids:
            return []
        out = subprocess.run([runtime, "inspect", "--format",
                              "{{range .Mounts}}{{.Source}} {{end}}", *ids],
                             capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    return [line for line in out.splitlines() if mine in line]


def lane_total(d: Path, mine: str) -> tuple[int, int, int]:
    """(total, held slots, running lane containers no held slot covers)."""
    live = held(d)
    paths = []
    for p in live:
        try:
            if json.loads(p.read_text()).get("path"):
                paths.append(json.loads(p.read_text())["path"].rstrip("/") + "/")
        except (OSError, ValueError):
            pass
    mounts = lane_container_mounts(mine)
    if mounts is None:
        return 10 ** 6, len(live), 10 ** 6       # cannot tell: no room
    uncovered = sum(1 for m in mounts
                    if not any(src.startswith(pp) or src + "/" == pp
                               for src in m.split() for pp in paths))
    return len(live) + uncovered, len(live), uncovered


def held(d: Path) -> list[Path]:
    """The live slot files (stale ones - a dead pid - are removed)."""
    live = []
    for p in sorted(d.glob("slot[0-9]*")):
        try:
            rec = json.loads(p.read_text())
        except (OSError, ValueError):
            rec = {}
        if rec.get("pid") and not pid_alive(int(rec["pid"])):
            p.unlink(missing_ok=True)
            continue
        live.append(p)
    return live


def try_acquire(d: Path, n: int, label: str, pid: int, mine: str,
                path: str | Path | None = None) -> Path | None:
    d.mkdir(parents=True, exist_ok=True)
    with open(d / ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        total, _, _ = lane_total(d, mine)
        if total >= n:
            return None
        for i in range(10 ** 3):
            p = d / f"slot{i:02d}"
            if p.exists():
                continue
            # The token makes a release exact: a finished job's slot can be reclaimed (dead
            # pid) and its NAME reused by another job before the owner releases it, so a
            # release must only ever delete the record it wrote.
            p.write_text(json.dumps({"pid": pid, "label": label, "since": int(time.time()),
                                     "path": str(path) if path else "",
                                     "token": f"{os.getpid()}-{time.time_ns()}"}))
            return p
    return None


def acquire(d: Path, n: int, label: str, pid: int | None = None, mine: str = "",
            path: str | None = None, poll: int = 30) -> Path:
    pid = pid or os.getpid()
    while True:
        p = try_acquire(d, n, label, pid, mine, path)
        if p:
            return p
        time.sleep(poll)


def token_of(slot: Path) -> str | None:
    try:
        return json.loads(Path(slot).read_text()).get("token")
    except (OSError, ValueError):
        return None


def set_pid(slot: Path, pid: int) -> None:
    rec = json.loads(slot.read_text())
    rec["pid"] = pid
    slot.write_text(json.dumps(rec))


def release(slot: Path, token: str | None = None) -> None:
    """Delete the slot - only if it is still the record `token` names (when given)."""
    d = Path(slot).parent
    with open(d / ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if token is None or token_of(slot) == token:
            Path(slot).unlink(missing_ok=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("acquire")
    p.add_argument("dir", type=Path)
    p.add_argument("n", type=int)
    p.add_argument("label")
    p.add_argument("--pid", type=int, help="the process whose life holds the slot (default: "
                                          "the caller's parent shell)")
    p.add_argument("--mine", default="")
    p.add_argument("--path", help="the job's directory: a container mounting under it is this "
                                  "slot's, not an extra one")
    p = sub.add_parser("release")
    p.add_argument("slot", type=Path)
    p.add_argument("--token", help="delete only if the slot still carries this token")
    p = sub.add_parser("status")
    p.add_argument("dir", type=Path)
    p.add_argument("--mine", default="")
    a = ap.parse_args()
    if a.cmd == "acquire":
        print(acquire(a.dir, a.n, a.label, a.pid or os.getppid(), a.mine, a.path))
    elif a.cmd == "release":
        release(a.slot, a.token)
    else:
        live = held(a.dir)
        for p in live:
            print(p.name, p.read_text())
        total, h, unc = lane_total(a.dir, a.mine)
        print(f"lane total {total} = {h} slot(s) held + {unc} running container(s) no slot covers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

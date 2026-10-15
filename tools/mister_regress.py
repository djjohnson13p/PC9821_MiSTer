#!/usr/bin/env python3
"""mister_regress.py - the automated hardware regression run on a MiSTer.

WHY. The Policenauts intro stall was hard-disk corruption caused by CD-DA traffic on a shared
hps_io word bus. It was found through a game symptom after a day of tracing. This runner is the
repeatable form of that investigation: deploy a test RBF under test names, boot a COPY of the
user's disk, drive the guest by keyboard/mouse, watch the screen, read the integrity probe's
own output out of the disk copy, and delete everything it created.

THE SCRIPTED SET (--items, default all)
  probe        INTEG.COM (tools/hwprobe/integ): verify the HDD / floppy / CD files against manifests
               made on the host from the same images, plus the write/read-back, no CD-DA
  probe-cda    the same WHILE CD-DA plays (INTEG P ... INTEG S; needs --cd and MSCDEX in the guest)
  doom         DOOM's start       }  the four game items run a command list from the scenarios file
  th05         Touhou 5's start   }  (--scenarios; tools/mister/regress_scenarios.example.json is the
  rusty        Rusty's start      }  shape), take a screenshot every N seconds and check
  policenauts  the Policenauts intro, to the logo
  PASS CHECKS  probe items: every INTEG_*.TXT ends 'INTEG END FAILS=0000', INTEG_OK.TXT exists, and
               for probe-cda the PLAY row says 'PLAY OK' (a probe that could not play audio proved nothing
               about CD-DA).  Game items: the screen is not frozen (frame-diff between consecutive
               screenshots), and a known frame is reached (downscaled difference to a reference image).

NOTHING OF THE USER'S IS EVER COMMITTED. The images are arguments; reference frames live in --refs
(a directory of the user's choosing, outside any commit); the patched image copies live under
.build/mister-regress/ (git-ignored) and on the MiSTer only for the run.

THE MiSTer IS SHARED. Without --go this prints the plan and touches nothing. With --go it takes a lock
(/tmp/zreg.lock on the MiSTer; an existing lock aborts the run and says who holds it), uses only names
that contain 'zreg', and a `finally` removes every file it created and verifies the removal.

    # plan only
    tools/mister_regress.py --rbf out.rbf --hdd-image <your-disk>.img --cd GAME.pcd --cd-drive E:
    # run it
    tools/mister_regress.py --go --rbf out.rbf --hdd-image <your-disk>.img --fdd0 A.hdm --cd GAME.pcd \
        --cd-drive E: --scenarios my_scenarios.json --refs ~/regress-refs --items probe,probe-cda,policenauts
    # record the known frames from a good build instead of checking them
    tools/mister_regress.py --go ... --items policenauts --record-refs

    tools/mister_regress.py --selftest      # hardware-free: frame-diff, parsing, plan, image patching
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools/hwprobe/integ"))
import fatimg  # noqa: E402
import integ_manifest as im  # noqa: E402

TAG = "zreg"                                   # every remote name contains this
CORE = "PC9821Z486"
SETNAME = "PC9821"
GAMES = "/media/fat/games/PC9821"
REMOTE_TMP = f"/tmp/{TAG}"
LOCK = f"/tmp/{TAG}.lock"
REMOTE_RBF = f"/media/fat/_Computer/{CORE}-{TAG}.rbf"
REMOTE_MGL = f"/media/fat/{TAG.upper()}.mgl"
SHOTS = f"/media/fat/screenshots/{SETNAME}"

ITEMS = ("keymap", "probe", "probe-cda", "doom", "th05", "rusty", "policenauts")
GAME_ITEMS = ("keymap", "doom", "th05", "rusty", "policenauts")

STATIC_DIFF = 0.2          # mean abs diff (0-255) below which two screenshots are 'the same frame'
THUMB = (80, 50)


# ---------------------------------------------------------------------------------------------
# pure logic (the part --selftest exercises without a MiSTer)
# ---------------------------------------------------------------------------------------------
def thumb(path):
    from PIL import Image
    return Image.open(path).convert("L").resize(THUMB)


def mean_abs_diff(a, b) -> float:
    from PIL import ImageChops, ImageStat
    return ImageStat.Stat(ImageChops.difference(a, b)).mean[0]


def frame_diffs(paths):
    """Mean abs difference between consecutive screenshots (same measure as the pn-stall grid)."""
    ts = [thumb(p) for p in paths]
    return [mean_abs_diff(ts[i - 1], ts[i]) for i in range(1, len(ts))]


def longest_static_run(diffs) -> int:
    """Longest run of consecutive near-identical screenshot pairs, in INTERVALS."""
    best = cur = 0
    for d in diffs:
        cur = cur + 1 if d < STATIC_DIFF else 0
        best = max(best, cur)
    return best


def check_motion(paths, max_static_s: float, every_s: float, min_changes: int):
    diffs = frame_diffs(paths)
    run = longest_static_run(diffs) * every_s
    changes = sum(1 for d in diffs if d >= STATIC_DIFF)
    ok = run <= max_static_s and changes >= min_changes
    return ok, f"{len(paths)} shots, {changes} changes, longest static run {run:.0f}s (limit {max_static_s:.0f}s, need {min_changes} changes)"


def check_known_frame(paths, ref_path, max_diff: float, every_s: float, not_before_s: float = 0.0):
    ref = thumb(ref_path)
    best = (1e9, -1)
    for i, p in enumerate(paths):
        if i * every_s < not_before_s:
            continue
        d = mean_abs_diff(thumb(p), ref)
        best = min(best, (d, i))
    if best[1] < 0:
        return False, "no screenshot after the earliest allowed time"
    return best[0] <= max_diff, f"closest to {Path(ref_path).name}: shot {best[1]} (~{best[1] * every_s:.0f}s), diff {best[0]:.2f} (limit {max_diff})"


def parse_integ(text: str) -> dict:
    """One INTEG capture -> {'fails': int|None, 'bad': [rows], 'play': row|None, 'files': n}."""
    fails = None
    m = re.findall(r"INTEG END FAILS=([0-9A-F]{4})", text)
    if m:
        fails = int(m[-1], 16)
    return {
        "fails": fails,
        "bad": [l.strip() for l in text.splitlines() if l.startswith("BAD ") or l.startswith("WFAIL") or " OPENFAIL" in l
                or " READFAIL" in l or "MANIFEST" in l],
        "play": next((l.strip() for l in text.splitlines() if l.startswith("PLAY ")), None),
        "files": text.count("\nFILE ") + text.count("\nWFILE "),
    }


def judge_probe(captures: dict, expect: list, want_play: bool):
    """captures: {'INTEG_C.TXT': text|None}. expect: the capture names that must exist and pass."""
    problems = []
    if captures.get("INTEG_OK.TXT") is None:
        problems.append("INTEG_OK.TXT missing: the run did not finish")
    for name in expect:
        t = captures.get(name)
        if t is None:
            problems.append(f"{name} missing")
            continue
        r = parse_integ(t)
        if r["fails"] is None:
            problems.append(f"{name}: no 'INTEG END' row (the probe died)")
        elif r["fails"] != 0:
            problems.append(f"{name}: FAILS={r['fails']:04X}: " + " | ".join(r["bad"][:3]))
    if want_play:
        t = captures.get("INTEG_P.TXT")
        r = parse_integ(t) if t else None
        if not r or not r["play"] or not r["play"].startswith("PLAY OK"):
            problems.append("INTEG_P.TXT: CD-DA was not playing (" + (r["play"] if r and r["play"] else "no PLAY row") + ")")
    return (not problems), ("; ".join(problems) if problems else "all INTEG captures FAILS=0000")


def load_scenarios(path):
    sc = json.load(open(path))
    for k in GAME_ITEMS:
        if k in sc:
            s = sc[k]
            for step in s.get("steps", []):
                if step[0] not in ("type", "wait", "click", "key"):
                    raise SystemExit(f"scenario {k}: unknown step {step!r}")
    return sc


def set_default_profile(config_sys: bytes, n: int) -> bytes:
    """Rewrite SELSYS's `REM DEFAULTn` line (CRLF kept; every other byte untouched)."""
    new, k = re.subn(rb"(?m)^REM DEFAULT\d+(\r?)$", lambda m: b"REM DEFAULT%d%s" % (n, m.group(1)), config_sys, count=1)
    if k != 1:
        raise SystemExit("CONFIG.SYS has no 'REM DEFAULTn' line to rewrite")
    return new


def item_needs(item, sc):
    """None if the item is runnable, else the reason it is not (a SKIP, not a pass)."""
    if item in GAME_ITEMS:
        if item not in sc:
            return f"no '{item}' entry in the scenarios file"
        for step in sc[item].get("steps", []):
            if any(str(x).startswith("?") for x in step[1:]):
                return f"'{item}' still has a '?' placeholder command (the scenarios file must supply it)"
    return None


# ---------------------------------------------------------------------------------------------
# preparing the guest-visible files (host side, on COPIES)
# ---------------------------------------------------------------------------------------------
def manifest_for(img: Path, drive: str, kind: str, select: dict) -> str:
    with open(img, "rb") as f:
        if kind == "cd":
            fs = fatimg.Iso(f, select.get("layout", "iso"))
            read = lambda e: fs.read(e.start, min(e.size, select["max_bytes"]))
        else:
            fs = fatimg.Fat(f, fatimg.locate_volume(f, select.get("partition"), select.get("offset"), select.get("skip", 0)))
            read = lambda e: fs.read_file(e, select["max_bytes"])
        ents = [e for e in fs.walk() if e.size > 0 and e.path.isascii()]   # Shift-JIS names cannot be typed into a manifest
        if select.get("under"):
            u = select["under"].upper().strip("\\/") + "\\"
            ents = [e for e in ents if e.path.upper().startswith(u)]
        ents = sorted(ents, key=lambda e: -e.size)[: select["largest"]]
        if not ents:
            raise SystemExit(f"{img}: no files selected for {drive}")
        return im.manifest_text(((e.path, read(e)) for e in ents), drive)


def patch_hdd(src: Path, dst: Path, files: dict, partition, offset, skip):
    """Copy the image and put the probe's files in its root. A COPY only."""
    shutil.copyfile(src, dst)
    with open(dst, "r+b") as f:
        fs = fatimg.Fat(f, fatimg.locate_volume(f, partition, offset, skip))
        for name, data in files.items():
            fs.put(name, data)


def bat_text(manifests: dict) -> bytes:
    """RUNINTEG.BAT for exactly the drives this run has manifests for (CRLF). Same shape as the
    shipped tools/hwprobe/integ/RUNINTEG.BAT, which hard-codes C:/A:/E:."""
    L = ["@ECHO OFF", 'IF "%1"=="/PLAY" INTEG P > INTEG_P.TXT']
    for drive in manifests:
        L.append(f"INTEG V {drive[0]}_INTEG.MAN > INTEG_{drive[0]}.TXT")
    hdd = next(iter(manifests))               # the first manifest is the hard disk's
    L.append(f"INTEG W {hdd} /K:512 > INTEG_W{hdd[0]}.TXT")
    if "A:" in manifests and hdd != "A:":
        L.append("INTEG W A: /K:256 > INTEG_WA.TXT")
    L += ['IF "%1"=="/PLAY" INTEG S >> INTEG_P.TXT', "ECHO done > INTEG_OK.TXT"]
    return ("\r\n".join(L) + "\r\n").encode()


def probe_files(manifests: dict) -> dict:
    com = ROOT / "tools/hwprobe/integ/integ.com"
    if not com.exists():
        subprocess.run(["make", "-C", str(ROOT / "tools/hwprobe"), "integ/integ.com"], check=True)
    files = {"INTEG.COM": com.read_bytes(), "RUNINTEG.BAT": bat_text(manifests)}
    for drive, text in manifests.items():
        files[f"{drive[0]}_INTEG.MAN"] = text.encode()
    return files


def expected_captures(manifests: dict, want_play: bool):
    exp = []
    for drive in manifests:
        exp.append(f"INTEG_{drive[0]}.TXT")
    exp.append(f"INTEG_W{next(iter(manifests))[0]}.TXT")
    if "A:" in manifests and next(iter(manifests)) != "A:":
        exp.append("INTEG_WA.TXT")
    return exp


def mgl_text(hdd=None, fdd0=None, fdd1=None, cd=None, pack="pc98pack-xe10.bin") -> str:
    """The same shape tools/mister_load.sh writes; an S entry's index is the hps_io slot."""
    lines = ["<mistergamedescription>", f"\t<rbf>_Computer/{CORE}-{TAG}</rbf>", f"\t<setname>{SETNAME}</setname>"]
    for idx, p in ((0, hdd), (1, fdd0), (2, fdd1), (4, cd)):
        if p:
            lines.append(f'\t<file delay="1" type="s" index="{idx}" path="{p}"/>')
    lines.append(f'\t<file delay="1" type="f" index="0" path="{pack}"/>')
    lines.append("</mistergamedescription>")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------------------------
# the MiSTer
# ---------------------------------------------------------------------------------------------
class Mister:
    def __init__(self, host, password, dry):
        # host is the ssh destination; a bare host name gets root@. Authentication is ssh keys
        # unless a password is given, which goes through sshpass -e (SSHPASS in the environment,
        # never on a command line).
        self.host = host if "@" in host else f"root@{host}"
        self.dry = dry
        self.env = dict(os.environ, SSHPASS=password) if password else dict(os.environ)
        self.auth = ["sshpass", "-e"] if password else []
        self.opts = ["-o", "StrictHostKeyChecking=no", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10"]
        self.created = []          # remote paths, for the cleanup verification
        self.plan = []

    def sh(self, cmd, check=True, timeout=600):
        self.plan.append(("ssh", cmd))
        if self.dry:
            return ""
        r = subprocess.run(self.auth + ["ssh"] + self.opts + [self.host, cmd], env=self.env,
                           capture_output=True, text=True, timeout=timeout)
        if check and r.returncode != 0:
            raise RuntimeError(f"ssh failed ({r.returncode}): {cmd}\n{r.stderr.strip()}")
        return r.stdout

    def put(self, local, remote):
        assert TAG in remote.lower(), f"refusing to write outside the {TAG} namespace: {remote}"
        self.plan.append(("scp-put", f"{local} -> {remote}"))
        self.created.append(remote)
        if not self.dry:
            subprocess.run(self.auth + ["scp", "-O"] + self.opts + [str(local), f"{self.host}:{remote}"],
                           env=self.env, check=True)

    def get(self, remote, local):
        self.plan.append(("scp-get", f"{remote} -> {local}"))
        if not self.dry:
            subprocess.run(self.auth + ["scp", "-O"] + self.opts + [f"{self.host}:{remote}", str(local)],
                           env=self.env, check=True)

    def write(self, text, remote):
        with tempfile.NamedTemporaryFile("w", delete=False) as t:
            t.write(text)
        try:
            self.put(t.name, remote)
        finally:
            os.unlink(t.name)


def log(out, msg):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    with open(out / "log.txt", "a") as f:
        f.write(line + "\n")


def run_item(m: Mister, item, a, sc, prep, out):
    """Boot the core on a fresh image copy, drive it, collect. Returns (verdict, detail)."""
    itemdir = out / item
    itemdir.mkdir(parents=True, exist_ok=True)
    # a fresh copy of the patched image for this item (items must not contaminate each other)
    m.sh(f"cp {GAMES}/{TAG}-hdd.base {GAMES}/{TAG}-hdd.img")
    m.created.append(f"{GAMES}/{TAG}-hdd.img")
    for n, base in (("fdd0", prep.get("fdd0")), ("fdd1", prep.get("fdd1"))):
        if base:
            m.sh(f"cp {GAMES}/{TAG}-{n}.base {GAMES}/{TAG}-{n}.img")
            m.created.append(f"{GAMES}/{TAG}-{n}.img")
    cfg = (sc.get(item, {}) if sc else {}).get("config_default")
    if cfg is not None:
        # a per-item boot profile: CONFIG.SYS of THIS item's image copy (SELSYS `REM DEFAULTn`, 0-based:
        # 0 = noemm, 1 = himem, 2 = emm386, 3 = full/NECCD), patched on the MiSTer with the shipped fatimg
        local = itemdir / "CONFIG.SYS"
        local.write_bytes(set_default_profile(prep["config_sys"], cfg))
        m.put(local, f"{REMOTE_TMP}/CONFIG.{item}")
        m.sh(f"python3 {REMOTE_TMP}/fatimg.py {GAMES}/{TAG}-hdd.img "
             f"{'--partition %d ' % a.partition if a.partition is not None else ''}--put CONFIG.SYS {REMOTE_TMP}/CONFIG.{item}")
    mgl = mgl_text(f"{TAG}-hdd.img", f"{TAG}-fdd0.img" if prep.get("fdd0") else None,
                   f"{TAG}-fdd1.img" if prep.get("fdd1") else None,
                   f"{TAG}-cd.img" if prep.get("cd") else None, a.pack)
    m.write(mgl, REMOTE_MGL)
    before = set(m.sh(f"ls {SHOTS} 2>/dev/null").split())
    if a.uart:
        m.sh("stty -F /dev/ttyS1 115200 raw -echo; rm -f /tmp/zreg/uart.bin; "
             "nohup sh -c 'cat /dev/ttyS1 > /tmp/zreg/uart.bin' </dev/null >/dev/null 2>&1 &")
    log(out, f"{item}: load_core")
    m.sh(f"echo 'load_core {REMOTE_MGL}' > /dev/MiSTer_cmd")
    boot = (sc.get(item, {}).get("boot_wait") if sc else None) or a.boot_wait
    time.sleep(0 if m.dry else boot)
    verdict, detail = "PASS", ""

    def type_(s):
        m.sh(f"python3 {REMOTE_TMP}/ztype.py {shlex.quote(s)}")

    if item in ("probe", "probe-cda"):
        # AUTOEXEC may leave the guest in another directory; the batch writes its captures to the cwd
        type_("cd \\\n")
        type_("RUNINTEG /PLAY\n" if item == "probe-cda" else "RUNINTEG\n")
        deadline = time.time() + a.probe_timeout
        exp = expected_captures(prep["manifests"], item == "probe-cda")
        cdcap = f"INTEG_{a.cd_drive[0].upper()}.TXT" if a.cd else None
        names = exp + ["INTEG_OK.TXT"] + (["INTEG_P.TXT"] if item == "probe-cda" else [])
        if item == "probe-cda" and cdcap in exp:
            # With CD-DA playing the NEC driver answers a data read with 'Not ready' (measured 2026-10-10:
            # OPENFAIL AX=0005 on every CD file), so the CD's own verify cannot be a pass criterion there;
            # the HDD verify and write/read-back under CD-DA are. The CD capture is reported, not judged.
            exp = [e for e in exp if e != cdcap]
        caps = {}
        while True:
            time.sleep(0 if m.dry else 20)
            m.sh("echo screenshot > /dev/MiSTer_cmd")      # what the guest shows while INTEG runs (a hang is visible)
            caps = {}
            for n in names:
                t = m.sh(f"python3 {REMOTE_TMP}/integ_manifest.py --image {GAMES}/{TAG}-hdd.img "
                         f"{'--partition %d ' % a.partition if a.partition is not None else ''}--cat {n} 2>/dev/null", check=False)
                caps[n] = t or None
            if m.dry or caps.get("INTEG_OK.TXT") or time.time() > deadline:
                break
        for n, t in caps.items():
            if t:
                (itemdir / n).write_text(t)
        if not m.dry:
            for f in sorted(set(m.sh(f"ls {SHOTS} 2>/dev/null").split()) - before):
                m.get(f"{SHOTS}/{f}", itemdir / f)
                m.created.append(f"{SHOTS}/{f}")
        ok, detail = judge_probe(caps, exp, item == "probe-cda") if not m.dry else (True, "dry run")
        if item == "probe-cda" and not m.dry and cdcap and caps.get(cdcap):
            r = parse_integ(caps[cdcap])
            detail += f"; CD verify under CD-DA (informational): FAILS={r['fails']}, " + ((r['bad'][0] if r['bad'] else 'no rows'))
        verdict = "DRY" if m.dry else ("PASS" if ok else "FAIL")
    else:
        s = sc[item]
        every = s.get("shot_every", 15)
        t_start = time.time()
        for step in s["steps"]:
            op = step[0]
            if op == "type":
                type_(step[1])
            elif op == "wait":
                time.sleep(0 if m.dry else float(step[1]))
            elif op == "click":
                m.sh(f"python3 {REMOTE_TMP}/zclick.py " + " ".join(str(x) for x in step[1:]))
            elif op == "key":
                type_(f"~k{int(step[1])};")
        n = int(s.get("run", 180) // every)
        for _ in range(n):
            time.sleep(0 if m.dry else every)
            m.sh("echo screenshot > /dev/MiSTer_cmd")
        time.sleep(0 if m.dry else 3)
        after = m.sh(f"ls {SHOTS} 2>/dev/null").split()
        new = sorted(set(after) - before)
        shots = []
        for f in new:
            m.get(f"{SHOTS}/{f}", itemdir / f)
            shots.append(itemdir / f)
            m.created.append(f"{SHOTS}/{f}")          # a screenshot the run made: removed in cleanup
        if m.dry:
            return "DRY", "dry run"
        # the screenshots taken before the steps finished (the boot) are part of the sequence
        if len(shots) < max(3, n // 2):
            return "FAIL", f"only {len(shots)} screenshots came back of {n} requested"
        ok1, d1 = check_motion(shots, s.get("max_static_s", 60), every, s.get("min_changes", 3))
        detail = d1
        if not ok1:
            verdict = "FAIL"
        ref = s.get("known_frame")
        if ref:
            refp = Path(a.refs or ".") / ref["ref"]
            if a.record_refs:
                idx = min(len(shots) - 1, int(ref.get("by_s", s.get("run", 180)) // every))
                Path(a.refs).mkdir(parents=True, exist_ok=True)
                shutil.copyfile(shots[idx], refp)
                detail += f"; RECORDED {refp.name} from shot {idx} (look at it before trusting it)"
            elif not refp.exists():
                detail += f"; known frame SKIPPED: {refp} does not exist (--record-refs from a good build)"
                if verdict == "PASS":
                    verdict = "SKIP-FRAME"
            else:
                ok2, d2 = check_known_frame(shots, refp, ref.get("max_diff", 12.0), every, ref.get("not_before_s", 0))
                detail += "; " + d2
                if not ok2:
                    verdict = "FAIL"
    if a.uart:
        m.get(f"{REMOTE_TMP}/uart.bin", itemdir / "uart.bin")
        m.sh("for p in $(pidof cat); do ls -l /proc/$p/fd 2>/dev/null | grep -q ttyS1 && kill $p; done", check=False)
    return verdict, detail


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rbf", help="the test RBF")
    ap.add_argument("--hdd-image", help="your HDD image (host path; a COPY is patched and uploaded)")
    ap.add_argument("--partition", type=int, default=None, help="MBR partition holding the DOS volume (default: auto - a bare volume, else partition 0)")
    ap.add_argument("--hdd-drive", default="C:", help="the letter the guest gives the HDD (a disk that boots as A: needs --hdd-drive A:)")
    ap.add_argument("--hdd-under", help="restrict the HDD manifest to a directory (e.g. GAMES\\DOOM)")
    ap.add_argument("--hdd-largest", type=int, default=8)
    ap.add_argument("--fdd0", help="a floppy image (raw; mounted as drive A:)")
    ap.add_argument("--fdd1", help="a second floppy image (drive B:)")
    ap.add_argument("--cd", help="a CD image (iso/pcd/raw) mounted on hps_io slot 4")
    ap.add_argument("--cd-layout", choices=("iso", "pcd", "raw"), default="pcd")
    ap.add_argument("--cd-drive", default="E:", help="the letter MSCDEX gives the CD in the guest")
    ap.add_argument("--max-bytes", type=int, default=2 << 20, help="bytes checked per file")
    ap.add_argument("--pack", default="pc98pack-xe10.bin", help="the pack already on the MiSTer (games/PC9821/)")
    ap.add_argument("--items", default=",".join(ITEMS))
    ap.add_argument("--scenarios", help="JSON: per game item boot_wait/steps/run/checks")
    ap.add_argument("--refs", help="directory of known-frame reference PNGs (yours; never committed)")
    ap.add_argument("--record-refs", action="store_true", help="write the known frames instead of checking them")
    ap.add_argument("--uart", action="store_true", help="capture /dev/ttyS1 (trace builds)")
    ap.add_argument("--boot-wait", type=int, default=40, help="seconds from load_core to the DOS prompt")
    ap.add_argument("--probe-timeout", type=int, default=900)
    ap.add_argument("--host", default=os.environ.get("MISTER_HOST", "root@MiSTer"),
                    help="ssh destination (default $MISTER_HOST, else root@MiSTer)")
    ap.add_argument("--password", default=os.environ.get("MISTER_PASS", "1"),
                    help="password auth via sshpass (default $MISTER_PASS, else 1 - the stock MiSTer "
                         "root password; an empty value uses ssh keys)")
    ap.add_argument("--out", help="results directory (default .build/mister-regress/<time>)")
    ap.add_argument("--go", action="store_true", help="actually touch the MiSTer (otherwise: print the plan)")
    ap.add_argument("--keep", action="store_true", help="do not clean up (debugging)")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    if not (a.rbf and a.hdd_image):
        ap.error("--rbf and --hdd-image are required")
    if a.fdd0 and a.hdd_drive.upper() == "A:":
        ap.error("the HDD is drive A: here, which the floppy would also be; no floppy with --hdd-drive A:")
    items = [i for i in a.items.split(",") if i]
    for i in items:
        if i not in ITEMS:
            ap.error(f"unknown item {i}")
    sc = load_scenarios(a.scenarios) if a.scenarios else {}
    out = Path(a.out) if a.out else ROOT / ".build/mister-regress" / time.strftime("%Y%m%d-%H%M%S")
    out.mkdir(parents=True, exist_ok=True)

    # ---- host-side preparation (no MiSTer involved)
    sel = {"largest": a.hdd_largest, "max_bytes": a.max_bytes, "under": a.hdd_under, "partition": a.partition}
    manifests = {a.hdd_drive.upper(): manifest_for(Path(a.hdd_image), a.hdd_drive.upper(), "fat", sel)}
    if a.fdd0:
        manifests["A:"] = manifest_for(Path(a.fdd0), "A:", "fat", {"largest": 99, "max_bytes": a.max_bytes})
    if a.cd:
        manifests[a.cd_drive.upper()] = manifest_for(
            Path(a.cd), a.cd_drive.upper(), "cd", {"largest": 6, "max_bytes": a.max_bytes, "layout": a.cd_layout})
    workdir = ROOT / ".build/mister-regress/work"
    workdir.mkdir(parents=True, exist_ok=True)
    patched = workdir / "hdd.patched.img"
    if a.go:
        log(out, f"patching a COPY of {a.hdd_image} -> {patched}")
        patch_hdd(Path(a.hdd_image), patched, probe_files(manifests), a.partition, None, 0)
    else:
        log(out, f"(dry run) would patch a COPY of {a.hdd_image} -> {patched} with {sorted(probe_files(manifests))}")
    with open(a.hdd_image, "rb") as f:
        cfg_sys = fatimg.Fat(f, fatimg.locate_volume(f, a.partition, None, 0)).cat("CONFIG.SYS")
    prep = {"config_sys": cfg_sys, "manifests": manifests, "cd": bool(a.cd), "fdd0": bool(a.fdd0), "fdd1": bool(a.fdd1)}

    # ---- the plan
    runnable, skipped = [], []
    for it in items:
        why = None
        if it == "probe-cda" and not a.cd:
            why = "needs --cd"
        why = why or item_needs(it, sc)
        (skipped if why else runnable).append((it, why))
    log(out, "plan: run " + (", ".join(i for i, _ in runnable) or "nothing") +
        ("; skip " + "; ".join(f"{i} ({w})" for i, w in skipped) if skipped else ""))
    m = Mister(a.host, a.password, dry=not a.go)
    results = {i: ("SKIP", w) for i, w in skipped}

    locked = False
    try:
        if a.go:
            held = m.sh(f"mkdir {LOCK} 2>/dev/null && echo '{os.uname().nodename} pid {os.getpid()} {time.ctime()}' > {LOCK}/owner "
                        f"&& echo got || (echo held: $(cat {LOCK}/owner 2>/dev/null))", check=False).strip()
            if not held.startswith("got"):
                raise SystemExit(f"the MiSTer is locked by another run ({held}); not touching it")
            locked = True
            busy = m.sh("ls /dev/MiSTer_cmd >/dev/null 2>&1 && echo ok", check=False).strip()
            if busy != "ok":
                raise SystemExit("/dev/MiSTer_cmd missing: is Main_MiSTer running?")
        m.sh(f"mkdir -p {REMOTE_TMP}")
        for f in ("ztype.py", "zclick.py"):
            m.put(ROOT / "tools/mister" / f, f"{REMOTE_TMP}/{f}")
        for f in ("fatimg.py", "integ_manifest.py"):
            m.put(ROOT / "tools/hwprobe/integ" / f, f"{REMOTE_TMP}/{f}")
        m.put(a.rbf, REMOTE_RBF)
        m.put(patched, f"{GAMES}/{TAG}-hdd.base")
        if a.fdd0:
            m.put(a.fdd0, f"{GAMES}/{TAG}-fdd0.base")
        if a.fdd1:
            m.put(a.fdd1, f"{GAMES}/{TAG}-fdd1.base")
        if a.cd:
            m.put(a.cd, f"{GAMES}/{TAG}-cd.img")
        for it, _ in runnable:
            try:
                results[it] = run_item(m, it, a, sc, prep, out)
            except Exception as e:                       # one item's failure must not skip the cleanup
                results[it] = ("FAIL", f"runner error: {e}")
            log(out, f"{it}: {results[it][0]} - {results[it][1]}")
    finally:
        if a.go and not a.keep:
            leftovers = cleanup(m, out)
            if leftovers:
                results["cleanup"] = ("FAIL", "left on the MiSTer: " + ", ".join(leftovers))
        if a.go and locked and not a.keep:
            m.sh(f"rm -rf {LOCK}", check=False)
        if not a.go:
            (out / "plan.txt").write_text("\n".join(f"{k}: {v}" for k, v in m.plan) + "\n")
            print(f"\ndry run: {len(m.plan)} remote actions listed in {out / 'plan.txt'}; nothing was touched (add --go)")
    (out / "results.json").write_text(json.dumps(results, indent=1))
    print("\n== mister_regress ==")
    for k, (v, d) in results.items():
        print(f"{v:10s} {k:12s} {d}")
    bad = [k for k, (v, _) in results.items() if v == "FAIL"]
    return 1 if bad else 0


def cleanup(m: Mister, out: Path):
    """Remove everything the run created and VERIFY it is gone. Returns what is still there."""
    log(out, "cleanup")
    m.sh("for p in $(pidof cat); do ls -l /proc/$p/fd 2>/dev/null | grep -q ttyS1 && kill $p; done", check=False)
    paths = sorted(set(m.created))
    for p in paths:
        assert TAG in p.lower() or p.startswith(SHOTS), p
    # the run's own screenshots are listed by name in m.created; the test files carry the tag
    m.sh("rm -f " + " ".join(shlex.quote(p) for p in paths) + f" {REMOTE_MGL}", check=False)
    m.sh(f"rm -rf {REMOTE_TMP}", check=False)
    left = []
    for p in paths + [REMOTE_MGL, REMOTE_TMP]:
        if m.sh(f"test -e {shlex.quote(p)} && echo there", check=False).strip():
            left.append(p)
    return left


# ---------------------------------------------------------------------------------------------
def selftest() -> int:
    from PIL import Image, ImageDraw
    rc = 0

    def check(c, what):
        nonlocal rc
        print(("ok:   " if c else "FAIL: ") + what)
        rc |= 0 if c else 1

    with tempfile.TemporaryDirectory() as d:
        d = Path(d)

        def shot(i, kind):
            im = Image.new("RGB", (640, 400), (10, 10, 10))
            dr = ImageDraw.Draw(im)
            if kind == "moving":
                dr.rectangle([i * 17 % 600, 50, i * 17 % 600 + 30, 90], fill=(255, 255, 255))
            elif kind == "logo":
                dr.rectangle([100, 100, 540, 300], fill=(200, 30, 30))
            p = d / f"2026{i:04d}.png"
            im.save(p)
            return p

        moving = [shot(i, "moving") for i in range(12)]
        ok, msg = check_motion(moving, 60, 15, 3)
        check(ok, f"a moving sequence is not frozen ({msg})")
        frozen = [shot(100, "frozen")] * 12
        ok, msg = check_motion(frozen, 60, 15, 3)
        check(not ok, f"an identical-shot sequence IS frozen ({msg})")
        stall = moving[:4] + [moving[3]] * 8
        ok, msg = check_motion(stall, 60, 15, 3)
        check(not ok, f"a stall after motion is caught ({msg})")
        ok, msg = check_motion(stall, 150, 15, 3)
        check(ok, "the same stall passes with a longer allowance (the limit is per scenario)")
        ref = shot(200, "logo")
        ok, msg = check_known_frame(moving + [ref], ref, 12.0, 15)
        check(ok, f"the known frame is found among the shots ({msg})")
        ok, msg = check_known_frame(moving, ref, 12.0, 15)
        check(not ok, f"a sequence without it is rejected ({msg})")

        good = "INTEG BEGIN V1\r\nFILE C:\\A SIZE=1 CRC=1 WANT=1 BADBLK=00000000 OK\r\nINTEG END FAILS=0000\r\n"
        bad = ("INTEG BEGIN V1\r\nBAD  C:\\A OFF=00004200 BLK=00000021 GOT=1 WANT=2 DATA=00\r\n"
               "FILE C:\\A SIZE=1 CRC=1 WANT=1 BADBLK=00000001 FAIL\r\nINTEG END FAILS=0001\r\n")
        names = ["INTEG_C.TXT", "INTEG_WC.TXT"]
        caps = {"INTEG_C.TXT": good, "INTEG_WC.TXT": good, "INTEG_OK.TXT": "done"}
        check(judge_probe(caps, names, False)[0], "judge: clean captures pass")
        caps2 = dict(caps, **{"INTEG_C.TXT": bad})
        ok, msg = judge_probe(caps2, names, False)
        check(not ok and "OFF=00004200" in msg, f"judge: a BAD row fails the run and names the offset ({msg})")
        check(not judge_probe(dict(caps, **{"INTEG_OK.TXT": None}), names, False)[0], "judge: a run with no INTEG_OK.TXT fails")
        check(not judge_probe(dict(caps, **{"INTEG_WC.TXT": "INTEG BEGIN V1\r\n"}), names, False)[0], "judge: a capture with no END row (probe died) fails")
        capsp = dict(caps, **{"INTEG_P.TXT": "PLAY NOMSCDEX\r\n"})
        check(not judge_probe(capsp, names, True)[0], "judge: CD-DA that never played fails the cda item")
        capsp = dict(caps, **{"INTEG_P.TXT": "PLAY OK DRV=04 TRACK=02 START=00051000 SECTORS=00000100\r\nINTEG END FAILS=0000\r\n"})
        check(judge_probe(capsp, names, True)[0], "judge: CD-DA playing passes")

        cs = b"DEVICE=X\r\nREM DEFAULT3\r\nREM WAIT5\r\n"
        check(set_default_profile(cs, 0) == b"DEVICE=X\r\nREM DEFAULT0\r\nREM WAIT5\r\n", "config: DEFAULTn rewritten, CRLF and every other byte kept")
        try:
            set_default_profile(b"nothing\r\n", 0)
            check(False, "config: a CONFIG.SYS without the line is refused")
        except SystemExit:
            check(True, "config: a CONFIG.SYS without the line is refused")
        sc = {"doom": {"steps": [["type", "?"]]}, "th05": {"steps": [["type", "th5\n"]]}}
        check(item_needs("doom", sc) is not None, "scenario: a '?' placeholder is a SKIP, not a pass")
        check(item_needs("th05", sc) is None and item_needs("rusty", sc) is not None, "scenario: filled items run, absent ones skip")

        # ---- the image patching: put the probe's files in a COPY of a synthetic volume, read back
        if shutil.which("mformat"):
            img = d / "disk.img"
            subprocess.run(["mformat", "-C", "-i", str(img), "-t", "400", "-h", "4", "-s", "32", "::"], check=True, capture_output=True)
            src = d / "game.bin"
            src.write_bytes(os.urandom(70_000))
            subprocess.run(["mcopy", "-i", str(img), str(src), "::GAME.BIN"], check=True, capture_output=True)
            orig = img.read_bytes()
            man = {"C:": manifest_for(img, "C:", "fat", {"largest": 4, "max_bytes": 1 << 20, "under": None, "partition": None})}
            files = probe_files(man)
            cp = d / "copy.img"
            patch_hdd(img, cp, files, None, None, 0)
            check(img.read_bytes() == orig, "patch: the ORIGINAL image is byte-identical after patching")
            with open(cp, "rb") as f:
                fs = fatimg.Fat(f, 0)
                got = {n: fs.cat(n) for n in files}
            check(got == files, "patch: every probe file reads back from the copy")
            fsck = shutil.which("fsck.fat")
            if fsck:
                check(subprocess.run([fsck, "-n", str(cp)], capture_output=True).returncode == 0, "patch: fsck.fat accepts the patched copy")
            check("F 00011170" in man["C:"] and "C:\\GAME.BIN" in man["C:"], "manifest: the file, its size and drive")

        # ---- the plan: dry run touches nothing and stays in the test namespace
        m = Mister("nowhere", "x", dry=True)
        mgl = mgl_text("zreg-hdd.img", "zreg-fdd0.img", None, "zreg-cd.img")
        check('index="0" path="zreg-hdd.img"' in mgl and 'index="4" path="zreg-cd.img"' in mgl and 'index="1"' in mgl,
              "mgl: HDD slot 0, FDD0 slot 1, CD slot 4, pack last")
        check(mgl.rstrip().endswith("</mistergamedescription>") and mgl.index('type="f"') > mgl.index('index="4"'), "mgl: the pack entry is last (images mount before the CPU runs)")
        try:
            m.put("x", "/media/fat/_Computer/PC9821Z486.rbf")
            check(False, "put: refuses a path outside the test namespace")
        except AssertionError:
            check(True, "put: refuses a path outside the test namespace (a real, non-test RBF)")
        m.put("x", REMOTE_RBF)
        check(all(TAG in r.lower() for _, r in [(k, v.split("-> ")[-1]) for k, v in m.plan if k == "scp-put"]), "plan: every uploaded name carries the test tag")
        # cleanup must list exactly what was created
        m2 = Mister("nowhere", "x", dry=True)
        m2.put("x", REMOTE_RBF)
        m2.created.append(f"{GAMES}/{TAG}-hdd.img")
        cleanup(m2, Path(tempfile.mkdtemp()))
        rm = [v for k, v in m2.plan if k == "ssh" and v.startswith("rm -f")][0]
        check(REMOTE_RBF in rm and f"{GAMES}/{TAG}-hdd.img" in rm and REMOTE_MGL in rm, "cleanup: removes the RBF, the image copy and the MGL")

    print("PASS" if rc == 0 else "FAIL")
    return rc


if __name__ == "__main__":
    sys.exit(main())

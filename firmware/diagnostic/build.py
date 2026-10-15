#!/usr/bin/env python3
"""Build the redistributable 512 KiB z486 PC-9821 diagnostic ROM pack."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
PACK_SIZE = 0x80000
ITF_SIZE = 0x8000
ANK_OFFSET = 0x30000
ANK_SIZE = 0x1000


def assemble(source: Path = HERE / "post.s") -> bytes:
    with tempfile.TemporaryDirectory() as td:
        obj = Path(td) / "post.o"
        raw = Path(td) / "post.bin"
        subprocess.run(["as", "--32", "-o", str(obj), str(source)],
                       check=True)
        subprocess.run(["objcopy", "-O", "binary", "-j", ".text",
                        str(obj), str(raw)], check=True)
        image = raw.read_bytes()
    if len(image) != ITF_SIZE:
        raise SystemExit(f"diagnostic ITF is {len(image)} bytes, expected {ITF_SIZE}")
    if image[0x7FF0:0x7FF5] != bytes.fromhex("ea000000f8"):
        raise SystemExit("diagnostic reset vector is not EA 0000:F800")
    return image


def assemble_ipl() -> bytes:
    with tempfile.TemporaryDirectory() as td:
        obj = Path(td) / "ipl.o"
        raw = Path(td) / "ipl.bin"
        subprocess.run(["as", "--32", "-o", str(obj), str(HERE / "ipl.s")],
                       check=True)
        subprocess.run(["objcopy", "-O", "binary", "-j", ".text",
                        str(obj), str(raw)], check=True)
        image = raw.read_bytes()
    if len(image) != 512 or image[4:8] != b"IPL1":
        raise SystemExit("diagnostic IPL size/signature mismatch")
    return image


def synthetic_ank() -> bytes:
    """Create original deterministic 8x16 patterns; no firmware/font input."""
    font = bytearray(ANK_SIZE)
    for code in range(256):
        for row in range(16):
            if code == 0x20:
                value = 0
            elif row in (0, 15):
                value = 0x7E
            else:
                # Distinct, visible pattern derived only from code and row.
                value = ((code << (row & 3)) | (code >> (8 - (row & 3)))) & 0x7E
                value |= 0x42
            font[code * 16 + row] = value
    return bytes(font)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=HERE / "diagnostic_pack.bin")
    parser.add_argument("--itf-src", type=Path, default=HERE / "post.s",
                        help="the ITF bank's source (default: this pack's post.s; the CPU-"
                             "throttle tier assembles tests/pc9821/throttle_guest.s)")
    parser.add_argument("--mem", type=Path,
                        help="optional sparse 16-bit readmemh file")
    parser.add_argument("--disk-out", type=Path,
                        help="optional one-sector deterministic IPL image")
    parser.add_argument("--disk-mem", type=Path,
                        help="optional 16-bit readmemh form of the IPL")
    args = parser.parse_args()

    pack = bytearray(PACK_SIZE)
    pack[:ITF_SIZE] = assemble(args.itf_src)
    pack[ANK_OFFSET:ANK_OFFSET + ANK_SIZE] = synthetic_ank()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(pack)
    if args.mem:
        args.mem.parent.mkdir(parents=True, exist_ok=True)
        with args.mem.open("w", encoding="ascii") as stream:
            stream.write("@00000\n")
            for offset in range(0, ITF_SIZE, 2):
                stream.write(f"{pack[offset] | (pack[offset + 1] << 8):04x}\n")
            stream.write(f"@{ANK_OFFSET // 2:05x}\n")
            for offset in range(ANK_OFFSET, ANK_OFFSET + ANK_SIZE, 2):
                stream.write(f"{pack[offset] | (pack[offset + 1] << 8):04x}\n")
    if args.disk_out or args.disk_mem:
        disk = assemble_ipl()
        if args.disk_out:
            args.disk_out.parent.mkdir(parents=True, exist_ok=True)
            args.disk_out.write_bytes(disk)
            print(f"{args.disk_out}: 512-byte IPL sha256={hashlib.sha256(disk).hexdigest()}")
        if args.disk_mem:
            args.disk_mem.parent.mkdir(parents=True, exist_ok=True)
            args.disk_mem.write_text("".join(
                f"{disk[i] | (disk[i + 1] << 8):04x}\n"
                for i in range(0, len(disk), 2)), encoding="ascii")
    digest = hashlib.sha256(pack).hexdigest()
    print(f"{args.out}: {len(pack)} bytes sha256={digest}")
    print("reset vector: EA 0000:F800; synthetic ANK: 4096 bytes")


if __name__ == "__main__":
    main()

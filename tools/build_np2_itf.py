#!/usr/bin/env python3
"""Build NP2kai's 32 KiB synthesized ITF from an explicit itfrom.res.

No firmware bytes or implicit external paths are embedded in this repository.
The transformation mirrors NP2kai bios/bios.c and can apply its optional
fast-memory-check patch. NP2kai separately pre-seeds low-memory BIOS vectors in
host code, so this output is a behavioral reference rather than a standalone
hardware ITF.
"""

from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path

ITF_SIZE = 0x8000
MEMCHECK_COUNT_OFFSET = 5886
MEMCHECK_WAIT_OPCODE_OFFSET = 5924


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True,
                        help="explicit path to NP2kai bios/itfrom.res")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--memcheck-speed", type=int, default=8,
                        help="NP2kai memcheckspeed; 1 preserves the original loop")
    args = parser.parse_args()

    text = args.source.read_text(encoding="ascii", errors="strict")
    data = bytearray(int(value, 16) for value in
                     re.findall(r"0x([0-9a-fA-F]{1,2})", text))
    if not data or len(data) > 0x7FF0:
        raise SystemExit(f"invalid itfrom.res payload size: {len(data)}")
    if args.memcheck_speed < 1 or 128 * args.memcheck_speed > 0xFFFF:
        raise SystemExit("memcheck speed must be in range 1..511")

    if args.memcheck_speed > 1:
        count = 128 * args.memcheck_speed
        data[MEMCHECK_COUNT_OFFSET:MEMCHECK_COUNT_OFFSET + 2] = \
            count.to_bytes(2, "little")
        data[MEMCHECK_WAIT_OPCODE_OFFSET] = 0x90

    payload_size = len(data)
    data += b"\x00" * (ITF_SIZE - len(data))
    # z486 resets through the high alias into the selected top 32 KiB bank.
    data[0x7FF0:0x7FF5] = b"\xEA\x00\x00\x00\xF8"  # jmp F800:0000

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(data)
    print(f"{args.out}: {len(data)} bytes, payload={payload_size}, "
          f"memcheckspeed={args.memcheck_speed}, "
          f"sha256={hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    main()

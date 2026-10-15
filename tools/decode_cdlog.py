#!/usr/bin/env python3
"""decode_cdlog.py <capture.bin> [...]   (or '-' for stdin)

Decodes the CD drive's command log (pc9821_atapi LOG_EN, built with
`build_profile.py base --cdrom --cdrom-log`) from a raw capture of the debug UART:

    stty -F /dev/ttyS1 115200 raw -echo && cat /dev/ttyS1 > cdlog.bin

Every record is 0xA5, a type, a 16-bit millisecond time (big-endian, wraps at 65.536 s), then:
  1 CMD    command, DRHD, DEV, STATUS before the write      2 CDB   the 12 CDB bytes
  3 DATA / 4 DONE (also an ATA command that left the drive idle)  STATUS, ERROR, interrupt reason, byte count lo/hi, sense key, ASC, ASCQ;
           DONE adds the data words the guest read since the command: sum, XOR, count (16-bit each, big-endian)
  5 MOUNT  img_size[39:0]       6 READY  PCD flag, tracks, sector count[23:0]
  7 DEVCTL the 0x074C byte      8 BANK  a bank switch (0x0432)     9 LOST  records dropped before this
  10 ALIVE 0x5A, at power-up and after every core reset (the path works even with no CD traffic)
  11 PLAYER audio status (0x11 play/0x12 pause/0x13 done/0x15 none), position, remaining length,
           engine-idle and cdda_req bits; on every status change and every 16th streamed audio sector
  (8 BANK records were retired after 28bbd257: the guest's disk traffic flooded the ring)
Bytes outside a record (the core's "Z386 start" banner, line noise) are skipped and counted.
"""
import sys

LEN = {1: 4, 2: 12, 3: 8, 4: 14, 5: 5, 6: 5, 7: 1, 8: 1, 9: 1, 10: 1, 11: 8}
OPS = {0x00: 'TEST UNIT READY', 0x03: 'REQUEST SENSE', 0x12: 'INQUIRY', 0x1B: 'START/STOP',
       0x1E: 'PREVENT/ALLOW', 0x25: 'READ CAPACITY', 0x28: 'READ(10)', 0x2B: 'SEEK',
       0x42: 'READ SUB-CHANNEL', 0x43: 'READ TOC', 0x45: 'PLAY AUDIO', 0x46: 'GET CONFIG',
       0x47: 'PLAY AUDIO MSF', 0x4B: 'PAUSE/RESUME', 0x4E: 'STOP PLAY', 0x55: 'MODE SELECT',
       0x5A: 'MODE SENSE', 0xBD: 'MECHANISM STATUS', 0xBE: 'READ CD', 0xB9: 'READ CD MSF'}


def decode(data):
    i, skipped, out = 0, 0, []
    while i < len(data):
        if data[i] != 0xA5 or i + 4 > len(data) or data[i + 1] not in LEN:
            skipped += 1
            i += 1
            continue
        t, ms = data[i + 1], (data[i + 2] << 8) | data[i + 3]
        p = data[i + 4:i + 4 + LEN[t]]
        if len(p) < LEN[t]:
            break
        h = ' '.join(f'{b:02x}' for b in p)
        if t == 1:
            s = f'CMD    {p[0]:02x}  drhd={p[1]:02x} dev={p[2]} status_before={p[3]:02x}'
        elif t == 2:
            s = f'CDB    {h}  ({OPS.get(p[0], "?")})'
        elif t in (3, 4):
            s = (f'{"DATA" if t == 3 else "DONE"}   status={p[0]:02x} error={p[1]:02x} '
                 f'ireason={p[2]:02x} bytes={p[3] | (p[4] << 8)} sense={p[5]:x}/{p[6]:02x}/{p[7]:02x}')
            if t == 4:
                s += (f'  read: {(p[12] << 8) | p[13]} words sum={(p[8] << 8) | p[9]:04x} '
                      f'xor={(p[10] << 8) | p[11]:04x}')
        elif t == 5:
            s = f'MOUNT  size={int.from_bytes(p, "big")}'
        elif t == 6:
            s = f'READY  pcd={p[0]} tracks={p[1]} sectors={int.from_bytes(p[2:5], "big")}'
        elif t == 7:
            s = f'DEVCTL {p[0]:02x}'
        elif t == 8:
            s = f'BANK   {p[0]:02x}'
        elif t == 11:
            s = (f'PLAYER status={p[0]:02x} pos={int.from_bytes(p[1:4], "big")} '
                 f'left={int.from_bytes(p[4:7], "big")} engine_idle={p[7] >> 1 & 1} cdda_req={p[7] & 1}')
        elif t == 10:
            s = f'ALIVE  {p[0]:02x}  (power-up or the end of a core reset)'
        else:
            s = f'LOST   {p[0]} record(s)'
        out.append(f'{ms:5d} ms  {s}')
        i += 4 + LEN[t]
    return out, skipped


def main():
    for path in sys.argv[1:] or ['-']:
        data = sys.stdin.buffer.read() if path == '-' else open(path, 'rb').read()
        lines, skipped = decode(data)
        print('\n'.join(lines))
        print(f'# {len(lines)} records, {skipped} byte(s) outside records', file=sys.stderr)


if __name__ == '__main__':
    main()

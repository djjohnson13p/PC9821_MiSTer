#!/usr/bin/env python3
# zclick.py - a uinput mouse on the MiSTer (runs ON the MiSTer; tools/mister_regress.py copies it to
# /tmp/zreg/ and deletes it afterwards): an optional relative move (dx dy), then a left click.
# Usage: zclick.py [dx dy]
#
# THE MiSTer IS 32-BIT ARM, so `struct input_event` is `@llHHi` (16 bytes); a 64-bit `qq` timeval makes
# Main_MiSTer silently ignore every event. Wait ~1.5 s after UI_DEV_CREATE before the first event.
import fcntl, os, struct, sys, time
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT, UI_DEV_CREATE, UI_DEV_DESTROY = 0x40045564, 0x40045565, 0x40045566, 0x5501, 0x5502
EV_SYN, EV_KEY, EV_REL = 0, 1, 2
BTN_LEFT, REL_X, REL_Y = 0x110, 0, 1
fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY); fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_LEFT)
fcntl.ioctl(fd, UI_SET_KEYBIT, 0x111)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_REL); fcntl.ioctl(fd, UI_SET_RELBIT, REL_X); fcntl.ioctl(fd, UI_SET_RELBIT, REL_Y)
os.write(fd, struct.pack('80sHHHHi', b'zclick', 3, 1, 2, 1, 0) + b'\0' * (64 * 4 * 4))
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(1.5)
def ev(t, c, v): os.write(fd, struct.pack('@llHHi', 0, 0, t, c, v))
if len(sys.argv) == 3:
    dx, dy = int(sys.argv[1]), int(sys.argv[2])
    for _ in range(10):
        ev(EV_REL, REL_X, dx // 10); ev(EV_REL, REL_Y, dy // 10); ev(EV_SYN, 0, 0); time.sleep(0.03)
time.sleep(0.3)
ev(EV_KEY, BTN_LEFT, 1); ev(EV_SYN, 0, 0); time.sleep(0.12)
ev(EV_KEY, BTN_LEFT, 0); ev(EV_SYN, 0, 0); time.sleep(0.5)
fcntl.ioctl(fd, UI_DEV_DESTROY)

#!/usr/bin/env python3
# ztype.py - type a string on the MiSTer through /dev/uinput (runs ON the MiSTer; tools/mister_regress.py
# copies it to /tmp/zreg/ and deletes it afterwards).
#
# THE MiSTer IS 32-BIT ARM, so `struct input_event` is `@llHHi` (16 bytes). A 64-bit `qq` timeval makes
# Main_MiSTer silently ignore EVERY key - the first attempt did exactly that. Wait ~1.5 s after
# UI_DEV_CREATE before the first event or the first keys are lost. There is no evdev module on the box:
# the ioctls are issued by hand.
#
# US key positions (the core maps them that way). Usage: ztype.py 'text\n'
#   '\n' = Enter, '~C' = Ctrl+C, '~k<code>;' = one raw Linux key code (e.g. ~k28; = Enter).
# KEYMAP (src/pc9821/input/pc9821_kbd.sv, JIS layout): '\\' = YEN (0x5C) via key 43; '!' = shift+1. The shifted symbols below
# follow the US layout and are NOT checked against the PC-98 JIS caps (JIS ':' is the unshifted quote key 40/set-2 0x52, '+' is shift+';').
# Not mapped: backslash and a few symbols - ztype exits with `unmapped: ...` rather than guess.
import fcntl, os, struct, sys, time
UI_SET_EVBIT, UI_SET_KEYBIT, UI_DEV_CREATE, UI_DEV_DESTROY = 0x40045564, 0x40045565, 0x5501, 0x5502
EV_SYN, EV_KEY = 0, 1
K = {c: v for c, v in zip("1234567890", [2,3,4,5,6,7,8,9,10,11])}
K.update({c: v for c, v in zip("qwertyuiop", range(16, 26))})
K.update({c: v for c, v in zip("asdfghjkl", range(30, 39))})
K.update({c: v for c, v in zip("zxcvbnm", range(44, 51))})
K.update({' ': 57, '\n': 28, '-': 12, '/': 53, '.': 52, ',': 51, ';': 39})
SH, CTRL = 42, 29
K.update({'=': 13, "'": 40, '\\': 43})   # backslash = Linux KEY_BACKSLASH(43) = PS/2 set-2 0x5D, which src/pc9821/input/pc9821_kbd.sv translates to the PC-98 YEN key (8'h5D: translate = 8'h0D; BIOS table gives 0x5C)
SHIFTED = {'!': 2, '&': 8, '$': 5, '?': 53, '_': 12, '>': 52, '<': 51, '*': 9, ':': 39, '|': 43, '+': 13}
fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
for k in range(1, 128): fcntl.ioctl(fd, UI_SET_KEYBIT, k)
os.write(fd, struct.pack('80sHHHHi', b'ztype', 3, 1, 1, 1, 0) + b'\0' * (64 * 4 * 4))
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(1.5)
def ev(t, c, v):
    os.write(fd, struct.pack('@llHHi', 0, 0, t, c, v))
def tap(code, shift=False):
    if shift: ev(EV_KEY, SH, 1); ev(EV_SYN, 0, 0); time.sleep(0.03)
    ev(EV_KEY, code, 1); ev(EV_SYN, 0, 0); time.sleep(0.04)
    ev(EV_KEY, code, 0); ev(EV_SYN, 0, 0); time.sleep(0.04)
    if shift: ev(EV_KEY, SH, 0); ev(EV_SYN, 0, 0); time.sleep(0.03)
text = sys.argv[1].replace('\\n', '\n')
i = 0
while i < len(text):
    if text.startswith('~k', i):                       # ~k<code>; = one raw key code
        j = text.index(';', i); tap(int(text[i+2:j])); i = j + 1; time.sleep(0.25); continue
    if text.startswith('~C', i):
        ev(EV_KEY, CTRL, 1); ev(EV_SYN, 0, 0); time.sleep(0.03); tap(46)
        ev(EV_KEY, CTRL, 0); ev(EV_SYN, 0, 0); time.sleep(0.03); i += 2; continue
    ch = text[i]; i += 1
    if ch in K: tap(K[ch])
    elif ch in SHIFTED: tap(SHIFTED[ch], True)
    elif ch.isupper() and ch.lower() in K: tap(K[ch.lower()], True)
    else: raise SystemExit('unmapped: %r' % ch)
time.sleep(0.5)
fcntl.ioctl(fd, UI_DEV_DESTROY)

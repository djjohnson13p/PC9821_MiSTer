#!/usr/bin/env python3
"""The shared platform-decode prefix P0: every endpoint whose worst path starts at the CPU's
bus_unit ext_addr_r (gated-clock register) and crosses the memory map (peg_high / bios_top /
eff_addr / mapper). usage: p0.py ENDS_RPT...  -> per fit: P0 endpoints by cone, the WNS without
P0 endpoints, and the slack of ext_addr_r's own D input (the CPU side of the same budget)."""
import sys, re, collections
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import census as c
for fn in sys.argv[1:]:
    ps = c.load(fn); w = ps[0]['slack']
    p0 = [p for p in ps if c.is_p0(p)]
    rest = [p for p in ps if not c.is_p0(p)]
    byc = collections.Counter(p['cone'] for p in p0 if p['slack'] <= w + 1.0)
    d = [p for p in ps if 'bus_unit_inst|ext_addr_r' in p['to']]
    # time from the ext_addr_r launch to the first node leaving the memory map (the decode cost)
    dec = []
    for p in p0[:50]:
        t0 = p['chain'][0][0]; last = None
        for tot, inc, ty, fo, loc, el in p['chain']:
            if ty == 'CELL' and re.search(r'memory\|(mapper|bios_top|peg_high|eff_addr)', el): last = tot
        if last: dec.append(last - t0)
    print(f"{c.label(fn)}: WNS {w:.3f}; P0 endpoints {sum(1 for p in p0 if p['slack']<=w+0.3)} <=0.3 / "
          f"{sum(1 for p in p0 if p['slack']<=w+1.0)} <=1.0 of {sum(1 for p in ps if p['slack']<=w+1.0)}; "
          f"WNS without P0 {rest[0]['slack']:.3f} ({rest[0]['slack']-w:+.3f}, next {rest[0]['cone']}); "
          f"ext_addr_r D worst {d[0]['slack'] if d else 'n/a'}; map-decode time on the 50 worst P0 paths " +
          (f"{min(dec):.2f}..{max(dec):.2f} ns" if dec else "-"))
    print("   P0 <=1.0 by cone: " + ', '.join(f"{k.split()[0]} {v}" for k, v in byc.most_common()))

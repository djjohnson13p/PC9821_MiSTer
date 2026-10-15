#!/usr/bin/env python3
"""Every instantiation's port list, against the module it names.

WHY THIS EXISTS. A bench instantiates the module it tests DIRECTLY and wires every port
itself. Nothing in this tree instantiates the DUT's parent, so a port that is connected in
the module but forgotten at the instantiation is INVISIBLE to every bench, to the whole
gate, and to a successful fit. It shows up only on hardware, as a feature that silently
does nothing.

That is not hypothetical here: `pc9821_memory_subsystem`'s nine EGC register inputs are
declared, produced by the iobus, carried on wires in pc9821_system.sv - and never connected
to the instance. The EGC's registers have therefore never been driven. Verilator's
UNUSEDSIGNAL and a code review both recorded it; nothing acted.

AN UNCONNECTED OUTPUT IS NORMAL; AN UNCONNECTED INPUT IS A DEFECT. An input nobody drives
is undriven: synthesis usually ties it low while simulation reads it as x, so a bench and
the card disagree about a signal that is supposed to carry state. So this check reports the
two separately and only the second is an error. An unconnected output is reported as
information, because a monitor port deliberately left open is a design decision - the top
leaves pc9821_system's `software_reset` open on purpose, and the comment above that
instantiation says why.

WHAT THIS CANNOT SEE, stated so nobody over-reads it:
  - a port connected to the WRONG signal. `.foo(bar)` where bar is not foo's meaning is
    invisible to a name-matching check, and is left to review.
  - a non-ANSI module header, which cannot be parsed mechanically. Those are reported as
    UNRESOLVED, never silently skipped.
  - anything inside src/z486/, the pinned submodule.
Expected values are read out of the RTL itself, so this cannot drift from the design - it
compares a design against ITSELF, which is the only thing a port-list check can do.

Usage: tools/check_port_lists.py [root] [--all | FILE ...]
       (no argument = every file under src/ plus the top level, which is what --all
        spells out; a named FILE narrows it)
Exit 0 when no input is unconnected; 1 otherwise, naming module, instance and port.
"""
import os, re, sys, pathlib

def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    s = re.sub(r'//[^\n]*', ' ', s)
    return re.sub(r'"(\\.|[^"\\])*"', '""', s)

def split_top(body):
    out, d, cur = [], 0, ''
    for ch in body:
        if ch in '([{': d += 1
        elif ch in ')]}': d -= 1
        if ch == ',' and d == 0: out.append(cur); cur = ''
        else: cur += ch
    out.append(cur); return out

def name_of(decl):
    d = re.sub(r'\[[^\]]*\]', ' ', decl.split('=')[0])
    t = re.findall(r'[A-Za-z_]\w*', d)
    return t[-1] if t else None

def port_dirs(decl):
    """(name, direction) for an ANSI port declaration."""
    n = name_of(decl)
    if not n: return None
    d = decl.lower()
    for k in ('input', 'output', 'inout'):
        if re.search(r'\b' + k + r'\b', d):
            return (n, k)
    return None

# DIRECTORIES A MODULE MUST NEVER BE READ FROM. `module_ports` finds a module by NAME, and it
# searched root.rglob('*.sv') - which walks the fit's scratch tree and every lane checkout. On this
# machine those ALWAYS exist, and rglob reaches .build/quartus FIRST, so the checker parsed a
# SNAPSHOT of the module taken at some earlier build instead of the source it was being asked
# about. It then reported six ports as "connected but not a port" that were declared in the file it
# had been given, and the same mechanism could equally have produced a false PASS when a stale copy
# happened to declare more. A checker that can read a different file than the one under test is not
# checking the tree; scope it to the source.
# A `reference/` directory (third-party sources dropped in locally for comparison, e.g. other
# cores' SDRAM controllers) has module names that collide with ours (`sdram`): never the tree.
SKIP_DIRS = ('.build', '.worktrees', 'lanes', 'output_files', 'db', 'incremental_db', 'mister_deploy', '.git',
             '__pycache__', 'build', 'reference')


def in_source_tree(path: pathlib.Path, root: pathlib.Path) -> bool:
    try:
        rel = path.relative_to(root)
    except ValueError:
        return False
    return not any(part in SKIP_DIRS for part in rel.parts)


def source_files(root):
    """Every *.sv under root, pruning SKIP_DIRS during the walk (rglob would descend into every
    lane checkout and build tree first, which costs minutes)."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for fn in sorted(filenames):
            if fn.endswith('.sv'):
                yield pathlib.Path(dirpath) / fn


def module_ports(root, name):
    for f in source_files(root):
        if not in_source_tree(f, root):
            continue
        try: src = strip_comments(f.read_text(errors='ignore'))
        except Exception: continue
        for m in re.finditer(r'\bmodule\s+' + re.escape(name) + r'\b', src):
            i = m.end()
            def skip_ws(i):
                while i < len(src) and src[i] in ' \t\n': i += 1
                return i
            i = skip_ws(i)
            if i < len(src) and src[i] == '#':
                i = skip_ws(i + 1)
                if i < len(src) and src[i] == '(':
                    d = 0
                    while i < len(src):
                        if src[i] == '(': d += 1
                        elif src[i] == ')':
                            d -= 1
                            if d == 0: break
                        i += 1
                    i += 1
            i = skip_ws(i)
            if i >= len(src) or src[i] != '(': return None
            d = 0; st = i
            while i < len(src):
                if src[i] == '(': d += 1
                elif src[i] == ')':
                    d -= 1
                    if d == 0: break
                i += 1
            ports = [port_dirs(p) for p in split_top(src[st+1:i])]
            ports = [p for p in ports if p]
            if ports: return (str(f), ports)
    return None

RESERVED = set(('module endmodule if else for while case endcase begin end always assign initial '
                'function task localparam parameter wire reg integer generate endgenerate input '
                'output inout return default posedge negedge or and not xor').split())

def audit(root, target, verbose):
    src = strip_comments(target.read_text(errors='ignore'))
    pat = re.compile(r'\b([A-Za-z_]\w*)\s*(#\s*\([^;]*?\)\s*)?([A-Za-z_]\w*)\s*\(', re.S)
    errs, info, unres = [], [], []
    for m in pat.finditer(src):
        mod, inst = m.group(1), m.group(3)
        if mod in RESERVED: continue
        j = m.end() - 1; d = 0
        while j < len(src):
            if src[j] == '(': d += 1
            elif src[j] == ')':
                d -= 1
                if d == 0: break
            j += 1
        if not src[j+1:j+3].strip().startswith(';'): continue
        body = src[m.end():j]
        if '.' not in body: continue
        conns = set(re.findall(r'\.\s*([A-Za-z_]\w*)\s*\(', body))
        declared = module_ports(root, mod)
        if declared is None:
            unres.append((mod, inst)); continue
        dfile, ports = declared
        for pname, pdir in ports:
            if pname in conns: continue
            if pdir == 'input':
                errs.append((mod, inst, pname, dfile))
            else:
                info.append((mod, inst, pname, pdir))
        for c in sorted(conns):
            if c not in [p[0] for p in ports]:
                errs.append((mod, inst, c + ' (connected but not a port)', dfile))
    if verbose:
        for mod, inst, port, dfile in info:
            print("  info  %-26s %-20s unconnected OUTPUT %s" % (mod, inst, port))
        for mod, inst in unres:
            print("  ??    %-26s %-20s module not found / non-ANSI - NOT CHECKED" % (mod, inst))
    return errs, unres

def main():
    args = [a for a in sys.argv[1:]]
    # Anchored to the tool, not to the caller's cwd -- the reason check_route_pairs.py states
    # for the same choice: a relative root made a check read whatever happened to be in the
    # caller's directory, which is not the tree under test, and a check that only works from
    # one directory is a check that does not get run.
    root = pathlib.Path(__file__).resolve().parent.parent
    if args and not args[0].startswith('--'):
        p = pathlib.Path(args[0])
        if p.is_dir(): root = p.resolve(); args = args[1:]
    allf = '--all' in args
    args = [a for a in args if not a.startswith('--')]
    # THE WHOLE SOURCE TREE IS THE DEFAULT, and that is a correction rather than a
    # preference: the default used to be the top level alone, while
    # tests/pc9821/tb_pc9821_artic_watch.sv:17 "is two named ports in one file" says the
    # pc9821_system -> pc9821_perf_msg
    # `.dbg_artic_hi(artic_hi)` hop "is checked by tools/check_port_lists.py" -- and in
    # pc9821_system.sv, which the old default never read. A cited check that does not run
    # is the defect class this round is about, so the tool now audits what its citations
    # say it audits; a named FILE still narrows it for a single-file fix.
    if allf or not args:
        targets = sorted(set(list(root.glob('src/**/*.sv')) + list(root.glob('src/**/*.v')) +
                             list(root.glob('*.sv'))))
    else:
        targets = [pathlib.Path(a) for a in args]

    # A NAMED TARGET THAT DOES NOT EXIST IS A FAILURE, NOT A PASS. This loop used to
    # `continue` past a missing file and then print PASS with len(targets), so
    # `check_port_lists.py no-such-file.sv` reported "PASS ... (1 file(s))" having audited
    # nothing, and a typo in a filename read as a clean bill of health.
    missing = [str(t) for t in targets if not t.exists()]
    if missing:
        for m in missing:
            print("  FAIL  %s does not exist" % m)
        print()
        print("PORT LIST CHECK: FAIL - %d named file(s) do not exist" % len(missing))
        return 1
    total = 0
    audited = 0
    for t in targets:
        if 'z486/' in str(t): continue          # a pinned submodule, not ours to police
        errs, unres = audit(root, t, verbose=allf or len(targets) == 1)
        audited += 1
        for mod, inst, port, dfile in errs:
            print("  FAIL  %s:%s" % (t, 0))
            print("        %s instance %s in %s" % (mod, inst, pathlib.Path(dfile).name))
            print("        UNCONNECTED INPUT or bad port: %s" % port)
        total += len(errs)
    print()
    if total:
        print("PORT LIST CHECK: FAIL - %d unconnected input(s)/bad connection(s)" % total)
        return 1
    if not audited:
        # Every target was skipped, so a PASS here would be a claim about work that did not
        # happen. Refuse a verdict instead of giving a meaningless one.
        print("PORT LIST CHECK: FAIL - every target was skipped, so nothing was audited")
        return 1
    # Count what was AUDITED, not what was asked for: the two differ whenever a target is
    # skipped, and the number in a PASS line is a claim about work that was done.
    print("PORT LIST CHECK: PASS - no instantiation leaves an input undriven (%d file(s))" % audited)
    return 0

if __name__ == '__main__':
    sys.exit(main())

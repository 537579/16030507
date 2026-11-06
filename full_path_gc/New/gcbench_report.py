#!/usr/bin/env python3
"""Summarise gcbench CSV: median per (pattern, keep, mode) and on-vs-off deltas."""
import csv, statistics as st, sys
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1])))
def f(r, k):
    try: return float(r[k])
    except (ValueError, KeyError, TypeError): return None
g = defaultdict(list)
for r in rows: g[(r["pattern"], int(r["keep"]), r["mode"])].append(r)

def med(rs, fn):
    v = [x for x in map(fn, rs) if x is not None]
    return st.median(v) if v else None

def metrics(rs):
    blks = med(rs, lambda r: f(r, "moved_blks") or None) or med(rs, lambda r: f(r, "prep"))
    wall = med(rs, lambda r: f(r, "wall_ms"))
    cpu = med(rs, lambda r: f(r, "thread_cpu_ms"))
    sysc = med(rs, lambda r: f(r, "sys_cpu_ms"))
    cmds = med(rs, lambda r: f(r, "offload_cmds"))
    return dict(
        n=len(rs), blks=blks, wall=wall, cpu=cpu, sysc=sysc, cmds=cmds,
        mbs=(blks * 4 / 1024) / (wall / 1000) if blks and wall else None,
        cpu_us_blk=cpu * 1000 / blks if blks and cpu is not None else None,
        sys_us_blk=sysc * 1000 / blks if blks and sysc is not None else None,
        blk_cmd=blks / cmds if blks and cmds else None,
        fg99=med(rs, lambda r: f(r, "fg_p99_us")), fgops=med(rs, lambda r: f(r, "fg_ops")),
        bad=sum(int(float(r["bad"] or 0)) for r in rs) + sum(r["verify"] != "OK" for r in rs))

def d(a, b):  # change of on relative to off, %
    return f"{(a / b - 1) * 100:+.1f}%" if a is not None and b else "n/a"
def v(x, p=1): return "n/a" if x is None else f"{x:.{p}f}"

print("| pattern | valid/seg | mode | n | MB/s moved | wall ms | GC thread CPU us/blk | system CPU us/blk | blks/cmd | FG p99 us | integrity bad |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for key in sorted({(p, k) for p, k, _ in g}):
    m = {mode: metrics(g[(key[0], key[1], mode)]) for mode in ("off", "on") if g.get((key[0], key[1], mode))}
    for mode in ("off", "on"):
        if mode in m:
            x = m[mode]
            print(f"| {key[0]} | {key[1]} | {mode} | {x['n']} | {v(x['mbs'])} | {v(x['wall'],0)} | {v(x['cpu_us_blk'],2)} | {v(x['sys_us_blk'],2)} | {v(x['blk_cmd'],0)} | {v(x['fg99'],0)} | {x['bad']} |")
    if len(m) == 2:
        o, n = m["off"], m["on"]
        print(f"| | | **on vs off** | | {d(n['mbs'], o['mbs'])} | {d(n['wall'], o['wall'])} | {d(n['cpu_us_blk'], o['cpu_us_blk'])} | {d(n['sys_us_blk'], o['sys_us_blk'])} | | {d(n['fg99'], o['fg99'])} | |")

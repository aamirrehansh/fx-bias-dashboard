#!/usr/bin/env python3
"""Append the weekly MT5 'recent' D1 export (Common\\Files\\FXDaily\\recent) to the 10-year master CSVs.
Usage: append_recent.py <recent_dir> [master_dir]. New dates are added; overlapping dates take the newer value."""
import glob, os, sys, csv
rec = sys.argv[1]
mst = sys.argv[2] if len(sys.argv) > 2 else "/mnt/project-files/data/fx_daily_mt5"
for f in sorted(glob.glob(os.path.join(rec, "*_D1.csv"))):
    m = os.path.join(mst, os.path.basename(f))
    rows = {}
    for src in (m, f):
        if os.path.exists(src):
            for r in csv.DictReader(open(src, newline="")):
                rows[r["date"]] = r
    keys = sorted(rows)
    before = sum(1 for _ in open(m)) - 1 if os.path.exists(m) else 0
    with open(m, "w", newline="") as o:
        w = csv.DictWriter(o, fieldnames=["date", "open", "high", "low", "close", "tick_volume"], lineterminator="\r\n")
        w.writeheader()
        for k in keys:
            w.writerow({x: rows[k][x] for x in w.fieldnames})
    print(os.path.basename(f), "bars", before, "->", len(keys), "last", keys[-1])

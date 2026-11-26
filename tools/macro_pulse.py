#!/usr/bin/env python3
"""Twice-daily BabyPips macro pulse: patch data/weeks.js and data/plan.csv in place (no workbook rebuild).

Usage: python3 tools/macro_pulse.py [week_id]   (default: last week in weeks.js)
Reads data/pulse/babypips_<week>.csv (daily recap scoreboards) and data/pulse/babypips_notes_<week>.csv
(policy notes from later BabyPips news), recomputes the week's macro pulse, replaces the previous
macro-pulse snapshot in the week's updates, and rewrites the Macro column of plan.csv's C rows
(the MT5 monitor re-downloads plan.csv hourly, so its live strength picks it up).
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract_weeks import ROOT, compute_macro_pulse, rescore_macro

WJS = os.path.join(ROOT, "data/weeks.js")
PLAN = os.path.join(ROOT, "data/plan.csv")
PFX = "window.FXDATA="


def main(wid=None):
    raw = open(WJS, encoding="utf-8").read().strip()
    data = json.loads(raw[len(PFX):].rstrip(";"))
    w = [x for x in data["weeks"] if x["id"] == wid][0] if wid else [x for x in data["weeks"] if not x.get("missing")][-1]
    rc = os.path.join(ROOT, "data/pulse/babypips_%s.csv" % w["id"])
    nt = "data/pulse/babypips_notes_%s.csv" % w["id"]
    mp = compute_macro_pulse(w, rc, nt)
    ups = [u for u in w.get("updates", []) if not u.get("macroPulse")]
    prev = sorted(ups, key=lambda u: u["at"])[-1] if ups else None
    if prev and mp["at"] and prev["at"] > mp["at"]:
        mp["at"] = prev["at"]
    w["macroPulse"] = mp
    if mp["at"]:
        ups.append(rescore_macro(w, prev, mp, "Macro pulse from BabyPips (%s)." % mp["at"][:16].replace("T", " ")))
    w["updates"] = ups
    with open(WJS, "w", encoding="utf-8") as f:
        f.write(PFX + json.dumps(data, ensure_ascii=False, separators=(",", ":"), default=str) + ";\n")
    # plan.csv C rows: C,ccy,fund,cot,seas,news,macro,strength
    mm = {r["ccy"]: r["macro"] for r in mp["rows"]}
    lines = open(PLAN, encoding="utf-8").read().splitlines()
    if lines and lines[0].split(",")[1] == w["id"]:
        for i, ln in enumerate(lines):
            p = ln.split(",")
            if p[0] == "C" and p[1] in mm:
                p[6] = "%.6g" % mm[p[1]]
                lines[i] = ",".join(p)
        open(PLAN, "w", newline="\n", encoding="utf-8").write("\n".join(lines) + "\n")
    for r in mp["rows"]:
        print("%s Sunday %+g  days %s  -> %+g (factor %+g)" % (r["ccy"], r["sunday"], r["days"], r["adjRaw"], r["macro"]))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else None)

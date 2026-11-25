#!/usr/bin/env python3
"""Build dashboard data (app/data/weeks.json) from the weekly model workbooks.

Usage: python3 extract_weeks.py  (paths below; recalculated copies are used where the
original has no cached values). Re-run each Sunday after the new Final_Weekly_Model file
is saved, then publish the app folder.
"""
import json, os, re, sys, datetime as dt
import openpyxl

PF = "/mnt/project-files"
CALC = os.environ.get("CALC_DIR", "")  # folder with LibreOffice-recalculated copies
CCYS = ["USD", "EUR", "GBP", "JPY", "CHF", "CAD", "AUD", "NZD"]

# (week id = Monday, label, file, kind, extra)
WEEKS = [
    ("2026-10-19", "19–23 Oct 2026", "Option2_Weighted_WoW_Model_Latest_Conditional_Revised_19-23_Oct_2026.xlsx", "opt2", {}),
    ("2026-10-26", "26–30 Oct 2026", None, "missing", {}),
    ("2026-11-02", "2–6 Nov 2026", "Final_Weekly_Model_2-6_Nov_2026.xlsx", "final", {}),
    ("2026-11-09", "9–13 Nov 2026", "Final_Weekly_Model_9-13_Nov_2026.xlsx", "final", {}),
    ("2026-11-16", "16–20 Nov 2026", "Final_Weekly_Model_16-20_Nov_2026.xlsx", "final", {"calc": "f1620.xlsx"}),
    ("2026-11-23", "23–27 Nov 2026", "Final_Weekly_Model_23-27_Nov_2026.xlsx", "final",
     {"updates": [("2026-11-25T12:00:00Z", "u25.xlsx", "News actuals re-scored 25-Nov ~17:00 PKT (US Core PCE/GDP not out yet). Gate unchanged from 22-Nov.")]}),
]


def rows(ws):
    return [list(r) for r in ws.iter_rows(values_only=True)]


def find_header(rs, first):
    for i, r in enumerate(rs):
        if r and isinstance(r[0], str) and r[0].strip() == first:
            return i
    return None


def table(ws, first="Currency", stop_on_blank=True):
    rs = rows(ws)
    h = find_header(rs, first)
    if h is None:
        return [], []
    hdr = [str(c).strip() if c is not None else "" for c in rs[h]]
    out = []
    for r in rs[h + 1:]:
        if r[0] is None:
            if stop_on_blank:
                break
            continue
        out.append(dict(zip(hdr, r)))
    return hdr, out


def num(v):
    if v is None or v == "" or v == "-":
        return None
    try:
        return round(float(v), 6)
    except (TypeError, ValueError):
        return None


def first_note(ws, row=2):
    v = ws.cell(row=row, column=1).value
    return v if isinstance(v, str) else ""


def pct_or_frac(v):
    """risk stored as fraction (0.01) in Final files, percent (1) in Option2."""
    n = num(v)
    return n


def load(path, calc=None):
    p = os.path.join(CALC, calc) if (calc and CALC and os.path.exists(os.path.join(CALC, calc))) else path
    return openpyxl.load_workbook(p, data_only=True)


def status_tier(s):
    s = (s or "").upper()
    if s.startswith("TRADE"):
        return "TRADE"
    if s.startswith("RESERVE"):
        return "RESERVE"
    if s.startswith("WATCH"):
        return "WATCH"
    return "NO"


def extract_final(wb):
    w = {}
    # currency model
    _, cm = table(wb["Currency Model"])
    cur = {}
    for r in cm:
        c = r.get("Currency")
        if c in CCYS:
            cur[c] = {"ccy": c, "fund": num(r.get("Fundamental")), "cot": num(r.get("COT")),
                      "seas": num(r.get("Seasonality")), "news": num(r.get("News")),
                      "macro": num(r.get("Macro")), "strength": num(r.get("Strength")),
                      "rank": num(r.get("Rank"))}
    # weights row
    for r in rows(wb["Currency Model"]):
        if r and r[0] == "Weight":
            w = {"fund": r[1], "cot": r[2], "seas": r[3], "news": r[4], "macro": r[5]}
    # fundamental
    fs = wb["Fundamental"]
    _, fr = table(fs)
    for r in fr:
        c = r.get("Currency")
        if c not in cur:
            continue
        ln = r.get("Latest net (curr)", r.get("Latest net Δ"))
        cn = r.get("Cond net (curr)", r.get("Cond net Δ"))
        cur[c].update({
            "investPrev": num(r.get("Prev Invest")), "investCurr": num(r.get("Curr Invest")),
            "investChg": num(r.get("Invest change")), "investStrength": num(r.get("Strength")),
            "latestPlus": num(r.get("Curr Latest+")), "latestMinus": num(r.get("Curr Latest−")),
            "condPlus": num(r.get("Curr Cond+")), "condMinus": num(r.get("Curr Cond−")),
            "latestNet": num(ln), "condNet": num(cn),
            "latestState": r.get("Latest state"), "condState": r.get("Cond state"),
            "fundBias": r.get("Bias"),
        })
    # COT
    cs = wb["COT"]
    hdr, cr = table(cs)
    nc = [h for h in hdr if h.startswith("Net NC")]
    cotDates = [h.replace("Net NC", "").strip() for h in nc]
    for r in cr:
        c = r.get("Currency")
        if c not in cur:
            continue
        cur[c].update({
            "cotPrev": num(r.get(nc[0])) if nc else None, "cotCurr": num(r.get(nc[1])) if len(nc) > 1 else None,
            "cotChg": num(r.get("Weekly change")), "cotDir": r.get("Direction"),
            "rsi52": num(r.get("COT RSI 52")), "rsi26": num(r.get("COT RSI 26")), "rsi13": num(r.get("COT RSI 13")),
            "rsiExtreme": r.get("RSI extreme"), "cotReversal": r.get("Reversal signal"),
        })
    # seasonality
    _, sr = table(wb["Seasonality"])
    for r in sr:
        c = r.get("Currency")
        if c in cur:
            cur[c].update({"seas1": num(r.get("Score 1")), "seas2": num(r.get("Score 2"))})
    # macro
    _, mr = table(wb["Macro"])
    for r in mr:
        c = r.get("Currency")
        if c in cur:
            cur[c].update({"macroRaw": num(r.get("Macro score (−2 to +2)")), "macroWhy": r.get("Rationale") or ""})
    # dashboard pairs
    ds = wb["Dashboard"]
    drs = rows(ds)
    h = find_header(drs, "Rank")
    hdr = [str(c).strip() if c is not None else "" for c in drs[h]]
    pairs = []
    for r in drs[h + 1:]:
        if not isinstance(r[0], (int, float)):
            break
        d = dict(zip(hdr, r))
        gate = d.get("Gate (Dow Fib D1+H1)", d.get("Gate"))
        timing = d.get("Timing / SL") or (r[13] if len(r) > 13 else None)
        pairs.append({"rank": int(d["Rank"]), "pair": d["Pair"], "bias": d["Bias"], "score": num(d["Pair score"]),
                      "elig": d.get("Eligibility"), "gate": gate, "risk": num(d.get("Final risk")),
                      "status": d.get("Status"), "tier": status_tier(d.get("Status")),
                      "timing": timing if isinstance(timing, str) else ""})
    notes = [first_note(ds, 2)]
    for r in drs:
        if r and isinstance(r[0], str) and (r[0].startswith("Event risk") or r[0].startswith("Gate =")):
            notes.append(r[0])
    # pair rankings: base/quote + fund diff + D1/H1
    _, pr = table(wb["Pair Rankings"], "Pair")
    pinfo = {r["Pair"]: r for r in pr}
    for p in pairs:
        r = pinfo.get(p["pair"], {})
        p.update({"base": p["pair"][:3], "quote": p["pair"][3:], "fundDiff": num(r.get("Fund. diff")),
                  "d1": r.get("D1"), "h1": r.get("H1"), "h4": r.get("H4")})
    # technicals (Dow Fib layout or EMA layout)
    tech = {}
    ts = wb["Technicals"]
    thdr, tr = table(ts, "Pair")
    for r in tr:
        if not isinstance(r.get("Pair"), str) or len(r["Pair"]) != 6:
            continue
        if "D1 Dow Trend" in thdr:
            tech[r["Pair"]] = {"d1": r.get("D1 Dow Trend"), "d1Fail": num(r.get("D1 trend-fails")),
                               "d1Pend": num(r.get("D1 Pending %")), "h1": r.get("H1 Dow Trend"),
                               "h1Fail": num(r.get("H1 trend-fails")), "h1Pend": num(r.get("H1 Pending %")),
                               "close": num(r.get("Close"))}
        else:
            tech[r["Pair"]] = {"d1": r.get("D1 Trend"), "h4": r.get("H4 Trend"), "h1": r.get("H1 Trend"),
                               "close": num(r.get("D1 Close"))}
    for p in pairs:
        t = tech.get(p["pair"])
        if t:
            p["tech"] = t
    # news
    ns = wb["News"]
    nrs = rows(ns)
    h = find_header(nrs, "Date")
    nh = [str(c).strip() if c is not None else "" for c in nrs[h]]
    news = []
    for r in nrs[h + 1:]:
        if r[0] is None:
            if r[4] is None:
                continue
        if isinstance(r[0], str) and r[0].startswith("Currency news"):
            break
        if r[0] is None:
            continue
        d = dict(zip(nh, r))
        dv = d.get("Date")
        if isinstance(dv, dt.datetime):
            dv = dv.date().isoformat()
        news.append({"date": str(dv), "time": d.get("Time (PKT)"), "ccy": d.get("Currency"), "impact": d.get("Impact"),
                     "event": d.get("Event"), "forecast": num(d.get("Forecast")), "previous": num(d.get("Previous")),
                     "actual": num(d.get("Actual")), "polarity": num(d.get("Polarity")), "weight": num(d.get("Weight")),
                     "score": num(d.get("Event score"))})
    # caution list
    caution = []
    h2 = None
    for i, r in enumerate(nrs):
        if r and isinstance(r[0], str) and r[0].startswith("Not scored"):
            h2 = i + 2
    if h2:
        for r in nrs[h2:]:
            if r[0] is None:
                break
            dv = r[0].date().isoformat() if isinstance(r[0], dt.datetime) else str(r[0])
            caution.append({"date": dv, "ccy": r[1], "impact": r[2], "event": r[3]})
    src = {"fundamental": first_note(fs), "cot": first_note(cs), "news": first_note(ns, 2),
           "macro": first_note(wb["Macro"]), "tech": first_note(ts), "cotDates": cotDates}
    return {"weights": w, "currencies": [cur[c] for c in CCYS if c in cur], "pairs": pairs,
            "news": news, "caution": caution, "notes": [n for n in notes if n], "sources": src}


def extract_opt2(wb):
    cur = {}
    _, cm = table(wb["Currency Model"])
    for r in cm:
        c = r.get("Currency")
        if c in CCYS:
            cur[c] = {"ccy": c, "fund": num(r.get("Fundamental factor")), "cot": num(r.get("COT")),
                      "seas": num(r.get("Seasonality")), "news": num(r.get("News")), "macro": num(r.get("Macro")),
                      "strength": num(r.get("Final strength")), "fundBias": r.get("Fundamental bias")}
    order = sorted(cur.values(), key=lambda x: -(x["strength"] or 0))
    for i, c in enumerate(order):
        c["rank"] = i + 1
    _, fr = table(wb["Weekly Log"])
    for r in fr:
        c = r.get("Currency")
        if c in cur:
            cur[c].update({"investPrev": num(r.get("Previous Invest")), "investCurr": num(r.get("Current Invest")),
                           "investChg": (num(r.get("Current Invest")) or 0) - (num(r.get("Previous Invest")) or 0),
                           "latestPlus": num(r.get("Curr Latest+")), "latestMinus": num(r.get("Curr Latest-")),
                           "condPlus": num(r.get("Curr Cond+")), "condMinus": num(r.get("Curr Cond-")),
                           "latestNet": (num(r.get("Curr Latest+")) or 0) - (num(r.get("Curr Latest-")) or 0),
                           "condNet": (num(r.get("Curr Cond+")) or 0) - (num(r.get("Curr Cond-")) or 0)})
    _, sr = table(wb["Seasonality"])
    for r in sr:
        c = r.get("Currency")
        if c in cur:
            cur[c].update({"seas1": num(r.get("Score 1")), "seas2": num(r.get("Score 2"))})
    _, mr = table(wb["Macro Overlay"])
    for r in mr:
        c = r.get("Currency")
        if c in cur:
            cur[c].update({"macroRaw": num(r.get("Score")), "macroWhy": r.get("Rationale") or ""})
    _, pr = table(wb["Pair Rankings"], "Rank")
    dash = {r[1]: r for r in rows(wb["Dashboard"])[3:] if r and isinstance(r[0], (int, float))}
    pairs = []
    for r in pr:
        g = r.get("Technical gate") or ""
        risk = num(r.get("Risk")) or 0
        tier = "TRADE" if r["Pair"] in dash and risk > 0 else ("NO")
        pairs.append({"rank": int(r["Rank"]), "pair": r["Pair"], "base": r["Pair"][:3], "quote": r["Pair"][3:],
                      "bias": r["Bias"], "score": num(r.get("Final score")), "elig": r.get("Model eligible"),
                      "fundDiff": num(r.get("Fundamental differential")), "gate": g, "risk": risk / 100.0,
                      "status": "TRADE" if tier == "TRADE" else ("NO (gate)" if g.startswith("REJECT") else "NO"),
                      "tier": tier, "timing": ""})
    notes = [first_note(wb["Dashboard"]), first_note(wb["Currency Model"]),
             "Pre-merge week: Option 2 shown as the model of record. Option 1 (Top Setups) picks: GBPCHF sell, CHFJPY buy, EURAUD buy, EURJPY buy."]
    w = {"fund": 0.393125, "cot": 0.235875, "seas": 0.15725, "news": 0.13875, "macro": 0.075}
    return {"weights": w, "currencies": [cur[c] for c in CCYS if c in cur], "pairs": pairs, "news": [], "caution": [],
            "notes": notes, "sources": {"cot": first_note(wb["COT"])}}


def monday_to_friday(mid):
    d = dt.date.fromisoformat(mid)
    return (d + dt.timedelta(days=4)).isoformat()


def write_plan(weeks, path):
    """plan.csv for the MT5 FX Bias Monitor EA: latest non-missing week, Sunday plan values."""
    w = [x for x in weeks if not x.get("missing")][-1]
    clean = lambda v: re.sub(r"[,\r\n]+", " ", str(v if v is not None else "")).strip()
    n = lambda v: "" if v is None else ("%.6g" % v)
    L = ["WEEK,%s,%s,%s" % (w["id"], w["end"], clean(w["label"]))]
    wt = w["weights"]
    L.append("W,%s,%s,%s,%s,%s" % tuple(n(wt[k]) for k in ("fund", "cot", "seas", "news", "macro")))
    for c in w["currencies"]:
        L.append("C,%s,%s,%s,%s,%s,%s,%s" % (c["ccy"], n(c["fund"]), n(c["cot"]), n(c["seas"]), n(c["news"]), n(c["macro"]), n(c["strength"])))
    for e in w.get("news", []):
        if e.get("weight") is None or e.get("ccy") is None:
            continue
        L.append("N,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s" % (e["date"], clean(e["time"]), e["ccy"], clean(e["impact"]), n(e["polarity"]), n(e["weight"]),
                                                    n(e["forecast"]), n(e["previous"]), n(e["score"]), clean(e["event"])))
    for p in w["pairs"]:
        t = p.get("tech") or {}
        L.append("P,%s,%s,%s,%s,%s,%s,%s" % (p["pair"], p["bias"], p["tier"], n(p["score"]), n(p.get("risk") or 0), n(t.get("d1Fail")), n(t.get("h1Fail"))))
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(L) + "\n")
    print("wrote", path, w["id"])


def main(out):
    weeks = []
    for wid, label, fn, kind, extra in WEEKS:
        base = {"id": wid, "label": label, "start": wid, "end": monday_to_friday(wid), "kind": kind}
        if kind == "missing":
            base.update({"missing": True, "notes": ["No model file was saved for this week. The EA ran FX28 V3.00 (NZD sells + GBPNZD buy) — see reports/FX28_Weekly_Performance_26-30_Oct.html."],
                         "currencies": [], "pairs": [], "news": []})
            weeks.append(base)
            continue
        wb = load(os.path.join(PF, fn), extra.get("calc"))
        body = extract_opt2(wb) if kind == "opt2" else extract_final(wb)
        base.update(body)
        base["file"] = fn
        ups = []
        for ts, cfile, note in extra.get("updates", []):
            p = os.path.join(CALC, cfile)
            if os.path.exists(p):
                b = extract_final(openpyxl.load_workbook(p, data_only=True))
                ups.append({"at": ts, "note": note, "currencies": [{k: c[k] for k in ("ccy", "fund", "cot", "seas", "news", "macro", "strength", "rank")} for c in b["currencies"]],
                            "pairs": [{"pair": x["pair"], "bias": x["bias"], "score": x["score"]} for x in b["pairs"]],
                            "news": b["news"]})
        base["updates"] = ups
        weeks.append(base)
    write_plan(weeks, os.path.join(os.path.dirname(out), "plan.csv"))
    data = {"generated": dt.datetime.utcnow().replace(microsecond=0).isoformat() + "Z", "ccys": CCYS, "weeks": weeks}
    with open(out, "w") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"), default=str)
    print("wrote", out, len(weeks), "weeks")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(PF, "dashboard/app/data/weeks.json"))

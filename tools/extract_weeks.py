#!/usr/bin/env python3
"""Build dashboard data (app/data/weeks.json) from the weekly model workbooks.

Usage: python3 extract_weeks.py  (paths below; recalculated copies are used where the
original has no cached values). Re-run each Sunday after the new Final_Weekly_Model file
is saved, then publish the app folder.
"""
import json, os, re, sys, datetime as dt
import openpyxl

PF = "/mnt/project-files"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root (data/pulse/...)
FUND_KEYS = ["db", "t1", "t2", "t3", "s1", "s2", "s3", "s4", "m1", "m2", "m3", "m4", "m5", "m6", "sn", "boost", "fs", "fo", "cap"]
FUND_CELLS = [11, 12, 13, 14, 15, 16, 17, 18, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31]  # Settings!B<row>
FUND_DEFAULT = dict(zip(FUND_KEYS, [2, 10, 25, 50, .25, .5, .75, 1, 1, .75, .5, .5, .25, 0, 3, .25, .25, .125, .375]))
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
     {"updates": [("2026-11-25T12:00:00Z", "u25.xlsx", "News actuals re-scored 25-Nov ~17:00 PKT (US Core PCE/GDP not out yet). Gate unchanged from 22-Nov.", 20)],
      "actuals": [("2026-11-25T13:40:00Z", "data/2026-11-25/actuals_ff.csv", "Forex Factory actuals incl. US 18:30 PKT releases (Core PCE, GDP, claims, durables, income/spending).")],
      "tracked": "data/pulse/tracked_2026-11-22.csv",
      "pulse": [("2026-11-25T15:10:00Z", "data/pulse/ff_2026-11-23.csv", "Investogenie Pulse: Conditional +/- updated from Forex Factory releases Mon-Wed (actual vs previous, tracked events); news actuals as of 18:30 PKT.",
                 "data/2026-11-25/actuals_ff.csv")],
      "macro": ("data/pulse/babypips_2026-11-23.csv", "data/pulse/babypips_notes_2026-11-23.csv")}),
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
    if "Settings" in wb.sheetnames:
        mw = wb["Settings"]["B41"].value
        if isinstance(mw, (int, float)):
            w["newsMinW"] = mw  # News score = sum / MAX(total weight, this)
        fsv = {k: wb["Settings"]["B%d" % r].value for k, r in zip(FUND_KEYS, FUND_CELLS)}
        if all(isinstance(v, (int, float)) for v in fsv.values()):
            w["fundSet"] = fsv  # Fundamental sheet thresholds / multipliers
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


def rescore_from_actuals(week, path, ts, note, fund=None):
    """Re-score News from a CSV of released actuals (date,ccy,event_starts,actual,forecast) and
    rebuild currency strength / pair scores exactly like the workbook (sum / MAX(weight, Settings B41))."""
    import csv
    acts = list(csv.DictReader(open(path)))
    news = [dict(n) for n in week.get("news", [])]
    for n in news:
        n["actual"] = None
        for a in acts:
            if a["date"] == n["date"] and a["ccy"] == n["ccy"] and str(n["event"]).startswith(a["event_starts"]):
                act, fc = float(a["actual"]), float(a["forecast"])
                n["actual"], n["forecast"] = act, fc
                d = act - fc
                n["score"] = (0 if d == 0 else (1 if d > 0 else -1)) * (n["polarity"] or 1) * (n["weight"] or 0.5)
                break
    minw = week["weights"].get("newsMinW", 2) or 2
    wt = week["weights"]
    cur = []
    for c0 in week["currencies"]:
        c = dict(c0)
        if fund and c["ccy"] in fund:
            c["fund"] = fund[c["ccy"]]
        rows = [n for n in news if n["ccy"] == c["ccy"] and n.get("weight") is not None]
        sw = sum(n["weight"] for n in rows)
        ns = sum(n["score"] or 0 for n in rows) / max(sw, minw)
        st = 100 * (wt["fund"] * c["fund"] + wt["cot"] * c["cot"] + wt["seas"] * c["seas"] + wt["news"] * ns + wt["macro"] * c["macro"])
        cur.append({"ccy": c["ccy"], "fund": c["fund"], "cot": c["cot"], "seas": c["seas"], "news": round(ns, 6), "macro": c["macro"], "strength": round(st, 6)})
    order = sorted(cur, key=lambda x: -x["strength"])
    for i, c in enumerate(order):
        c["rank"] = i + 1
    smap = {c["ccy"]: c["strength"] for c in cur}
    pairs = [{"pair": p["pair"], "score": round(smap[p["pair"][:3]] - smap[p["pair"][3:]], 6),
              "bias": "BUY" if smap[p["pair"][:3]] - smap[p["pair"][3:]] >= 0 else "SELL"} for p in week["pairs"]]
    return {"at": ts, "note": note, "currencies": cur, "pairs": pairs, "news": news}


def sgn(v):
    return (v > 0) - (v < 0)


def fund_score(L, O, P, S):
    """Fundamental sheet column Y: Investogenie change L, Latest net O, Conditional net P."""
    L, O, P = L or 0, O or 0, P or 0
    M = 0 if abs(L) < S["db"] else sgn(L)
    N = 0 if abs(L) < S["db"] else S["s1"] if abs(L) < S["t1"] else S["s2"] if abs(L) < S["t2"] else S["s3"] if abs(L) < S["t3"] else S["s4"]
    st = lambda n: "n/a" if M == 0 else "FLAT" if n == 0 else ("CONFIRM" if sgn(n) == M else "OPPOSE")
    Q, R = st(O), st(P)
    C, Op = (Q == "CONFIRM") + (R == "CONFIRM"), (Q == "OPPOSE") + (R == "OPPOSE")
    U = 0 if M == 0 else S["m1"] if C == 2 else S["m2"] if (C == 1 and Op == 0) else S["m3"] if (C == 1 and Op == 1) else S["m4"] if (C == 0 and Op == 0) else S["m5"] if (C == 0 and Op == 1) else S["m6"]
    V = S["boost"] if ((Q == "CONFIRM" and abs(O) >= S["sn"]) or (R == "CONFIRM" and abs(P) >= S["sn"])) else 0
    if M != 0:
        return M * N * min(1, U + V), R
    if sgn(O) * sgn(P) < 0:
        return 0, R
    base = S["fs"] if (O != 0 and P != 0) else S["fo"] if (O != 0 or P != 0) else 0
    return sgn(O + P) * min(S["cap"], base * (2 if (abs(O) >= S["sn"] or abs(P) >= S["sn"]) else 1)), R


def tracked_events(path):
    """Sarmaaya Conditional Scoring > Forex Currency Data event list (+ extra_events.csv). {(ccy, name lower): polarity}"""
    import csv
    out = {}
    for f in (path, os.path.join(ROOT, "data/pulse/extra_events.csv")):
        if f and os.path.exists(f):
            for r in csv.DictReader(open(f), delimiter="|"):
                out[(r["ccy"], r["event"].strip().lower())] = (-1 if r["pol"] == "L" else 1, r["event"].strip())
    return out


def ff_value(s):
    s = (s or "").strip().replace(",", "")
    if not s:
        return None
    mult = {"K": 1e3, "M": 1e6, "B": 1e9, "T": 1e12}.get(s[-1], 1)
    try:
        return float(s.rstrip("%KMBT")) * mult
    except ValueError:
        return None


def compute_pulse(week, ff_csv, tracked, asof=None):
    """Investogenie Pulse: Sunday Conditional +/- plus each tracked release this week scored actual vs previous
    (+ above, - below, tie ignored, flipped for unemployment/claims). Day = PKT date (UTC+5)."""
    import csv
    start = dt.datetime.fromisoformat(week["id"]) - dt.timedelta(hours=5)  # Monday 00:00 PKT in UTC
    days = {c["ccy"]: [[0, 0] for _ in range(5)] for c in week["currencies"]}
    newm = {c["ccy"]: [0, 0] for c in week["currencies"]}  # releases after the month turned (Conditional resets on the 1st)
    now = dt.datetime.fromisoformat(asof.rstrip("Z")) if asof else dt.datetime.utcnow()
    month_turned = (now + dt.timedelta(hours=5)).strftime("%Y-%m") != week["id"][:7]
    evs = []
    for r in csv.DictReader(open(ff_csv), delimiter="|"):
        k = (r["ccy"], r["event"].strip().lower())
        t = dt.datetime.fromisoformat(r["utc"])
        if k not in tracked or r["ccy"] not in days or t < start:
            continue
        a, p = ff_value(r["actual"]), ff_value(r["previous"])
        if a is None or p is None:
            continue
        sg_ = sgn(a - p) * tracked[k][0]
        d = (t - start).days
        if d > 4:
            continue
        if sg_ > 0:
            days[r["ccy"]][d][0] += 1
        elif sg_ < 0:
            days[r["ccy"]][d][1] += 1
        if (t + dt.timedelta(hours=5)).strftime("%Y-%m") != week["id"][:7] and sg_:
            newm[r["ccy"]][0 if sg_ > 0 else 1] += 1
        evs.append({"utc": r["utc"] + "Z", "day": d, "ccy": r["ccy"], "event": r["event"], "actual": r["actual"], "previous": r["previous"], "sign": sg_})
    S = week["weights"].get("fundSet") or FUND_DEFAULT
    rows = []
    for c in week["currencies"]:
        pp, pm = int(c.get("condPlus") or 0), int(c.get("condMinus") or 0)
        dp, dm = sum(x[0] for x in days[c["ccy"]]), sum(x[1] for x in days[c["ccy"]])
        plus, minus = (newm[c["ccy"]][0], newm[c["ccy"]][1]) if month_turned else (pp + dp, pm + dm)
        lastPct = 100.0 * pp / (pp + pm) if pp + pm else None
        curPct = 100.0 * plus / (plus + minus) if plus + minus else None
        gain = (curPct / lastPct - 1) * 100 if (lastPct and curPct is not None) else None
        f0, st0 = fund_score(c.get("investChg"), c.get("latestNet"), pp - pm, S)
        f1, st1 = fund_score(c.get("investChg"), c.get("latestNet"), plus - minus, S)
        rows.append({"ccy": c["ccy"], "prevPlus": pp, "prevMinus": pm, "days": days[c["ccy"]], "plus": plus, "minus": minus,
                     "lastPct": lastPct, "curPct": curPct, "gain": gain, "condStatePrev": st0, "condState": st1,
                     "fundPlan": c["fund"], "fundCalc": round(f0, 6), "fund": round(f1, 6)})
    return {"rows": rows, "events": evs}


MACRO_STEP = 0.5     # each daily +1/-1 moves the -2..+2 Macro score by this much
MACRO_NOISE = 0.15   # % move vs the 8-currency average needed to count


def compute_macro_pulse(week, recap_csv, notes_csv):
    """Macro pulse from the free BabyPips daily recap (and policy notes from later BabyPips news).
    Each recap: every currency's day move vs USD from the scoreboard, minus the 8-currency average.
    Top 2 = +1, bottom 2 = -1 (only if beyond MACRO_NOISE). Notes rows add their own +/-1.
    Adjusted Macro = clamp(Sunday score + MACRO_STEP x sum, -2, +2); model factor = adjusted / 2."""
    import csv
    inv = {"USDJPY": "JPY", "USDCHF": "CHF", "USDCAD": "CAD"}
    days = {c["ccy"]: [0] * 5 for c in week["currencies"]}
    entries, last = [], None
    for r in csv.DictReader(open(recap_csv), delimiter="|"):
        mv = {"USD": 0.0}
        for k in ("EURUSD", "GBPUSD", "AUDUSD", "NZDUSD", "USDJPY", "USDCHF", "USDCAD"):
            v = float(r[k])
            if k in inv:
                mv[inv[k]] = -v
            else:
                mv[k[:3]] = v
        avg = sum(mv.values()) / len(mv)
        rel = {c: round(v - avg, 3) for c, v in mv.items()}
        order = sorted(rel, key=lambda c: -rel[c])
        d = int(r["day"])
        sc = {}
        for c in order[:2]:
            if rel[c] >= MACRO_NOISE:
                sc[c] = 1
        for c in order[-2:]:
            if rel[c] <= -MACRO_NOISE:
                sc[c] = -1
        for c, v in sc.items():
            days[c][d] += v
        entries.append({"utc": r["utc"] + ":00Z", "day": d, "kind": "recap", "url": r["url"], "rel": rel, "score": sc, "drivers": r["drivers"]})
        last = r["utc"] + ":00Z"
    if notes_csv and os.path.exists(os.path.join(ROOT, notes_csv)):
        start = dt.datetime.fromisoformat(week["id"]) - dt.timedelta(hours=5)
        for r in csv.DictReader(open(os.path.join(ROOT, notes_csv)), delimiter="|"):
            t = dt.datetime.fromisoformat(r["utc"])
            d = min(4, max(0, (t - start).days))
            v = int(r["delta"])
            days[r["ccy"]][d] += v
            entries.append({"utc": r["utc"] + ":00Z", "day": d, "kind": "news", "url": r["url"], "score": {r["ccy"]: v}, "drivers": r["note"]})
            last = max(last or "", r["utc"] + ":00Z")
    rows = []
    for c in week["currencies"]:
        base = c.get("macroRaw") or 0
        net = sum(days[c["ccy"]])
        adj = max(-2.0, min(2.0, base + MACRO_STEP * net))
        rows.append({"ccy": c["ccy"], "sunday": base, "days": days[c["ccy"]], "net": net, "adjRaw": adj, "macroPlan": c["macro"], "macro": adj / 2})
    return {"at": last, "rows": rows, "entries": entries, "step": MACRO_STEP, "noise": MACRO_NOISE}


def rescore_macro(week, prev, mp, note):
    """New snapshot = latest snapshot's Fund/COT/Seas/News with the macro pulse's Macro factor."""
    wt = week["weights"]
    mm = {r["ccy"]: r["macro"] for r in mp["rows"]}
    src = {c["ccy"]: c for c in (prev["currencies"] if prev else week["currencies"])}
    cur = []
    for c0 in week["currencies"]:
        c = dict(src.get(c0["ccy"], c0))
        c["macro"] = mm[c0["ccy"]]
        st = 100 * (wt["fund"] * c["fund"] + wt["cot"] * c["cot"] + wt["seas"] * c["seas"] + wt["news"] * c["news"] + wt["macro"] * c["macro"])
        cur.append({"ccy": c0["ccy"], "fund": c["fund"], "cot": c["cot"], "seas": c["seas"], "news": c["news"], "macro": c["macro"], "strength": round(st, 6)})
    for i, c in enumerate(sorted(cur, key=lambda x: -x["strength"])):
        c["rank"] = i + 1
    smap = {c["ccy"]: c["strength"] for c in cur}
    pairs = [{"pair": p["pair"], "score": round(smap[p["pair"][:3]] - smap[p["pair"][3:]], 6),
              "bias": "BUY" if smap[p["pair"][:3]] - smap[p["pair"][3:]] >= 0 else "SELL"} for p in week["pairs"]]
    out = {"at": mp["at"], "note": note, "currencies": cur, "pairs": pairs, "macroPulse": True}
    if prev and prev.get("news"):
        out["news"] = prev["news"]
    return out


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
    L.append("W,%s,%s,%s,%s,%s,%s" % (tuple(n(wt[k]) for k in ("fund", "cot", "seas", "news", "macro")) + (n(wt.get("newsMinW", 2)),)))
    mpm = {r["ccy"]: r["macro"] for r in (w.get("macroPulse") or {}).get("rows", [])}  # macro pulse replaces Sunday Macro
    for c in w["currencies"]:
        L.append("C,%s,%s,%s,%s,%s,%s,%s" % (c["ccy"], n(c["fund"]), n(c["cot"]), n(c["seas"]), n(c["news"]), n(mpm.get(c["ccy"], c["macro"])), n(c["strength"])))
    fs = wt.get("fundSet") or FUND_DEFAULT
    L.append("FS," + ",".join(n(fs[k]) for k in FUND_KEYS))
    for c in w["currencies"]:
        L.append("F,%s,%s,%s,%s,%s,%s" % (c["ccy"], n(c.get("investChg") or 0), n(c.get("latestNet") or 0), n(c.get("condPlus") or 0), n(c.get("condMinus") or 0), w["id"][:7]))
    if w.get("trackedFile"):
        for (ccy, _), (pol, name) in sorted(tracked_events(os.path.join(ROOT, w["trackedFile"])).items()):
            L.append("T,%s,%d,%s" % (ccy, pol, clean(name)))
    for e in w.get("news", []):
        if e.get("weight") is None or e.get("ccy") is None:
            continue
        L.append("N,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s" % (e["date"], clean(e["time"]), e["ccy"], clean(e["impact"]), n(e["polarity"]), n(e["weight"]),
                                                    n(e["forecast"]), n(e["previous"]), n(e["score"]), clean(e["event"])))
    for p in w["pairs"]:
        t = p.get("tech") or {}
        L.append("P,%s,%s,%s,%s,%s,%s,%s,%s,%s" % (p["pair"], p["bias"], p["tier"], n(p["score"]), n(p.get("risk") or 0), n(t.get("d1Fail")), n(t.get("h1Fail")),
                                                 clean(t.get("d1") or ""), clean(t.get("h1") or "")))
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
        for upd in extra.get("updates", []):
            ts, cfile, note = upd[:3]
            nrel = upd[3] if len(upd) > 3 else 0  # first N news rows hold Actual (col F) vs Forecast (col G)
            p = os.path.join(CALC, cfile)
            if os.path.exists(p):
                b = extract_final(openpyxl.load_workbook(p, data_only=True))
                for k, e in enumerate(b["news"]):
                    if k < nrel:
                        e["actual"], e["forecast"] = e["forecast"], e["previous"]
                    else:
                        e["actual"] = None
                ups.append({"at": ts, "note": note, "currencies": [{k: c[k] for k in ("ccy", "fund", "cot", "seas", "news", "macro", "strength", "rank")} for c in b["currencies"]],
                            "pairs": [{"pair": x["pair"], "bias": x["bias"], "score": x["score"]} for x in b["pairs"]],
                            "news": b["news"]})
        for ts, csvp, note in extra.get("actuals", []):
            ups.append(rescore_from_actuals(base, os.path.join(PF, csvp), ts, note))
        trk = tracked_events(os.path.join(ROOT, extra["tracked"])) if extra.get("tracked") else {}
        base["trackedFile"] = extra.get("tracked")
        for ts, ffp, note, actp in extra.get("pulse", []):
            pu = compute_pulse(base, os.path.join(ROOT, ffp), trk, ts)
            pu["at"] = ts
            base["pulse"] = pu
            upd = rescore_from_actuals(base, os.path.join(PF, actp), ts, note, {r["ccy"]: r["fund"] for r in pu["rows"]})
            upd["pulse"] = True
            ups.append(upd)
        if extra.get("macro"):
            mp = compute_macro_pulse(base, os.path.join(ROOT, extra["macro"][0]), extra["macro"][1])
            base["macroPulse"] = mp
            if mp["at"]:
                prev = sorted(ups, key=lambda u: u["at"])[-1] if ups else None
                if prev and prev["at"] > mp["at"]:
                    mp["at"] = prev["at"]  # keep it the newest snapshot
                ups.append(rescore_macro(base, prev, mp, "Macro pulse from BabyPips daily recap (%s)." % mp["at"][:10]))
        base["updates"] = ups
        weeks.append(base)
    write_plan(weeks, os.path.join(os.path.dirname(out), "plan.csv"))
    data = {"generated": dt.datetime.utcnow().replace(microsecond=0).isoformat() + "Z", "ccys": CCYS, "weeks": weeks}
    with open(out, "w") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"), default=str)
    print("wrote", out, len(weeks), "weeks")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(PF, "dashboard/app/data/weeks.json"))

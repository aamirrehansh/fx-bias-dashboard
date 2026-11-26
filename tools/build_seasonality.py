#!/usr/bin/env python3
"""Seasonality from MT5 (OneRoyal) D1 exports in data/fx_daily_mt5/*_D1.csv.
Weekly return = last close of ISO week vs last close of previous week (Friday NY close).
Uses the last 10 (and 5) COMPLETE occurrences of each ISO week (1-52; week 53 folded into 52).
Currency seasonality = average % move of the currency vs the other 7 (from the 28 pairs).
Daily curve = average year-to-date % path by calendar day (rebased to previous year's last close), last 10 / 5 complete years."""
import glob, os, sys
import numpy as np, pandas as pd
D = sys.argv[1] if len(sys.argv) > 1 else "/mnt/project-files/data/fx_daily_mt5"
OUT = sys.argv[2] if len(sys.argv) > 2 else "/mnt/project-files/reports/Seasonality_MT5_10y.xlsx"
CC = ["USD", "EUR", "GBP", "JPY", "CHF", "CAD", "AUD", "NZD"]
px = {}
for f in sorted(glob.glob(os.path.join(D, "*_D1.csv"))):
    s = os.path.basename(f)[:-7]
    df = pd.read_csv(f)
    df["date"] = pd.to_datetime(df["date"], format="%Y.%m.%d")
    df = df[df["date"].dt.dayofweek < 5]          # drop Sunday stubs if any
    px[s] = df.set_index("date")["close"]
P = pd.DataFrame(px).sort_index().ffill()
iso = P.index.isocalendar()
key = (iso["year"].astype(str) + "-" + iso["week"].astype(str).str.zfill(2)).values
W = P.groupby(key).last()
WR = np.log(W).diff().iloc[1:] * 100                  # weekly % (log)
yr = np.array(WR.index.str[:4].astype(int)); wk = np.minimum(np.array(WR.index.str[5:].astype(int)), 52)
last_complete = WR.index[-2] if P.index[-1].dayofweek < 4 else WR.index[-1]   # current week incomplete unless Friday
WR = WR.loc[:last_complete]; yr = yr[:len(WR)]; wk = wk[:len(WR)]
# currency strength vs other 7
pairs = [s for s in P.columns if len(s) == 6 and s[:3] in CC and s[3:] in CC]
CR = pd.DataFrame(0.0, index=WR.index, columns=CC)
for c in CC:
    tot = 0
    for p in pairs:
        if p[:3] == c: CR[c] += WR[p]; tot += 1
        elif p[3:] == c: CR[c] -= WR[p]; tot += 1
    CR[c] /= tot
def table(R, n):
    rows = []
    for w in range(1, 53):
        sub = R[wk == w].tail(n)
        rows.append([w, len(sub)] + [x for c in R.columns for x in (round(sub[c].mean(), 3), round(sub[c].median(), 3), round(100 * (sub[c] > 0).mean(), 0))])
    cols = ["ISO week", "years"] + [f"{c} {k}" for c in R.columns for k in ("avg %", "median %", "% up")]
    return pd.DataFrame(rows, columns=cols)
def daily_curve(n):
    out = {}
    yrs = sorted(set(P.index.year))
    full = [y for y in yrs if (P.index.year == y).sum() > 240][-n:]
    for s in P.columns:
        paths = []
        for y in full:
            base = P[s][P.index.year == y - 1]
            if base.empty: continue
            seg = P[s][P.index.year == y]
            c = (np.log(seg / base.iloc[-1]) * 100)
            c.index = c.index.strftime("%m-%d")
            paths.append(c.groupby(level=0).last())
        out[s] = pd.concat(paths, axis=1).mean(axis=1) if paths else pd.Series(dtype=float)
    df = pd.DataFrame(out).sort_index().ffill().round(3)
    df.index.name = "day (MM-DD)"
    return df, full
# Aamir's four-line seasonality score (26-Nov-2026): windows 2016-18, 2019-21, 2022-25, All (complete years).
# >=3 of 4 lines must agree on direction (else 0); 3/4 = half, 4/4 = full; tier by avg |move| of the 4 lines:
# >=0.30% 1.0, >=0.15% 0.75, >=0.05% 0.5, else 0.25. Score in -1..+1.
FOUR = {"2016-18": (2016, 2018), "2019-21": (2019, 2021), "2022-25": (2022, 2025)}
def four_lines(w):
    last = int(pd.Timestamp.now().year) - 1
    win = dict(FOUR); win["All"] = (2016, last)
    out = {}
    for k, (a, b) in win.items():
        m = (wk == w) & (yr >= a) & (yr <= b)
        out[k] = CR[m].mean()
    L = pd.DataFrame(out)
    sg = np.sign(L.values); up = (sg > 0).sum(1); dn = (sg < 0).sum(1)
    d = np.where(up >= 3, 1, np.where(dn >= 3, -1, 0)); n = np.maximum(up, dn)
    mv = np.abs(L.values.mean(1))
    tier = np.select([mv >= .30, mv >= .15, mv >= .05], [1, .75, .5], .25)
    L["agree"] = [f"{x}/4" for x in n]
    L["score"] = np.round(d * tier * np.where(n == 4, 1, .5), 3)
    L.index.name = "Currency"
    return L.round(3)

# ---- Stretch flag + expected weekly range (Aamir 26-Nov-2026) ----
# Stretch: last complete week's currency move vs its typical weekly swing (std of the 26 weeks before).
# |x| > 2 = STRETCHED -> fade it next week (backtest 2017-26: 56% hit, +0.15% avg, stable in both halves); 1.5-2 = watch.
import json
def wk_dates(k):
    y, w = int(k[:4]), int(k[5:])
    mon = pd.Timestamp.fromisocalendar(y, w, 1)
    return mon.strftime("%d %b"), (mon + pd.Timedelta(days=4)).strftime("%d %b %Y")
std26 = CR.rolling(26).std().shift(1)
X = (CR / std26)
lk = CR.index[-1]
stretch = pd.DataFrame({"move %": CR.loc[lk].round(3), "typical %": std26.loc[lk].round(3), "x typical": X.loc[lk].round(2)})
stretch["flag"] = np.where(X.loc[lk].abs() > 2, "STRETCHED", np.where(X.loc[lk].abs() > 1.5, "watch", ""))
stretch["fade side next week"] = np.where(stretch["flag"] != "", np.where(X.loc[lk] > 0, "SELL", "BUY"), "")
stretch.index.name = "Currency"
hist = X.tail(12).round(2)
# expected range: weekly high-low per symbol in pips
def pip(s):
    return 1.0 if s == "USTEC" else 0.1 if s == "XAUUSD" else 0.01 if s.endswith("JPY") else 0.0001
HL = {}
for f2 in sorted(glob.glob(os.path.join(D, "*_D1.csv"))):
    s2 = os.path.basename(f2)[:-7]
    d2 = pd.read_csv(f2); d2["date"] = pd.to_datetime(d2["date"], format="%Y.%m.%d"); d2 = d2[d2["date"].dt.dayofweek < 5].set_index("date")
    i2 = d2.index.isocalendar(); k2 = (i2["year"].astype(str) + "-" + i2["week"].astype(str).str.zfill(2)).values
    wkr = ((d2["high"].groupby(k2).max() - d2["low"].groupby(k2).min()) / pip(s2)).loc[:lk]
    dr = ((d2["high"] - d2["low"]) / pip(s2))
    HL[s2] = {"expected week (pips)": round(float(wkr.tail(8).median()), 0), "last week (pips)": round(float(wkr.iloc[-1]), 0),
              "10y avg week (pips)": round(float(wkr.tail(520).mean()), 0), "daily ATR14 (pips)": round(float(dr.tail(14).mean()), 0)}
rng = pd.DataFrame(HL).T; rng.index.name = "Symbol"
d0, d1 = wk_dates(lk); ny, nw = (pd.Timestamp.fromisocalendar(int(lk[:4]), int(lk[5:]), 1) + pd.Timedelta(days=7)).isocalendar()[:2]
n0, n1 = wk_dates(f"{ny}-{nw:02d}")
INS = {"built": pd.Timestamp.now().strftime("%Y-%m-%d %H:%M"), "basedOn": f"{d0} - {d1}", "appliesTo": f"{n0} - {n1}",
       "stretch": [{"ccy": c, **{k: (None if pd.isna(v) else v) for k, v in stretch.loc[c].items()}} for c in CC],
       "range": [{"sym": s, **{k: float(v) for k, v in rng.loc[s].items()}} for s in rng.index],
       "note": "Stretch = last week's move vs typical weekly swing (26w std). >2x = STRETCHED, fade next week (2017-26 backtest: 56% hit, +0.15% avg). Expected range = median weekly high-low of last 8 weeks."}
nxt = int(pd.Timestamp.now().isocalendar()[1]) + 1
with pd.ExcelWriter(OUT) as xw:
    c10, c5 = table(CR, 10), table(CR, 5)
    summ = pd.DataFrame({"Currency": CC,
        f"Wk{nxt} avg % (10y)": [c10.loc[nxt - 1, f"{c} avg %"] for c in CC],
        f"Wk{nxt} % up (10y)": [c10.loc[nxt - 1, f"{c} % up"] for c in CC],
        f"Wk{nxt} avg % (5y)": [c5.loc[nxt - 1, f"{c} avg %"] for c in CC],
        f"Wk{nxt} % up (5y)": [c5.loc[nxt - 1, f"{c} % up"] for c in CC]}).sort_values(f"Wk{nxt} avg % (10y)", ascending=False)
    summ.to_excel(xw, sheet_name="Next week currencies", index=False)
    stretch.to_excel(xw, sheet_name="Stretch flag")
    hist.to_excel(xw, sheet_name="Stretch last 12 weeks")
    rng.to_excel(xw, sheet_name="Expected weekly range")
    four_lines(nxt).sort_values("score", ascending=False).to_excel(xw, sheet_name=f"Wk{nxt} four-line score")
    pd.concat({w: four_lines(w)["score"] for w in range(1, 53)}, axis=1).T.rename_axis("ISO week").to_excel(xw, sheet_name="Four-line score all weeks")
    c10.to_excel(xw, sheet_name="Currency weekly 10y", index=False)
    c5.to_excel(xw, sheet_name="Currency weekly 5y", index=False)
    table(WR, 10).to_excel(xw, sheet_name="Symbol weekly 10y", index=False)
    table(WR, 5).to_excel(xw, sheet_name="Symbol weekly 5y", index=False)
    d10, y10 = daily_curve(10); d10.to_excel(xw, sheet_name="Daily curve 10y")
    d5, y5 = daily_curve(5); d5.to_excel(xw, sheet_name="Daily curve 5y")
    WR.round(4).to_excel(xw, sheet_name="Weekly returns raw")
    pd.DataFrame({"note": [
        "Source: OneRoyal MT5 D1 closes (New York 17:00), exported 26-Nov-2026, 24-Nov-2016 .. 26-Nov-2026.",
        "Weekly = ISO week last close vs previous week last close, log %, last 10 / 5 complete occurrences of each week.",
        "Currency = average % move vs the other 7 majors (from the 28 crosses).",
        f"Daily curve: average YTD path rebased to previous year close; 10y years {y10[0]}-{y10[-1]}, 5y years {y5[0]}-{y5[-1]}.",
        f"Last complete week used: {last_complete}."]}).to_excel(xw, sheet_name="About", index=False)
print(summ.to_string(index=False)); print("wrote", OUT, "last complete", last_complete)

for p_out in [os.path.join(D, "insights.json")] + sys.argv[3:]:
    if p_out.endswith(".js"):
        open(p_out, "w").write("window.FXINSIGHT=" + json.dumps(INS) + ";\n")
    else:
        json.dump(INS, open(p_out, "w"), indent=1)
print("stretch", INS["basedOn"], "->", INS["appliesTo"]); print(stretch.to_string())

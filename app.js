/* FX Weekly Bias dashboard — offline PWA. Data: data/weeks.js (window.FXDATA), live: data/live.json (MT5 monitor). */
(function () {
  "use strict";
  const D = window.FXDATA || { weeks: [], ccys: [] };
  const CCYS = D.ccys && D.ccys.length ? D.ccys : ["USD", "EUR", "GBP", "JPY", "CHF", "CAD", "AUD", "NZD"];
  const WEEKS = D.weeks.slice().sort((a, b) => a.id.localeCompare(b.id));
  const SHORT = ["TRADE", "RESERVE", "WATCH"];
  const LS = {
    get(k, d) { try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : d; } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { } }
  };
  const $ = (s, el) => (el || document).querySelector(s);
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const isNum = (v) => typeof v === "number" && isFinite(v);
  const f = (v, d = 1) => (isNum(v) ? v.toFixed(d) : "–");
  const sg = (v, d = 1) => (isNum(v) ? (v > 0 ? "+" : "") + v.toFixed(d) : "–");
  const cls = (v, eps = 0) => (!isNum(v) ? "mut" : v > eps ? "up" : v < -eps ? "dn" : "mut");
  const kfmt = (v) => (!isNum(v) ? "–" : Math.abs(v) >= 1000 ? (v / 1000).toFixed(1) + "k" : v.toFixed(0));
  const pipSize = (pair) => (pair.endsWith("JPY") ? 0.01 : 0.0001);
  const dirOf = (b) => (b === "BUY" ? 1 : b === "SELL" ? -1 : 0);
  const today = () => new Date().toISOString().slice(0, 10);

  const state = {
    wk: LS.get("fx_wk", null),
    tab: LS.get("fx_tab", "overview"),
    pairFilter: LS.get("fx_pf", "short"),
    cotCcy: LS.get("fx_cotccy2", "ALL"),
    factor: LS.get("fx_factor", "fund"),
    live: null, liveErr: null, rates: LS.get("fx_rates", { at: 0, data: {} }),
  };
  // merge the bundled price seed (works offline on first open) with anything fetched later
  if (window.FXRATES && window.FXRATES.data) state.rates.data = Object.assign({}, window.FXRATES.data, state.rates.data || {});
  if (!WEEKS.find((w) => w.id === state.wk)) state.wk = currentWeekId();

  function currentWeekId() {
    const t = today();
    let pick = WEEKS[WEEKS.length - 1];
    for (const w of WEEKS) if (w.start <= t && !w.missing) pick = w;
    return pick ? pick.id : null;
  }
  const week = () => WEEKS.find((w) => w.id === state.wk);
  const prevWeek = (w) => { const i = WEEKS.indexOf(w); for (let j = i - 1; j >= 0; j--) if (!WEEKS[j].missing) return WEEKS[j]; return null; };
  const isCurrent = (w) => w && w.id === currentWeekId() && today() <= addDays(w.end, 2);
  function addDays(iso, n) { const d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); }

  /* ---------- snapshot: plan + intra-week updates + MT5 live ---------- */
  function snapshot(w) {
    const snaps = (w.updates || []).slice();
    const L = state.live;
    if (L && L.week === w.id) snaps.push({ at: L.at, note: "Live (MT5 monitor)", currencies: L.currencies, pairs: L.pairs, news: L.news, live: true, prices: L.prices });
    snaps.sort((a, b) => String(a.at).localeCompare(String(b.at)));
    const last = snaps[snaps.length - 1];
    const cmap = {}; (w.currencies || []).forEach((c) => (cmap[c.ccy] = Object.assign({}, c, { planStrength: c.strength, planNews: c.news })));
    const pmap = {}; (w.pairs || []).forEach((p) => (pmap[p.pair] = Object.assign({}, p, { planScore: p.score, planBias: p.bias })));
    let news = (w.news || []).map((n) => Object.assign({}, n));
    if (last) {
      (last.currencies || []).forEach((c) => { if (cmap[c.ccy]) Object.assign(cmap[c.ccy], pick(c, ["news", "strength", "rank", "fund", "cot", "seas", "macro"])); });
      (last.pairs || []).forEach((p) => { if (pmap[p.pair]) { pmap[p.pair].score = p.score; pmap[p.pair].bias = p.bias || (p.score >= 0 ? "BUY" : "SELL"); } });
      if (last.news && last.news.length) news = mergeNews(news, last.news);
    }
    if (w.weights && w.weights.fundMode === "rank")  // Aamir 26-Nov: bias label from Investogenie direction + Latest/Cond confirmation
      Object.values(cmap).forEach((c) => { c.fundBiasOld = c.fundBias; c.fundBias = fundBiasLabel(c); });
    return { at: last ? last.at : null, note: last ? last.note : null, live: !!(last && last.live), prices: last && last.prices, ccy: cmap, pairs: pmap, news, snaps };
  }
  // Investogenie change sets direction (|chg| < 2 = NEUTRAL); 2-10 = weak move -> WEAK; otherwise both confirm = STRONG, one = plain, none = WEAK
  function fundBiasLabel(c) {
    const L = c.investChg;
    if (!isNum(L) || Math.abs(L) < 2) return "NEUTRAL";
    const side = L > 0 ? "BUY" : "SELL";
    if (Math.abs(L) < 10) return "WEAK " + side;
    const n = (String(c.latestState).toUpperCase() === "CONFIRM") + (String(c.condState).toUpperCase() === "CONFIRM");
    return n === 2 ? "STRONG " + side : n === 1 ? side : "WEAK " + side;
  }
  function pick(o, ks) { const r = {}; ks.forEach((k) => { if (o[k] !== undefined && o[k] !== null) r[k] = o[k]; }); return r; }
  function mergeNews(base, upd) {
    const key = (n) => (n.date + "|" + n.ccy + "|" + String(n.event || "").toLowerCase().replace(/\s+/g, " ").slice(0, 40));
    const m = {}; upd.forEach((n) => (m[key(n)] = n));
    return base.map((n) => { const u = m[key(n)]; if (!u) return n; const rel = isNum(u.actual);
      const r = Object.assign({}, n, { actual: rel ? u.actual : n.actual, forecast: rel && isNum(u.forecast) ? u.forecast : n.forecast, liveScore: isNum(u.score) ? u.score : null }); if (r.liveScore === null && isNum(u.score) && u.score !== n.score) r.liveScore = u.score; return r; });
  }

  /* ---------- alerts ---------- */
  function alertsFor(w) {
    const s = snapshot(w), out = [];
    if (!s.at) return out;
    Object.values(s.pairs).forEach((p) => {
      if (!SHORT.includes(p.tier)) return;
      if (p.planBias && p.bias !== p.planBias) out.push({ lvl: "dn", pair: p.pair, text: `${p.pair}: bias flipped ${p.planBias} → ${p.bias} (score ${sg(p.planScore)} → ${sg(p.score)}). Consider closing / not entering.` });
      else if (isNum(p.planScore) && isNum(p.score)) {
        const d = Math.abs(p.score) - Math.abs(p.planScore);
        if (Math.abs(p.planScore) >= 50 && Math.abs(p.score) < 50) out.push({ lvl: "warn", pair: p.pair, text: `${p.pair}: score fell below 50 (${sg(p.planScore)} → ${sg(p.score)}). Conviction reduced.` });
        else if (d <= -15) out.push({ lvl: "warn", pair: p.pair, text: `${p.pair}: score weakened ${sg(p.planScore)} → ${sg(p.score)}.` });
        else if (d >= 15) out.push({ lvl: "ok", pair: p.pair, text: `${p.pair}: score strengthened ${sg(p.planScore)} → ${sg(p.score)}.` });
      }
    });
    if (state.live && state.live.week === w.id) (state.live.alerts || []).forEach((a) => out.push({ lvl: a.level || "warn", pair: a.pair, text: a.text, at: a.at }));
    // newest first; timed (live EA) alerts above the untimed snapshot summary
    return out.map((a, i) => ({ a, i })).sort((x, y) => (y.a.at ? Date.parse(y.a.at) : -1) - (x.a.at ? Date.parse(x.a.at) : -1) || y.i - x.i).map((x) => x.a);
  }

  /* ---------- rates (ECB daily via frankfurter.dev, cached for offline) ---------- */
  async function loadRates(force) {
    const r = state.rates;
    const start = addDays(WEEKS[0].start, -7), end = today();
    const fresh = Date.now() - (r.at || 0) < 60 * 60 * 1000;
    if (!force && fresh && r.data && Object.keys(r.data).length) return;
    if (!navigator.onLine) return;
    try {
      const url = `https://api.frankfurter.dev/v1/${start}..${end}?base=USD&symbols=EUR,GBP,JPY,CHF,CAD,AUD,NZD`;
      const res = await fetch(url, { cache: "no-store" });
      if (!res.ok) throw new Error("HTTP " + res.status);
      const j = await res.json();
      state.rates = { at: Date.now(), data: Object.assign({}, (window.FXRATES && window.FXRATES.data) || {}, j.rates || {}) };
      LS.set("fx_rates", state.rates);
      render();
    } catch (e) { console.warn("rates", e); }
  }
  const rateDates = () => Object.keys(state.rates.data || {}).sort();
  function price(pair, date) {
    const rr = state.rates.data[date]; if (!rr) return null;
    const b = pair.slice(0, 3), q = pair.slice(3);
    const rb = b === "USD" ? 1 : rr[b], rq = q === "USD" ? 1 : rr[q];
    return rb && rq ? rq / rb : null;
  }
  function weekDates(w) {
    const ds = rateDates();
    const open = ds.filter((d) => d < w.start).pop();
    const inWeek = ds.filter((d) => d >= w.start && d <= w.end);
    return { open, inWeek, close: inWeek[inWeek.length - 1] };
  }
  function livePrice(w, pair) {
    const s = state.live; if (!s || s.week !== w.id || !s.prices) return null;
    return isNum(s.prices[pair]) ? s.prices[pair] : null;
  }
  function pairResult(w, p) {
    const wd = weekDates(w); if (!wd.open) return null;
    const o = price(p.pair, wd.open); if (!o) return null;
    let c = null, src = "", at = wd.close;
    const lp = isCurrent(w) ? livePrice(w, p.pair) : null;
    if (lp) { c = lp; src = "live"; at = state.live.at; }
    else if (wd.close) { c = price(p.pair, wd.close); src = wd.close >= w.end ? "final" : "so far"; }
    if (!c) return null;
    const dir = dirOf(p.planBias || p.bias);
    const pips = ((c - o) / pipSize(p.pair)) * dir;
    const pct = ((c - o) / o) * 100 * dir;
    const path = wd.inWeek.map((d) => ({ d, v: ((price(p.pair, d) - o) / pipSize(p.pair)) * dir }));
    return { open: o, close: c, pips, pct, src, at, path };
  }
  function ccyRealised(w) {
    const wd = weekDates(w); if (!wd.open || !wd.close) return null;
    const a = state.rates.data[wd.open], b = state.rates.data[wd.close];
    const raw = {}; CCYS.forEach((c) => { raw[c] = c === "USD" ? 0 : -Math.log(b[c] / a[c]) * 100; });
    const m = CCYS.reduce((s, c) => s + raw[c], 0) / CCYS.length;
    const out = {}; CCYS.forEach((c) => (out[c] = raw[c] - m));
    return { v: out, final: wd.close >= w.end };
  }
  function ccyWeekMove(w) {
    // Currency move this week: average log % change of its 7 pairs since the previous Friday close (+ = currency stronger).
    const wd = weekDates(w); if (!wd.open) return null;
    const useLive = isCurrent(w) && state.live && state.live.week === w.id && state.live.prices;
    const acc = {}; CCYS.forEach((c) => (acc[c] = []));
    let nLive = 0;
    for (let i = 0; i < CCYS.length; i++) for (let j = i + 1; j < CCYS.length; j++) {
      const a = CCYS[i], b = CCYS[j];
      const p = (w.pairs || []).find((x) => x.pair === a + b || x.pair === b + a); if (!p) continue;
      const o = price(p.pair, wd.open); if (!o) continue;
      let c = useLive ? livePrice(w, p.pair) : null;
      if (c) nLive++; else if (wd.close) c = price(p.pair, wd.close);
      if (!c) continue;
      const ch = Math.log(c / o) * 100;
      acc[p.pair.slice(0, 3)].push(ch); acc[p.pair.slice(3)].push(-ch);
    }
    const v = {}; CCYS.forEach((c) => (v[c] = acc[c].length ? acc[c].reduce((t, x) => t + x, 0) / acc[c].length : null));
    const rank = {}; CCYS.filter((c) => isNum(v[c])).sort((x, y) => v[y] - v[x]).forEach((c, i) => (rank[c] = i + 1));
    if (!Object.keys(rank).length) return null;
    const src = nLive ? "MT5 live prices" : wd.close && wd.close >= w.end ? "ECB final" : "ECB daily so far, " + wd.close;
    return { v, rank, src };
  }
  function spearman(xs, ys) {
    const rk = (a) => { const idx = a.map((v, i) => [v, i]).sort((p, q) => q[0] - p[0]); const r = []; idx.forEach((e, i) => (r[e[1]] = i + 1)); return r; };
    const rx = rk(xs), ry = rk(ys), n = xs.length; let d2 = 0; for (let i = 0; i < n; i++) d2 += (rx[i] - ry[i]) ** 2;
    return 1 - (6 * d2) / (n * (n * n - 1));
  }
  function weekPerf(w) {
    if (w.missing) return null;
    const s = snapshot(w);
    const plan = (w.pairs || []).filter((p) => p.tier === "TRADE").map((p) => ({ p: s.pairs[p.pair], r: pairResult(w, s.pairs[p.pair]) }));
    const watch = (w.pairs || []).filter((p) => p.tier === "WATCH" || p.tier === "RESERVE").map((p) => ({ p: s.pairs[p.pair], r: pairResult(w, s.pairs[p.pair]) }));
    const all = (w.pairs || []).map((p) => ({ p, r: pairResult(w, Object.assign({}, p, { planBias: p.bias })) })).filter((x) => x.r);
    if (!all.length) return { w, plan, watch, none: true };
    const top5 = all.slice().sort((a, b) => Math.abs(b.p.score) - Math.abs(a.p.score)).slice(0, 5);
    const hit = (arr) => (arr.length ? arr.filter((x) => x.r && x.r.pips > 0).length / arr.filter((x) => x.r).length : null);
    const sum = (arr) => arr.reduce((t, x) => t + (x.r ? x.r.pips : 0), 0);
    const real = ccyRealised(w);
    let rho = null;
    if (real && w.currencies && w.currencies.length === 8) rho = spearman(CCYS.map((c) => (w.currencies.find((x) => x.ccy === c) || {}).strength || 0), CCYS.map((c) => real.v[c]));
    const final = all[0].r.src === "final";
    return { w, plan, watch, all, top5, planHit: hit(plan), planPips: sum(plan), watchHit: hit(watch), allHit: hit(all), top5Hit: hit(top5), top5Pips: sum(top5), rho, real, final };
  }

  /* ---------- small renderers ---------- */
  function pill(v, scale = 100) {
    if (!isNum(v)) return `<span class="pill none">–</span>`;
    const x = v * scale, a = Math.abs(x);
    const c = a < 0.5 ? "" : x > 0 ? (a >= 50 ? "up2" : "up") : a >= 50 ? "dn2" : "dn";
    return `<span class="pill ${c}">${x > 0.5 ? "+" : ""}${Math.round(x)}</span>`;
  }
  function rsiPill(v) {
    if (!isNum(v)) return `<span class="mut">–</span>`;
    if (v <= 20) return `<span class="pill up">${v.toFixed(1)}</span>`;
    if (v >= 80) return `<span class="pill dn">${v.toFixed(1)}</span>`;
    return `<span class="b">${v.toFixed(1)}</span>`;
  }
  function bar(v, max = 100) {
    if (!isNum(v)) return "";
    const w = Math.min(50, (Math.abs(v) / max) * 50);
    const left = v >= 0 ? 50 : 50 - w;
    return `<div class="bar"><i style="left:${left}%;width:${w}%;background:${v >= 0 ? "var(--up)" : "var(--dn)"}"></i></div>`;
  }
  const tier = (t) => `<span class="tier ${t || "NO"}">${t === "NO" || !t ? "—" : t}</span>`;
  const biasTxt = (b) => { const u = String(b || "").toUpperCase(); return `<span class="${u.includes("BUY") || u.includes("BULL") ? "up" : u.includes("SELL") || u.includes("BEAR") ? "dn" : "mut"} b">${esc(b || "–")}</span>`; };
  function flagsFor(c) {
    const out = [];
    const comps = [["Fund", c.fund], ["COT", c.cot], ["Seas", c.seas], ["News", c.news], ["Macro", c.macro]];
    const sgn = Math.sign(c.strength || 0);
    const div = comps.filter(([, v]) => isNum(v) && Math.abs(v) > 0.01 && Math.sign(v) === -sgn).length;
    if (c.cotReversal && /REVERSAL/i.test(c.cotReversal)) out.push(`<span class="tag warn">COT ${esc(c.cotReversal.toLowerCase())}</span>`);
    else if (c.rsiExtreme) out.push(`<span class="tag warn">COT RSI ${esc(c.rsiExtreme.toLowerCase())}</span>`);
    if (c.rsiExtreme === "TOP") out.push(`<span class="tag">Contrarian bearish</span>`);
    if (c.rsiExtreme === "BOTTOM") out.push(`<span class="tag">Contrarian bullish</span>`);
    if (div >= 2) out.push(`<span class="tag warn">${div} divergence</span>`);
    else if (div === 1) out.push(`<span class="tag">${div} divergence</span>`);
    if (c.latestState === "OPPOSE" && c.condState === "OPPOSE") out.push(`<span class="tag dn">Latest+Cond oppose</span>`);
    if (isNum(c.planStrength) && isNum(c.strength) && Math.abs(c.strength - c.planStrength) >= 3) out.push(`<span class="tag info">intra-week ${sg(c.strength - c.planStrength)}</span>`);
    return out.join("");
  }
  function spark(vals, w = 120, h = 28) {
    const v = vals.filter(isNum); if (v.length < 2) return "";
    const mn = Math.min(0, ...v), mx = Math.max(0, ...v), r = mx - mn || 1;
    const pts = vals.map((x, i) => (isNum(x) ? `${(i / (vals.length - 1)) * w},${h - ((x - mn) / r) * h}` : null)).filter(Boolean).join(" ");
    const zy = h - ((0 - mn) / r) * h; const last = v[v.length - 1];
    return `<svg width="${w}" height="${h}" class="chart"><line x1="0" x2="${w}" y1="${zy}" y2="${zy}" stroke="var(--line2)"/><polyline fill="none" stroke="${last >= 0 ? "var(--up)" : "var(--dn)"}" stroke-width="2" points="${pts}"/></svg>`;
  }
  function card(title, sub, body, foot) {
    return `<section class="card"><h2>${title}</h2>${sub ? `<p class="sub">${sub}</p>` : ""}${body}${foot ? `<div class="foot">${foot}</div>` : ""}</section>`;
  }

  /* ---------- views ---------- */
  function vOverview(w) {
    if (w.missing) return missing(w);
    const s = snapshot(w), pw = prevWeek(w);
    const cs = Object.values(s.ccy).sort((a, b) => b.strength - a.strength);
    const short = Object.values(s.pairs).filter((p) => SHORT.includes(p.tier)).sort((a, b) => SHORT.indexOf(a.tier) - SHORT.indexOf(b.tier) || Math.abs(b.planScore) - Math.abs(a.planScore));
    const trades = short.filter((p) => p.tier === "TRADE");
    const risk = trades.reduce((t, p) => t + (p.risk || 0), 0);
    const perf = weekPerf(w);
    const al = alertsFor(w);
    let h = `<div class="grid g4">
      <div class="kpi"><div class="l">Week</div><div class="v">${esc(w.label)}</div><div class="s">${s.at ? (s.live ? "Live MT5 data " : "Updated ") + new Date(s.at).toLocaleString() : "Sunday plan"}</div></div>
      <div class="kpi"><div class="l">Trades / risk</div><div class="v">${trades.length} <span class="mut" style="font-size:15px">· ${(risk * 100).toFixed(1)}%</span></div><div class="s">${short.filter((p) => p.tier === "WATCH").length} watch · ${short.filter((p) => p.tier === "RESERVE").length} reserve</div></div>
      <div class="kpi"><div class="l">Strongest / weakest</div><div class="v"><span class="up">${cs[0] ? cs[0].ccy : "–"}</span> <span class="mut" style="font-size:15px">vs</span> <span class="dn">${cs[cs.length - 1] ? cs[cs.length - 1].ccy : "–"}</span></div><div class="s">${cs[0] ? sg(cs[0].strength) : ""} / ${cs.length ? sg(cs[cs.length - 1].strength) : ""}</div></div>
      <div class="kpi"><div class="l">Plan result ${perf && perf.plan.length && perf.plan[0].r ? "(" + perf.plan[0].r.src + ")" : ""}</div><div class="v ${perf ? cls(perf.planPips) : "mut"}">${perf && perf.planHit !== null && perf.plan.some((x) => x.r) ? sg(perf.planPips, 0) + " pips" : "–"}</div><div class="s">${perf && perf.planHit !== null && perf.plan.some((x) => x.r) ? Math.round(perf.planHit * 100) + "% of trades in profit (ECB daily)" : "Waiting for price data"}</div></div>
    </div>`;
    const isKey = (a) => /NEW SETUP|BIAS FLIPPED/.test(a.text);
    const listAl = al.filter((a) => !isKey(a));
    let ab = "";
    if (listAl.length) ab = listAl.map((a) => `<div class="alert ${a.lvl === "ok" ? "ok" : a.lvl === "info" ? "info" : ""}"><div>${a.lvl === "dn" ? "⛔" : a.lvl === "ok" ? "✅" : "⚠️"}</div><div style="flex:1">${esc(a.text)}</div>${a.at ? `<time>${new Date(a.at).toLocaleTimeString()}</time>` : ""}</div>`).join("");
    else ab = `<div class="alert ok"><div>✅</div><div>No other changes to the shortlisted pairs since the Sunday plan${s.at ? " (last check " + new Date(s.at).toLocaleString() + ")" : ""}.</div></div>`;
    h += vKeyBox(w, al.filter(isKey));
    const LS_ = state.live && state.live.week === w.id && Array.isArray(state.live.setups) ? state.live.setups : null;
    const liveOk = (p) => { const r = LS_ && LS_.find((x) => x.pair === p.pair); return r && (r.entry || r.ready); };
    const shown = LS_ ? short.filter((p) => p.tier === "TRADE" || liveOk(p)) : short;
    const hidden = short.length - shown.length;
    h += `<section class="card" style="margin-top:16px"><h2>This week's shortlist<small>${trades.length} trade${LS_ ? ` · ${shown.length - trades.length} watch ready` : ""} · tap a pair for levels</small></h2><p class="sub">Pips from last Friday's ECB fix to the latest price${state.live ? " (MT5 live)" : ""}.${hidden ? ` Trade pairs always shown; watch pairs only when the live gate is ready or at entry. <span class="click" data-go="pairs" style="color:var(--info);text-decoration:underline;cursor:pointer">${hidden} watch pair${hidden === 1 ? "" : "s"} still waiting · see Pairs</span>` : ""}</p><div class="plan">${shown.map((p) => {
      const r = pairResult(w, p);
      const chg = isNum(p.score) && isNum(p.planScore) && p.score !== p.planScore ? ` <span class="${cls(Math.abs(p.score) - Math.abs(p.planScore))}">(${sg(p.score)})</span>` : "";
      return `<div class="pc" data-pair="${p.pair}"><div class="h"><span class="p">${p.pair}</span><span class="d ${p.planBias}">${p.planBias}</span><span class="spacer"></span>${tier(p.tier)}</div>
        <div class="row"><span class="mut">Score</span><b class="${cls(p.planScore)}">${sg(p.planScore)}${chg}</b></div>
        <div class="row"><span class="mut">Risk</span><b>${p.risk ? (p.risk * 100).toFixed(1) + "%" : "–"}</b></div>
        <div class="row"><span class="mut">Week so far</span><b class="${r ? cls(r.pips) : "mut"}">${r ? sg(r.pips, 0) + " pips" : "–"}</b></div>
        ${r && r.path.length > 1 ? `<div style="margin-top:6px">${spark(r.path.map((x) => x.v), 260, 26)}</div>` : ""}
        <div class="meta">${liveGate(w, p)}${p.timing && p.timing !== "-" ? `<div class="mut" style="font-size:11px">${esc(p.timing)}</div>` : ""}</div></div>`;
    }).join("") || `<div class="empty">No shortlisted pairs this week.</div>`}</div></section>`;
    h += `<div class="grid g2" style="margin-top:16px">${card("Alerts", "Shortlisted pairs whose score or bias changed after news releases", ab, state.live ? "" : "Live alerts need the MT5 monitor EA running (see About). Without it, this shows saved intra-week updates only.")}`;
    h += card("Currency strength", "Plan strength, with intra-week change", `<div class="tw"><table><thead><tr><th>#</th><th>CCY</th><th class="r">Score</th><th>Strength</th><th class="r">Last wk</th><th>Bias</th></tr></thead><tbody>${cs.map((c, i) => {
      const lw = pw && (pw.currencies || []).find((x) => x.ccy === c.ccy);
      return `<tr class="click" data-go="currencies"><td class="mut">${i + 1}</td><td class="ccy ${cls(c.strength, 4)}">${c.ccy}</td><td class="r b ${cls(c.strength)}">${sg(c.strength)}</td><td>${bar(c.strength, 70)}</td><td class="r mut">${lw ? sg(lw.strength) : "–"}</td><td>${biasTxt(c.fundBias)}</td></tr>`;
    }).join("")}</tbody></table></div>`) + `</div>`;
    h += vSetups(w);
    if (w.notes && w.notes.length) h += `<section class="card" style="margin-top:16px"><h2>Notes</h2>${w.notes.map((n) => `<p class="note" style="margin:8px 0">${esc(n)}</p>`).join("")}</section>`;
    return h;
  }

  function vCurrencies(w) {
    if (w.missing) return missing(w);
    const s = snapshot(w), pw = prevWeek(w);
    const cs = Object.values(s.ccy).sort((a, b) => b.strength - a.strength);
    const wt = w.weights || {};
    const pct = (x) => (isNum(x) ? Math.round(x * 100) + "%" : "");
    const mv = ccyWeekMove(w);
    const mvCell = (c) => {
      const x = mv && mv.v[c.ccy]; if (!isNum(x)) return `<span class="mut">–</span>`;
      const sc = c.strength || 0, ok = Math.sign(x) === Math.sign(sc);
      return `<span class="b ${cls(x, 0.02)}">${sg(x, 2)}%</span> <span class="mut" style="font-size:10px">#${mv.rank[c.ccy]}${Math.abs(sc) > 0 ? (ok ? " ✓" : " ✗") : ""}</span>`;
    };
    let h = card("Ranking by layer", `Factor scores −100…+100 · weights Fund ${pct(wt.fund)}, COT ${pct(wt.cot)}, Seas ${pct(wt.seas)}, News ${pct(wt.news)}, Macro ${pct(wt.macro)}`,
      `<div class="tw"><table><thead><tr><th>#</th><th>CCY</th><th>Score</th><th class="r">This week</th><th class="c">Fund</th><th class="c">COT</th><th class="c">Seas</th><th class="c">News</th><th class="c">Macro</th><th>Flags</th></tr></thead><tbody>${cs.map((c, i) => `<tr><td class="mut">${i + 1}</td><td class="ccy ${cls(c.strength, 4)}">${c.ccy}</td><td class="b ${cls(c.strength)}">${sg(c.strength, 1)}</td><td class="r">${mvCell(c)}</td><td class="c">${pill(c.fund)}</td><td class="c">${pill(c.cot)}</td><td class="c">${pill(c.seas)}</td><td class="c">${pill(c.news)}${isNum(c.planNews) && c.planNews !== c.news ? `<div class="mut" style="font-size:10px">plan ${Math.round(c.planNews * 100)}</div>` : ""}</td><td class="c">${pill(c.macro)}</td><td class="wrap">${flagsFor(c)}</td></tr>`).join("")}</tbody></table></div>`,
      `Updated · ${s.at ? new Date(s.at).toLocaleString() : w.start + " (Sunday plan)"}` + (mv ? ` · This week = average move of the currency against the other 7 since last Friday close (${esc(mv.src)}); #rank by move; ✓ = moving with the model score` : ""));
    const rows = cs.map((c) => {
      const lw = pw && (pw.currencies || []).find((x) => x.ccy === c.ccy);
      const ch = lw ? c.strength - lw.strength : null;
      const seas = (c.seas1 || 0) + (c.seas2 || 0);
      return `<tr><td class="ccy">${c.ccy}</td><td class="r b">${sg(c.strength)}</td><td class="r mut">${lw ? sg(lw.strength) : "–"}</td><td class="r ${cls(ch)}">${sg(ch)} ${isNum(ch) ? (ch > 0 ? "▲" : ch < 0 ? "▼" : "–") : ""}</td>
        <td class="r">${f(c.investCurr, 1)}</td><td class="r ${cls(c.investChg)}">${sg(c.investChg, 1)}</td><td class="r ${cls(c.latestNet)}">${sg(c.latestNet, 0)}</td><td class="r ${cls(c.condNet)}">${sg(c.condNet, 0)}</td><td>${biasTxt(c.fundBias)}</td>
        <td class="r ${cls(seas)}">${sg(seas, 0)}</td><td class="r">${kfmt(c.cotCurr)}</td><td class="r mut">${kfmt(c.cotPrev)}</td><td class="r ${cls(c.cotChg)}">${isNum(c.cotChg) ? (c.cotChg > 0 ? "+" : "") + kfmt(c.cotChg) + (c.cotChg > 0 ? " ▲" : " ▼") : "–"}</td>
        <td class="r">${isNum(c.rsi13) ? `${f(c.rsi13, 0)} / ${f(c.rsi26, 0)} / ${f(c.rsi52, 0)}` : "–"}</td><td class="r">${c.rank ? Math.round(c.rank) : "–"}</td></tr>`;
    }).join("");
    h += `<div style="height:16px"></div>` + card("Currency bias", `Investogenie change sets direction; Latest / Conditional (this week's net) confirm · ${esc((w.sources && w.sources.fundamental) || "")}`,
      `<div class="tw"><table><thead><tr><th>Currency</th><th class="r">This week</th><th class="r">Last week</th><th class="r">Change</th><th class="r">Investogenie</th><th class="r">Inv. Δ</th><th class="r">Latest net</th><th class="r">Cond net</th><th>Bias</th><th class="r">Seasonality</th><th class="r">Net now</th><th class="r">Net prev</th><th class="r">Net change</th><th class="r">COT RSI 13/26/52</th><th class="r">Rank</th></tr></thead><tbody>${rows}</tbody></table></div>`,
      "Bias = fundamental (Investogenie change vs last week, confirmed by this week's Latest/Conditional net). COT RSI: 20 or below = crowded short (contrarian bullish), 80 or above = crowded long.");
    return h;
  }

  function vFactors(w) {
    if (w.missing) return missing(w);
    const s = snapshot(w);
    const segs = [["fund", "Fundamental"], ["pulse", "Pulse"], ["cot", "COT"], ["seas", "Seasonality"], ["macro", "Macro"]];
    let h = `<div class="toolbar"><div class="seg">${segs.map(([k, l]) => `<button data-factor="${k}" class="${state.factor === k ? "on" : ""}">${l}</button>`).join("")}</div></div>`;
    const cs = CCYS.map((c) => s.ccy[c]).filter(Boolean);
    if (state.factor === "fund") {
      h += card("Fundamental", esc((w.sources && w.sources.fundamental) || ""), `<div class="tw"><table><thead><tr><th>CCY</th><th class="r">Prev Invest</th><th class="r">Curr Invest</th><th class="r">Change</th><th class="r">Strength</th><th class="r">Latest + / −</th><th>Latest</th><th class="r">Cond + / −</th><th>Cond</th><th class="c">Score</th><th>Bias</th></tr></thead><tbody>${cs.map((c) => `<tr><td class="ccy">${c.ccy}</td><td class="r mut">${f(c.investPrev, 2)}</td><td class="r">${f(c.investCurr, 2)}</td><td class="r b ${cls(c.investChg)}">${sg(c.investChg, 2)}</td><td class="r">${f(c.investStrength, 2)}</td><td class="r">${f(c.latestPlus, 0)} / ${f(c.latestMinus, 0)}</td><td>${stateTag(c.latestState)}</td><td class="r">${f(c.condPlus, 0)} / ${f(c.condMinus, 0)}</td><td>${stateTag(c.condState)}</td><td class="c">${pill(c.fund)}</td><td>${biasTxt(c.fundBias)}</td></tr>`).join("")}</tbody></table></div>`, (w.weights && w.weights.fundMode === "rank" ? "Score = raw Investogenie change ranked across the 8 currencies (+100 highest … −100 lowest), per the 26-Nov factor weight review. Latest / Conditional are shown for reference and no longer change the score. " : "Investogenie change vs last week = primary direction. Latest and Conditional use this week's net only (plus − minus). ") + "Sarmaaya figures are month-to-date and reset on the 1st.");
    } else if (state.factor === "pulse") {
      h += vPulse(w);
    } else if (state.factor === "cot") {
      h += vCOT(w);
    } else if (state.factor === "seas") {
      h += card("Seasonality", "Sarmaaya Seasonality Score 1 and 2 (−10…+10)", `<div class="tw"><table><thead><tr><th>CCY</th><th class="r">Score 1</th><th class="r">Score 2</th><th class="c">Model score</th></tr></thead><tbody>${cs.map((c) => `<tr><td class="ccy">${c.ccy}</td><td class="r ${cls(c.seas1)}">${sg(c.seas1, 0)}</td><td class="r ${cls(c.seas2)}">${sg(c.seas2, 0)}</td><td class="c">${pill(c.seas)}</td></tr>`).join("")}</tbody></table></div>`);
    } else if (w.macroPulse && w.macroPulse.rows) {
      h += vMacroPulse(w, cs);
    } else {
      h += card("Macro overlay", esc((w.sources && w.sources.macro) || "Your weekly macro commentary, −2…+2"), `<div class="tw"><table><thead><tr><th>CCY</th><th class="c">Score</th><th>Rationale</th></tr></thead><tbody>${cs.map((c) => `<tr><td class="ccy">${c.ccy}</td><td class="c">${pill(c.macroRaw, 50)}</td><td class="wrap" style="white-space:normal">${esc(c.macroWhy || "")}</td></tr>`).join("")}</tbody></table></div>`);
    }
    return h;
  }
  function vMacroPulse(w, cs) {
    const M = w.macroPulse, start = new Date(w.id + "T00:00:00Z");
    const dn = [0, 1, 2, 3, 4].map((i) => new Date(start.getTime() + i * 864e5).toLocaleDateString("en-GB", { weekday: "short", day: "numeric", timeZone: "UTC" }));
    const dcell = (v) => (v > 0 ? `<span class="tag up">+${v}</span>` : v < 0 ? `<span class="tag dn">−${-v}</span>` : '<span class="mut">·</span>');
    const rows = cs.map((c) => [c, M.rows.find((r) => r.ccy === c.ccy)]).filter((x) => x[1]);
    const asof = M.at ? `Updated ${new Date(M.at).toLocaleString("en-GB", { timeZone: "Asia/Karachi", weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })} PKT` : "Sunday scores only";
    const tbl = `<div class="tw"><table><thead><tr class="grp"><th></th><th>Sunday</th><th colspan="5">BabyPips daily pulse</th><th colspan="2">Now</th><th></th></tr>
      <tr><th>CCY</th><th class="c">Score</th>${dn.map((d) => `<th class="c">${d}</th>`).join("")}<th class="c">Score</th><th class="c">Model</th><th>Sunday rationale</th></tr></thead>
      <tbody>${rows.map(([c, r]) => `<tr><td class="ccy">${c.ccy}</td><td class="c">${pill(r.sunday, 50)}</td>${r.days.map((v) => `<td class="c">${dcell(v)}</td>`).join("")}<td class="c b">${r.adjRaw !== r.sunday ? `${pill(r.adjRaw, 50)}` : pill(r.adjRaw, 50)}</td><td class="c">${isNum(r.macroPlan) && Math.abs(r.macro - r.macroPlan) > 1e-9 ? `${pill(r.macroPlan)} → ${pill(r.macro)}` : pill(r.macro)}</td><td class="wrap" style="white-space:normal">${esc(c.macroWhy || "")}</td></tr>`).join("")}</tbody></table></div>`;
    const ent = (M.entries || []).slice().sort((a, b) => String(b.utc).localeCompare(String(a.utc)));
    const et = ent.length ? `<div class="tw"><table><thead><tr><th>Posted (PKT)</th><th>Source</th><th>Counted</th><th>Drivers</th></tr></thead><tbody>${ent.map((e) => `<tr><td class="mut">${new Date(e.utc).toLocaleString("en-GB", { timeZone: "Asia/Karachi", weekday: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}</td><td><a href="${esc(e.url)}" target="_blank" rel="noopener">${e.kind === "recap" ? "Daily recap" : "News"}</a></td><td>${Object.entries(e.score || {}).map(([k, v]) => `<span class="tag ${v > 0 ? "up" : "dn"}">${k} ${v > 0 ? "+" : "−"}${Math.abs(v)}</span>`).join(" ") || '<span class="mut">none</span>'}</td><td class="wrap" style="white-space:normal">${esc(e.drivers || "")}</td></tr>`).join("")}</tbody></table></div>` : `<p class="mut">No BabyPips updates yet this week.</p>`;
    return card("Macro overlay + BabyPips pulse", asof, tbl, `Sunday score = your macro commentary (−2…+2). Each free BabyPips daily recap adds +1 for the two strongest and −1 for the two weakest currencies of the day (move vs USD from its scoreboard, minus the 8-currency average, at least ${M.noise}%), and BabyPips news adds ±1 for a clear policy shift. Score now = Sunday + ${M.step} × pulse, kept within −2…+2. Model = score ÷ 2, and it flows into strength, pair scores and the MT5 monitor.`)
      + card("BabyPips updates counted", "Free articles only · checked about 4 AM and 6 PM PKT", et);
  }
  function pulseData(w) {
    const L = state.live;
    if (L && L.week === w.id && L.pulse && L.pulse.rows && (!w.pulse || String(L.pulse.at) > String(w.pulse.at))) return Object.assign({ live: true }, L.pulse);
    if (w.pulse) return w.pulse;
    if (!(w.currencies || []).some((c) => isNum(c.condPlus))) return null;
    return { at: null, rows: w.currencies.map((c) => ({ ccy: c.ccy, prevPlus: c.condPlus, prevMinus: c.condMinus, days: [[0, 0], [0, 0], [0, 0], [0, 0], [0, 0]], plus: c.condPlus, minus: c.condMinus,
      lastPct: c.condPlus + c.condMinus ? (100 * c.condPlus) / (c.condPlus + c.condMinus) : null, curPct: c.condPlus + c.condMinus ? (100 * c.condPlus) / (c.condPlus + c.condMinus) : null, gain: 0,
      condStatePrev: c.condState, condState: c.condState, fundPlan: c.fund, fund: c.fund })), events: [] };
  }
  function vPulse(w) {
    const P = pulseData(w);
    if (!P) return card("Investogenie Pulse", "", `<p class="mut">No Conditional counts for this week.</p>`);
    const start = new Date(w.id + "T00:00:00Z");
    const dn = [0, 1, 2, 3, 4].map((i) => { const d = new Date(start.getTime() + i * 864e5); return d.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", timeZone: "UTC" }); });
    const pm = (a) => `<span class="up">${a[0] || 0}</span> / <span class="dn">${a[1] || 0}</span>`;
    const rows = CCYS.map((c) => P.rows.find((r) => r.ccy === c)).filter(Boolean);
    const tbl = `<div class="tw"><table><thead><tr class="grp"><th></th><th colspan="2">Previous (Sunday)</th><th colspan="5">This week + / −</th><th colspan="2">Total</th><th colspan="3">Positive share</th><th colspan="2">Model</th></tr>
      <tr><th>CCY</th><th class="r">+</th><th class="r">−</th>${dn.map((d) => `<th class="c">${d}</th>`).join("")}<th class="r">+</th><th class="r">−</th><th class="r">Last wk</th><th class="r">Now</th><th class="r">Gain</th><th>Cond</th><th class="c">Fund (plan → now)</th></tr></thead>
      <tbody>${rows.map((r) => `<tr><td class="ccy">${r.ccy}</td><td class="r up">${f(r.prevPlus, 0)}</td><td class="r dn">${f(r.prevMinus, 0)}</td>${(r.days || []).map((d) => `<td class="c">${(d[0] || d[1]) ? pm(d) : '<span class="mut">·</span>'}</td>`).join("")}<td class="r b up">${f(r.plus, 0)}</td><td class="r b dn">${f(r.minus, 0)}</td><td class="r mut">${f(r.lastPct, 1)}</td><td class="r">${f(r.curPct, 1)}</td><td class="r b ${cls(r.gain)}">${isNum(r.gain) ? sg(Math.round(r.gain), 0) : "–"}</td><td>${stateTag(r.condState)}${r.condStatePrev && r.condState !== r.condStatePrev ? ` <span class="mut">was ${esc(String(r.condStatePrev).toLowerCase())}</span>` : ""}</td><td class="c">${isNum(r.fund) && isNum(r.fundPlan) && Math.abs(r.fund - r.fundPlan) > 1e-9 ? `${pill(r.fundPlan)} → ${pill(r.fund)}` : pill(r.fund)}</td></tr>`).join("")}</tbody></table></div>`;
    const ev = (P.events || []).slice().sort((a, b) => String(b.utc).localeCompare(String(a.utc)));
    const evt = ev.length ? `<div class="tw"><table><thead><tr><th>Time (PKT)</th><th>CCY</th><th>Event</th><th class="r">Actual</th><th class="r">Previous</th><th class="c">Count</th></tr></thead><tbody>${ev.map((e) => `<tr><td class="mut">${new Date(e.utc).toLocaleString("en-GB", { timeZone: "Asia/Karachi", weekday: "short", hour: "2-digit", minute: "2-digit" })}</td><td class="ccy">${esc(e.ccy)}</td><td>${esc(e.event)}</td><td class="r b">${esc(e.actual)}</td><td class="r mut">${esc(e.previous)}</td><td class="c">${e.sign > 0 ? '<span class="tag up">+1</span>' : e.sign < 0 ? '<span class="tag dn">−1</span>' : '<span class="mut">tie</span>'}</td></tr>`).join("")}</tbody></table></div>` : `<p class="mut">No tracked releases yet this week.</p>`;
    const asof = P.at ? `${P.live ? "Live from MT5 monitor" : "Snapshot"} · ${new Date(P.at).toLocaleString("en-GB", { timeZone: "Asia/Karachi", weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })} PKT` : "Sunday counts only";
    return card("Investogenie Pulse", asof, tbl, "Conditional +/− from Sunday plus each tracked release this week: actual above previous = +1, below = −1, tie ignored, flipped for unemployment and claims. Gain = (positive share now ÷ last week − 1) × 100. A new Conditional net re-scores the Fundamental layer with the same rules as the workbook, and that flows into strength and pair scores.")
      + card("Releases counted this week", "Tracked event list from Sarmaaya Forex Currency Data (refreshed each Sunday)", evt);
  }
  function vKeyBox(w, keyAl) {
    const L = state.live;
    if (!L || L.week !== w.id) return "";
    const entries = (Array.isArray(L.setups) ? L.setups : []).filter((r) => r.entry && r.conv !== false);
    const t = (a) => a.at ? `<time>${new Date(a.at).toLocaleString([], { weekday: "short", hour: "2-digit", minute: "2-digit" })}</time>` : "";
    const now = entries.map((r) => `<div class="kb-row up click" data-pair="${esc(r.pair)}"><span class="kb-ic">🎯</span><div style="flex:1"><b>${esc(r.pair)} ${r.bias}</b> <span class="mut">score ${sg(r.score)}</span><br><span>${esc(r.status)}</span>${isNum(r.h1Fail) ? ` <span class="mut">· SL beyond ${r.h1Fail}</span>` : ""}</div><span class="tag up">ENTRY NOW</span></div>`).join("");
    const hist = keyAl.map((a) => `<div class="kb-row ${/BIAS FLIPPED/.test(a.text) ? "dn" : "up"}"><span class="kb-ic">${/BIAS FLIPPED/.test(a.text) ? "🔄" : "🔔"}</span><div style="flex:1">${esc(a.text)}</div>${t(a)}</div>`).join("");
    const n = entries.length;
    const head = n ? `${n} entry setup${n === 1 ? "" : "s"} ready now` : "No entry setup right now";
    const empty = !now && !hist ? `<div class="mut" style="font-size:13px">The scanner checks every shortlisted pair, plus any pair with a live |score| ≥ 50, at each H1 close. New setups and bias flips will appear here first${L.at ? " · last update " + new Date(L.at).toLocaleTimeString() : ""}.</div>` : "";
    return `<section class="keybox ${n ? "on" : ""}" style="margin-top:16px"><div class="kb-h"><span>🎯 New setups &amp; bias flips</span><span class="mut" style="font-weight:500">${head}</span></div>${now}${hist}${empty}</section>`;
  }
  function vSetups(w) {
    const L = state.live;
    if (!L || L.week !== w.id || !Array.isArray(L.setups)) return "";
    const rows = L.setups.slice().sort((a, b) => (b.entry - a.entry) || (b.ready - a.ready) || Math.abs(b.score) - Math.abs(a.score));
    const tag = (r) => r.entry && r.conv === false ? '<span class="tag warn">entry · low score</span>' : r.entry ? '<span class="tag up">ENTRY</span>' : r.ready ? '<span class="tag gold">ready</span>' : '<span class="tag">wait</span>';
    const body = rows.length ? `<div class="tw"><table><thead><tr><th></th><th>Pair</th><th>Bias</th><th class="r">Score</th><th>D1</th><th class="r">D1 pullback</th><th>H1</th><th class="r">H1 pullback</th><th class="r">SL beyond (H1)</th><th class="wrap">Status</th></tr></thead><tbody>${rows.map((r) => `<tr class="click" data-pair="${esc(r.pair)}"><td>${tag(r)}</td><td class="ccy">${esc(r.pair)}</td><td class="${r.bias === "BUY" ? "up" : "dn"} b">${r.bias}</td><td class="r b ${cls(r.score)}">${sg(r.score)}</td><td class="${r.d1Trend === (r.bias === "BUY" ? "UP" : "DOWN") ? "up" : "dn"}">${esc(r.d1Trend)}</td><td class="r">${isNum(r.d1Pct) && r.d1Pct ? f(r.d1Pct, 0) + "%" : "–"}</td><td class="${r.h1Trend === (r.bias === "BUY" ? "UP" : "DOWN") ? "up" : "dn"}">${esc(r.h1Trend)}</td><td class="r">${isNum(r.h1Pct) && r.h1Pct ? f(r.h1Pct, 0) + "%" : "–"}</td><td class="r mut">${isNum(r.h1Fail) ? r.h1Fail : "–"}</td><td class="wrap" style="white-space:normal">${esc(r.status)}</td></tr>`).join("")}</tbody></table></div>` : `<p class="mut">No shortlisted pair or pair with live |score| ≥ 50 right now.</p>`;
    const n = rows.filter((r) => r.entry && r.conv !== false).length;
    return `<div style="margin-top:16px">${card("Live setups", `Scanner · ${n} entry setup${n === 1 ? "" : "s"} · every H1 close · Dow Fib D1 + H1`, body, "Every shortlisted pair, plus any pair with a live |score| ≥ 50, runs the Sunday gate (bias = sign of the live score). A shortlisted pair at entry with |score| < 50 shows as low score and does not push: D1 Dow trend = bias, D1 pullback ≥ 50% (FULL) or 38.2–50% with H1 aligned (LOW). ENTRY = H1 pullback 50–100% with H1 aligned, or an H1 close beyond the H1 fail level. Check the chart before entering.")}</div>`;
  }
  function stateTag(s) { if (!s || s === "n/a") return `<span class="mut">–</span>`; return `<span class="tag ${s === "CONFIRM" ? "up" : s === "OPPOSE" ? "dn" : ""}">${esc(s.toLowerCase())}</span>`; }

  function vCOT(w) {
    const c = state.cotCcy;
    const segBar = `<div class="toolbar"><div class="seg">${["ALL", ...CCYS].map((k) => `<button data-cot="${k}" class="${k === c ? "on" : ""}">${k === "ALL" ? "All" : k}</button>`).join("")}</div></div>`;
    if (c === "ALL") {
      const date = w.sources && w.sources.cotDates && w.sources.cotDates[1];
      const pw = prevWeek(w);
      const rows = CCYS.map((k) => ({ k, r: (w.currencies || []).find((y) => y.ccy === k) || {}, lr: pw && (pw.currencies || []).find((y) => y.ccy === k) }));
      const body = segBar + `<div class="tw"><table><thead><tr class="grp"><th></th><th colspan="4">Net non-commercial</th><th colspan="3">COT RSI</th><th colspan="3">Model</th></tr><tr><th>CCY</th><th class="r">Net</th><th class="r">Prev</th><th class="r">Net Δ</th><th class="r">% Δ</th><th class="r">52</th><th class="r">26</th><th class="r">13</th><th>Signal</th><th class="c">COT score</th><th class="c">Last wk</th></tr></thead><tbody>${rows.map(({ k, r, lr }) => {
        const pc = isNum(r.cotChg) && isNum(r.cotPrev) && r.cotPrev ? (r.cotChg / Math.abs(r.cotPrev)) * 100 : null;
        return `<tr class="click" data-cot="${k}"><td class="ccy b">${k}</td><td class="r">${isNum(r.cotCurr) ? r.cotCurr.toLocaleString() : "–"}</td><td class="r mut">${isNum(r.cotPrev) ? r.cotPrev.toLocaleString() : "–"}</td><td class="r ${cls(r.cotChg)}">${isNum(r.cotChg) ? (r.cotChg > 0 ? "+" : "") + r.cotChg.toLocaleString() : "–"}</td><td class="r ${cls(pc)}">${sg(pc, 1)}${isNum(pc) ? "%" : ""}</td><td class="r">${rsiPill(r.rsi52)}</td><td class="r">${rsiPill(r.rsi26)}</td><td class="r">${rsiPill(r.rsi13)}</td><td>${r.cotReversal ? `<span class="tag warn">${esc(r.cotReversal)}</span>` : r.rsiExtreme ? `<span class="tag">${esc(r.rsiExtreme)}</span>` : ""}</td><td class="c">${pill(r.cot)}</td><td class="c">${lr ? pill(lr.cot) : "–"}</td></tr>`;
      }).join("")}</tbody></table></div>`;
      const hw = WEEKS.filter((x) => !x.missing && x.id <= w.id).slice(-6).reverse();
      const hist = `<div class="tw"><table><thead><tr><th>CCY</th>${hw.map((x) => `<th class="c">${esc((x.sources && x.sources.cotDates && x.sources.cotDates[1]) || x.label)}</th>`).join("")}</tr></thead><tbody>${CCYS.map((k) => `<tr class="click" data-cot="${k}"><td class="ccy b">${k}</td>${hw.map((x) => { const r = (x.currencies || []).find((y) => y.ccy === k) || {}; return `<td class="c">${pill(r.cot)}<div class="mut" style="font-size:11px">${isNum(r.cotChg) ? (r.cotChg > 0 ? "+" : "") + r.cotChg.toLocaleString() : ""}</div></td>`; }).join("")}</tr>`).join("")}</tbody></table></div>`;
      return card(`Weekly COT · all currencies`, `Report ${esc(date || "–")} · plan week ${esc(w.label)} · RSI ≤ 20 bullish extreme · ≥ 80 bearish extreme · tap a currency for its history`, body)
        + `<div style="margin-top:16px">${card("COT score by week", "Latest report first · small number = net change", hist)}</div>`;
    }
    const rows = WEEKS.filter((x) => !x.missing && x.id <= w.id).slice().reverse().map((x) => {
      const r = (x.currencies || []).find((y) => y.ccy === c) || {};
      const date = x.sources && x.sources.cotDates && x.sources.cotDates[1];
      return { x, r, date };
    });
    const body = segBar + `
      <div class="tw"><table><thead><tr class="grp"><th></th><th colspan="4">Net non-commercial</th><th colspan="3">COT RSI</th><th colspan="3">Model</th></tr><tr><th>Report date</th><th class="r">Net</th><th class="r">Prev</th><th class="r">Net Δ</th><th class="r">% Δ</th><th class="r">52</th><th class="r">26</th><th class="r">13</th><th>Signal</th><th class="c">COT score</th><th>Plan week</th></tr></thead><tbody>${rows.map(({ x, r, date }, i) => {
        const p = isNum(r.cotChg) && isNum(r.cotPrev) && r.cotPrev ? (r.cotChg / Math.abs(r.cotPrev)) * 100 : null;
        return `<tr><td class="b">${esc(date || "–")}${i === 0 ? '<span class="latest">Latest</span>' : ""}</td><td class="r">${isNum(r.cotCurr) ? r.cotCurr.toLocaleString() : "–"}</td><td class="r mut">${isNum(r.cotPrev) ? r.cotPrev.toLocaleString() : "–"}</td><td class="r ${cls(r.cotChg)}">${isNum(r.cotChg) ? (r.cotChg > 0 ? "+" : "") + r.cotChg.toLocaleString() : "–"}</td><td class="r ${cls(p)}">${sg(p, 1)}${isNum(p) ? "%" : ""}</td><td class="r">${rsiPill(r.rsi52)}</td><td class="r">${rsiPill(r.rsi26)}</td><td class="r">${rsiPill(r.rsi13)}</td><td>${r.cotReversal ? `<span class="tag warn">${esc(r.cotReversal)}</span>` : r.rsiExtreme ? `<span class="tag">${esc(r.rsiExtreme)}</span>` : ""}</td><td class="c">${pill(r.cot)}</td><td class="mut">${esc(x.label)}</td></tr>`;
      }).join("")}</tbody></table></div>`;
    return card(`Weekly COT · ${c}`, `Sarmaaya COT Categories, non-commercial · last week first · RSI ≤ 20 bullish extreme · ≥ 80 bearish extreme`, body,
      "Stored per plan week from the model files. Weeks before 9 Nov have no COT RSI; 19–23 Oct stored only Sarmaaya's COT Total. Open interest / long / short columns aren't in the model files, so they aren't shown.");
  }

  function liveGate(w, p) {
    const L = state.live;
    const r = L && L.week === w.id && Array.isArray(L.setups) ? L.setups.find((x) => x.pair === p.pair) : null;
    if (!r) return esc(p.gate || "");
    const tg = r.entry && r.conv === false ? '<span class="tag warn">entry · low score</span>' : r.entry ? '<span class="tag up">ENTRY</span>' : r.ready ? '<span class="tag gold">ready</span>' : '<span class="tag">wait</span>';
    const at = L.at ? new Date(L.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "";
    return `${tg} <span class="tag info">live ${esc(at)}</span> ${r.bias !== p.planBias ? `<b class="${r.bias === "BUY" ? "up" : "dn"}">${r.bias}</b> ` : ""}${esc(r.status)}<div class="mut" style="font-size:11px">Sunday: ${esc(p.gate || "–")}</div>`;
  }
  function vPairs(w) {
    if (w.missing) return missing(w);
    const s = snapshot(w);
    let ps = Object.values(s.pairs).sort((a, b) => a.rank - b.rank);
    const fl = state.pairFilter;
    if (fl === "short") ps = ps.filter((p) => SHORT.includes(p.tier));
    else if (fl !== "all") ps = ps.filter((p) => p.tier === fl);
    const segs = [["short", "Shortlist"], ["TRADE", "Trade"], ["WATCH", "Watch"], ["all", "All 28"]];
    const body = `<div class="toolbar"><div class="seg">${segs.map(([k, l]) => `<button data-pf="${k}" class="${fl === k ? "on" : ""}">${l}</button>`).join("")}</div></div>
      <div class="tw"><table><thead><tr><th>#</th><th>Pair</th><th>Bias</th><th class="r">Score</th><th>Strength</th><th class="r">Now</th><th>Elig.</th><th>Gate (Dow Fib D1+H1)</th><th>Status</th><th class="r">Week pips</th></tr></thead><tbody>${ps.map((p) => {
        const r = pairResult(w, p);
        const moved = isNum(p.score) && p.score !== p.planScore;
        return `<tr class="click" data-pair="${p.pair}"><td class="mut">${p.rank}</td><td class="b">${p.pair}</td><td>${biasTxt(p.planBias)}</td><td class="r b ${cls(p.planScore)}">${sg(p.planScore)}</td><td>${bar(p.planScore, 80)}</td><td class="r ${moved ? cls(p.score) : "mut"}">${moved ? sg(p.score) : "="}</td><td>${esc(p.elig || "")}</td><td class="wrap" style="white-space:normal;max-width:320px">${liveGate(w, p)}</td><td>${tier(p.tier)}</td><td class="r ${r ? cls(r.pips) : "mut"}">${r ? sg(r.pips, 0) : "–"}</td></tr>`;
      }).join("") || `<tr><td colspan="10" class="empty">None in this filter.</td></tr>`}</tbody></table></div>`;
    return card("Pairs", "Pair score = base strength − quote strength · tap a row for levels, history and news", body);
  }

  function vNews(w) {
    if (w.missing) return missing(w);
    const s = snapshot(w);
    const days = {};
    s.news.forEach((n) => (days[n.date] = days[n.date] || []).push(n));
    const short = new Set(Object.values(s.pairs).filter((p) => SHORT.includes(p.tier)).flatMap((p) => [p.base || p.pair.slice(0, 3), p.quote || p.pair.slice(3)]));
    let body = Object.keys(days).sort().map((d) => `<tr><td colspan="9" style="background:var(--bg2);font-weight:700">${new Date(d + "T12:00:00Z").toDateString()}</td></tr>` + days[d].map((n) => {
      const released = isNum(n.actual);
      const sc = isNum(n.liveScore) ? n.liveScore : n.score;
      return `<tr><td class="mut">${esc(n.time || "")}</td><td class="b ${short.has(n.ccy) ? "warn" : ""}">${esc(n.ccy)}</td><td><span class="tag ${n.impact === "High" ? "dn" : n.impact === "Medium" ? "warn" : ""}">${esc(n.impact || "")}</span></td><td class="wrap" style="white-space:normal">${esc(n.event)}</td><td class="r">${f(n.forecast, 2)}</td><td class="r mut">${f(n.previous, 2)}</td><td class="r b ${released ? cls((n.actual - n.forecast) * (n.polarity || 1)) : "mut"}">${released ? f(n.actual, 2) : "pending"}</td><td class="r ${cls(sc)}">${sg(sc, 2)}</td><td>${released ? `<span class="tag up">released</span>` : ""}</td></tr>`;
    }).join("")).join("");
    let h = card("News this week", `${esc((w.sources && w.sources.news) || "")} Currencies in your shortlist are highlighted.`,
      `<div class="tw"><table><thead><tr><th>Time (PKT)</th><th>CCY</th><th>Impact</th><th>Event</th><th class="r">Forecast</th><th class="r">Previous</th><th class="r">Actual</th><th class="r">Score</th><th></th></tr></thead><tbody>${body || `<tr><td colspan="9" class="empty">No news list stored for this week.</td></tr>`}</tbody></table></div>`,
      "Before release, score = forecast vs previous. After release, score = actual vs forecast (MT5 monitor or a saved re-score). News is 15% of currency strength.");
    if (w.caution && w.caution.length) h += `<div style="height:16px"></div>` + card("Event-risk only (not scored)", "No numeric forecast", `<div class="tw"><table><tbody>${w.caution.map((c) => `<tr><td class="mut">${esc(c.date)}</td><td class="b">${esc(c.ccy)}</td><td>${esc(c.impact)}</td><td class="wrap" style="white-space:normal">${esc(c.event)}</td></tr>`).join("")}</tbody></table></div>`);
    return h;
  }

  function vHistory() {
    const ws = WEEKS;
    const heat = `<div class="tw"><table class="heat"><thead><tr><th>CCY</th>${ws.map((w) => `<th class="c">${esc(w.label.replace(/ 2026/, ""))}</th>`).join("")}</tr></thead><tbody>${CCYS.map((c) => `<tr><td class="ccy">${c}</td>${ws.map((w) => {
      const x = (w.currencies || []).find((y) => y.ccy === c);
      if (!x) return `<td class="h mut">—</td>`;
      const v = x.strength, a = Math.min(1, Math.abs(v) / 60);
      const bg = v >= 0 ? `rgba(34,211,127,${0.08 + a * 0.45})` : `rgba(255,93,98,${0.08 + a * 0.45})`;
      return `<td class="h" style="background:${bg}">${sg(v, 0)}</td>`;
    }).join("")}</tr>`).join("")}</tbody></table></div>`;
    let h = card("Currency strength by week", "Model strength at the Sunday plan (−100…+100)", heat);
    const list = ws.slice().reverse().map((w) => {
      if (w.missing) return `<tr><td class="b">${esc(w.label)}</td><td colspan="3" class="mut">No model file saved for this week</td></tr>`;
      const sh = (w.pairs || []).filter((p) => SHORT.includes(p.tier));
      const perf = weekPerf(w);
      const res = (p) => { const r = pairResult(w, Object.assign({}, p, { planBias: p.bias })); return r ? ` <span class="${cls(r.pips)}">${sg(r.pips, 0)}</span>` : ""; };
      return `<tr class="click" data-week="${w.id}"><td class="b">${esc(w.label)}</td><td class="wrap" style="white-space:normal">${sh.filter((p) => p.tier === "TRADE").map((p) => `<span class="tag ${p.bias === "BUY" ? "up" : "dn"}">${p.pair} ${p.bias.toLowerCase()}${res(p)}</span>`).join("") || '<span class="mut">none</span>'}</td><td class="wrap" style="white-space:normal">${sh.filter((p) => p.tier !== "TRADE").map((p) => `<span class="tag">${p.pair} ${p.bias.toLowerCase()}${res(p)}</span>`).join("")}</td><td class="r ${perf && !perf.none ? cls(perf.planPips) : "mut"}">${perf && !perf.none && perf.plan.length ? sg(perf.planPips, 0) : "–"}</td></tr>`;
    }).join("");
    h += `<div style="height:16px"></div>` + card("Weekly plans", "Tap a week to open it · pips = previous Friday → Friday (ECB daily)", `<div class="tw"><table><thead><tr><th>Week</th><th>Trade</th><th>Watch / reserve</th><th class="r">Trade pips</th></tr></thead><tbody>${list}</tbody></table></div>`);
    return h;
  }

  function vPerformance() {
    const ps = WEEKS.map(weekPerf).filter((p) => p && !p.none);
    if (!ps.length) return card("Performance", "", `<div class="empty">${navigator.onLine ? "Loading price history…" : "Price history not downloaded yet. Connect once to fetch it; it's then stored for offline use."}</div>`);
    const agg = (k) => { let n = 0, h = 0; ps.forEach((p) => p[k].forEach((x) => { if (x.r) { n++; if (x.r.pips > 0) h++; } })); return n ? h / n : null; };
    const allN = ps.reduce((t, p) => t + p.all.length, 0), allH = ps.reduce((t, p) => t + p.all.filter((x) => x.r.pips > 0).length, 0);
    const t5N = ps.reduce((t, p) => t + p.top5.length, 0), t5H = ps.reduce((t, p) => t + p.top5.filter((x) => x.r.pips > 0).length, 0);
    const planPips = ps.reduce((t, p) => t + p.planPips, 0);
    const rhos = ps.map((p) => p.rho).filter(isNum);
    let h = `<div class="grid g4">
      <div class="kpi"><div class="l">Trade picks in profit</div><div class="v">${agg("plan") !== null ? Math.round(agg("plan") * 100) + "%" : "–"}</div><div class="s">${ps.reduce((t, p) => t + p.plan.filter((x) => x.r).length, 0)} trades · ${sg(planPips, 0)} pips total</div></div>
      <div class="kpi"><div class="l">Top-5 bias hit rate</div><div class="v">${t5N ? Math.round((t5H / t5N) * 100) + "%" : "–"}</div><div class="s">${t5H}/${t5N} strongest scores right</div></div>
      <div class="kpi"><div class="l">All 28 pairs bias hit rate</div><div class="v">${allN ? Math.round((allH / allN) * 100) + "%" : "–"}</div><div class="s">${allH}/${allN} pair-weeks</div></div>
      <div class="kpi"><div class="l">Currency rank accuracy</div><div class="v ${cls(rhos.length ? rhos.reduce((a, b) => a + b, 0) / rhos.length : null, 0.1)}">${rhos.length ? (rhos.reduce((a, b) => a + b, 0) / rhos.length).toFixed(2) : "–"}</div><div class="s">avg rank correlation (+1 perfect, 0 random)</div></div>
    </div>`;
    // bar chart of weekly trade pips
    const mx = Math.max(10, ...ps.map((p) => Math.abs(p.planPips)), ...ps.map((p) => Math.abs(p.top5Pips)));
    const W = 1000, H = 230, bw = W / ps.length;
    const y0 = H / 2;
    const bars = ps.map((p, i) => {
      const a = (p.planPips / mx) * (H / 2 - 16), b = (p.top5Pips / mx) * (H / 2 - 16);
      const x = i * bw;
      return `<rect x="${x + bw * 0.18}" width="${bw * 0.3}" y="${a >= 0 ? y0 - a : y0}" height="${Math.abs(a)}" rx="3" fill="${a >= 0 ? "var(--up)" : "var(--dn)"}"/><rect x="${x + bw * 0.52}" width="${bw * 0.3}" y="${b >= 0 ? y0 - b : y0}" height="${Math.abs(b)}" rx="3" fill="${b >= 0 ? "rgba(34,211,127,.45)" : "rgba(255,93,98,.45)"}"/><text x="${x + bw / 2}" y="${H - 2}" text-anchor="middle">${esc(p.w.label.replace(/ 2026/, ""))}</text><text x="${x + bw * 0.33}" y="${a >= 0 ? y0 - a - 4 : y0 + Math.abs(a) + 11}" text-anchor="middle">${Math.round(p.planPips)}</text>`;
    }).join("");
    h += `<div style="height:16px"></div>` + card("Pips per week", "Solid = Trade picks · light = top-5 scores (all directions as predicted)", `<svg class="chart" viewBox="0 0 ${W} ${H}" width="100%" style="max-height:260px" preserveAspectRatio="xMidYMid meet"><line x1="0" x2="${W}" y1="${y0}" y2="${y0}" stroke="var(--line2)"/>${bars}</svg>`);
    const rows = ps.slice().reverse().map((p) => `<tr class="click" data-week="${p.w.id}"><td class="b">${esc(p.w.label)}${p.final ? "" : ' <span class="latest">in progress</span>'}</td><td class="r">${p.plan.filter((x) => x.r).length}</td><td class="r">${p.planHit !== null && p.plan.some((x) => x.r) ? Math.round(p.planHit * 100) + "%" : "–"}</td><td class="r b ${cls(p.planPips)}">${p.plan.length ? sg(p.planPips, 0) : "–"}</td><td class="r">${p.watch.some((x) => x.r) ? Math.round(p.watchHit * 100) + "%" : "–"}</td><td class="r">${Math.round(p.top5Hit * 100)}%</td><td class="r ${cls(p.top5Pips)}">${sg(p.top5Pips, 0)}</td><td class="r">${Math.round(p.allHit * 100)}%</td><td class="r ${cls(p.rho, 0.1)}">${isNum(p.rho) ? p.rho.toFixed(2) : "–"}</td></tr>`).join("");
    h += `<div style="height:16px"></div>` + card("By week", "Hit = pair moved in the predicted direction from the prior Friday fix to the week's last fix",
      `<div class="tw"><table><thead><tr><th>Week</th><th class="r">Trades</th><th class="r">Trade hit</th><th class="r">Trade pips</th><th class="r">Watch hit</th><th class="r">Top-5 hit</th><th class="r">Top-5 pips</th><th class="r">All-28 hit</th><th class="r">Ccy rank ρ</th></tr></thead><tbody>${rows}</tbody></table></div>`);
    const det = ps.slice().reverse().map((p) => p.plan.concat(p.watch).filter((x) => x.r).map((x) => `<tr><td class="mut">${esc(p.w.label)}</td><td class="b">${x.p.pair}</td><td>${biasTxt(x.p.planBias)}</td><td>${tier(x.p.tier)}</td><td class="r">${f(x.r.open, x.p.pair.endsWith("JPY") ? 3 : 5)}</td><td class="r">${f(x.r.close, x.p.pair.endsWith("JPY") ? 3 : 5)}</td><td class="r b ${cls(x.r.pips)}">${sg(x.r.pips, 0)}</td><td class="r ${cls(x.r.pct)}">${sg(x.r.pct, 2)}%</td><td>${spark(x.r.path.map((q) => q.v), 90, 22)}</td></tr>`).join("")).join("");
    h += `<div style="height:16px"></div>` + card("Shortlisted pairs, every week", "", `<div class="tw"><table><thead><tr><th>Week</th><th>Pair</th><th>Bias</th><th>Tier</th><th class="r">Open</th><th class="r">Close</th><th class="r">Pips</th><th class="r">%</th><th>Path</th></tr></thead><tbody>${det}</tbody></table></div>`,
      "Prices: ECB daily reference rates (~16:00 CET) via frankfurter.dev, cached on this device for offline use; the current week uses MT5 live prices when the monitor EA is running. This measures the model's direction, not your broker fills, entries or stops.");
    return h;
  }

  function vAbout() {
    const L = state.live;
    return `<div class="grid g2">` + card("Live updates and alerts", "", `<div class="kv"><span>Model data</span><span>${esc(D.generated || "")} · ${WEEKS.length} weeks</span><span>MT5 live feed</span><span>${L ? "Last update " + new Date(L.at).toLocaleString() : state.liveErr ? "Not connected (" + esc(state.liveErr) + ")" : "Checking…"}</span><span>Prices</span><span>${state.rates.at ? "Fetched " + new Date(state.rates.at).toLocaleString() : "Not fetched yet"}</span><span>Notifications</span><span>${"Notification" in window ? Notification.permission : "not supported"}</span></div>
      <div class="toolbar"><button class="iconbtn" id="btnNotif">Enable notifications</button><button class="iconbtn" id="btnRefresh">Refresh now</button></div>
      <p class="note">The MT5 <b>FX Bias Monitor</b> EA runs on your PC terminal. It reads news actuals from the MT5 calendar, re-scores the model, and sends a push notification to the MetaTrader app on your phone when a shortlisted pair's bias flips or its score weakens, or when price closes beyond the D1 invalidation level. It also publishes <code>live.json</code> so this dashboard shows the same values on your phone. If the PC is off, the dashboard still works offline with the last saved data.</p>`) +
      card("Install on phone and PC", "", `<p class="note"><b>Android (Chrome):</b> open the link → menu ⋮ → <i>Install app</i>.<br><b>iPhone (Safari):</b> Share → <i>Add to Home Screen</i>.<br><b>Windows (Chrome/Edge):</b> install icon in the address bar.<br>After the first open, it works offline. Each Sunday the new week is added automatically the next time you're online.</p>
      <p class="note" style="margin-top:10px">Sarmaaya inputs still need your signed-in browser on Sunday, so the weekly plan is added after the usual routine. Weeks before the merged model (19–23 Oct) show Option 2. 26–30 Oct has no saved model file.</p>`) + `</div>`;
  }

  function missing(w) { return card(esc(w.label), "", `<div class="empty">${esc((w.notes || [])[0] || "No data for this week.")}</div>`); }

  /* ---------- pair drawer ---------- */
  function openPair(pair) {
    const w = week(), s = snapshot(w), p = s.pairs[pair]; if (!p) return;
    const t = p.tech || {};
    const r = pairResult(w, p);
    const hist = WEEKS.filter((x) => !x.missing).map((x) => { const q = (x.pairs || []).find((y) => y.pair === pair); return { w: x, q }; });
    const ccys = [pair.slice(0, 3), pair.slice(3)];
    const news = s.news.filter((n) => ccys.includes(n.ccy));
    const dp = pair.endsWith("JPY") ? 3 : 5;
    $("#drawer .panel").innerHTML = `<button class="iconbtn close" data-close>Close</button><h2 style="margin:0">${pair} ${biasTxt(p.planBias)} ${tier(p.tier)}</h2>
      <p class="mut" style="margin:6px 0 0">${esc(w.label)} · rank ${p.rank} · score ${sg(p.planScore)}${p.score !== p.planScore ? " → now " + sg(p.score) : ""}</p>
      <div class="kv"><span>Gate</span><span>${esc(p.gate || "–")}</span><span>Timing / SL</span><span>${esc(p.timing || "–")}</span><span>Final risk</span><span>${p.risk ? (p.risk * 100).toFixed(2) + "%" : "–"}</span><span>Fund. diff</span><span>${sg(p.fundDiff, 3)} (${esc(p.elig || "")})</span>
      ${t.d1 ? `<span>D1 Dow trend</span><span>${esc(t.d1)}${isNum(t.d1Fail) ? " · fails " + f(t.d1Fail, dp) : ""}${isNum(t.d1Pend) ? " · pending " + t.d1Pend + "%" : ""}</span>` : ""}
      ${t.h1 ? `<span>H1 Dow trend</span><span>${esc(t.h1)}${isNum(t.h1Fail) ? " · fails " + f(t.h1Fail, dp) : ""}${isNum(t.h1Pend) ? " · pending " + t.h1Pend + "%" : ""}</span>` : ""}
      ${t.h4 ? `<span>H4</span><span>${esc(t.h4)}</span>` : ""}
      <span>Plan close</span><span>${f(t.close, dp)}</span>
      <span>Week so far</span><span class="${r ? cls(r.pips) : ""}">${r ? `${sg(r.pips, 0)} pips (${f(r.open, dp)} → ${f(r.close, dp)}, ${r.src})` : "–"}</span></div>
      <h3 style="font-size:14px;margin:18px 0 8px">${ccys.join(" / ")} strength</h3>
      <div class="kv">${ccys.map((c) => { const x = s.ccy[c] || {}; return `<span>${c}</span><span>${sg(x.strength)} · Fund ${pill(x.fund)} COT ${pill(x.cot)} News ${pill(x.news)}</span>`; }).join("")}</div>
      <h3 style="font-size:14px;margin:18px 0 8px">Score history</h3>
      <div class="tw"><table><thead><tr><th>Week</th><th>Bias</th><th class="r">Score</th><th>Tier</th><th class="r">Result</th></tr></thead><tbody>${hist.slice().reverse().map(({ w: x, q }) => { if (!q) return ""; const rr = pairResult(x, Object.assign({}, q, { planBias: q.bias })); return `<tr><td>${esc(x.label)}</td><td>${biasTxt(q.bias)}</td><td class="r ${cls(q.score)}">${sg(q.score)}</td><td>${tier(q.tier)}</td><td class="r ${rr ? cls(rr.pips) : "mut"}">${rr ? sg(rr.pips, 0) : "–"}</td></tr>`; }).join("")}</tbody></table></div>
      <h3 style="font-size:14px;margin:18px 0 8px">News this week</h3>
      ${news.length ? `<div class="tw"><table><tbody>${news.map((n) => `<tr><td class="mut">${esc(n.date.slice(5))} ${esc(n.time || "")}</td><td class="b">${n.ccy}</td><td class="wrap" style="white-space:normal">${esc(n.event)}</td><td class="r">${isNum(n.actual) ? "<b>" + f(n.actual, 2) + "</b>" : "f " + f(n.forecast, 2)}</td><td class="r ${cls(isNum(n.liveScore) ? n.liveScore : n.score)}">${sg(isNum(n.liveScore) ? n.liveScore : n.score, 1)}</td></tr>`).join("")}</tbody></table></div>` : `<p class="mut">No scored news.</p>`}`;
    $("#drawer").classList.add("on");
  }

  /* ---------- shell ---------- */
  const TABS = [["overview", "Overview"], ["currencies", "Currencies"], ["factors", "Factors"], ["pairs", "Pairs"], ["news", "News"], ["history", "History"], ["performance", "Performance"], ["about", "About"]];
  function render() {
    const w = week();
    $("#weekSel").innerHTML = WEEKS.slice().reverse().map((x) => `<option value="${x.id}" ${x.id === state.wk ? "selected" : ""}>${esc(x.label)}${x.id === currentWeekId() ? " · current" : ""}${x.missing ? " (no file)" : ""}</option>`).join("");
    const nAl = w ? alertsFor(w).filter((a) => a.lvl !== "ok").length : 0;
    $("#tabs").innerHTML = TABS.map(([k, l]) => `<button data-tab="${k}" class="${state.tab === k ? "on" : ""}">${l}${k === "overview" && nAl ? `<span class="badge">${nAl}</span>` : ""}</button>`).join("");
    const live = $("#liveDot");
    live.className = "status-dot " + (state.live && Date.now() - new Date(state.live.at).getTime() < 3 * 3600e3 ? "on" : navigator.onLine ? "" : "off");
    live.querySelector("span").textContent = state.live && Date.now() - new Date(state.live.at).getTime() < 3 * 3600e3 ? "MT5 live" : navigator.onLine ? "Online" : "Offline";
    let html = "";
    if (!w) html = `<div class="empty">No data.</div>`;
    else if (state.tab === "overview") html = vOverview(w);
    else if (state.tab === "currencies") html = vCurrencies(w);
    else if (state.tab === "factors") html = vFactors(w);
    else if (state.tab === "pairs") html = vPairs(w);
    else if (state.tab === "news") html = vNews(w);
    else if (state.tab === "history") html = vHistory();
    else if (state.tab === "performance") html = vPerformance();
    else html = vAbout();
    $("#main").innerHTML = html;
  }

  document.addEventListener("click", (e) => {
    const t = e.target.closest("[data-tab],[data-pair],[data-pf],[data-factor],[data-cot],[data-week],[data-go],[data-close],#btnNotif,#btnRefresh,#drawer");
    if (!t) return;
    if (t.id === "drawer" && e.target === t) return t.classList.remove("on");
    if (t.dataset.close !== undefined) return $("#drawer").classList.remove("on");
    if (t.id === "btnNotif") { if ("Notification" in window) Notification.requestPermission().then(render); return; }
    if (t.id === "btnRefresh") { loadLive(); loadRates(true); return; }
    if (t.dataset.tab) { state.tab = t.dataset.tab; LS.set("fx_tab", state.tab); render(); window.scrollTo(0, 0); }
    else if (t.dataset.go) { state.tab = t.dataset.go; LS.set("fx_tab", state.tab); render(); }
    else if (t.dataset.pair) openPair(t.dataset.pair);
    else if (t.dataset.pf) { state.pairFilter = t.dataset.pf; LS.set("fx_pf", state.pairFilter); render(); }
    else if (t.dataset.factor) { state.factor = t.dataset.factor; LS.set("fx_factor", state.factor); render(); }
    else if (t.dataset.cot) { state.cotCcy = t.dataset.cot; LS.set("fx_cotccy2", state.cotCcy); render(); }
    else if (t.dataset.week) { state.wk = t.dataset.week; LS.set("fx_wk", state.wk); state.tab = "overview"; render(); window.scrollTo(0, 0); }
  });
  document.addEventListener("change", (e) => { if (e.target.id === "weekSel") { state.wk = e.target.value; LS.set("fx_wk", state.wk); render(); } });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") $("#drawer").classList.remove("on"); });

  /* ---------- live feed (MT5 monitor → data/live.json) ---------- */
  async function loadLive() {
    let j = null;
    try {
      // MT5 monitor commits live.json to the 'live' branch; the contents API is not CDN-cached.
      const urls = [["https://api.github.com/repos/aamirrehansh/fx-bias-dashboard/contents/data/live.json?ref=live", { headers: { Accept: "application/vnd.github.raw+json" }, cache: "no-store" }], ["data/live.json?t=" + Date.now(), { cache: "no-store" }]];
      for (const [u, o] of urls) { try { const res = await fetch(u, o); if (res.ok) { j = await res.json(); break; } } catch (e) { } }
      if (!j) throw new Error("none");
      LS.set("fx_live", j);
      state.liveErr = null;
    } catch (e) { state.liveErr = navigator.onLine ? "no live file yet" : "offline"; j = LS.get("fx_live", null); }
    const prevAlerts = new Set(LS.get("fx_seen", []));
    state.live = j && j.week ? j : null;
    const w = WEEKS.find((x) => x.id === currentWeekId());
    if (w) {
      const fresh = alertsFor(w).filter((a) => a.lvl !== "ok").filter((a) => !prevAlerts.has(a.text));
      if (fresh.length && "Notification" in window && Notification.permission === "granted") {
        const reg = navigator.serviceWorker && (await navigator.serviceWorker.getRegistration());
        fresh.slice(0, 3).forEach((a) => { const o = { body: a.text, tag: a.pair || a.text, icon: "icons/icon-192.png" }; if (reg) reg.showNotification("FX Bias alert", o); else new Notification("FX Bias alert", o); });
      }
      LS.set("fx_seen", Array.from(new Set([...prevAlerts, ...fresh.map((a) => a.text)])).slice(-200));
    }
    render();
  }

  if ("serviceWorker" in navigator && location.protocol.startsWith("http")) navigator.serviceWorker.register("sw.js").catch(() => { });
  window.addEventListener("online", () => { loadLive(); loadRates(); render(); });
  window.addEventListener("offline", render);
  render();
  loadLive();
  loadRates();
  setInterval(loadLive, 5 * 60 * 1000);
  setInterval(() => loadRates(), 60 * 60 * 1000);
})();

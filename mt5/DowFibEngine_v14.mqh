//+------------------------------------------------------------------+
//| DowFibEngine_v14.mqh                                              |
//| v14 = dow_fib_mtf14.pine: + sweep rule (a sweep beyond the last   |
//|   HL / LH without a trend break becomes the new pending HL / LH;  |
//|   trend then fails only beyond the swept level), HH / LL never    |
//|   move back on a successive HL / LH.                              |
//| Line-by-line MQL5 port of Aamir's TradingView indicator           |
//| "Dow Fib Structure MTF (Daily + 1H)" (dow_fib_mtf11.pine, v6):    |
//| the structure ENGINE only (method core / scanExt / feed).         |
//|                                                                   |
//| New vs the mtf6 port:                                             |
//|  - seqMode: successive lower highs / higher lows confirm the      |
//|    previous pending LH / HL even without a new LL / HH.           |
//|  - trend ends only after brkBars consecutive closes beyond the    |
//|    last HL / LH by more than brkBuf x ATR(14) of the structure TF |
//|    (single-candle spikes = sweeps).                               |
//|  - FibBase(): Fib 100% anchor = newest HL / LH incl. pending      |
//|    (indicator default "Newest HL / LH (incl. pending)").          |
//|                                                                   |
//| Usage (Aamir's current settings):                                 |
//|   CDowFibEngine d1(23.6, 3, 730, true, true, 2, 0.5, true);       |
//|   CDowFibEngine h1(38.2, 5, 120, true, true, 2, 0.5, true);       |
//|   d1.Build(sym, PERIOD_D1);  h1.Build(sym, PERIOD_H1);            |
//|   Trend() 1/-1/0 | FailLevel() last HL/LH | Extreme() HH/LL       |
//|   HasPending() Pending() PendingPct() | OriginPrice() OriginTime() |
//|   FibBase(true)  = 100% anchor (pending if any, else FailLevel)   |
//|   FibLevel(pct, true) = price at pct% (0 = HH/LL, 100 = anchor)   |
//| Old 5-argument constructor still compiles (defaults 2 / 0.5 / on). |
//+------------------------------------------------------------------+
#property strict

class CDowFibEngine
{
private:
   // settings
   double   m_fibMin;
   int      m_sw;
   int      m_days;
   bool     m_useImp;     // "Last impulse" (true) vs "Last HL / LH (whole leg)"
   bool     m_brkClose;   // "Close" (true) vs "Wick"
   int      m_brkBars;    // closes beyond HL / LH to end trend
   double   m_brkBuf;     // break buffer x ATR
   bool     m_seq;        // successive lower highs / higher lows count
   bool     m_sweepRule;  // v14: sweep beyond last HL / LH becomes the new pending HL / LH
   bool     m_pendSweep;
   // structure-bar history
   double   m_hs[], m_ls[], m_cs[];
   datetime m_hts[], m_lts[];
   int      m_n;
   // trend state
   int      m_trend;
   bool     m_fromWindow;
   int      m_oIdx;
   double   m_oPx;
   double   m_legLow;  int m_legLowIdx;
   double   m_legHigh; int m_legHighIdx;
   double   m_impLow, m_impHigh;
   bool     m_hasMn;   double m_mn; int m_mnIdx;
   bool     m_hasMx;   double m_mx; int m_mxIdx;
   bool     m_hasPend; double m_pend; int m_pendIdx; double m_pendRet;
   bool     m_hasPX;   double m_pX;   int m_pXIdx;
   bool     m_hasAtr;  double m_atr;
   int      m_brkCnt;

   void Push(double h, double l, double c, datetime hT, datetime lT)
   {
      ArrayResize(m_hs, m_n + 1, 1024); ArrayResize(m_ls, m_n + 1, 1024); ArrayResize(m_cs, m_n + 1, 1024);
      ArrayResize(m_hts, m_n + 1, 1024); ArrayResize(m_lts, m_n + 1, 1024);
      m_hs[m_n] = h; m_ls[m_n] = l; m_cs[m_n] = c; m_hts[m_n] = hT; m_lts[m_n] = lT;
      m_n++;
   }

   // Pine: method scanExt - extreme reached since the pending HL / LH
   void ScanExt(int i)
   {
      m_hasPX = false; m_pX = 0; m_pXIdx = -1;
      if(m_hasPend && m_pendIdx >= 0 && m_pendIdx < i)
      {
         for(int k = m_pendIdx + 1; k <= i; k++)
         {
            double v = (m_trend == 1) ? m_hs[k] : m_ls[k];
            if(!m_hasPX || (m_trend == 1 ? v > m_pX : v < m_pX))
            { m_pX = v; m_pXIdx = k; m_hasPX = true; }
         }
      }
   }

   // Pine: method core(Eng e, int i) - one structure bar of the active trend
   void Core(int i)
   {
      int    sw = m_sw;
      double h  = m_hs[i];
      double l  = m_ls[i];
      double c  = m_cs[i];
      double uS = m_brkClose ? c : h;
      double dS = m_brkClose ? c : l;
      int    pi = i - sw;
      bool   isPH = false, isPL = false;
      if(pi - sw >= 0)
      {
         isPH = true; isPL = true;
         double ph0 = m_hs[pi], pl0 = m_ls[pi];
         for(int j = 1; j <= sw; j++)
         {
            if(m_hs[pi - j] >= ph0 || m_hs[pi + j] > ph0) isPH = false;
            if(m_ls[pi - j] <= pl0 || m_ls[pi + j] < pl0) isPL = false;
         }
      }
      if(m_trend == 1)
      {
         // pullback low -> pending HL if it retraced at least fibMin
         if(isPL && pi > m_legHighIdx && m_ls[pi] > m_legLow)
         {
            double p = m_ls[pi];
            if(m_seq && m_hasPend && p > m_pend && pi > m_pendIdx && m_hasPX && m_pXIdx < pi && m_pX > m_pend)
            {
               // successive higher low: previous pending low becomes an HL
               double r2 = (m_pX - p) / (m_pX - m_pend) * 100.0;
               if(r2 >= m_fibMin)
               {
                  m_legLow = m_pend; m_legLowIdx = m_pendIdx; m_impLow = m_pend;
                  if(m_pX > m_legHigh) { m_legHigh = m_pX;  m_legHighIdx = m_pXIdx; }
                  m_hasMn = false;
                  m_pend = p; m_pendIdx = pi; m_pendRet = r2; m_hasPend = true; m_pendSweep = false;
                  ScanExt(i);
               }
            }
            else
            {
               double bs  = m_useImp ? m_impLow : m_legLow;
               double rng = m_legHigh - bs;
               double ret = rng > 0 ? (m_legHigh - p) / rng * 100.0 : 0.0;
               if(ret >= m_fibMin && (!m_hasPend || p < m_pend))
               {
                  m_pend = p; m_pendIdx = pi; m_pendRet = ret; m_hasPend = true; m_pendSweep = false;
                  ScanExt(i);
               }
            }
         }
         else if(m_sweepRule && isPL && pi > m_legHighIdx && m_ls[pi] <= m_legLow && (!m_hasPend || m_ls[pi] < m_pend))
         {
            // sweep below the last HL without a trend break -> swept low is the new pending HL
            double p = m_ls[pi];
            if(m_hasPend && !m_pendSweep) { m_legLow = m_pend; m_legLowIdx = m_pendIdx; }
            double rng = m_legHigh - m_legLow;
            m_pendRet = rng > 0 ? (m_legHigh - p) / rng * 100.0 : 0.0;
            m_pend = p; m_pendIdx = pi; m_pendSweep = true; m_hasPend = true;
            ScanExt(i);
         }
         if(m_hasPend)
         {
            // break of the HH confirms the HL
            if(uS > m_legHigh)
            {
               m_legLow = m_pend; m_legLowIdx = m_pendIdx; m_impLow = m_pend;
               m_hasMn = false; m_hasPend = false; m_pendSweep = false; m_pendIdx = -1;
               m_legHigh = h; m_legHighIdx = i;
            }
         }
         else if(h > m_legHigh)
         {
            if(m_hasMn && m_mnIdx - m_legHighIdx >= sw && m_mn > m_legLow) m_impLow = m_mn;
            m_legHigh = h; m_legHighIdx = i; m_hasMn = false;
         }
         if(m_legHighIdx != i && (!m_hasMn || l < m_mn)) { m_mn = l; m_mnIdx = i; m_hasMn = true; }
         if(m_hasPend && i > m_pendIdx && (!m_hasPX || h > m_pX)) { m_pX = h; m_pXIdx = i; m_hasPX = true; }
      }
      else if(m_trend == -1)
      {
         // pullback high -> pending LH if it retraced at least fibMin
         if(isPH && pi > m_legLowIdx && m_hs[pi] < m_legHigh)
         {
            double p = m_hs[pi];
            if(m_seq && m_hasPend && p < m_pend && pi > m_pendIdx && m_hasPX && m_pXIdx < pi && m_pX < m_pend)
            {
               // successive lower high: previous pending high becomes an LH
               double r2 = (p - m_pX) / (m_pend - m_pX) * 100.0;
               if(r2 >= m_fibMin)
               {
                  m_legHigh = m_pend; m_legHighIdx = m_pendIdx; m_impHigh = m_pend;
                  if(m_pX < m_legLow) { m_legLow = m_pX;    m_legLowIdx = m_pXIdx; }
                  m_hasMx = false;
                  m_pend = p; m_pendIdx = pi; m_pendRet = r2; m_hasPend = true; m_pendSweep = false;
                  ScanExt(i);
               }
            }
            else
            {
               double bs  = m_useImp ? m_impHigh : m_legHigh;
               double rng = bs - m_legLow;
               double ret = rng > 0 ? (p - m_legLow) / rng * 100.0 : 0.0;
               if(ret >= m_fibMin && (!m_hasPend || p > m_pend))
               {
                  m_pend = p; m_pendIdx = pi; m_pendRet = ret; m_hasPend = true; m_pendSweep = false;
                  ScanExt(i);
               }
            }
         }
         else if(m_sweepRule && isPH && pi > m_legLowIdx && m_hs[pi] >= m_legHigh && (!m_hasPend || m_hs[pi] > m_pend))
         {
            // sweep above the last LH without a trend break -> swept high is the new pending LH
            double p = m_hs[pi];
            if(m_hasPend && !m_pendSweep) { m_legHigh = m_pend; m_legHighIdx = m_pendIdx; }
            double rng = m_legHigh - m_legLow;
            m_pendRet = rng > 0 ? (p - m_legLow) / rng * 100.0 : 0.0;
            m_pend = p; m_pendIdx = pi; m_pendSweep = true; m_hasPend = true;
            ScanExt(i);
         }
         if(m_hasPend)
         {
            // break of the LL confirms the LH
            if(dS < m_legLow)
            {
               m_legHigh = m_pend; m_legHighIdx = m_pendIdx; m_impHigh = m_pend;
               m_hasMx = false; m_hasPend = false; m_pendSweep = false; m_pendIdx = -1;
               m_legLow = l; m_legLowIdx = i;
            }
         }
         else if(l < m_legLow)
         {
            if(m_hasMx && m_mxIdx - m_legLowIdx >= sw && m_mx < m_legHigh) m_impHigh = m_mx;
            m_legLow = l; m_legLowIdx = i; m_hasMx = false;
         }
         if(m_legLowIdx != i && (!m_hasMx || h > m_mx)) { m_mx = h; m_mxIdx = i; m_hasMx = true; }
         if(m_hasPend && i > m_pendIdx && (!m_hasPX || l < m_pX)) { m_pX = l; m_pXIdx = i; m_hasPX = true; }
      }
   }

   // Pine: method feed(...) - one completed structure bar
   void Feed(double h, double l, double c, datetime hT, datetime lT, datetime startT)
   {
      if(m_trend == 0)
      {
         if(hT >= startT)
         {
            Push(h, l, c, hT, lT);
            m_trend = 1; m_fromWindow = true;
            m_oIdx = 0; m_oPx = l;
            m_legLow = l; m_legLowIdx = 0;
            m_legHigh = h; m_legHighIdx = 0;
            m_impLow = l;
            m_atr = h - l; m_hasAtr = true;
         }
         return;
      }
      Push(h, l, c, hT, lT);
      int i = m_n - 1;
      double pc = m_cs[i - 1];
      double tr = MathMax(h - l, MathMax(MathAbs(h - pc), MathAbs(l - pc)));
      m_atr = m_hasAtr ? (m_atr * 13.0 + tr) / 14.0 : tr; m_hasAtr = true;
      Core(i);
      double uS  = m_brkClose ? c : h;
      double dS  = m_brkClose ? c : l;
      double buf = m_brkBuf * m_atr;
      bool   swp   = m_pendSweep && m_hasPend;
      double lvlLo = swp ? MathMin(m_pend, m_legLow) : m_legLow;
      double lvlHi = swp ? MathMax(m_pend, m_legHigh) : m_legHigh;
      bool beyond = (m_trend == 1) ? (dS < lvlLo - buf) : (uS > lvlHi + buf);
      m_brkCnt = beyond ? m_brkCnt + 1 : 0;
      // trend change (CHoCH) -> new trend starts from the latest HH / LL, replay from there
      if(m_trend == 1 && m_brkCnt >= m_brkBars)
      {
         m_brkCnt = 0;
         m_trend = -1; m_fromWindow = false;
         m_oIdx = m_legHighIdx; m_oPx = m_legHigh;
         m_legHigh = m_oPx; m_legHighIdx = m_oIdx;
         m_legLow = m_ls[m_oIdx]; m_legLowIdx = m_oIdx;
         m_impHigh = m_oPx;
         m_hasMx = false; m_hasPend = false; m_pendSweep = false; m_pendIdx = -1;
         for(int k = m_oIdx + 1; k <= i; k++) Core(k);
      }
      else if(m_trend == -1 && m_brkCnt >= m_brkBars)
      {
         m_brkCnt = 0;
         m_trend = 1; m_fromWindow = false;
         m_oIdx = m_legLowIdx; m_oPx = m_legLow;
         m_legLow = m_oPx; m_legLowIdx = m_oIdx;
         m_legHigh = m_hs[m_oIdx]; m_legHighIdx = m_oIdx;
         m_impLow = m_oPx;
         m_hasMn = false; m_hasPend = false; m_pendSweep = false; m_pendIdx = -1;
         for(int k = m_oIdx + 1; k <= i; k++) Core(k);
      }
   }

public:
   CDowFibEngine(double fibMin, int swingBars, int lookbackDays, bool lastImpulse, bool breakByClose,
                 int breakBars = 2, double breakBufAtr = 0.5, bool seqMode = true, bool sweepRule = true)
   {
      m_fibMin = fibMin; m_sw = swingBars; m_days = lookbackDays;
      m_useImp = lastImpulse; m_brkClose = breakByClose;
      m_brkBars = MathMax(1, breakBars); m_brkBuf = MathMax(0.0, breakBufAtr); m_seq = seqMode; m_sweepRule = sweepRule;
      Reset();
   }

   void Reset()
   {
      m_n = 0;
      ArrayResize(m_hs, 0); ArrayResize(m_ls, 0); ArrayResize(m_cs, 0); ArrayResize(m_hts, 0); ArrayResize(m_lts, 0);
      m_trend = 0; m_fromWindow = false; m_oIdx = 0; m_oPx = 0;
      m_legLow = 0; m_legLowIdx = 0; m_legHigh = 0; m_legHighIdx = 0;
      m_impLow = 0; m_impHigh = 0;
      m_hasMn = false; m_mn = 0; m_mnIdx = 0;
      m_hasMx = false; m_mx = 0; m_mxIdx = 0;
      m_hasPend = false; m_pend = 0; m_pendIdx = -1; m_pendRet = 0; m_pendSweep = false;
      m_hasPX = false; m_pX = 0; m_pXIdx = -1;
      m_hasAtr = false; m_atr = 0; m_brkCnt = 0;
   }

   // Rebuild from closed bars of symbol/tf inside the lookback window. false = not enough history.
   // asOf (server time, 0 = now): use only bars fully closed by then (for checking against a past TradingView reading)
   bool Build(string symbol, ENUM_TIMEFRAMES tf, datetime asOf = 0)
   {
      Reset();
      // Pine: start = last_bar_time - days. Aamir reads the table on a 1H chart, so last_bar_time = current H1 bar.
      datetime lastT = iTime(symbol, PERIOD_H1, 0);
      if(asOf > 0) { int sh = iBarShift(symbol, PERIOD_H1, asOf, false); lastT = (sh >= 0 ? iTime(symbol, PERIOD_H1, sh) : asOf); }
      if(lastT <= 0) lastT = iTime(symbol, tf, 0);
      if(lastT <= 0) return false;
      int per = PeriodSeconds(tf);
      datetime startT = lastT - (datetime)((long)m_days * 86400);
      int oldest = iBarShift(symbol, tf, startT, false);
      int bars = Bars(symbol, tf);
      if(oldest < 0 || oldest >= bars) oldest = bars - 1;
      for(int s = oldest; s >= 1; s--)
      {
         datetime t = iTime(symbol, tf, s);
         double h = iHigh(symbol, tf, s), l = iLow(symbol, tf, s), c = iClose(symbol, tf, s);
         if(t <= 0 || h <= 0) continue;
         if(asOf > 0 && t + per > asOf) break;              // bar not closed yet at asOf
         Feed(h, l, c, t, t, startT);
      }
      return (m_trend != 0);
   }

   int      Trend()       const { return m_trend; }
   double   FailLevel()   const { return (m_pendSweep && m_hasPend) ? m_pend : (m_trend == 1 ? m_legLow : m_legHigh); }   // table "Last HL / LH (fails beyond)"
   bool     PendingIsSweep() const { return m_pendSweep && m_hasPend; }
   double   Extreme()     const { return m_trend == 1 ? m_legHigh : m_legLow; }   // Latest HH / LL
   bool     HasPending()  const { return m_hasPend; }
   double   Pending()     const { return m_hasPend ? m_pend : 0.0; }
   double   PendingPct()  const { return m_hasPend ? m_pendRet : 0.0; }
   double   OriginPrice() const { return m_oPx; }
   datetime OriginTime()  const { return (m_n > 0) ? (m_trend == 1 ? m_lts[m_oIdx] : m_hts[m_oIdx]) : 0; }
   double   Atr()         const { return m_atr; }                                  // ATR(14) of the structure TF
   double   BreakLevel()  const                                                     // trend really ends beyond this (fail +/- buffer)
   { return m_trend == 1 ? FailLevel() - m_brkBuf * m_atr : FailLevel() + m_brkBuf * m_atr; }
   // Fib 100% anchor: "Newest HL / LH (incl. pending)" when newest = true, else last confirmed HL / LH
   double   FibBase(bool newest = true) const { return (newest && m_hasPend && !m_pendSweep) ? m_pend : (m_trend == 1 ? m_legLow : m_legHigh); }
   // price at pct% of the Fib (0% = latest HH / LL, 100% = anchor), same formula as the indicator
   double   FibLevel(double pct, bool newest = true) const
   {
      double ext = Extreme(), base = FibBase(newest);
      return (m_trend == 1) ? ext - (ext - base) * pct / 100.0 : ext + (base - ext) * pct / 100.0;
   }
   string   Describe(int digits) const
   {
      if(m_trend == 0) return "no structure";
      return StringFormat("%s since %s @ %s%s | fails beyond %s | latest %s %s | pending %s",
                          m_trend == 1 ? "UPTREND" : "DOWNTREND", TimeToString(OriginTime(), TIME_DATE),
                          DoubleToString(m_oPx, digits), m_fromWindow ? " (lookback)" : "",
                          DoubleToString(FailLevel(), digits),
                          m_trend == 1 ? "HH" : "LL", DoubleToString(Extreme(), digits),
                          m_hasPend ? DoubleToString(m_pend, digits) + StringFormat(" %.1f%%", m_pendRet)
                                    : StringFormat("none (<%.1f%%)", m_fibMin));
   }
};
//+------------------------------------------------------------------+

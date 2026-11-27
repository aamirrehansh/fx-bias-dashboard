//+------------------------------------------------------------------+
//| FX_Bias_Monitor_V1_05_MT5.mq5                                    |
//| Live monitor for the weekly Sarmaaya bias model. Does NOT trade. |
//|  - downloads this week's plan (data/plan.csv) from GitHub        |
//|  - reads news actuals from the MT5 economic calendar             |
//|  - re-scores News -> currency strength -> 28 pair scores         |
//|  - V1.04: Investogenie Pulse - counts tracked Forex Factory       |
//|    releases (actual vs previous) into Conditional +/- and        |
//|    re-scores the Fundamental layer live                          |
//|  - V1.05: setup scanner - every H1 close, all 28 pairs with a     |
//|    live |score| >= ScanMinScore run the Dow Fib gate (D1 + H1,   |
//|    DowFibEngine_v14.mqh = Aamir's TradingView indicator v14) and  |
//|    push NEW SETUP alerts. Needs DowFibEngine_v14.mqh next to it. |
//|  - V1.07: shortlist always gated live; push only if |score|>=50|
//|  - V1.08: Saturday export of last 21 D1 bars to FXDaily\recent    |
//|  - V1.08: defaults ConvictionLine/ScanMinScore 25 (26-Nov rescale)|
//|  - V1.08: plan "FR" rows = Fund is raw Investogenie rank; Pulse  |
//|    still counts Conditional but no longer rewrites Fund         |
//|  - push alerts (MetaTrader app) when a shortlisted pair's bias   |
//|    flips / score weakens, or price breaks the invalidation level |
//|  - writes live.json (MQL5\Files common) and optionally commits   |
//|    it to the 'live' branch so the dashboard app shows it.        |
//| Setup: Tools > Options > Expert Advisors > Allow WebRequest for: |
//|   https://raw.githubusercontent.com                              |
//|   https://api.github.com                                         |
//|   https://www.forexfactory.com   (actuals fallback, V1.02)        |
//| Tools > Options > Notifications: enable + your MetaQuotes ID.    |
//| Attach to ONE chart (any symbol, any timeframe).                 |
//+------------------------------------------------------------------+
#property copyright "FX28 weekly model"
#property version   "1.08"
#include "DowFibEngine_v14.mqh"
#property strict

input string PlanURL        = "https://raw.githubusercontent.com/aamirrehansh/fx-bias-dashboard/main/data/plan.csv";
input int    CheckSeconds   = 60;      // news / price check interval
input int    PlanRefreshMin = 60;      // re-download plan every N minutes
input string SymbolSuffix   = "";      // broker suffix, e.g. ".r" (blank = auto-detect)
input bool   PushAlerts     = true;    // SendNotification to the MetaTrader mobile app
input bool   PopupAlerts    = true;    // terminal Alert() popup
input bool   PushKeyOnly    = true;    // 1.06: phone push + popup only for NEW SETUP and BIAS FLIPPED (all else -> log + app)
input double ScoreAlertDrop = 15.0;    // alert if |score| weakens by this much vs plan
input double ConvictionLine = 25.0;    // alert if |score| falls below this (from above)
input bool   AlertWatchPairs= true;    // include WATCH / RESERVE pairs in alerts
input string GitHubToken    = "";      // fine-grained token: Contents read/write on fx-bias-dashboard only (blank = no upload)
input string GitHubRepo     = "aamirrehansh/fx-bias-dashboard";
input string GitHubBranch   = "live";
input int    PublishMinutes = 10;      // upload live.json at most every N minutes (and on any alert)
input bool   UseForexFactory= true;    // read actuals from forexfactory.com when the MT5 calendar has none
input int    FFPollSeconds  = 90;      // FF poll interval while a released event is still missing
input bool   UsePulse       = true;    // V1.04: live Conditional (Investogenie Pulse) from Forex Factory
input int    PulsePollSec   = 180;     // Pulse: FF poll interval (seconds)
input bool   PulsePush      = true;    // push when a currency's Conditional state / fundamental score changes
input bool   ScanSetups     = true;    // V1.05: scan all 28 pairs for new setups at every H1 close
input double ScanMinScore   = 25.0;    // scanner: min |live pair score|
input bool   SetupPush      = true;    // scanner: push NEW SETUP alerts
input double D1FibMin       = 23.6;    // Dow Fib D1: min retracement for HL / LH (%)
input int    D1Swing        = 5;       // Dow Fib D1: swing confirmation bars
input int    D1Days         = 730;     // Dow Fib D1: lookback days
input double H1FibMin       = 38.2;    // Dow Fib H1: min retracement for HL / LH (%)
input int    H1Swing        = 5;       // Dow Fib H1: swing confirmation bars
input int    H1Days         = 120;     // Dow Fib H1: lookback days
input int    DFBreakBars    = 2;       // Dow Fib: closes beyond HL / LH to end trend
input double DFBreakBuf     = 0.5;     // Dow Fib: break buffer x ATR
input string CheckAsOfUTC   = "2026.11.21 19:50";   // one-off check vs Sunday TradingView read (blank = off)
input bool   WeeklyD1Export = true;    // 1.08: every Saturday export the last D1ExportDays daily bars (28 pairs + XAUUSD + USTEC) to Common\Files\FXDaily\recent
input int    D1ExportDays   = 21;      // calendar days per weekly export (only new days are appended to the 10y history)
input double MaxH1PullbackPct = 61.8;  // 1.08 (Aamir 27-Nov: entry zone 50-61.8%): no ENTRY when H1 pullback is beyond this % (price too close to the H1 SL level)

//--- model data
string   CCY[8] = {"USD","EUR","GBP","JPY","CHF","CAD","AUD","NZD"};
double   cFund[8], cCot[8], cSeas[8], cNewsPlan[8], cMacro[8], cStrPlan[8];
double   cNews[8], cStr[8];
double   wFund=0.4, wCot=0.2, wSeas=0.1, wNews=0.15, wMacro=0.15, newsMinW=2.0;
string   gWeekId="", gWeekEnd="", gWeekLabel="";
string   gPlanText="";

//--- V1.04 Pulse / Fundamental
double   gFS[19];                  // Settings B11..B14, B15..B18, B21..B26, B27..B31
bool     gHasF=false;
bool     gFundRaw=false;   // 1.08: Fund from plan C rows (raw Investogenie rank), Pulse is display only
double   fInv[8], fLat[8], fCP[8], fCM[8];   // Investogenie change, Latest net, Sunday Cond+/-
double   cFundPlan[8];
string   gBaseMonth="";
string   tCcy[], tName[]; double tPol[];
int      pDay[8][5][2];            // Pulse counts per currency / weekday / (+,-)
int      pNew[8][2];               // releases after the month turned
int      pPlus[8], pMinus[8];
string   pState[8], pStatePrev[8];
string   gPulseEv[];               // JSON event objects
datetime gLastPulse=0, gPulseAt=0, gFFAt=0;
string   gFFPage="";

//--- V1.05 scanner
struct SetupRow
{
   string pair, sym, want, status, d1Trend, h1Trend;
   double score, d1Fail, d1Pct, d1Ext, h1Fail, h1Pct, band, close;
   bool   entry, ready, shortl, conv;
   datetime since;
};
SetupRow gSetups[];
datetime gLastScanBar=0;
string   gCheckJson="";
bool     gCheckDone=false;

struct NewsRow
{
   datetime tUtc;        // release time (UTC)
   string   date, time, ccy, impact, name;
   double   pol, w, fc, pv, planScore;
   bool     matched, released, diagDone;
   ulong    valueId;
   double   actual, score;
};
NewsRow  gNews[];

struct PairRow
{
   string pair, bias, tier, sym, d1Trend, h1Trend;
   double planScore, risk, d1Fail, h1Fail;
   double score;
   string lastState;     // for de-duplicating alerts
   bool   invalidSent, slSent, turnSent, entrySent;
};
PairRow  gPairs[];

string   gAlerts[];          // JSON alert objects for live.json (newest last)
string   gPushQueue[];
datetime gLastPush=0, gLastPlan=0, gLastPublish=0, gLastFF=0;
bool     gFFWarned=false;
bool     gDirty=true;
string   gLiveSha="";

//+------------------------------------------------------------------+
int CcyIdx(const string c){ for(int i=0;i<8;i++) if(CCY[i]==c) return i; return -1; }
double Num(const string s){ string t=s; StringTrimLeft(t); StringTrimRight(t); if(t=="") return EMPTY_VALUE; return StringToDouble(t); }
double Sgn(const double v){ return v>0 ? 1.0 : (v<0 ? -1.0 : 0.0); }
string D2S(const double v,const int d){ if(v==EMPTY_VALUE) return "null"; return DoubleToString(v,d); }
string JsonEsc(const string s){ string r=s; StringReplace(r,"\\","\\\\"); StringReplace(r,"\"","\\\""); return r; }
string IsoUtc(const datetime t){ MqlDateTime m; TimeToStruct(t,m); return StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",m.year,m.mon,m.day,m.hour,m.min,m.sec); }
int    ServerOffset(){ return (int)(TimeTradeServer()-TimeGMT()); }   // seconds, server - UTC

//+------------------------------------------------------------------+
int OnInit()
{
   if(!LoadPlan(true))
      Print("FX Bias Monitor: no plan yet (will retry). Check WebRequest URLs in Tools > Options > Expert Advisors.");
   EventSetTimer(MathMax(10,CheckSeconds));
   OnTimer();
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason){ EventKillTimer(); Comment(""); }
void OnTick(){}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| 1.08 weekly D1 export (same format as FX_Export_D1_History.mq5)  |
//+------------------------------------------------------------------+
string gD1ExportWeek="";
string D1Resolve(const string base)
{
   if(base=="USTEC")
   {
      string al[]={"USTEC","NAS100","US100","NDX100","USTECH","NQ100"};
      for(int j=0;j<ArraySize(al);j++){ string r=ResolveSymbol(al[j]); if(r!="" && SymbolInfoInteger(r,SYMBOL_DIGITS)>0) return r; }
      return "";
   }
   return ResolveSymbol(base);
}
void WeeklyExport()
{
   MqlDateTime m; TimeToStruct(TimeTradeServer(),m);
   if(m.day_of_week!=6) return;                                  // Saturday (server time)
   string wk=TimeToString(TimeTradeServer(),TIME_DATE);
   if(gD1ExportWeek==wk) return;
   string list[]={"EURUSD","GBPUSD","AUDUSD","NZDUSD","USDJPY","USDCHF","USDCAD","EURGBP","EURAUD","EURNZD","EURJPY","EURCHF","EURCAD",
                  "GBPAUD","GBPNZD","GBPJPY","GBPCHF","GBPCAD","AUDNZD","AUDJPY","AUDCHF","AUDCAD","NZDJPY","NZDCHF","NZDCAD","CADJPY","CADCHF","CHFJPY","XAUUSD","USTEC"};
   datetime from=TimeCurrent()-(datetime)((long)D1ExportDays*86400);
   int ok=0;
   int s=FileOpen("FXDaily\\recent\\_summary.csv",FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(s!=INVALID_HANDLE) FileWriteString(s,"symbol,bars,first,last,server\r\n");
   for(int i=0;i<ArraySize(list);i++)
   {
      string sym=D1Resolve(list[i]); if(sym=="") continue;
      MqlRates r[]; int got=CopyRates(sym,PERIOD_D1,from,TimeCurrent(),r);
      if(got<=0) continue;
      int dg=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
      int h=FileOpen("FXDaily\\recent\\"+list[i]+"_D1.csv",FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h==INVALID_HANDLE) continue;
      FileWriteString(h,"date,open,high,low,close,tick_volume\r\n");
      for(int k=0;k<got;k++)
         FileWriteString(h,StringFormat("%s,%s,%s,%s,%s,%I64d\r\n",TimeToString(r[k].time,TIME_DATE),DoubleToString(r[k].open,dg),DoubleToString(r[k].high,dg),
                         DoubleToString(r[k].low,dg),DoubleToString(r[k].close,dg),r[k].tick_volume));
      FileClose(h); ok++;
      if(s!=INVALID_HANDLE) FileWriteString(s,StringFormat("%s,%d,%s,%s,%s\r\n",list[i],got,TimeToString(r[0].time,TIME_DATE),TimeToString(r[got-1].time,TIME_DATE),AccountInfoString(ACCOUNT_SERVER)));
   }
   if(s!=INVALID_HANDLE) FileClose(s);
   if(ok>=ArraySize(list)-1){ gD1ExportWeek=wk; PrintFormat("FX Bias Monitor: weekly D1 export done, %d symbols -> Common\\Files\\FXDaily\\recent",ok); }
   else PrintFormat("FX Bias Monitor: weekly D1 export got %d of %d symbols, will retry",ok,ArraySize(list));
}

void OnTimer()
{
   if(WeeklyD1Export) WeeklyExport();
   if(TimeGMT()-gLastPlan >= PlanRefreshMin*60) LoadPlan(false);
   if(ArraySize(gPairs)>0)
   {
      MatchNews();
      UpdateNews();
      if(UseForexFactory) UpdateFromFF();
      if(UsePulse) UpdatePulse();
      if(ScanSetups) ScanAll(false);
      if(CheckAsOfUTC!="" && !gCheckDone) RunCheck();
      Recompute();
      CheckAlerts();
      CheckPrices();
      WriteLive();
      Panel();
   }
   FlushPush();
}

//+------------------------------------------------------------------+
//| Plan download / parse                                            |
//+------------------------------------------------------------------+
bool HttpGet(const string url,string &body)
{
   char data[], res[]; string rh;
   ResetLastError();
   int code=WebRequest("GET",url,"User-Agent: FXBiasMonitor\r\nCache-Control: no-cache\r\n",8000,data,res,rh);
   if(code!=200){ if(code==-1) PrintFormat("WebRequest error %d for %s (add the URL in Tools > Options > Expert Advisors)",GetLastError(),url); return false; }
   body=CharArrayToString(res,0,WHOLE_ARRAY,CP_UTF8);
   return true;
}

bool LoadPlan(const bool first)
{
   gLastPlan=TimeGMT();
   string txt="";
   string url=PlanURL+"?t="+IntegerToString((long)TimeGMT());
   if(HttpGet(url,txt))
   {
      int h=FileOpen("FXBias\\plan.csv",FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_ANSI);
      if(h!=INVALID_HANDLE){ FileWriteString(h,txt); FileClose(h); }
   }
   else
   {
      int h=FileOpen("FXBias\\plan.csv",FILE_READ|FILE_TXT|FILE_COMMON|FILE_ANSI);
      if(h==INVALID_HANDLE) return false;
      while(!FileIsEnding(h)) txt+=FileReadString(h)+"\n";
      FileClose(h);
   }
   if(txt==gPlanText) return true;           // unchanged
   gPlanText=txt;
   return ParsePlan(txt);
}

bool ParsePlan(const string txt)
{
   string lines[]; int n=StringSplit(txt,'\n',lines);
   if(n<5) return false;
   ArrayResize(gNews,0); ArrayResize(gPairs,0);
   ArrayResize(tCcy,0); ArrayResize(tName,0); ArrayResize(tPol,0); gHasF=false; gFundRaw=false;
   double defFS[19]={2,10,25,50,0.25,0.5,0.75,1,1,0.75,0.5,0.5,0.25,0,3,0.25,0.25,0.125,0.375};
   ArrayCopy(gFS,defFS);
   for(int i=0;i<n;i++)
   {
      string ln=lines[i]; StringReplace(ln,"\r","");
      if(ln=="") continue;
      string f[]; int k=StringSplit(ln,',',f);
      if(k<2) continue;
      if(f[0]=="WEEK" && k>=4){ gWeekId=f[1]; gWeekEnd=f[2]; gWeekLabel=f[3]; }
      else if(f[0]=="W" && k>=6){ wFund=Num(f[1]); wCot=Num(f[2]); wSeas=Num(f[3]); wNews=Num(f[4]); wMacro=Num(f[5]); if(k>=7 && Num(f[6])!=EMPTY_VALUE) newsMinW=Num(f[6]); }
      else if(f[0]=="C" && k>=8)
      {
         int c=CcyIdx(f[1]); if(c<0) continue;
         cFund[c]=Num(f[2]); cCot[c]=Num(f[3]); cSeas[c]=Num(f[4]); cNewsPlan[c]=Num(f[5]); cMacro[c]=Num(f[6]); cStrPlan[c]=Num(f[7]);
      }
      else if(f[0]=="FS" && k>=20){ for(int j=0;j<19;j++){ double v=Num(f[j+1]); if(v!=EMPTY_VALUE) gFS[j]=v; } }
      else if((f[0]=="F" || f[0]=="FR") && k>=7)
      {
         int c=CcyIdx(f[1]); if(c<0) continue;
         fInv[c]=Num(f[2]); fLat[c]=Num(f[3]); fCP[c]=Num(f[4]); fCM[c]=Num(f[5]); gBaseMonth=f[6]; gHasF=true;
         if(f[0]=="FR") gFundRaw=true;
      }
      else if(f[0]=="T" && k>=4)
      {
         string nm=f[3]; for(int j=4;j<k;j++) nm+=","+f[j];
         StringTrimLeft(nm); StringTrimRight(nm); StringToLower(nm);
         int m=ArraySize(tName); ArrayResize(tName,m+1); ArrayResize(tCcy,m+1); ArrayResize(tPol,m+1);
         tName[m]=nm; tCcy[m]=f[1]; tPol[m]=Num(f[2]); if(tPol[m]==EMPTY_VALUE) tPol[m]=1;
      }
      else if(f[0]=="N" && k>=11)
      {
         NewsRow r;
         r.date=f[1]; r.time=f[2]; r.ccy=f[3]; r.impact=f[4];
         r.pol=Num(f[5]); r.w=Num(f[6]); r.fc=Num(f[7]); r.pv=Num(f[8]); r.planScore=Num(f[9]);
         r.name=f[10]; for(int j=11;j<k;j++) r.name+=" "+f[j];
         if(r.pol==EMPTY_VALUE) r.pol=1; if(r.w==EMPTY_VALUE) r.w=0.5; if(r.planScore==EMPTY_VALUE) r.planScore=0;
         string dd=r.date; StringReplace(dd,"-",".");
         r.tUtc=StringToTime(dd+" "+(r.time=="" ? "00:00" : r.time))-5*3600;   // PKT = UTC+5
         r.matched=false; r.released=false; r.diagDone=false; r.valueId=0; r.actual=EMPTY_VALUE; r.score=r.planScore;
         int m=ArraySize(gNews); ArrayResize(gNews,m+1); gNews[m]=r;
      }
      else if(f[0]=="P" && k>=8)
      {
         PairRow p;
         p.pair=f[1]; p.bias=f[2]; p.tier=f[3]; p.planScore=Num(f[4]); p.risk=Num(f[5]); p.d1Fail=Num(f[6]); p.h1Fail=Num(f[7]);
         p.d1Trend=(k>=9 ? f[8] : ""); p.h1Trend=(k>=10 ? f[9] : "");
         p.score=p.planScore; p.lastState=""; p.invalidSent=false; p.slSent=false; p.turnSent=false; p.entrySent=false;
         p.sym=ResolveSymbol(p.pair);
         int m=ArraySize(gPairs); ArrayResize(gPairs,m+1); gPairs[m]=p;
      }
   }
   for(int c=0;c<8;c++){ cFundPlan[c]=cFund[c]; pState[c]=""; pStatePrev[c]=""; pPlus[c]=(int)fCP[c]; pMinus[c]=(int)fCM[c]; }
   gLastPulse=0; ArrayResize(gPulseEv,0);
   if(gHasF && !gFundRaw)
      for(int c=0;c<8;c++)
      {
         string st; double y=FundScore(fInv[c],fLat[c],fCP[c]-fCM[c],st);
         if(MathAbs(y-cFundPlan[c])>1e-6) PrintFormat("Note: %s fundamental from plan %.4f, recomputed %.4f",CCY[c],cFundPlan[c],y);
      }
   PrintFormat("FX Bias Monitor: plan %s loaded, %d news rows, %d pairs, %d Pulse events tracked",gWeekLabel,ArraySize(gNews),ArraySize(gPairs),ArraySize(tName));
   Queue(StringFormat("FX Bias: plan loaded for %s (%d shortlisted pairs)",gWeekLabel,CountShort()));
   gDirty=true;
   Recompute();
   return ArraySize(gPairs)>0;
}

int CountShort(){ int c=0; for(int i=0;i<ArraySize(gPairs);i++) if(IsShort(gPairs[i].tier)) c++; return c; }
bool IsShort(const string t){ if(t=="TRADE") return true; if(AlertWatchPairs && (t=="WATCH" || t=="RESERVE")) return true; return false; }

string ResolveSymbol(const string pair)
{
   string s=pair+SymbolSuffix;
   if(SymbolSelect(s,true)) return s;
   int tot=SymbolsTotal(false);
   for(int i=0;i<tot;i++)
   {
      string nm=SymbolName(i,false);
      if(StringFind(nm,pair)==0 && StringLen(nm)<=StringLen(pair)+4){ SymbolSelect(nm,true); return nm; }
   }
   return "";
}

//+------------------------------------------------------------------+
//| News matching against the MT5 economic calendar                  |
//+------------------------------------------------------------------+
string NormName(const string s)
{
   string r=s; StringToLower(r);
   int p=StringFind(r,"*"); if(p>=0) r=StringSubstr(r,0,p);
   // drop "(...)" groups (country, notes)
   while(true){ int a=StringFind(r,"("); if(a<0) break; int b=StringFind(r,")",a); if(b<0) break; r=StringSubstr(r,0,a)+" "+StringSubstr(r,b+1); }
   StringReplace(r,"&"," "); StringReplace(r,"/"," "); StringReplace(r,"-"," "); StringReplace(r,"."," ");
   while(StringFind(r,"  ")>=0) StringReplace(r,"  "," ");
   StringTrimLeft(r); StringTrimRight(r);
   return r;
}
string CountryOf(const string s)
{
   int a=StringFind(s,"("); if(a<0) return "";
   int b=StringFind(s,")",a); if(b<0) return "";
   string c=StringSubstr(s,a+1,b-a-1); StringToLower(c);
   if(c=="euro area" || c=="eurozone") c="european union";
   return c;
}
double Similar(const string a,const string b)
{
   string ta[], tb[]; int na=StringSplit(a,' ',ta), nb=StringSplit(b,' ',tb);
   if(na==0 || nb==0) return 0;
   int common=0;
   for(int i=0;i<na;i++) for(int j=0;j<nb;j++) if(ta[i]==tb[j]){ common++; break; }
   return (double)common/MathMax(na,nb);
}

void MatchNews()
{
   int off=ServerOffset();
   for(int i=0;i<ArraySize(gNews);i++)
   {
      if(gNews[i].matched) continue;
      if(gNews[i].tUtc > TimeGMT()+2*86400) continue;           // match close to the date only
      MqlCalendarValue vals[];
      datetime t0=gNews[i].tUtc+off-3*3600, t1=gNews[i].tUtc+off+3*3600;
      if(CalendarValueHistory(vals,t0,t1,NULL,gNews[i].ccy)<=0) continue;
      string want=NormName(gNews[i].name), wantC=CountryOf(gNews[i].name);
      double best=0; ulong bestId=0;
      for(int v=0;v<ArraySize(vals);v++)
      {
         MqlCalendarEvent ev; if(!CalendarEventById(vals[v].event_id,ev)) continue;
         string nm=NormName(ev.name);
         double s=Similar(want,nm);
         if(StringFind(nm,want)>=0 || StringFind(want,nm)>=0) s=MathMax(s,0.8);
         if(wantC!="")
         {
            MqlCalendarCountry co; if(CalendarCountryById(ev.country_id,co)){ string cn=co.name; StringToLower(cn); if(cn==wantC) s+=0.2; else s-=0.3; }
         }
         double dt=MathAbs((double)(vals[v].time-(gNews[i].tUtc+off)))/3600.0;
         s-=0.05*dt;
         if(s>best){ best=s; bestId=vals[v].id; }
      }
      if(best>=0.55)
      {
         gNews[i].matched=true; gNews[i].valueId=bestId;
         MqlCalendarValue mv; MqlCalendarEvent me;
         if(CalendarValueById(bestId,mv) && CalendarEventById(mv.event_id,me))
            PrintFormat("Matched: %s (%s) -> MT5 '%s' %s, actual %s",gNews[i].name,gNews[i].ccy,me.name,TimeToString(mv.time),(mv.actual_value==LONG_MIN?"none yet":DoubleToString(mv.actual_value/1e6,2)));
      }
      else if(gNews[i].tUtc<TimeGMT()-1800 && !gNews[i].diagDone){ PrintFormat("Not matched in MT5 calendar: %s (%s) %s %s PKT",gNews[i].name,gNews[i].ccy,gNews[i].date,gNews[i].time); gNews[i].diagDone=true; }
   }
}

void UpdateNews()
{
   for(int i=0;i<ArraySize(gNews);i++)
   {
      if(!gNews[i].matched || gNews[i].released) continue;
      MqlCalendarValue v;
      if(!CalendarValueById(gNews[i].valueId,v)){ if(!gNews[i].diagDone){ PrintFormat("News %s: CalendarValueById failed (%d)",gNews[i].name,GetLastError()); gNews[i].diagDone=true; } continue; }
      bool has=(v.actual_value!=LONG_MIN);
      if(!has)
      {
         // past release time + 30 min and still no actual: log once so we can see what MT5 holds
         if(!gNews[i].diagDone && TimeGMT()>gNews[i].tUtc+1800)
         {
            MqlCalendarEvent ev; CalendarEventById(v.event_id,ev);
            PrintFormat("News %s (%s): matched MT5 '%s' at %s server, no actual yet (forecast %s, prev %s)",gNews[i].name,gNews[i].ccy,ev.name,TimeToString(v.time),
                        (v.forecast_value==LONG_MIN?"-":DoubleToString(v.forecast_value/1e6,2)),(v.prev_value==LONG_MIN?"-":DoubleToString(v.prev_value/1e6,2)));
            gNews[i].diagDone=true;
         }
         continue;
      }
      double act=v.actual_value/1e6;
      double s=0;
      if(v.forecast_value!=LONG_MIN)
         s=Sgn(act-v.forecast_value/1e6)*gNews[i].pol*gNews[i].w;
      else if(gNews[i].fc!=EMPTY_VALUE && MathAbs(act-gNews[i].fc)<10*MathMax(1.0,MathAbs(gNews[i].fc)))
         s=Sgn(act-gNews[i].fc)*gNews[i].pol*gNews[i].w;
      else if(v.impact_type==CALENDAR_IMPACT_POSITIVE) s= gNews[i].w;
      else if(v.impact_type==CALENDAR_IMPACT_NEGATIVE) s=-gNews[i].w;
      ApplyRelease(i,act,s,"MT5");
   }
}

void ApplyRelease(const int i,const double act,const double s,const string src)
{
   {
      gNews[i].released=true; gNews[i].actual=act; gNews[i].score=s;
      gDirty=true; gLastPublish=0;
      PrintFormat("Released (%s): %s %s actual %s -> event score %+.2f",src,gNews[i].ccy,gNews[i].name,DoubleToString(act,2),s);
      int c=CcyIdx(gNews[i].ccy);
      double before=(c>=0 ? cStr[c] : 0);
      Recompute();
      bool recent=(TimeGMT()-gNews[i].tUtc < 2*3600);   // no push storm for older releases at start-up
      if(c>=0 && recent && CcyInShort(gNews[i].ccy))
         Queue(StringFormat("%s %s: actual %s vs f %s -> event %+.1f, %s strength %+.1f -> %+.1f",
               gNews[i].ccy,gNews[i].name,DoubleToString(act,2),(gNews[i].fc==EMPTY_VALUE?"-":DoubleToString(gNews[i].fc,2)),s,gNews[i].ccy,before,cStr[c]));
   }
}
//+------------------------------------------------------------------+
//| Forex Factory fallback: calendar page embeds the events as JSON   |
//+------------------------------------------------------------------+
string FFField(const string chunk,const string key)
{
   string k="\""+key+"\":";
   int p=StringFind(chunk,k); if(p<0) return "";
   p+=StringLen(k);
   if(StringGetCharacter(chunk,p)=='"')
   {
      int e=StringFind(chunk,"\"",p+1); if(e<0) return "";
      string v=StringSubstr(chunk,p+1,e-p-1); StringReplace(v,"\\/","/"); return v;
   }
   int e1=StringFind(chunk,",",p), e2=StringFind(chunk,"}",p);
   int e=(e1<0 ? e2 : (e2<0 ? e1 : MathMin(e1,e2))); if(e<0) return "";
   return StringSubstr(chunk,p,e-p);
}
double FFNum(const string v)
{
   string t=v; StringReplace(t,"%",""); StringReplace(t,"K",""); StringReplace(t,"M",""); StringReplace(t,"B",""); StringReplace(t,"T","");
   StringReplace(t,"<",""); StringReplace(t,">",""); StringReplace(t,",",""); StringTrimLeft(t); StringTrimRight(t);
   if(t=="") return EMPTY_VALUE;
   return StringToDouble(t);
}
string FFNorm(const string s)
{
   string r=" "+NormName(s)+" ";
   string stop[]={"s p","s","p","global","cips","flash","prelim","final","german","french","spanish","italian","au","jibun","bank","boj","cb","the","of","fed","initial","jobless","unemployment","index"};
   for(int i=0;i<ArraySize(stop);i++) StringReplace(r," "+stop[i]+" "," ");
   StringTrimLeft(r); StringTrimRight(r);
   return r;
}

// EUR events: our name says (Germany)/(France)/..., FF prefixes German/French/...
bool SameCountry(const string ours,const string ff)
{
   string c=CountryOf(ours), f=ff; StringToLower(f);
   string adj[]={"german","french","spanish","italian"}, cty[]={"germany","france","spain","italy"};
   for(int k=0;k<4;k++)
   {
      bool ffHas=(StringFind(f,adj[k])==0);
      if(c==cty[k]) return ffHas;                 // ours is Germany -> FF must say German
      if(ffHas && c!="" ) return false;           // FF is German but ours is another country
   }
   if(c=="european union") { for(int k=0;k<4;k++) if(StringFind(f,adj[k])==0) return false; }
   return true;
}

void UpdateFromFF()
{
   bool need=false;
   for(int i=0;i<ArraySize(gNews);i++) if(!gNews[i].released && gNews[i].tUtc<=TimeGMT()-60 && gNews[i].tUtc>TimeGMT()-6*86400) { need=true; break; }
   if(!need || TimeGMT()-gLastFF<FFPollSeconds) return;
   gLastFF=TimeGMT();
   string page="";
   if(!FetchFF(page,30)) return;
   string chunks[]; int n=StringSplit(page,'{',chunks);
   int got=0;
   for(int i=0;i<ArraySize(gNews);i++)
   {
      if(gNews[i].released || gNews[i].tUtc>TimeGMT()-60) continue;
      string want=FFNorm(gNews[i].name);
      double best=-1; string bAct="", bFc="";
      for(int c=0;c<n;c++)
      {
         if(StringFind(chunks[c],"\"dateline\":")<0 || StringFind(chunks[c],"\"actual\":")<0) continue;
         if(FFField(chunks[c],"currency")!=gNews[i].ccy) continue;
         long dl=StringToInteger(FFField(chunks[c],"dateline"));
         double dt=MathAbs((double)(dl-(long)gNews[i].tUtc));
         if(dt>300) continue;                                   // same release slot only (FR 13:15 vs DE 13:30 PKT)
         string act=FFField(chunks[c],"actual"); if(act=="") continue;
         string ffn=FFField(chunks[c],"name");
         if(!SameCountry(gNews[i].name,ffn)) continue;
         double sc=Similar(want,FFNorm(ffn))-dt/3600.0;
         if(sc>best){ best=sc; bAct=act; bFc=FFField(chunks[c],"forecast"); }
      }
      if(best<0.34) continue;
      double a=FFNum(bAct), f=FFNum(bFc);
      if(a==EMPTY_VALUE) continue;
      if(f==EMPTY_VALUE) f=gNews[i].fc;
      double s=(f==EMPTY_VALUE ? 0 : Sgn(a-f)*gNews[i].pol*gNews[i].w);
      ApplyRelease(i,a,s,"ForexFactory");
      got++;
   }
   if(got>0){ Recompute(); CheckAlerts(); }
}

bool FetchFF(string &page,const int maxAge)
{
   if(gFFPage!="" && TimeGMT()-gFFAt<maxAge){ page=gFFPage; return true; }
   char data[], res[]; string rh;
   string hdr="User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36\r\nAccept: text/html\r\nAccept-Language: en-US,en;q=0.9\r\n";
   ResetLastError();
   int code=WebRequest("GET","https://www.forexfactory.com/calendar?week=this",hdr,15000,data,res,rh);
   if(code!=200)
   {
      if(!gFFWarned){ PrintFormat("Forex Factory fetch failed: HTTP %d err %d (add https://www.forexfactory.com to WebRequest URLs)",code,GetLastError()); gFFWarned=true; }
      return false;
   }
   gFFPage=CharArrayToString(res,0,WHOLE_ARRAY,CP_UTF8); gFFAt=TimeGMT();
   page=gFFPage;
   return true;
}

//+------------------------------------------------------------------+
//| V1.04 Investogenie Pulse -> Conditional -> Fundamental            |
//| Each tracked release this week: actual vs previous, + above,     |
//| - below, tie ignored, flipped for unemployment/claims (T rows).  |
//| Sunday Cond+/- (F rows) + this week's counts = live Conditional. |
//+------------------------------------------------------------------+
double FFVal(const string v)
{
   string t=v; StringReplace(t,",",""); StringReplace(t,"<",""); StringReplace(t,">",""); StringTrimLeft(t); StringTrimRight(t);
   if(t=="") return EMPTY_VALUE;
   double m=1; ushort last=StringGetCharacter(t,StringLen(t)-1);
   if(last=='K') m=1e3; else if(last=='M') m=1e6; else if(last=='B') m=1e9; else if(last=='T') m=1e12;
   StringReplace(t,"%",""); StringReplace(t,"K",""); StringReplace(t,"M",""); StringReplace(t,"B",""); StringReplace(t,"T","");
   if(t=="" || t=="-") return EMPTY_VALUE;
   return StringToDouble(t)*m;
}

string PktMonth(const datetime utc){ MqlDateTime m; TimeToStruct(utc+5*3600,m); return StringFormat("%04d-%02d",m.year,m.mon); }

double FundScore(const double L,const double O,const double P,string &condState)
{
   double M=(MathAbs(L)<gFS[0] ? 0 : Sgn(L));
   double N=0;
   if(MathAbs(L)>=gFS[0]) N=(MathAbs(L)<gFS[1] ? gFS[4] : (MathAbs(L)<gFS[2] ? gFS[5] : (MathAbs(L)<gFS[3] ? gFS[6] : gFS[7])));
   string Q=(M==0 ? "n/a" : (O==0 ? "FLAT" : (Sgn(O)==M ? "CONFIRM" : "OPPOSE")));
   string R=(M==0 ? "n/a" : (P==0 ? "FLAT" : (Sgn(P)==M ? "CONFIRM" : "OPPOSE")));
   condState=R;
   int C=(Q=="CONFIRM" ? 1 : 0)+(R=="CONFIRM" ? 1 : 0), Op=(Q=="OPPOSE" ? 1 : 0)+(R=="OPPOSE" ? 1 : 0);
   double U=0;
   if(M!=0) U=(C==2 ? gFS[8] : (C==1&&Op==0 ? gFS[9] : (C==1&&Op==1 ? gFS[10] : (C==0&&Op==0 ? gFS[11] : (C==0&&Op==1 ? gFS[12] : gFS[13])))));
   double V=((Q=="CONFIRM" && MathAbs(O)>=gFS[14]) || (R=="CONFIRM" && MathAbs(P)>=gFS[14])) ? gFS[15] : 0;
   if(M!=0) return M*N*MathMin(1.0,U+V);
   if(Sgn(O)*Sgn(P)<0) return 0;
   double base=((O!=0 && P!=0) ? gFS[16] : ((O!=0 || P!=0) ? gFS[17] : 0));
   return Sgn(O+P)*MathMin(gFS[18],base*((MathAbs(O)>=gFS[14] || MathAbs(P)>=gFS[14]) ? 2 : 1));
}

int TrackedIdx(const string ccy,const string name)
{
   string n=name; StringTrimLeft(n); StringTrimRight(n); StringToLower(n);
   for(int i=0;i<ArraySize(tName);i++) if(tCcy[i]==ccy && tName[i]==n) return i;
   return -1;
}

void UpdatePulse()
{
   if(!gHasF || ArraySize(tName)==0 || gWeekId=="") return;
   if(TimeGMT()-gLastPulse<PulsePollSec) return;
   gLastPulse=TimeGMT();
   string page="";
   if(!FetchFF(page,60)) return;
   string wid=gWeekId; StringReplace(wid,"-",".");
   datetime wStart=StringToTime(wid+" 00:00")-5*3600;          // Monday 00:00 PKT
   bool turned=(PktMonth(TimeGMT())!=gBaseMonth);
   for(int c=0;c<8;c++){ pNew[c][0]=0; pNew[c][1]=0; for(int d=0;d<5;d++){ pDay[c][d][0]=0; pDay[c][d][1]=0; } }
   int oldN=ArraySize(gPulseEv);
   string evs[]; string seen="|";
   string chunks[]; int n=StringSplit(page,'{',chunks);
   for(int c=0;c<n;c++)
   {
      if(StringFind(chunks[c],"\"dateline\":")<0 || StringFind(chunks[c],"\"previous\":")<0) continue;
      string ccy=FFField(chunks[c],"currency"); int ci=CcyIdx(ccy); if(ci<0) continue;
      long dl=StringToInteger(FFField(chunks[c],"dateline"));
      if(dl<(long)wStart || dl>(long)TimeGMT()) continue;
      int d=(int)((dl-(long)wStart)/86400); if(d<0 || d>4) continue;
      string nm=FFField(chunks[c],"name");
      int ti=TrackedIdx(ccy,nm); if(ti<0) continue;
      string act=FFField(chunks[c],"actual"), prv=FFField(chunks[c],"previous");
      double a=FFVal(act), p=FFVal(prv);
      if(a==EMPTY_VALUE || p==EMPTY_VALUE) continue;
      string key=ccy+nm+IntegerToString(dl)+"|"; if(StringFind(seen,"|"+key)>=0) continue; seen+=key;
      int sg=(int)(Sgn(a-p)*tPol[ti]);
      if(sg>0) pDay[ci][d][0]++; else if(sg<0) pDay[ci][d][1]++;
      if(PktMonth((datetime)dl)!=gBaseMonth && sg!=0) pNew[ci][(sg>0?0:1)]++;
      string j=StringFormat("{\"utc\":\"%s\",\"day\":%d,\"ccy\":\"%s\",\"event\":\"%s\",\"actual\":\"%s\",\"previous\":\"%s\",\"sign\":%d}",
                            IsoUtc((datetime)dl),d,ccy,JsonEsc(nm),JsonEsc(act),JsonEsc(prv),sg);
      int m=ArraySize(evs); ArrayResize(evs,m+1); evs[m]=j;
   }
   ArrayResize(gPulseEv,ArraySize(evs)); for(int i=0;i<ArraySize(evs);i++) gPulseEv[i]=evs[i];
   gPulseAt=TimeGMT();
   bool changed=false;
   for(int c=0;c<8;c++)
   {
      int dp=0, dm=0; for(int d=0;d<5;d++){ dp+=pDay[c][d][0]; dm+=pDay[c][d][1]; }
      pPlus[c]=(turned ? pNew[c][0] : (int)fCP[c]+dp);
      pMinus[c]=(turned ? pNew[c][1] : (int)fCM[c]+dm);
      string st; double before=cFund[c];
      double y=FundScore(fInv[c],fLat[c],pPlus[c]-pMinus[c],st);
      if(pStatePrev[c]==""){ string s0; FundScore(fInv[c],fLat[c],fCP[c]-fCM[c],s0); pStatePrev[c]=s0; }
      if(gFundRaw) y=before;                   // 1.08: raw-rank Fund is fixed for the week; Conditional is shown only
      cFund[c]=y;
      if(MathAbs(y-before)>1e-9) changed=true;
      if(pState[c]!="" && (st!=pState[c] || MathAbs(y-before)>1e-9))
      {
         string msg=StringFormat("%s Pulse: Conditional %d/%d (net %+d) %s -> %s, fundamental %+.3f -> %+.3f",CCY[c],pPlus[c],pMinus[c],pPlus[c]-pMinus[c],pState[c],st,before,y);
         if(PulsePush && CcyInShort(CCY[c])) Queue(msg); else Print(msg);
         AddPulseAlert(CCY[c],msg);
      }
      pState[c]=st;
   }
   if(ArraySize(gPulseEv)!=oldN){ gDirty=true; gLastPublish=0; PrintFormat("Pulse: %d tracked releases this week",ArraySize(gPulseEv)); }
   if(changed){ Recompute(); CheckAlerts(); }
}

void AddPulseAlert(const string ccy,const string text)
{
   string j=StringFormat("{\"at\":\"%s\",\"level\":\"info\",\"pair\":\"%s\",\"text\":\"%s\"}",IsoUtc(TimeGMT()),ccy,JsonEsc(text));
   int n=ArraySize(gAlerts); ArrayResize(gAlerts,n+1); gAlerts[n]=j;
   if(n+1>30){ for(int i=0;i<n;i++) gAlerts[i]=gAlerts[i+1]; ArrayResize(gAlerts,30); }
   gDirty=true; gLastPublish=0;
}

string PulseJson()
{
   if(!gHasF) return "null";
   string j="{\"at\":\""+IsoUtc(gPulseAt)+"\",\"rows\":[";
   for(int c=0;c<8;c++)
   {
      double pp=fCP[c], pm=fCM[c];
      double last=(pp+pm>0 ? 100.0*pp/(pp+pm) : EMPTY_VALUE), cur=(pPlus[c]+pMinus[c]>0 ? 100.0*pPlus[c]/(pPlus[c]+pMinus[c]) : EMPTY_VALUE);
      double gain=((last!=EMPTY_VALUE && last>0 && cur!=EMPTY_VALUE) ? (cur/last-1)*100 : EMPTY_VALUE);
      string dd=""; for(int d=0;d<5;d++) dd+=StringFormat("%s[%d,%d]",(d?",":""),pDay[c][d][0],pDay[c][d][1]);
      j+=StringFormat("%s{\"ccy\":\"%s\",\"prevPlus\":%d,\"prevMinus\":%d,\"days\":[%s],\"plus\":%d,\"minus\":%d,\"lastPct\":%s,\"curPct\":%s,\"gain\":%s,\"condStatePrev\":\"%s\",\"condState\":\"%s\",\"fundPlan\":%s,\"fund\":%s}",
                      (c?",":""),CCY[c],(int)pp,(int)pm,dd,pPlus[c],pMinus[c],D2S(last,2),D2S(cur,2),D2S(gain,2),pStatePrev[c],pState[c],D2S(cFundPlan[c],4),D2S(cFund[c],4));
   }
   j+="],\"events\":[";
   for(int i=0;i<ArraySize(gPulseEv);i++) j+=(i?",":"")+gPulseEv[i];
   j+="]}";
   return j;
}

//+------------------------------------------------------------------+
//| V1.05 setup scanner (same gate as the Sunday plan, gate_dowfib)  |
//|  D1 Dow trend = bias, D1 close not beyond D1 trend-fails;        |
//|  D1 pending >=50% FULL, 38.2-50% LOW only with H1 aligned;       |
//|  >100% = check chart. ENTRY when H1 with us and H1 pullback      |
//|  50-100%, or H1 against us and H1 closes beyond its fail level.  |
//+------------------------------------------------------------------+
string TrendTxt(const int t){ return t==1 ? "UP" : (t==-1 ? "DOWN" : "-"); }

bool EvalPair(const string sym,const string pair,const double score,SetupRow &r,const datetime asOf)
{
   r.pair=pair; r.sym=sym; r.score=score; r.want=(score>=0 ? "UP" : "DOWN");
   r.entry=false; r.ready=false; r.band=0; r.status="";
   CDowFibEngine d1(D1FibMin,D1Swing,D1Days,true,true,DFBreakBars,DFBreakBuf,true,true);
   CDowFibEngine h1(H1FibMin,H1Swing,H1Days,true,true,DFBreakBars,DFBreakBuf,true,true);
   bool ok1=d1.Build(sym,PERIOD_D1,asOf), ok2=h1.Build(sym,PERIOD_H1,asOf);
   r.d1Trend=TrendTxt(d1.Trend()); r.h1Trend=TrendTxt(h1.Trend());
   r.d1Fail=d1.FailLevel(); r.d1Pct=(d1.HasPending()?d1.PendingPct():0); r.d1Ext=d1.Extreme();
   r.h1Fail=h1.FailLevel(); r.h1Pct=(h1.HasPending()?h1.PendingPct():0);
   int sh=(asOf>0 ? iBarShift(sym,PERIOD_H1,asOf,false)+1 : 1);
   r.close=iClose(sym,PERIOD_H1,sh);
   double d1c=iClose(sym,PERIOD_D1,(asOf>0 ? iBarShift(sym,PERIOD_D1,asOf,false)+1 : 1));
   if(!ok1 || !ok2){ r.status="no history (open the "+sym+" H1/D1 chart once)"; return false; }
   if(r.d1Trend!=r.want){ r.status="D1 "+r.d1Trend+" (against)"; return true; }
   bool upW=(r.want=="UP");
   if(r.d1Fail>0 && ((upW && d1c<r.d1Fail) || (!upW && d1c>r.d1Fail))){ r.status="D1 closed beyond trend-fails"; return true; }
   bool h1ok=(r.h1Trend==r.want);
   double pct=r.d1Pct;
   if(pct>100){ r.status=StringFormat("D1 pending %.0f%% (>100%%, check chart)",pct); return true; }
   if(pct>=50) r.band=1.0;
   else if(pct>=38.2 && h1ok) r.band=0.5;
   else if(pct>=38.2){ r.status=StringFormat("D1 pullback %.0f%%, needs H1 reversal",pct); r.ready=true; }
   else { r.status="D1 pullback <38.2% (stretched)"; return true; }
   if(r.band==0 && !h1ok)
   {  // 38.2-50% without H1: an H1 close beyond its fail level is the reversal
      if(r.h1Fail>0 && ((upW && r.close>r.h1Fail) || (!upW && r.close<r.h1Fail))){ r.band=0.5; r.entry=true; r.status=StringFormat("ENTRY: H1 closed beyond %s (reversal), D1 pullback %.0f%% LOW",DoubleToString(r.h1Fail,(int)SymbolInfoInteger(sym,SYMBOL_DIGITS)),pct); }
      return true;
   }
   r.ready=true;
   int dg=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   string bandTxt=(r.band>=1 ? "FULL" : "LOW");
   if(h1ok)
   {
      if(r.h1Pct>MaxH1PullbackPct && r.h1Pct<=100) r.status=StringFormat("D1 %s ok, H1 pullback %.0f%% late (>%.1f%%, too close to SL), no entry",bandTxt,r.h1Pct,MaxH1PullbackPct);
      else if(r.h1Pct>=50 && r.h1Pct<=100){ r.entry=true; r.status=StringFormat("ENTRY: H1 pullback %.0f%%, D1 pullback %.0f%% %s",r.h1Pct,pct,bandTxt); }
      else if(r.h1Pct>100) r.status=StringFormat("D1 %s ok, H1 pending %.0f%% (>100%%, check)",bandTxt,r.h1Pct);
      else r.status=StringFormat("D1 %s ok, wait H1 pullback >=50%%",bandTxt);
   }
   else
   {
      if(r.h1Fail>0 && ((upW && r.close>r.h1Fail) || (!upW && r.close<r.h1Fail))){ r.entry=true; r.status=StringFormat("ENTRY: H1 closed beyond %s, D1 pullback %.0f%% %s",DoubleToString(r.h1Fail,dg),pct,bandTxt); }
      else r.status=StringFormat("D1 %s ok, wait H1 close %s %s",bandTxt,(upW?"above":"below"),DoubleToString(r.h1Fail,dg));
   }
   return true;
}

void ScanAll(const bool force)
{
   if(ArraySize(gPairs)==0 || !IsTradeWeek()) return;
   string ref=""; for(int i=0;i<ArraySize(gPairs);i++) if(gPairs[i].sym!=""){ ref=gPairs[i].sym; break; }
   if(ref=="") return;
   datetime bar=iTime(ref,PERIOD_H1,0);
   if(!force && bar==gLastScanBar) return;
   gLastScanBar=bar;
   SetupRow prev[]; ArrayResize(prev,ArraySize(gSetups)); for(int i=0;i<ArraySize(gSetups);i++) prev[i]=gSetups[i];
   ArrayResize(gSetups,0);
   int nEntry=0;
   for(int i=0;i<ArraySize(gPairs);i++)
   {
      if(gPairs[i].sym=="") continue;
      bool sl=IsShort(gPairs[i].tier);
      bool cv=(MathAbs(gPairs[i].score)>=ScanMinScore);
      if(!sl && !cv) continue;                 // 1.07: shortlist always scanned; others only with |score| >= ScanMinScore
      SetupRow r;
      EvalPair(gPairs[i].sym,gPairs[i].pair,gPairs[i].score,r,0);
      r.shortl=sl; r.conv=cv;
      r.since=TimeGMT();
      bool was=false;
      for(int k=0;k<ArraySize(prev);k++) if(prev[k].pair==r.pair && prev[k].want==r.want){ if(prev[k].entry && r.entry) r.since=prev[k].since; was=prev[k].entry; if(!r.entry && prev[k].ready==r.ready && prev[k].status==r.status) r.since=prev[k].since; break; }
      int m=ArraySize(gSetups); ArrayResize(gSetups,m+1); gSetups[m]=r;
      if(r.entry && r.conv) nEntry++;
      if(r.entry && !was && !r.conv)
      {
         string bias=(r.want=="UP" ? "BUY" : "SELL");
         string msg=StringFormat("%s %s at entry but live score %+.1f is below %.0f (low conviction): %s",r.pair,bias,r.score,ScanMinScore,r.status);
         AddAlert("info",r.pair,msg);
         gDirty=true;
      }
      else if(r.entry && !was)
      {
         string bias=(r.want=="UP" ? "BUY" : "SELL");
         int dg=(int)SymbolInfoInteger(r.sym,SYMBOL_DIGITS);
         string msg=StringFormat("NEW SETUP %s %s (%s, score %+.1f): %s. SL beyond H1 %s, invalid on D1 close beyond %s.",
                                 r.pair,bias,gPairs[i].tier,r.score,r.status,DoubleToString(r.h1Fail,dg),DoubleToString(r.d1Fail,dg));
         string j=StringFormat("{\"at\":\"%s\",\"level\":\"ok\",\"pair\":\"%s\",\"text\":\"%s\"}",IsoUtc(TimeGMT()),r.pair,JsonEsc(msg));
         int n=ArraySize(gAlerts); ArrayResize(gAlerts,n+1); gAlerts[n]=j;
         if(n+1>30){ for(int a=0;a<n;a++) gAlerts[a]=gAlerts[a+1]; ArrayResize(gAlerts,30); }
         if(SetupPush) Queue(msg,true); else Print(msg);
         gDirty=true; gLastPublish=0;
      }
   }
   bool missing=false; for(int i=0;i<ArraySize(gSetups);i++) if(StringFind(gSetups[i].status,"no history")==0) missing=true;
   if(missing) gLastScanBar=0;   // history still downloading: retry on the next timer tick
   PrintFormat("Scanner: %d pairs (shortlist + |score| >= %.0f), %d entry setups",ArraySize(gSetups),ScanMinScore,nEntry);
   gDirty=true;
}

string SetupsJson()
{
   string j="[";
   for(int i=0;i<ArraySize(gSetups);i++)
   {
      SetupRow r=gSetups[i];
      int dg=(int)SymbolInfoInteger(r.sym,SYMBOL_DIGITS);
      j+=StringFormat("%s{\"pair\":\"%s\",\"bias\":\"%s\",\"score\":%s,\"entry\":%s,\"ready\":%s,\"shortlist\":%s,\"conv\":%s,\"band\":%s,\"status\":\"%s\",\"d1Trend\":\"%s\",\"d1Fail\":%s,\"d1Pct\":%s,\"h1Trend\":\"%s\",\"h1Fail\":%s,\"h1Pct\":%s,\"close\":%s,\"since\":\"%s\"}",
                      (i?",":""),r.pair,(r.want=="UP"?"BUY":"SELL"),D2S(r.score,2),(r.entry?"true":"false"),(r.ready?"true":"false"),(r.shortl?"true":"false"),(r.conv?"true":"false"),D2S(r.band,2),JsonEsc(r.status),
                      r.d1Trend,D2S(r.d1Fail,dg),D2S(r.d1Pct,1),r.h1Trend,D2S(r.h1Fail,dg),D2S(r.h1Pct,1),D2S(r.close,dg),IsoUtc(r.since));
   }
   return j+"]";
}

// one-off: structure as of CheckAsOfUTC for all 28 pairs (compare with the Sunday TradingView read)
void RunCheck()
{
   gCheckDone=true;
   if(ArraySize(gPairs)==0) return;
   string t=CheckAsOfUTC; StringTrimLeft(t); StringTrimRight(t);
   datetime asUtc=StringToTime(t); if(asUtc<=0) return;
   datetime asSrv=asUtc+ServerOffset();
   string j="{\"asOfUtc\":\""+IsoUtc(asUtc)+"\",\"rows\":[";
   int n=0;
   for(int i=0;i<ArraySize(gPairs);i++)
   {
      string sym=gPairs[i].sym; if(sym=="") continue;
      CDowFibEngine d1(D1FibMin,D1Swing,D1Days,true,true,DFBreakBars,DFBreakBuf,true,true);
      CDowFibEngine h1(H1FibMin,H1Swing,H1Days,true,true,DFBreakBars,DFBreakBuf,true,true);
      d1.Build(sym,PERIOD_D1,asSrv); h1.Build(sym,PERIOD_H1,asSrv);
      int dg=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
      j+=StringFormat("%s{\"pair\":\"%s\",\"d1\":[\"%s\",%s,%s,%s],\"h1\":[\"%s\",%s,%s,%s]}",(n?",":""),gPairs[i].pair,
                      TrendTxt(d1.Trend()),D2S(d1.FailLevel(),dg),D2S(d1.HasPending()?d1.PendingPct():0,1),D2S(d1.Extreme(),dg),
                      TrendTxt(h1.Trend()),D2S(h1.FailLevel(),dg),D2S(h1.HasPending()?h1.PendingPct():0,1),D2S(h1.Extreme(),dg));
      PrintFormat("Check %s as of %s UTC | D1 %s | H1 %s",gPairs[i].pair,t,d1.Describe(dg),h1.Describe(dg));
      n++;
   }
   gCheckJson=j+"]}";
   gDirty=true; gLastPublish=0;
}

bool CcyInShort(const string c)
{
   for(int i=0;i<ArraySize(gPairs);i++) if(IsShort(gPairs[i].tier) && (StringSubstr(gPairs[i].pair,0,3)==c || StringSubstr(gPairs[i].pair,3,3)==c)) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Model: News -> strength -> pair score                            |
//+------------------------------------------------------------------+
void Recompute()
{
   double sum[8], wt[8]; ArrayInitialize(sum,0); ArrayInitialize(wt,0);
   for(int i=0;i<ArraySize(gNews);i++)
   {
      int c=CcyIdx(gNews[i].ccy); if(c<0) continue;
      sum[c]+=gNews[i].score; wt[c]+=gNews[i].w;
   }
   for(int c=0;c<8;c++)
   {
      cNews[c]=sum[c]/MathMax(wt[c],newsMinW);   // = News sheet: SUM / MAX(weight, Settings!B41)
      cStr[c]=100.0*(wFund*cFund[c]+wCot*cCot[c]+wSeas*cSeas[c]+wNews*cNews[c]+wMacro*cMacro[c]);
   }
   for(int p=0;p<ArraySize(gPairs);p++)
   {
      int b=CcyIdx(StringSubstr(gPairs[p].pair,0,3)), q=CcyIdx(StringSubstr(gPairs[p].pair,3,3));
      if(b>=0 && q>=0) gPairs[p].score=cStr[b]-cStr[q];
   }
}

//+------------------------------------------------------------------+
//| Alerts                                                           |
//+------------------------------------------------------------------+
void AddAlert(const string level,const string pair,const string text)
{
   string j=StringFormat("{\"at\":\"%s\",\"level\":\"%s\",\"pair\":\"%s\",\"text\":\"%s\"}",IsoUtc(TimeGMT()),level,pair,JsonEsc(text));
   int n=ArraySize(gAlerts); ArrayResize(gAlerts,n+1); gAlerts[n]=j;
   if(n+1>30){ for(int i=0;i<n;i++) gAlerts[i]=gAlerts[i+1]; ArrayResize(gAlerts,30); }
   Queue(text,StringFind(text,"BIAS FLIPPED")>=0);
   gDirty=true; gLastPublish=0;   // publish now
}

void CheckAlerts()
{
   for(int i=0;i<ArraySize(gPairs);i++)
   {
      if(!IsShort(gPairs[i].tier)) continue;
      double ps=gPairs[i].planScore, s=gPairs[i].score;
      string planDir=gPairs[i].bias, nowDir=(s>=0 ? "BUY" : "SELL");
      string st="OK";
      if(nowDir!=planDir) st="FLIP";
      else if(MathAbs(ps)>=ConvictionLine && MathAbs(s)<ConvictionLine) st="BELOW";
      else if(MathAbs(s)-MathAbs(ps)<=-ScoreAlertDrop) st="WEAK";
      if(st==gPairs[i].lastState) continue;
      if(st=="FLIP")  AddAlert("dn",gPairs[i].pair,StringFormat("%s %s: BIAS FLIPPED to %s (score %+.1f -> %+.1f). Consider closing / not entering.",gPairs[i].tier,gPairs[i].pair,nowDir,ps,s));
      if(st=="BELOW") AddAlert("warn",gPairs[i].pair,StringFormat("%s %s %s: score fell below %.0f (%+.1f -> %+.1f).",gPairs[i].tier,gPairs[i].pair,planDir,ConvictionLine,ps,s));
      if(st=="WEAK")  AddAlert("warn",gPairs[i].pair,StringFormat("%s %s %s: score weakened %+.1f -> %+.1f.",gPairs[i].tier,gPairs[i].pair,planDir,ps,s));
      if(st=="OK" && gPairs[i].lastState!="") AddAlert("ok",gPairs[i].pair,StringFormat("%s %s %s: score back to normal (%+.1f).",gPairs[i].tier,gPairs[i].pair,planDir,s));
      gPairs[i].lastState=st;
   }
}

void CheckPrices()
{
   for(int i=0;i<ArraySize(gPairs);i++)
   {
      if(!IsShort(gPairs[i].tier) || gPairs[i].sym=="") continue;
      int dir=(gPairs[i].bias=="BUY" ? 1 : -1);
      string want=(dir>0 ? "UP" : "DOWN");
      string sym=gPairs[i].sym;
      int dg=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
      double c1=iClose(sym,PERIOD_D1,1);
      double h1c=iClose(sym,PERIOD_H1,1);
      double bid=SymbolInfoDouble(sym,SYMBOL_BID);
      bool d1With=(gPairs[i].d1Trend==want), h1With=(gPairs[i].h1Trend==want);
      // D1 trend-fails level
      if(gPairs[i].d1Fail!=EMPTY_VALUE && gPairs[i].d1Fail>0 && c1>0)
      {
         bool beyondAgainst=((dir>0 && c1<gPairs[i].d1Fail) || (dir<0 && c1>gPairs[i].d1Fail));
         bool beyondFor=((dir>0 && c1>gPairs[i].d1Fail) || (dir<0 && c1<gPairs[i].d1Fail));
         if(d1With && beyondAgainst && !gPairs[i].invalidSent)
         {  // D1 trend in our favour has failed -> idea invalid
            gPairs[i].invalidSent=true;
            AddAlert("dn",gPairs[i].pair,StringFormat("%s %s %s: D1 closed %s beyond the D1 trend-fails level %s. Idea invalid, exit.",gPairs[i].tier,gPairs[i].pair,gPairs[i].bias,DoubleToString(c1,dg),DoubleToString(gPairs[i].d1Fail,dg)));
         }
         if(!d1With && gPairs[i].d1Trend!="" && beyondFor && !gPairs[i].turnSent)
         {  // opposing D1 trend has failed -> D1 turning our way (gate may now pass)
            gPairs[i].turnSent=true;
            AddAlert("ok",gPairs[i].pair,StringFormat("%s %s %s: D1 closed %s beyond the opposing D1 trend-fails level %s. D1 turning our way, re-check the gate.",gPairs[i].tier,gPairs[i].pair,gPairs[i].bias,DoubleToString(c1,dg),DoubleToString(gPairs[i].d1Fail,dg)));
         }
      }
      // H1 trend-fails level
      if(gPairs[i].h1Fail!=EMPTY_VALUE && gPairs[i].h1Fail>0)
      {
         if(h1With && gPairs[i].tier=="TRADE" && !gPairs[i].slSent && bid>0 && ((dir>0 && bid<gPairs[i].h1Fail) || (dir<0 && bid>gPairs[i].h1Fail)))
         {  // H1 with us: level = SL zone
            gPairs[i].slSent=true;
            AddAlert("warn",gPairs[i].pair,StringFormat("Planned %s %s: price %s crossed the H1 trend-fails / SL level %s.",gPairs[i].bias,gPairs[i].pair,DoubleToString(bid,dg),DoubleToString(gPairs[i].h1Fail,dg)));
         }
         if(!h1With && gPairs[i].h1Trend!="" && !gPairs[i].entrySent && h1c>0 && ((dir>0 && h1c>gPairs[i].h1Fail) || (dir<0 && h1c<gPairs[i].h1Fail)))
         {  // H1 against us: level = entry trigger (H1 close beyond it)
            gPairs[i].entrySent=true;
            AddAlert("ok",gPairs[i].pair,StringFormat("%s %s %s: H1 closed %s beyond %s, the entry trigger. Check the setup.",gPairs[i].tier,gPairs[i].pair,gPairs[i].bias,DoubleToString(h1c,dg),DoubleToString(gPairs[i].h1Fail,dg)));
         }
      }
   }
}

void Queue(const string msg,const bool key=false)
{
   Print(msg);
   if(PushKeyOnly && !key) return;          // log + app only
   if(PopupAlerts) Alert(msg);
   if(!PushAlerts) return;
   string m=msg; if(StringLen(m)>255) m=StringSubstr(m,0,252)+"...";
   int n=ArraySize(gPushQueue); ArrayResize(gPushQueue,n+1); gPushQueue[n]=m;
}
void FlushPush()
{
   if(ArraySize(gPushQueue)==0 || TimeLocal()-gLastPush<7) return;   // platform limit ~10/min
   if(!SendNotification(gPushQueue[0])) Print("SendNotification failed ",GetLastError()," (set MetaQuotes ID in Tools > Options > Notifications)");
   gLastPush=TimeLocal();
   int n=ArraySize(gPushQueue); for(int i=0;i<n-1;i++) gPushQueue[i]=gPushQueue[i+1]; ArrayResize(gPushQueue,n-1);
}

//+------------------------------------------------------------------+
//| live.json                                                        |
//+------------------------------------------------------------------+
string BuildJson()
{
   string j="{\"week\":\""+gWeekId+"\",\"at\":\""+IsoUtc(TimeGMT())+"\",\"source\":\"MT5 FX Bias Monitor 1.08\",\"pulse\":"+PulseJson()+",\"setups\":"+SetupsJson()+","+(gCheckJson!="" ? "\"dowfibCheck\":"+gCheckJson+"," : "")+"\"currencies\":[";
   for(int c=0;c<8;c++)
      j+=StringFormat("%s{\"ccy\":\"%s\",\"fund\":%s,\"news\":%s,\"strength\":%s}",(c?",":""),CCY[c],D2S(cFund[c],4),D2S(cNews[c],4),D2S(cStr[c],3));
   j+="],\"pairs\":[";
   for(int p=0;p<ArraySize(gPairs);p++)
      j+=StringFormat("%s{\"pair\":\"%s\",\"score\":%s,\"bias\":\"%s\"}",(p?",":""),gPairs[p].pair,D2S(gPairs[p].score,3),(gPairs[p].score>=0?"BUY":"SELL"));
   j+="],\"news\":[";
   bool first=true;
   for(int i=0;i<ArraySize(gNews);i++)
   {
      if(!gNews[i].released) continue;
      j+=StringFormat("%s{\"date\":\"%s\",\"ccy\":\"%s\",\"event\":\"%s\",\"actual\":%s,\"score\":%s}",(first?"":","),gNews[i].date,gNews[i].ccy,JsonEsc(gNews[i].name),D2S(gNews[i].actual,4),D2S(gNews[i].score,3));
      first=false;
   }
   j+="],\"prices\":{";
   first=true;
   for(int p=0;p<ArraySize(gPairs);p++)
   {
      if(gPairs[p].sym=="") continue;
      double bid=SymbolInfoDouble(gPairs[p].sym,SYMBOL_BID); if(bid<=0) continue;
      j+=StringFormat("%s\"%s\":%s",(first?"":","),gPairs[p].pair,DoubleToString(bid,(int)SymbolInfoInteger(gPairs[p].sym,SYMBOL_DIGITS)));
      first=false;
   }
   // 1.08: this week's running range per symbol: [last Friday close, week high, week low, bid] (W1 bar 0)
   j+="},\"weekRange\":{";
   first=true;
   string wl[]; int nw=ArraySize(gPairs); ArrayResize(wl,nw+2);
   for(int p=0;p<nw;p++) wl[p]=gPairs[p].pair;
   wl[nw]="XAUUSD"; wl[nw+1]="USTEC";
   for(int p=0;p<ArraySize(wl);p++)
   {
      string sy=(p<nw?gPairs[p].sym:D1Resolve(wl[p])); if(sy=="") continue;
      double pc=iClose(sy,PERIOD_W1,1), hi=iHigh(sy,PERIOD_W1,0), lo=iLow(sy,PERIOD_W1,0), bd=SymbolInfoDouble(sy,SYMBOL_BID);
      if(pc<=0 || hi<=0 || lo<=0 || bd<=0) continue;
      int dg=(int)SymbolInfoInteger(sy,SYMBOL_DIGITS);
      j+=StringFormat("%s\"%s\":[%s,%s,%s,%s]",(first?"":","),wl[p],DoubleToString(pc,dg),DoubleToString(hi,dg),DoubleToString(lo,dg),DoubleToString(bd,dg));
      first=false;
   }
   j+="},\"alerts\":[";
   for(int a=0;a<ArraySize(gAlerts);a++) j+=(a?",":"")+gAlerts[a];
   j+="]}";
   return j;
}

void WriteLive()
{
   bool due=(TimeGMT()-gLastPublish >= PublishMinutes*60);
   if(!due) return;
   string j=BuildJson();
   int h=FileOpen("FXBias\\live.json",FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_ANSI);
   if(h!=INVALID_HANDLE){ FileWriteString(h,j); FileClose(h); }
   if(GitHubToken!="" && IsTradeWeek()) PublishGitHub(j);
   gLastPublish=TimeGMT(); gDirty=false;
}
bool IsTradeWeek()
{
   MqlDateTime m; TimeToStruct(TimeGMT(),m);
   return !(m.day_of_week==6 || (m.day_of_week==0 && m.hour<20));   // skip Saturday / early Sunday
}

string ShaFrom(const string resp)
{
   int p=StringFind(resp,"\"sha\":\""); if(p<0) return "";
   p+=7; int e=StringFind(resp,"\"",p); if(e<0) return "";
   return StringSubstr(resp,p,e-p);
}

void PublishGitHub(const string json)
{
   string api="https://api.github.com/repos/"+GitHubRepo+"/contents/data/live.json";
   string hdr="Authorization: Bearer "+GitHubToken+"\r\nAccept: application/vnd.github+json\r\nUser-Agent: FXBiasMonitor\r\nContent-Type: application/json\r\n";
   char none[], res[]; string rh;
   if(gLiveSha=="")
   {
      int c=WebRequest("GET",api+"?ref="+GitHubBranch,hdr,8000,none,res,rh);
      if(c==200) gLiveSha=ShaFrom(CharArrayToString(res,0,WHOLE_ARRAY,CP_UTF8));
   }
   uchar src[], key[], b64[];
   StringToCharArray(json,src,0,WHOLE_ARRAY,CP_UTF8);
   int len=ArraySize(src); if(len>0 && src[len-1]==0) ArrayResize(src,len-1);
   if(CryptEncode(CRYPT_BASE64,src,key,b64)<=0){ Print("base64 failed"); return; }
   string content=CharArrayToString(b64,0,WHOLE_ARRAY,CP_ACP);
   string body="{\"message\":\"live "+IsoUtc(TimeGMT())+"\",\"branch\":\""+GitHubBranch+"\",\"content\":\""+content+"\""+(gLiveSha!="" ? ",\"sha\":\""+gLiveSha+"\"" : "")+"}";
   char data[]; StringToCharArray(body,data,0,WHOLE_ARRAY,CP_UTF8);
   int dl=ArraySize(data); if(dl>0 && data[dl-1]==0) ArrayResize(data,dl-1);
   ResetLastError();
   int code=WebRequest("PUT",api,hdr,10000,data,res,rh);
   string resp=CharArrayToString(res,0,WHOLE_ARRAY,CP_UTF8);
   if(code==200 || code==201) gLiveSha=ShaFrom(StringSubstr(resp,StringFind(resp,"\"content\"")));
   else
   {
      PrintFormat("GitHub upload failed: HTTP %d err %d %s",code,GetLastError(),StringSubstr(resp,0,200));
      gLiveSha="";   // re-read sha next time (409 conflict)
   }
}

//+------------------------------------------------------------------+
void Panel()
{
   string s="FX Bias Monitor 1.08 | "+gWeekLabel+" | news released: ";
   int rel=0, mat=0; for(int i=0;i<ArraySize(gNews);i++){ if(gNews[i].released) rel++; if(gNews[i].matched) mat++; }
   s+=IntegerToString(rel)+"/"+IntegerToString(ArraySize(gNews))+" (matched "+IntegerToString(mat)+")\n";
   s+="Strength: ";
   for(int c=0;c<8;c++) s+=StringFormat("%s %+.0f  ",CCY[c],cStr[c]);
   s+="\n";
   if(gHasF && UsePulse)
   {
      s+="Pulse (Cond +/-): ";
      for(int c=0;c<8;c++) s+=StringFormat("%s %d/%d %s  ",CCY[c],pPlus[c],pMinus[c],(pState[c]=="CONFIRM"?"C":(pState[c]=="OPPOSE"?"O":"-")));
      s+="\n";
   }
   if(ScanSetups && ArraySize(gSetups)>0)
   {
      s+="Setups: ";
      int shown=0;
      for(int i=0;i<ArraySize(gSetups);i++) if(gSetups[i].entry || gSetups[i].ready){ s+=StringFormat("%s %s %s  ",gSetups[i].pair,(gSetups[i].want=="UP"?"BUY":"SELL"),(gSetups[i].entry?(gSetups[i].conv?"ENTRY":"entry-lowconv"):"ready")); shown++; }
      if(shown==0) s+="none ready";
      s+="\n";
   }
   for(int i=0;i<ArraySize(gPairs);i++)
   {
      if(!IsShort(gPairs[i].tier)) continue;
      s+=StringFormat("%-7s %-4s %-7s plan %+6.1f  now %+6.1f  %s%s\n",gPairs[i].tier,gPairs[i].bias,gPairs[i].pair,gPairs[i].planScore,gPairs[i].score,
                      (gPairs[i].lastState=="" ? "OK" : gPairs[i].lastState),(gPairs[i].sym=="" ? "  (symbol not found)" : ""));
   }
   Comment(s);
}
//+------------------------------------------------------------------+

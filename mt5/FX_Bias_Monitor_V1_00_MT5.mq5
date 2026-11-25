//+------------------------------------------------------------------+
//| FX_Bias_Monitor_V1_00_MT5.mq5                                    |
//| Live monitor for the weekly Sarmaaya bias model. Does NOT trade. |
//|  - downloads this week's plan (data/plan.csv) from GitHub        |
//|  - reads news actuals from the MT5 economic calendar             |
//|  - re-scores News -> currency strength -> 28 pair scores         |
//|  - push alerts (MetaTrader app) when a shortlisted pair's bias   |
//|    flips / score weakens, or price breaks the invalidation level |
//|  - writes live.json (MQL5\Files common) and optionally commits   |
//|    it to the 'live' branch so the dashboard app shows it.        |
//| Setup: Tools > Options > Expert Advisors > Allow WebRequest for: |
//|   https://raw.githubusercontent.com                              |
//|   https://api.github.com                                         |
//| Tools > Options > Notifications: enable + your MetaQuotes ID.    |
//| Attach to ONE chart (any symbol, any timeframe).                 |
//+------------------------------------------------------------------+
#property copyright "FX28 weekly model"
#property version   "1.00"
#property strict

input string PlanURL        = "https://raw.githubusercontent.com/aamirrehansh/fx-bias-dashboard/main/data/plan.csv";
input int    CheckSeconds   = 60;      // news / price check interval
input int    PlanRefreshMin = 60;      // re-download plan every N minutes
input string SymbolSuffix   = "";      // broker suffix, e.g. ".r" (blank = auto-detect)
input bool   PushAlerts     = true;    // SendNotification to the MetaTrader mobile app
input bool   PopupAlerts    = true;    // terminal Alert() popup
input double ScoreAlertDrop = 15.0;    // alert if |score| weakens by this much vs plan
input double ConvictionLine = 50.0;    // alert if |score| falls below this (from above)
input bool   AlertWatchPairs= true;    // include WATCH / RESERVE pairs in alerts
input string GitHubToken    = "";      // fine-grained token: Contents read/write on fx-bias-dashboard only (blank = no upload)
input string GitHubRepo     = "aamirrehansh/fx-bias-dashboard";
input string GitHubBranch   = "live";
input int    PublishMinutes = 10;      // upload live.json at most every N minutes (and on any alert)

//--- model data
string   CCY[8] = {"USD","EUR","GBP","JPY","CHF","CAD","AUD","NZD"};
double   cFund[8], cCot[8], cSeas[8], cNewsPlan[8], cMacro[8], cStrPlan[8];
double   cNews[8], cStr[8];
double   wFund=0.4, wCot=0.2, wSeas=0.1, wNews=0.15, wMacro=0.15;
string   gWeekId="", gWeekEnd="", gWeekLabel="";
string   gPlanText="";

struct NewsRow
{
   datetime tUtc;        // release time (UTC)
   string   date, time, ccy, impact, name;
   double   pol, w, fc, pv, planScore;
   bool     matched, released;
   ulong    valueId;
   double   actual, score;
};
NewsRow  gNews[];

struct PairRow
{
   string pair, bias, tier, sym;
   double planScore, risk, d1Fail, h1Fail;
   double score;
   string lastState;     // for de-duplicating alerts
   bool   invalidSent, slSent;
};
PairRow  gPairs[];

string   gAlerts[];          // JSON alert objects for live.json (newest last)
string   gPushQueue[];
datetime gLastPush=0, gLastPlan=0, gLastPublish=0;
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
void OnTimer()
{
   if(TimeGMT()-gLastPlan >= PlanRefreshMin*60) LoadPlan(false);
   if(ArraySize(gPairs)>0)
   {
      MatchNews();
      UpdateNews();
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
   for(int i=0;i<n;i++)
   {
      string ln=lines[i]; StringReplace(ln,"\r","");
      if(ln=="") continue;
      string f[]; int k=StringSplit(ln,',',f);
      if(k<2) continue;
      if(f[0]=="WEEK" && k>=4){ gWeekId=f[1]; gWeekEnd=f[2]; gWeekLabel=f[3]; }
      else if(f[0]=="W" && k>=6){ wFund=Num(f[1]); wCot=Num(f[2]); wSeas=Num(f[3]); wNews=Num(f[4]); wMacro=Num(f[5]); }
      else if(f[0]=="C" && k>=8)
      {
         int c=CcyIdx(f[1]); if(c<0) continue;
         cFund[c]=Num(f[2]); cCot[c]=Num(f[3]); cSeas[c]=Num(f[4]); cNewsPlan[c]=Num(f[5]); cMacro[c]=Num(f[6]); cStrPlan[c]=Num(f[7]);
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
         r.matched=false; r.released=false; r.valueId=0; r.actual=EMPTY_VALUE; r.score=r.planScore;
         int m=ArraySize(gNews); ArrayResize(gNews,m+1); gNews[m]=r;
      }
      else if(f[0]=="P" && k>=8)
      {
         PairRow p;
         p.pair=f[1]; p.bias=f[2]; p.tier=f[3]; p.planScore=Num(f[4]); p.risk=Num(f[5]); p.d1Fail=Num(f[6]); p.h1Fail=Num(f[7]);
         p.score=p.planScore; p.lastState=""; p.invalidSent=false; p.slSent=false;
         p.sym=ResolveSymbol(p.pair);
         int m=ArraySize(gPairs); ArrayResize(gPairs,m+1); gPairs[m]=p;
      }
   }
   PrintFormat("FX Bias Monitor: plan %s loaded, %d news rows, %d pairs",gWeekLabel,ArraySize(gNews),ArraySize(gPairs));
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
      if(best>=0.55){ gNews[i].matched=true; gNews[i].valueId=bestId; }
   }
}

void UpdateNews()
{
   for(int i=0;i<ArraySize(gNews);i++)
   {
      if(!gNews[i].matched || gNews[i].released) continue;
      MqlCalendarValue v;
      if(!CalendarValueById(gNews[i].valueId,v)) continue;
      if(!v.HasActualValue()) continue;
      double act=v.GetActualValue();
      double s=0;
      if(v.HasForecastValue())
         s=Sgn(act-v.GetForecastValue())*gNews[i].pol*gNews[i].w;
      else if(gNews[i].fc!=EMPTY_VALUE && MathAbs(act-gNews[i].fc)<10*MathMax(1.0,MathAbs(gNews[i].fc)))
         s=Sgn(act-gNews[i].fc)*gNews[i].pol*gNews[i].w;
      else if(v.impact_type==CALENDAR_IMPACT_POSITIVE) s= gNews[i].w;
      else if(v.impact_type==CALENDAR_IMPACT_NEGATIVE) s=-gNews[i].w;
      gNews[i].released=true; gNews[i].actual=act; gNews[i].score=s;
      gDirty=true;
      int c=CcyIdx(gNews[i].ccy);
      double before=(c>=0 ? cStr[c] : 0);
      Recompute();
      bool recent=(TimeGMT()-gNews[i].tUtc < 2*3600);   // no push storm for older releases at start-up
      if(c>=0 && recent && CcyInShort(gNews[i].ccy))
         Queue(StringFormat("%s %s: actual %s vs f %s -> event %+.1f, %s strength %+.1f -> %+.1f",
               gNews[i].ccy,gNews[i].name,DoubleToString(act,2),(gNews[i].fc==EMPTY_VALUE?"-":DoubleToString(gNews[i].fc,2)),s,gNews[i].ccy,before,cStr[c]));
   }
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
      cNews[c]=(wt[c]>0 ? sum[c]/wt[c] : cNewsPlan[c]);
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
   Queue(text);
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
      string sym=gPairs[i].sym;
      int dg=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
      // D1 invalidation: completed D1 close beyond the D1 trend-fails level
      if(!gPairs[i].invalidSent && gPairs[i].d1Fail!=EMPTY_VALUE && gPairs[i].d1Fail>0)
      {
         double c1=iClose(sym,PERIOD_D1,1);
         if(c1>0 && ((dir>0 && c1<gPairs[i].d1Fail) || (dir<0 && c1>gPairs[i].d1Fail)))
         {
            gPairs[i].invalidSent=true;
            AddAlert("dn",gPairs[i].pair,StringFormat("%s %s %s: D1 closed %s beyond the trend-fails level %s. Idea invalid, exit.",gPairs[i].tier,gPairs[i].pair,gPairs[i].bias,DoubleToString(c1,dg),DoubleToString(gPairs[i].d1Fail,dg)));
         }
      }
      // H1 trend-fails (SL zone) touched
      if(!gPairs[i].slSent && gPairs[i].h1Fail!=EMPTY_VALUE && gPairs[i].h1Fail>0 && gPairs[i].tier=="TRADE")
      {
         double bid=SymbolInfoDouble(sym,SYMBOL_BID);
         if(bid>0 && ((dir>0 && bid<gPairs[i].h1Fail) || (dir<0 && bid>gPairs[i].h1Fail)))
         {
            gPairs[i].slSent=true;
            AddAlert("warn",gPairs[i].pair,StringFormat("%s %s: price %s crossed the H1 trend-fails / SL level %s.",gPairs[i].pair,gPairs[i].bias,DoubleToString(bid,dg),DoubleToString(gPairs[i].h1Fail,dg)));
         }
      }
   }
}

void Queue(const string msg)
{
   if(PopupAlerts) Alert(msg);
   Print(msg);
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
   string j="{\"week\":\""+gWeekId+"\",\"at\":\""+IsoUtc(TimeGMT())+"\",\"source\":\"MT5 FX Bias Monitor 1.00\",\"currencies\":[";
   for(int c=0;c<8;c++)
      j+=StringFormat("%s{\"ccy\":\"%s\",\"news\":%s,\"strength\":%s}",(c?",":""),CCY[c],D2S(cNews[c],4),D2S(cStr[c],3));
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
   string s="FX Bias Monitor 1.00 | "+gWeekLabel+" | news released: ";
   int rel=0, mat=0; for(int i=0;i<ArraySize(gNews);i++){ if(gNews[i].released) rel++; if(gNews[i].matched) mat++; }
   s+=IntegerToString(rel)+"/"+IntegerToString(ArraySize(gNews))+" (matched "+IntegerToString(mat)+")\n";
   s+="Strength: ";
   for(int c=0;c<8;c++) s+=StringFormat("%s %+.0f  ",CCY[c],cStr[c]);
   s+="\n";
   for(int i=0;i<ArraySize(gPairs);i++)
   {
      if(!IsShort(gPairs[i].tier)) continue;
      s+=StringFormat("%-7s %-4s %-7s plan %+6.1f  now %+6.1f  %s%s\n",gPairs[i].tier,gPairs[i].bias,gPairs[i].pair,gPairs[i].planScore,gPairs[i].score,
                      (gPairs[i].lastState=="" ? "OK" : gPairs[i].lastState),(gPairs[i].sym=="" ? "  (symbol not found)" : ""));
   }
   Comment(s);
}
//+------------------------------------------------------------------+

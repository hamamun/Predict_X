#ifndef __PX_PANEL_MQH__
#define __PX_PANEL_MQH__
#include "PX_Scoring.mqh"
#include "PX_MarketRegime.mqh"
#include "PX_Layer2_Trend.mqh"
#include "PX_Layer3_Value.mqh"
#include "PX_SignalLifecycle.mqh"

string PX_OBJ_PREFIX="PX_";

// The timeframe the EA engine is designed to run on. If the chart timeframe
// differs, the top-right chip warns the user which timeframe to attach to.
// (M5/M15/M30 are natively supported by PX_LoadPreset; this is the "working" one.)
#define PXM_WORKING_TF PERIOD_M30

string PX_TFCompatText(ENUM_TIMEFRAMES tf,color &clrOut)
{
   if(tf==PERIOD_M5 || tf==PERIOD_M15 || tf==PERIOD_M30)
   {
      clrOut=clrLime;
      return "TF "+PX_TFToString(tf)+" · COMPATIBLE";
   }
   clrOut=clrOrange;
   return "EA "+PX_TFToString(PXM_WORKING_TF)+" · chart "+PX_TFToString(tf);
}

void PX_DeleteObjects()
{
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
   {
      string name=ObjectName(0,i);
      if(StringFind(name,PX_OBJ_PREFIX)==0) ObjectDelete(0,name);
   }
}

bool PX_IsPanelObject(const string rawName)
{
   if(StringFind(rawName,PX_OBJ_PREFIX)!=0) return false;
   string n=StringSubstr(rawName,StringLen(PX_OBJ_PREFIX));
   if(StringFind(n,"ARROW_")==0 || StringFind(n,"TXT_")==0 || StringFind(n,"PROJ_")==0 || n=="REGIME_BAR") return false;
   return true;
}

void PX_DeletePanelObjects()
{
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
   {
      string name=ObjectName(0,i);
      if(PX_IsPanelObject(name)) ObjectDelete(0,name);
   }
}

int PX_Pct(const int pts,const int max)
{
   return (max>0 ? (int)MathRound((double)pts/max*100.0) : 0);
}

string PX_WrapTooltip(string text,int width=58)
{
   string words[];
   int n=StringSplit(text,' ',words);
   if(n<=0) return text;
   string out="", line="";
   for(int i=0;i<n;i++)
   {
      string w=words[i];
      if(StringLen(line)==0) line=w;
      else if(StringLen(line)+1+StringLen(w)>width)
      {
         out+=(out==""?line:"\n"+line);
         line=w;
      }
      else line+=" "+w;
   }
   if(line!="") out+=(out==""?line:"\n"+line);
   return out;
}

void PX_Label(string name,int x,int y,string text,color clr=clrWhite,int fontSize=10,string font="Consolas",string tooltip="")
{
   name=PX_OBJ_PREFIX+name;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fontSize);
   ObjectSetString(0,name,OBJPROP_FONT,font);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,PX_WrapTooltip(tooltip==""?text:tooltip));
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}

void PX_Rect(string name,int x,int y,int w,int h,color bg,color border=clrDimGray,string tooltip="")
{
   name=PX_OBJ_PREFIX+name;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,border);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,PX_WrapTooltip(tooltip));
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,(name==PX_OBJ_PREFIX+"PANEL_BG"));
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
}

string PX_Bar(int pts,int maxPts,int width=18)
{
   int filled=(maxPts>0?(int)MathRound((double)pts/maxPts*width):0);
   if(filled<0) filled=0; if(filled>width) filled=width;
   string s="";
   for(int i=0;i<width;i++) s+=(i<filled?"#":"-");
   return s;
}

string PX_LayerTooltip(const string title)
{
   if(title=="SMART MONEY") return "Layer 1 Smart Money: liquidity sweep, order block, fair value gap, and SMC confluence.";
   if(title=="TREND/MOM") return "Layer 2 Trend/Momentum: SuperTrend, RSI, TTM Squeeze, and ADX.";
   if(title=="INST VALUE/VOL") return "Layer 3 Institutional Value/Volatility: VWAP, Keltner, session, spread.";
   if(title=="HTF CONFLUENCE") return "Layer 4 Higher Timeframe Confluence: SuperTrend and VWAP on HTF1/HTF2.";
   if(title=="MARKOV STATE") return "Layer 5 Markov Chain: probability of Up/Neutral/Down state.";
   if(title=="AI CONFIRM") return "Layer 6 Online AI confirmation bonus. Never subtracts points.";
   return title;
}

void PX_RenderDetail(int &y,const PX_ScoreDetail &d)
{
   int pct=(d.maxPoints>0?(int)MathRound((double)d.points/d.maxPoints*100.0):0);
   PX_Label("D_"+d.title,14,y,StringFormat("%-15s %2d/%2d  [%s] %3d%%",d.title,d.points,d.maxPoints,PX_Bar(d.points,d.maxPoints,15),pct),clrWhite,10,"Consolas",PX_LayerTooltip(d.title)); y+=18;
   for(int i=0;i<d.detailCount && i<4;i++)
   {
      PX_Label("DD_"+d.title+IntegerToString(i),28,y,"- "+d.details[i],clrSilver,9,"Consolas","Component result: "+d.details[i]);
      y+=16;
   }
   y+=6;
}

void PX_RenderPanel(bool showPanel,string symbol,ENUM_TIMEFRAMES tf,const PX_RegimeState &reg,const PX_ScoreDetail &l1,const PX_ScoreDetail &l2,const PX_ScoreDetail &l3,const PX_ScoreDetail &l4,const PX_ScoreDetail &l5,const PX_ScoreDetail &l6,const PX_ScoreResult &sr,const PX_TradeSetup &ts,const PX_ValueContext &vc,const PX_TrendContext &tc,const PX_Lifecycle &lc,string warning,int signalsToday,int wins,int losses,int streak,const bool autoTradingOn,const string &togglesRest,const string &fvStatus,const string &summary,const string &lastAction,const string &lastActionTime)
{
   PX_DeletePanelObjects();
   if(!showPanel) return;

   // ---- Full panel background (height fits every section with comfortable margin) ----
   PX_Rect("PANEL_BG",5,18,455,462,(color)0x101010,clrDimGray,"PREDICT-X main decision panel.");

   // ---- Header band: title + symbol + timeframe compatibility chip (top-right) ----
   PX_Rect("HDR_BG",5,18,455,26,(color)0x141414,clrDimGray,"PREDICT-X header: title, symbol and timeframe compatibility.");
   PX_Label("HDR_TITLE",14,23,"PREDICT-X v3.0",clrAqua,11,"Segoe UI");
   PX_Label("HDR_SYMBOL",150,23,symbol,clrWhite,12,"Segoe UI");
   color tfClr; string tfChip=PX_TFCompatText(tf,tfClr);
   PX_Label("HDR_TFCOMP",290,23,tfChip,tfClr,9,"Consolas","Timeframe compatibility mode. If the chart timeframe is not one the EA runs on natively, it shows the EA's working timeframe so you know which timeframe to attach it to.");

   int y=52;

   // ---- Core toggle statuses (only the ones that matter) ----
   PX_Label("TOG_AUTO",14,y,"AUTO TRADE "+(autoTradingOn?"ON":"OFF"),(autoTradingOn?clrLime:clrTomato),10,"Segoe UI","Master switch. When ON the EA may place and manage trades automatically.");
   PX_Label("TOG_REST",150,y,togglesRest,clrSilver,9,"Consolas","Core protection/display switches.");
   y+=20;

   // ---- Market regime (name + the metrics you asked to keep) ----
   PX_Label("MRH",14,y,"-- MARKET REGIME -------------------------",clrWhite,10,"Segoe UI"); y+=17;
   PX_Label("MR1",14,y,"MARKET:  "+reg.name,reg.clr,11); y+=18;
   PX_Label("MR2",14,y,StringFormat("ADX %.1f   |   ER %.2f   |   ATR ratio %.2f",reg.adx,reg.er,reg.atrRatio),clrSilver,9,"Consolas","ADX = trend strength, ER = efficiency, ATR ratio = volatility. Higher ADX + efficient = cleaner trend.");
   y+=20;

   // ---- Score (medium loud) ----
   PX_Label("SCR_TOP",14,y,"===============================================",clrDimGray,10); y+=14;
   color scoreClr=(sr.total>=85?clrLime:(sr.total>=70?clrLime:(sr.total>=55?clrGold:(sr.total>=40?clrOrange:clrSilver))));
   PX_Label("SCORE",14,y,StringFormat("SCORE  %3d / 100  ·  %s",sr.total,PX_TierText(sr.tier)),scoreClr,12,"Segoe UI","Combined 0-100 confidence. Higher = cleaner setup.");
   y+=18;
   PX_Label("SCR_BOT",14,y,"===============================================",clrDimGray,10); y+=18;

   // ---- Signal (loud) + plain "Why" ----
   string sigLine="WATCH";
   color sigClr=clrSilver;
   if(sr.tier>=PX_TIER_MEDIUM && sr.dir!=PX_DIR_NONE)
   {
      sigLine=PX_DirectionText(sr.dir)+"  ·  "+PX_TierText(sr.tier);
      sigClr=(sr.dir==PX_DIR_BUY?clrLime:clrTomato);
   }
   PX_Label("SIGNAL",14,y,sigLine,sigClr,14,"Segoe UI","The loud decision line: what the engine currently recommends.");
   y+=24;

   string why="";
   if(sr.dir!=PX_DIR_NONE)
   {
      bool buy=(sr.dir==PX_DIR_BUY);
      bool stAgree=(buy && tc.stDir>0)||(!buy && tc.stDir<0);
      bool vwAgree=(buy && vc.price>vc.vwap)||(!buy && vc.price<vc.vwap);
      string driver=(stAgree && vwAgree)?"trend and value agree":(stAgree?"the trend agrees":(vwAgree?"price is on the value side":"momentum-led"));
      why="Why: leaning "+(buy?"up":"down")+" - "+driver+".";
   }
   else
      why=(reg.blockSignals?"Why: market unsafe - waiting.":(vc.spreadBlocked?"Why: costs too high - waiting.":"Why: no strong setup yet."));
   PX_Label("WHY",14,y,why,clrSilver,10,"Consolas","Short plain-language reason for the current state.");
   y+=24;

   // ---- Six sub-scores, two lines, xx/xx (xx%) ----
   PX_Label("SUB_H",14,y,"-- LAYER SCORES --------------------------",clrWhite,9,"Segoe UI"); y+=15;
   string s1=StringFormat("L1 %2d/%2d (%3d%%)   L2 %2d/%2d (%3d%%)   L3 %2d/%2d (%3d%%)",
      l1.points,l1.maxPoints,PX_Pct(l1.points,l1.maxPoints),
      l2.points,l2.maxPoints,PX_Pct(l2.points,l2.maxPoints),
      l3.points,l3.maxPoints,PX_Pct(l3.points,l3.maxPoints));
   PX_Label("SUB_L1",14,y,s1,clrSilver,9,"Consolas",PX_LayerTooltip(l1.title)+"  |  "+PX_LayerTooltip(l2.title)+"  |  "+PX_LayerTooltip(l3.title));
   y+=15;
   string s2=StringFormat("L4 %2d/%2d (%3d%%)   L5 %2d/%2d (%3d%%)   L6 %2d/%2d (%3d%%)",
      l4.points,l4.maxPoints,PX_Pct(l4.points,l4.maxPoints),
      l5.points,l5.maxPoints,PX_Pct(l5.points,l5.maxPoints),
      l6.points,l6.maxPoints,PX_Pct(l6.points,l6.maxPoints));
   PX_Label("SUB_L2",14,y,s2,clrSilver,9,"Consolas",PX_LayerTooltip(l4.title)+"  |  "+PX_LayerTooltip(l5.title)+"  |  "+PX_LayerTooltip(l6.title));
   y+=18;

   // ---- Session / spread / market open-or-closed ----
   PX_Label("CTX",14,y,"===============================================",clrDimGray,10); y+=14;
   string ctx=StringFormat("Session %s   ·   Spread %.0f pts   ·   Market %s",vc.sessionName,vc.spreadPoints,(vc.tickValid?"OPEN":"CLOSED"));
   PX_Label("CTX1",14,y,ctx,clrSilver,10,"Consolas","Current session, spread and whether the market is live.");
   y+=16;
   if(warning!="")
   {
      string w=warning;
      if(StringLen(w)>82) w=StringSubstr(w,0,80)+"...";
      PX_Label("WARN",14,y,w,clrOrange,9,"Consolas","Setup warning (often a timeframe/indicator note).");
      y+=16;
   }
   y+=4;

   // ---- Future view status (simple language) ----
   PX_Label("FV_H",14,y,"-- FUTURE VIEW ----------------------------",clrAqua,10,"Segoe UI"); y+=15;
   PX_Label("FV1",14,y,fvStatus,clrSilver,9,"Consolas","How similar past setups on this symbol+TF ended. Show-only - never changes a trade.");
   y+=20;

   // ---- Summary (why / what / how) ----
   PX_Label("SUM_H",14,y,"-- SUMMARY -------------------------------",clrWhite,10,"Segoe UI"); y+=15;
   PX_Label("SUM1",14,y,summary,clrGold,9,"Consolas","Plain-language explanation of what the engine sees and why.");
   y+=32;

   // ---- Last action (real time) ----
   PX_Label("ACT_H",14,y,"-- LAST ACTION ---------------------------",clrWhite,10,"Segoe UI"); y+=15;
   PX_Label("ACT1",14,y,StringFormat("%s   %s",lastActionTime,lastAction),clrSilver,10,"Consolas","The most recent action the engine took, with a live timestamp.");
   y+=18;

   // ---- Today's summary line (small) ----
   PX_Label("TODAY",14,y,StringFormat("Today: %d signal%s | %d win | %d loss",signalsToday,(signalsToday==1?"":"s"),wins,losses),clrDimGray,9,"Consolas","Today's signal/win/loss counts.");
}

void PX_DrawRegimeBar(const PX_RegimeState &reg)
{
   PX_Rect("REGIME_BAR",0,0,(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS),8,reg.clr,reg.clr,"Regime color bar. Current regime: "+reg.name+".");
}

void PX_DeleteProjectionLines()
{
   ObjectDelete(0,PX_OBJ_PREFIX+"PROJ_TP1");
   ObjectDelete(0,PX_OBJ_PREFIX+"PROJ_TP2");
   ObjectDelete(0,PX_OBJ_PREFIX+"PROJ_ENTRY");
   ObjectDelete(0,PX_OBJ_PREFIX+"PROJ_LABEL");
}

void PX_DrawProjectionLine(string name,datetime t1,double p1,datetime t2,double p2,color clr,ENUM_LINE_STYLE style,int width,string tooltip)
{
   name=PX_OBJ_PREFIX+name;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_TREND,0,t1,p1,t2,p2);
   ObjectSetInteger(0,name,OBJPROP_TIME,0,t1);
   ObjectSetDouble(0,name,OBJPROP_PRICE,0,p1);
   ObjectSetInteger(0,name,OBJPROP_TIME,1,t2);
   ObjectSetDouble(0,name,OBJPROP_PRICE,1,p2);
   ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_STYLE,style);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,width);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,PX_WrapTooltip(tooltip));
}

void PX_DrawPredictionProjection(const PX_TradeSetup &ts,const PX_ScoreResult &sr,int projectionBars)
{
   PX_DeleteProjectionLines();
   if(!ts.valid || sr.dir==PX_DIR_NONE || sr.tier<PX_TIER_MEDIUM || projectionBars<=0) return;
   if(ts.entry<=0.0 || ts.tp1<=0.0 || ts.tp2<=0.0) return;

   datetime t1=iTime(_Symbol,_Period,1);
   if(t1<=0) t1=TimeCurrent();
   datetime t2=t1+(datetime)(PeriodSeconds(_Period)*projectionBars);
   color tp1Clr=(sr.dir==PX_DIR_BUY?(color)0x90EE90:(color)0x8080FF);
   color tp2Clr=(sr.dir==PX_DIR_BUY?(color)0x66CCFF:(color)0x80D7FF);

   PX_DrawProjectionLine("PROJ_TP1",t1,ts.entry,t2,ts.tp1,tp1Clr,STYLE_SOLID,2,"Prediction projection: Entry to TP1 over the active signal projection bars.");
   PX_DrawProjectionLine("PROJ_TP2",t1,ts.entry,t2,ts.tp2,tp2Clr,STYLE_DASH,1,"Prediction projection: Entry to TP2 bonus target over the active signal projection bars.");
   PX_DrawProjectionLine("PROJ_ENTRY",t1,ts.entry,t2,ts.entry,clrSilver,STYLE_DOT,1,"Projected entry reference line.");

   string label=PX_OBJ_PREFIX+"PROJ_LABEL";
   if(ObjectFind(0,label)<0) ObjectCreate(0,label,OBJ_TEXT,0,t2,ts.tp1);
   ObjectSetInteger(0,label,OBJPROP_TIME,0,t2);
   ObjectSetDouble(0,label,OBJPROP_PRICE,0,ts.tp1);
   ObjectSetString(0,label,OBJPROP_TEXT,StringFormat("%s projection %d bars",PX_DirectionText(sr.dir),projectionBars));
   ObjectSetInteger(0,label,OBJPROP_COLOR,tp1Clr);
   ObjectSetInteger(0,label,OBJPROP_FONTSIZE,9);
   ObjectSetInteger(0,label,OBJPROP_SELECTABLE,false);
}

void PX_DrawSignalArrow(datetime t,double price,PX_Direction dir,PX_Tier tier,int waiting,int expiry)
{
   if(dir==PX_DIR_NONE || tier<PX_TIER_MEDIUM) return;
   string id=TimeToString(t,TIME_DATE|TIME_MINUTES);
   string name=PX_OBJ_PREFIX+"ARROW_"+id;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_ARROW,0,t,price);
   ObjectSetInteger(0,name,OBJPROP_ARROWCODE,(dir==PX_DIR_BUY?233:234));
   color c=clrLime;
   if(dir==PX_DIR_BUY) c=(tier==PX_TIER_VERY_STRONG?clrLime:(tier==PX_TIER_STRONG?clrGreen:clrPaleGreen));
   else c=(tier==PX_TIER_VERY_STRONG?clrRed:(tier==PX_TIER_STRONG?clrTomato:clrOrange));
   ObjectSetInteger(0,name,OBJPROP_COLOR,c);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,PX_WrapTooltip("Signal arrow. Closed-bar signal direction and tier."));

   string txt=PX_OBJ_PREFIX+"TXT_"+id;
   if(ObjectFind(0,txt)<0) ObjectCreate(0,txt,OBJ_TEXT,0,t,price);
   ObjectSetString(0,txt,OBJPROP_TEXT,StringFormat("%d/%d bars",waiting,expiry));
   ObjectSetString(0,txt,OBJPROP_TOOLTIP,PX_WrapTooltip("Pending signal age."));
   ObjectSetInteger(0,txt,OBJPROP_COLOR,c);
   ObjectSetInteger(0,txt,OBJPROP_FONTSIZE,9);
}

#endif

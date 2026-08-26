#ifndef __PX_PANEL_MQH__
#define __PX_PANEL_MQH__
#include "PX_Scoring.mqh"
#include "PX_MarketRegime.mqh"
#include "PX_Layer2_Trend.mqh"
#include "PX_Layer3_Value.mqh"
#include "PX_SignalLifecycle.mqh"

string PX_OBJ_PREFIX="PX_";

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

void PX_RenderPanel(bool showPanel,string symbol,ENUM_TIMEFRAMES tf,const PX_RegimeState &reg,const PX_ScoreDetail &l1,const PX_ScoreDetail &l2,const PX_ScoreDetail &l3,const PX_ScoreDetail &l4,const PX_ScoreDetail &l5,const PX_ScoreDetail &l6,const PX_ScoreResult &sr,const PX_TradeSetup &ts,const PX_ValueContext &vc,const PX_TrendContext &tc,const PX_Lifecycle &lc,string warning,int signalsToday,int wins,int losses,int streak)
{
   PX_DeletePanelObjects();
   if(!showPanel) return;
   PX_Rect("PANEL_BG",5,18,455,735,(color)0x101010,clrDimGray,"Main prediction/scoring panel. Trade setup and execution details are shown in the secondary panel.");
   int y=30;
   PX_Label("TITLE",16,y,"PREDICT-X v3.0        "+symbol+" | "+PX_TFToString(tf),clrAqua,11,"Segoe UI"); y+=19;
   PX_Label("RULE",16,y,"------------------------------------------------",clrDimGray,10); y+=18;
   if(warning!="") { PX_Label("WARN",16,y,"WARNING: "+warning,clrOrange,9); y+=18; }

   PX_Label("MRH",16,y,"-- MARKET REGIME -----------------------------",clrWhite,10,"Segoe UI"); y+=17;
   PX_Label("MR1",16,y,"REGIME: "+reg.name,reg.clr,10); y+=18;
   PX_Label("MR2",16,y,StringFormat("ER: %.2f | ATR Ratio: %.2f | ADX: %.1f",reg.er,reg.atrRatio,reg.adx),clrSilver,10); y+=18;
   PX_Label("MR3",16,y,"Adjustments: "+reg.adjustments,clrSilver,9); y+=19;

   PX_Label("TOTAL1",16,y,"================================================",clrDimGray,10); y+=16;
   PX_Label("TOTAL2",16,y,StringFormat("TOTAL SCORE    %3d/100 [%s]",sr.total,PX_Bar(sr.total,100,20)),(sr.total>=70?clrLime:(sr.total>=55?clrGold:clrSilver)),11); y+=19;
   PX_Label("TOTAL3",16,y,"================================================",clrDimGray,10); y+=18;

   string sigLine="SIGNAL: NO TRADE";
   color sigColor=clrSilver;
   if(sr.tier>=PX_TIER_MEDIUM && sr.dir!=PX_DIR_NONE)
   {
      string arrow=(sr.dir==PX_DIR_BUY?"UP":"DOWN");
      sigLine="SIGNAL: "+arrow+" "+PX_TierText(sr.tier)+" "+PX_DirectionText(sr.dir);
      sigColor=(sr.dir==PX_DIR_BUY?clrLime:clrTomato);
   }
   PX_Label("SIGNAL",16,y,sigLine,sigColor,11); y+=21;

   PX_RenderDetail(y,l1);
   PX_RenderDetail(y,l2);
   PX_RenderDetail(y,l3);
   PX_RenderDetail(y,l4);
   PX_RenderDetail(y,l5);
   PX_RenderDetail(y,l6);
   PX_Label("CANDLE",16,y,StringFormat("CANDLE CONFIRM  +%d/5",sr.candleBonus),(sr.candleBonus>0?clrGold:clrSilver),10,"Consolas","Candlestick confirmation bonus. Supports scoring only; never subtracts points."); y+=18;

   int digs=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   PX_Label("MCH",16,y,"-- MARKET CONTEXT ----------------------------",clrWhite,10,"Segoe UI"); y+=17;
   PX_Label("MC1",16,y,StringFormat("SESSION: %s | SPREAD: %.1f pts",vc.sessionName,vc.spreadPoints),clrSilver,10); y+=17;
   PX_Label("MC2",16,y,StringFormat("VWAP: %.*f | ATR: %.1f pts",digs,vc.vwap,vc.atr/_Point),clrSilver,10); y+=17;
   PX_Label("MC3",16,y,StringFormat("ST: %s | SQZ: %s | ADX: %.1f",(tc.stDir>0?"GREEN":(tc.stDir<0?"RED":"FLAT")),(tc.ttmSqueeze>0.5?"ACTIVE":"FIRED"),tc.adx),clrSilver,10); y+=18;

   PX_Label("SSH",16,y,"-- SIGNAL STATE ------------------------------",clrWhite,10,"Segoe UI"); y+=17;
   PX_Label("SS1",16,y,StringFormat("STATE: %s | BARS WAITING: %d/%d",PX_StateText(lc.state),lc.barsWaiting,reg.adjusted.signalExpiryBars),clrSilver,10); y+=17;
   PX_Label("SS2",16,y,StringFormat("SIGNALS TODAY: %d | WIN: %d | LOSS: %d",signalsToday,wins,losses),clrSilver,9); y+=18;
   PX_Label("PHASE",16,y,"Auto-trading only if master switch is ON.",clrOrange,8);
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

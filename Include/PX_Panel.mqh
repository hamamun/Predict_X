#ifndef __PX_PANEL_MQH__
#define __PX_PANEL_MQH__
#include "PX_Scoring.mqh"
#include "PX_MarketRegime.mqh"
#include "PX_Layer2_Trend.mqh"
#include "PX_Layer3_Value.mqh"
#include "PX_SignalLifecycle.mqh"
#include "PX_PanelGeometry.mqh"

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

//+------------------------------------------------------------------+
//| Left-panel geometry + text metrics.                              |
//|                                                                  |
//| Does MQL5 wrap text on the chart? No. A chart text object        |
//| (OBJ_LABEL / OBJ_TEXT) paints OBJPROP_TEXT as exactly ONE line:  |
//| there is no word-wrap property for it, and embedded newlines are |
//| not honoured either (MetaQuotes was asked for a multiline text   |
//| object and declined it). Only Comment() and TOOLTIPS take line    |
//| breaks - which is what PX_WrapTooltip() above exists for.        |
//|                                                                  |
//| So wrapping has to be done by hand: PX_WrapText() cuts the       |
//| string at word boundaries, PX_RenderWrappedLines() paints one     |
//| label per line and returns the new y.                            |
//+------------------------------------------------------------------+
// Shared left/right panel coordinates live in PX_PanelGeometry.mqh so the
// order-manager panel can stay adjacent to this main panel.
// Detail blocks that may span several lines (FUTURE VIEW / SUMMARY /
// LAST ACTION) are capped at this many lines.
#define PX_DETAIL_MAX_LINES 3
// Approximate width of one character of the panel's monospace font, in
// pixels, per font point (Consolas is ~0.55 em wide; points -> px is x1.333).
// MQL5 offers no text-metrics call for chart objects, so this is calibrated
// a touch WIDE on purpose: at worst a line breaks one word early, but a line
// can never spill outside the panel.
#define PX_FONT_PX_PER_PT   0.76

double PX_CharPx(const int fontSize)
{
   double pt=(double)(fontSize>4?fontSize:9);
   double px=pt*PX_FONT_PX_PER_PT;
   return (px<1.0?1.0:px);
}

// How many characters of this font size fit on one line of the left panel.
int PX_FitChars(const int fontSize,const int x=PX_TEXT_X,const int widthPx=PX_PNL_W)
{
   int avail=widthPx-(x-PX_PNL_X)-PX_TEXT_PAD_R;
   if(avail<40) avail=40;
   int n=(int)MathFloor((double)avail/PX_CharPx(fontSize));
   return (n<16?16:n);
}

// Vertical pitch of one text line, in pixels (keeps the panel's 16/18 px rhythm).
int PX_LineHeight(const int fontSize)
{
   double pt=(double)(fontSize>4?fontSize:9);
   return (int)MathCeil(pt*1.75);
}

void PX_TrimSpaces(string &s)
{
   int n=StringLen(s);
   int b=0,e=n;
   while(b<e)
   {
      ushort c=StringGetCharacter(s,b);
      if(c!=32 && c!=9) break;   // not space / tab
      b++;
   }
   while(e>b)
   {
      ushort c=StringGetCharacter(s,e-1);
      if(c!=32 && c!=9) break;
      e--;
   }
   s=StringSubstr(s,b,e-b);
}

void PX_PushLine(string &lines[],const string line)
{
   int n=ArraySize(lines);
   ArrayResize(lines,n+1);
   lines[n]=line;
}

//+------------------------------------------------------------------+
//| Greedy word wrap for one chart text block.                       |
//| Honours hard breaks (\n, which a label cannot show itself),      |
//| collapses doubled spaces, splits a single word that is longer    |
//| than the line, and stops at maxLines with "..." so a block can   |
//| never grow past its allowance. Returns the number of lines.      |
//+------------------------------------------------------------------+
int PX_WrapText(string text,const int maxChars,const int maxLines,string &lines[])
{
   ArrayResize(lines,0);
   if(StringLen(text)<=0) return 0;
   int width=(maxChars>8?maxChars:8);
   int cap=(maxLines>0?maxLines:1);

   string body=text;                    // 'text' stays untouched for the fallback + log
   StringReplace(body,"\r\n","\n");
   StringReplace(body,"\r","\n");

   string all[];
   string paras[];
   int np=StringSplit(body,'\n',paras);
   if(np<0) np=0;
   for(int p=0;p<np;p++)
   {
      string para=paras[p];
      while(StringFind(para,"  ")>=0) StringReplace(para,"  "," ");   // labels need single spaces
      PX_TrimSpaces(para);
      if(StringLen(para)<=0) continue;

      string words[];
      int nw=StringSplit(para,' ',words);
      string cur="";
      for(int i=0;i<nw;i++)
      {
         string w=words[i];
         if(StringLen(w)<=0) continue;
         while(StringLen(w)>width)                 // word wider than the line: break it
         {
            if(StringLen(cur)>0) { PX_PushLine(all,cur); cur=""; }
            PX_PushLine(all,StringSubstr(w,0,width));
            w=StringSubstr(w,width);
         }
         if(StringLen(cur)<=0) cur=w;
         else if(StringLen(cur)+1+StringLen(w)<=width) cur+=" "+w;
         else { PX_PushLine(all,cur); cur=w; }
      }
      if(StringLen(cur)>0) PX_PushLine(all,cur);
   }
   if(ArraySize(all)==0) PX_PushLine(all,StringSubstr(text,0,width));

   int n=ArraySize(all);
   if(n<=cap)
   {
      ArrayResize(lines,n);
      for(int i=0;i<n;i++) lines[i]=all[i];
      return n;
   }

   // Does not fit the allowance: keep the first cap lines, mark the last as
   // truncated, and put what had to be dropped in the Experts log.
   ArrayResize(lines,cap);
   for(int i=0;i<cap;i++) lines[i]=all[i];
   string rest="";
   for(int i=cap;i<n;i++) rest+=(rest==""?all[i]:" "+all[i]);
   int room=width-3;
   if(StringLen(lines[cap-1])>room) lines[cap-1]=StringSubstr(lines[cap-1],0,room);
   lines[cap-1]+="...";
   Print("PREDICT-X panel: text needs ",IntegerToString(n)," lines, only ",IntegerToString(cap)," allowed. Dropped: ",rest);
   return cap;
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

// Paint a wrapped block starting at (x,y); returns the y just below it.
// The first line keeps the section tooltip, continuation lines show their
// own text as tooltip.
int PX_RenderWrappedLines(const string nameBase,const int x,const int y,const string text,const color clr,const int fontSize,const string font,const string tooltip,const int maxChars=0,const int maxLines=PX_DETAIL_MAX_LINES)
{
   int width=(maxChars>0?maxChars:PX_FitChars(fontSize,x));
   int lh=PX_LineHeight(fontSize);
   string lines[];
   int n=PX_WrapText(text,width,maxLines,lines);
   if(n<=0) return y+lh;                    // empty value: still reserve the line
   for(int i=0;i<n;i++)
      PX_Label(nameBase+"_"+IntegerToString(i),x,y+i*lh,lines[i],clr,fontSize,font,(i==0?tooltip:lines[i]));
   return y+n*lh;
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

void PX_RenderPanel(bool showPanel,string symbol,ENUM_TIMEFRAMES tf,const PX_RegimeState &reg,const PX_ScoreDetail &l1,const PX_ScoreDetail &l2,const PX_ScoreDetail &l3,const PX_ScoreDetail &l4,const PX_ScoreDetail &l5,const PX_ScoreDetail &l6,const PX_ScoreResult &sr,const PX_DisplayState &ds,const PX_TradeSetup &ts,const PX_ValueContext &vc,const PX_TrendContext &tc,const PX_Lifecycle &lc,string warning,int signalsToday,int wins,int losses,int streak,const bool autoTradingOn,const string togglesRest,const string fvStatus,const string summary,const string lastAction,const string lastActionTime)
{
   PX_DeletePanelObjects();
   if(!showPanel) return;

   // ---- Full panel background (height is re-fitted at the end, once the
   //      wrapped detail blocks know how many lines they needed) ----
   PX_Rect("PANEL_BG",PX_PNL_X,PX_PNL_Y,PX_PNL_W,PX_PNL_H,(color)0x101010,clrDimGray,"PREDICT-X main decision panel.");

   // ---- Header band: title + symbol + timeframe compatibility chip (top-right) ----
   PX_Rect("HDR_BG",PX_PNL_X,PX_PNL_Y,PX_PNL_W,26,(color)0x141414,clrDimGray,"PREDICT-X header: title, symbol and timeframe compatibility.");
   PX_Label("HDR_TITLE",14,23,"PREDICT-X v3.0",clrAqua,11,"Segoe UI");
   PX_Label("HDR_SYMBOL",150,23,symbol,clrWhite,12,"Segoe UI");
   color tfClr; string tfChip=PX_TFCompatText(tf,tfClr);
   PX_Label("HDR_TFCOMP",290,23,tfChip,tfClr,9,"Consolas","Timeframe compatibility mode. If the chart timeframe is not one the EA runs on natively, it shows the EA's working timeframe so you know which timeframe to attach it to.");

   int y=52;

   // ---- Core toggle statuses (only the ones that matter) ----
   PX_Label("TOG_AUTO",14,y,"AUTO TRADE "+(autoTradingOn?"ON":"OFF"),(autoTradingOn?clrLime:clrTomato),10,"Segoe UI","Master switch for NEW trades. OFF = the EA places nothing new, but trade protection still guards its existing open position and pending order (see the PROTECTION switches).");
   PX_Label("TOG_REST",150,y,togglesRest,clrSilver,9,"Consolas","Core protection/display switches.");
   y+=20;

   // ---- Market regime (name + trend word from the SAME 4 votes the EA uses) ----
   PX_Label("MRH",14,y,"-- MARKET REGIME -------------------------",clrWhite,10,"Segoe UI"); y+=17;
   string trendWord=(ds.bullVotes>ds.bearVotes?"TREND UP":(ds.bearVotes>ds.bullVotes?"TREND DOWN":"SIDEWAYS"));
   PX_Label("MR1",14,y,"MARKET:  "+reg.name+"  ·  "+trendWord,reg.clr,11,"Segoe UI","Market regime plus the trend word. The trend word comes from the same 4 direction votes the EA uses, so this line can never contradict the DIRECTION line.");
   y+=18;
   PX_Label("MR2",14,y,StringFormat("ADX %.1f   |   ER %.2f   |   ATR ratio %.2f",reg.adx,reg.er,reg.atrRatio),clrSilver,9,"Consolas","ADX = trend strength, ER = efficiency, ATR ratio = volatility. Higher ADX + efficient = cleaner trend.");
   y+=20;

   // ---- Score: the REAL voting, always shown, never forced to 0 ----
   PX_Label("SCR_TOP",14,y,"===============================================",clrDimGray,10); y+=14;
   int gate=(reg.adjusted.minScore>0?reg.adjusted.minScore:55);
   int expBars=(reg.adjusted.signalExpiryBars>0?reg.adjusted.signalExpiryBars:3);
   string scoreText;
   color scoreClr=clrSilver;
   if(ds.valid)
   {
      scoreText=StringFormat("SCORE  %3d / 100  ·  %s  ·  needs %d",ds.total,PX_TierText(ds.tier),gate);
      // Grey = blocked: the number is information only, not permission.
      if(ds.blocked) scoreClr=clrDarkGray;
      else scoreClr=(ds.total>=gate?clrLime:(ds.total>=gate-10?clrGold:clrSilver));
   }
   else
      scoreText=StringFormat("SCORE   -- / 100  ·  no score yet  ·  needs %d",gate);
   PX_Label("SCORE",14,y,scoreText,scoreClr,12,"Segoe UI","The real 0-100 voting, always shown - a blocked market no longer hides it. Grey means the market is blocked: the number is information only, the DIRECTION line decides. 'needs' is the minimum score the current regime requires (timeframe base, regime-adjusted).");
   y+=18;
   PX_Label("SCR_BOT",14,y,"===============================================",clrDimGray,10); y+=18;

   // ---- Direction: one decision word + what physically exists ----
   // BUY / SELL = act now, or a live order/trade in that direction.
   // HOLD = do nothing, always with the reason (blocked, no direction, or
   // score below the gate). A live/armed signal owns its direction
   // (lc.pendingDir); the current bar's lean is only a footnote.
   string sigLine="HOLD";
   color sigClr=clrSilver;
   if(lc.state==PX_STATE_ACTIVE || lc.state==PX_STATE_PENDING)
   {
      PX_Direction liveDir=(lc.pendingDir!=PX_DIR_NONE?lc.pendingDir:sr.dir);
      if(liveDir==PX_DIR_NONE) liveDir=ds.dir;
      if(liveDir!=PX_DIR_NONE)
      {
         string stateTag=(lc.state==PX_STATE_ACTIVE?"open trade":
                          ((ts.valid && ts.method!=PX_ENTRY_MARKET)?StringFormat("limit waiting %d/%d",lc.barsWaiting,expBars):"signal armed"));
         string leanTag=(ds.dir!=PX_DIR_NONE && ds.dir!=liveDir?"  ·  lean "+PX_DirectionText(ds.dir):"");
         sigLine=PX_DirectionText(liveDir)+"  ·  "+stateTag+leanTag;
         sigClr=(liveDir==PX_DIR_BUY?clrLime:clrTomato);
      }
   }
   else if(reg.blockSignals)
   {
      sigLine="HOLD  ·  blocked: "+reg.name;
      sigClr=clrGray;
   }
   else if(vc.spreadBlocked)
   {
      sigLine="HOLD  ·  blocked: spread too high";
      sigClr=clrGray;
   }
   else if(!ds.valid || sr.dir==PX_DIR_NONE)
   {
      if(ds.bullVotes==ds.bearVotes)
         sigLine=StringFormat("HOLD  ·  no direction (%d-%d votes)",ds.bullVotes,ds.bearVotes);
      else
         sigLine=StringFormat("HOLD  ·  no score yet (%d-%d votes)",ds.bullVotes,ds.bearVotes);
   }
   else if(sr.total>=gate)
   {
      sigLine=PX_DirectionText(sr.dir)+"  ·  "+PX_TierText(sr.tier);
      sigClr=(sr.dir==PX_DIR_BUY?clrLime:clrTomato);
   }
   else
   {
      sigLine=StringFormat("HOLD  ·  %d points short of %d",gate-sr.total,gate);
      sigClr=clrGold;
   }
   PX_Label("SIGNAL",14,y,sigLine,sigClr,14,"Segoe UI","One decision word. BUY/SELL = actionable now, or a live trade/order in that direction ('open trade' = position exists, 'limit waiting n/"+IntegerToString(expBars)+"' = limit order placed, expires after that many bars). HOLD = do nothing, with the reason: blocked market, no clear direction, or score below the gate ("+IntegerToString(gate)+").");
   y+=24;

   // ---- Why: one sentence, always the same shape: votes -> score vs gate -> blocker ----
   int vHi=(ds.bullVotes>ds.bearVotes?ds.bullVotes:ds.bearVotes);
   int vLo=(ds.bullVotes>ds.bearVotes?ds.bearVotes:ds.bullVotes);
   string voteTxt=StringFormat("%d-%d %s",vHi,vLo,
      (ds.bullVotes>ds.bearVotes?"BUY":(ds.bearVotes>ds.bullVotes?"SELL":"tie")));
   string scoreTxt=(ds.valid?IntegerToString(ds.total):"no score");
   string why="";
   if(lc.state==PX_STATE_ACTIVE && lc.pendingDir!=PX_DIR_NONE)
   {
      why="Why "+PX_DirectionText(lc.pendingDir)+" · open trade: protection (TP/trail) decides the exit, not today's score";
      if(ds.valid && ds.dir!=PX_DIR_NONE && ds.dir!=lc.pendingDir) why+=" (bar now leans "+PX_DirectionText(ds.dir)+")";
      why+=".";
   }
   else if(lc.state==PX_STATE_PENDING)
   {
      PX_Direction pd=(lc.pendingDir!=PX_DIR_NONE?lc.pendingDir:sr.dir);
      why=StringFormat("Why %s: votes %s, score %s over gate %d - order waits up to %d bars.",PX_DirectionText(pd),voteTxt,scoreTxt,gate,expBars);
   }
   else if(reg.blockSignals)
      why=StringFormat("Why HOLD: votes %s, %s, but the market is %s - trading paused.",voteTxt,scoreTxt,reg.name);
   else if(vc.spreadBlocked)
      why=StringFormat("Why HOLD: votes %s, %s, but the spread is over 2x normal - costs too high.",voteTxt,scoreTxt);
   else if(!ds.valid || sr.dir==PX_DIR_NONE)
   {
      if(ds.bullVotes==ds.bearVotes)
         why=StringFormat("Why HOLD: the 4 direction votes split %d-%d - no clear direction to score.",ds.bullVotes,ds.bearVotes);
      else
         why=StringFormat("Why HOLD: votes %s, but the data is not ready to score yet.",voteTxt);
   }
   else if(sr.total>=gate)
   {
      bool buy=(sr.dir==PX_DIR_BUY);
      bool stAgree=(buy && tc.stDir>0)||(!buy && tc.stDir<0);
      bool vwAgree=(buy && vc.price>vc.vwap)||(!buy && vc.price<vc.vwap);
      string driver=(stAgree && vwAgree)?"trend and value agree":(stAgree?"the trend agrees":(vwAgree?"price is on the value side":"momentum-led"));
      why=StringFormat("Why %s: votes %s, score %d over gate %d - %s.",PX_DirectionText(sr.dir),voteTxt,sr.total,gate,driver);
   }
   else
      why=StringFormat("Why HOLD: votes %s, score %d - needs %d (%d points short).",voteTxt,sr.total,gate,gate-sr.total);
   // Wrapped as a safety net: this line embeds the dynamic regime name, and a
   // label cannot wrap itself. One line still costs exactly the old 24px.
   y=PX_RenderWrappedLines("WHY",PX_TEXT_X,y,why,clrSilver,10,"Consolas","Plain-language reason: direction votes, score vs gate, and any blocker.",0,3)+6;

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
   // Wrapping instead of clipping: MT5 labels cannot word-wrap, so the block
   // is laid out as up to PX_DETAIL_MAX_LINES label lines (see PX_WrapText).
   PX_Label("FV_H",14,y,"-- FUTURE VIEW ----------------------------",clrAqua,10,"Segoe UI"); y+=15;
   y=PX_RenderWrappedLines("FV1",PX_TEXT_X,y,fvStatus,clrSilver,9,"Consolas","How similar past setups on this symbol+TF ended. Show-only - never changes a trade.")+4;

   // ---- Summary (why / what / how) ----
   PX_Label("SUM_H",14,y,"-- SUMMARY -------------------------------",clrWhite,10,"Segoe UI"); y+=15;
   y=PX_RenderWrappedLines("SUM1",PX_TEXT_X,y,summary,clrGold,9,"Consolas","Plain-language explanation of what the engine sees and why.")+PX_LineHeight(9);

   // ---- Last action (real time) ----
   PX_Label("ACT_H",14,y,"-- LAST ACTION ---------------------------",clrWhite,10,"Segoe UI"); y+=15;
   y=PX_RenderWrappedLines("ACT1",PX_TEXT_X,y,StringFormat("%s %s",lastActionTime,lastAction),clrSilver,10,"Consolas","The most recent action the engine took, with a live timestamp.");

   // ---- Today's summary line (small) ----
   PX_Label("TODAY",14,y,StringFormat("Today: %d signal%s | %d win | %d loss",signalsToday,(signalsToday==1?"":"s"),wins,losses),clrDimGray,9,"Consolas","Today's signal/win/loss counts.");

   // ---- Fit the background to the content: single-line details keep the
   //      panel exactly as tall as before; wrapped details grow it. ----
   int need=y+PX_LineHeight(9)+16-PX_PNL_Y;
   ObjectSetInteger(0,PX_OBJ_PREFIX+"PANEL_BG",OBJPROP_YSIZE,(need>PX_PNL_H?need:PX_PNL_H));
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

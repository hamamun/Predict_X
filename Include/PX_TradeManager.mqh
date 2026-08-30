#ifndef __PX_TRADEMANAGER_MQH__
#define __PX_TRADEMANAGER_MQH__

#include <Trade/Trade.mqh>
#include "PX_Scoring.mqh"
#include "PX_MarketRegime.mqh"
#include "PX_Layer2_Trend.mqh"
#include "PX_Layer3_Value.mqh"
#include "PX_SignalLifecycle.mqh"
#include "PX_PanelGeometry.mqh"

#define PX_MAGIC 26070501

CTrade px_trade;

struct PX_TradeManagerState
{
   bool enabled;
   bool dailyHalted;
   int dayOfYear;
   double dayStartBalance;
   double dailyLossPct;
   bool dailyLossControlEnabled;
   bool tp1Hit;
   int earlyStage;
   int entryTimeframe;
   bool postTP1MidLocked;
   double postTP1Best;
   double preTP1Best;
   double entry;
   double originalSL;
   double tp1;
   double tp2;
   double breakeven;
   double lastTrail;
   ulong positionTicket;
   ulong pendingTicket;
   string stateText;
   string lastAction;
   datetime lastActionTime;

   // --- Staircase protection state (additive; defaults are safe no-ops) ---
   // protectArmed=true once floating P/L has reached triggerPctOfRisk of the
   // position's live risk. Until then, the trade is left untouched with only
   // the broker-side initial SL as its downside (per the user's intent).
   bool   protectArmed;
   double triggerMoney;     // cached 1% of risk at arming time, in account money
   int    currentBucket;    // 0=pre-bucket1, 1=lock1->lock2, 2=lock2->lock3, 3=lock3->TP1, 4=post-TP1
   double bucketPeak;       // best favorable price since entering currentBucket
   double bucketEntry;      // price at which the current bucket was entered
   double currentLock;      // lock price of the current bucket (0 if none)
   double staircaseRisk;    // live risk in $ at arming time, for re-arming checks
};

string PX2_PREFIX="PX2_";

string PX_TM_Key(string suffix)
{
   return "PREDICTX."+IntegerToString(PX_MAGIC)+"."+_Symbol+"."+suffix;
}

void PX_TM_SavePersistence(PX_TradeManagerState &tm)
{
   GlobalVariableSet(PX_TM_Key("entry"),tm.entry);
   GlobalVariableSet(PX_TM_Key("originalSL"),tm.originalSL);
   GlobalVariableSet(PX_TM_Key("tp1"),tm.tp1);
   GlobalVariableSet(PX_TM_Key("tp2"),tm.tp2);
   GlobalVariableSet(PX_TM_Key("breakeven"),tm.breakeven);
   GlobalVariableSet(PX_TM_Key("lastTrail"),tm.lastTrail);
   GlobalVariableSet(PX_TM_Key("tp1Hit"),(tm.tp1Hit?1.0:0.0));
   GlobalVariableSet(PX_TM_Key("earlyStage"),(double)tm.earlyStage);
   GlobalVariableSet(PX_TM_Key("entryTimeframe"),(double)tm.entryTimeframe);
   GlobalVariableSet(PX_TM_Key("postTP1MidLocked"),(tm.postTP1MidLocked?1.0:0.0));
   GlobalVariableSet(PX_TM_Key("postTP1Best"),tm.postTP1Best);
   GlobalVariableSet(PX_TM_Key("preTP1Best"),tm.preTP1Best);
   GlobalVariableSet(PX_TM_Key("savedAt"),(double)TimeCurrent());
   // Staircase protection state (additive; does not change existing behavior).
   GlobalVariableSet(PX_TM_Key("protectArmed"),(tm.protectArmed?1.0:0.0));
   GlobalVariableSet(PX_TM_Key("triggerMoney"),tm.triggerMoney);
   GlobalVariableSet(PX_TM_Key("currentBucket"),(double)tm.currentBucket);
   GlobalVariableSet(PX_TM_Key("bucketPeak"),tm.bucketPeak);
   GlobalVariableSet(PX_TM_Key("bucketEntry"),tm.bucketEntry);
   GlobalVariableSet(PX_TM_Key("currentLock"),tm.currentLock);
   GlobalVariableSet(PX_TM_Key("staircaseRisk"),tm.staircaseRisk);
}

void PX_TM_LoadPersistence(PX_TradeManagerState &tm)
{
   if(GlobalVariableCheck(PX_TM_Key("entry")))     tm.entry=GlobalVariableGet(PX_TM_Key("entry"));
   if(GlobalVariableCheck(PX_TM_Key("originalSL")))tm.originalSL=GlobalVariableGet(PX_TM_Key("originalSL"));
   if(GlobalVariableCheck(PX_TM_Key("tp1")))       tm.tp1=GlobalVariableGet(PX_TM_Key("tp1"));
   if(GlobalVariableCheck(PX_TM_Key("tp2")))       tm.tp2=GlobalVariableGet(PX_TM_Key("tp2"));
   if(GlobalVariableCheck(PX_TM_Key("breakeven"))) tm.breakeven=GlobalVariableGet(PX_TM_Key("breakeven"));
   if(GlobalVariableCheck(PX_TM_Key("lastTrail"))) tm.lastTrail=GlobalVariableGet(PX_TM_Key("lastTrail"));
   if(GlobalVariableCheck(PX_TM_Key("tp1Hit")))    tm.tp1Hit=(GlobalVariableGet(PX_TM_Key("tp1Hit"))>0.5);
   if(GlobalVariableCheck(PX_TM_Key("earlyStage"))) tm.earlyStage=(int)GlobalVariableGet(PX_TM_Key("earlyStage"));
   if(GlobalVariableCheck(PX_TM_Key("entryTimeframe"))) tm.entryTimeframe=(int)GlobalVariableGet(PX_TM_Key("entryTimeframe"));
   if(GlobalVariableCheck(PX_TM_Key("postTP1MidLocked"))) tm.postTP1MidLocked=(GlobalVariableGet(PX_TM_Key("postTP1MidLocked"))>0.5);
   if(GlobalVariableCheck(PX_TM_Key("postTP1Best"))) tm.postTP1Best=GlobalVariableGet(PX_TM_Key("postTP1Best"));
   if(GlobalVariableCheck(PX_TM_Key("preTP1Best"))) tm.preTP1Best=GlobalVariableGet(PX_TM_Key("preTP1Best"));
   // Staircase protection state (additive). Defaults to "not armed" on first run.
   if(GlobalVariableCheck(PX_TM_Key("protectArmed"))) tm.protectArmed=(GlobalVariableGet(PX_TM_Key("protectArmed"))>0.5);
   if(GlobalVariableCheck(PX_TM_Key("triggerMoney")))  tm.triggerMoney=GlobalVariableGet(PX_TM_Key("triggerMoney"));
   if(GlobalVariableCheck(PX_TM_Key("currentBucket"))) tm.currentBucket=(int)GlobalVariableGet(PX_TM_Key("currentBucket"));
   if(GlobalVariableCheck(PX_TM_Key("bucketPeak")))    tm.bucketPeak=GlobalVariableGet(PX_TM_Key("bucketPeak"));
   if(GlobalVariableCheck(PX_TM_Key("bucketEntry")))  tm.bucketEntry=GlobalVariableGet(PX_TM_Key("bucketEntry"));
   if(GlobalVariableCheck(PX_TM_Key("currentLock")))   tm.currentLock=GlobalVariableGet(PX_TM_Key("currentLock"));
   if(GlobalVariableCheck(PX_TM_Key("staircaseRisk"))) tm.staircaseRisk=GlobalVariableGet(PX_TM_Key("staircaseRisk"));
}

void PX_TM_ClearPersistence()
{
   string keys[20]={"entry","originalSL","tp1","tp2","breakeven","lastTrail","tp1Hit","earlyStage","entryTimeframe","postTP1MidLocked","postTP1Best","preTP1Best","savedAt","protectArmed","triggerMoney","currentBucket","bucketPeak","bucketEntry","currentLock","staircaseRisk"};
   for(int i=0;i<20;i++) GlobalVariableDel(PX_TM_Key(keys[i]));
}

double PX_NormPrice(const double price)
{
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   return NormalizeDouble(price,digits);
}

void PX_TM_DeleteObjects()
{
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
   {
      string name=ObjectName(0,i);
      if(StringFind(name,PX2_PREFIX)==0) ObjectDelete(0,name);
   }
}

void PX2_Label(string name,int x,int y,string text,color clr=clrWhite,int fontSize=11,string font="Consolas")
{
   name=PX2_PREFIX+name;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fontSize);
   ObjectSetString(0,name,OBJPROP_FONT,font);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}

void PX2_Rect(string name,int x,int y,int w,int h,color bg,color border=clrDimGray)
{
   name=PX2_PREFIX+name;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,border);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}

void PX2_HLine(string name,double price,color clr,ENUM_LINE_STYLE style=STYLE_DASH,int width=1)
{
   name=PX2_PREFIX+name;
   if(price<=0.0) { ObjectDelete(0,name); return; }
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_HLINE,0,0,price);
   ObjectSetDouble(0,name,OBJPROP_PRICE,price);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_STYLE,style);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,width);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}

void PX_TM_DeletePanelObjectsOnly()
{
   // Rebuild secondary panel every refresh to prevent stale/garbled text.
   // Keep trade lines; they are updated separately.
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
   {
      string n=ObjectName(0,i);
      if(StringFind(n,PX2_PREFIX)==0 && StringFind(n,"LINE")<0)
         ObjectDelete(0,n);
   }
}

string PX_TM_ShortMethod(string method)
{
   string m=method;
   StringReplace(m,"market (very strong)","MKT very strong");
   StringReplace(m,"market (strong momentum, not extended)","MKT strong momentum");
   StringReplace(m,"market (medium strong momentum)","MKT medium momentum");
   StringReplace(m,"market (price past value)","MKT price past value");
   StringReplace(m,"market (price past ST)","MKT price past ST");
   StringReplace(m,"market (pending momentum refresh)","MKT pending refresh");
   StringReplace(m,"Order Block/VWAP limit","OB/VWAP limit");
   StringReplace(m,"SuperTrend limit","ST limit");
   return m;
}

string PX_TM_ShortAction(string action)
{
   string a=action;
   StringReplace(a,"market (strong momentum, not extended)","MKT strong momentum");
   StringReplace(a,"market (medium strong momentum)","MKT medium momentum");
   StringReplace(a,"market (price past value)","MKT price past value");
   StringReplace(a,"market (pending momentum refresh)","MKT pending refresh");
   StringReplace(a,"without initial SL","no initial SL");
   StringReplace(a,"with initial SL","with SL");
   StringReplace(a,"adaptive SuperTrend/profit lock trail","adaptive trail");
   StringReplace(a,"post-TP1 midpoint reached: lock TP1","post-TP1 lock TP1");
   StringReplace(a,"post-TP1 30% giveback trail","post-TP1 giveback trail");
   if(StringLen(a)>68) a=StringSubstr(a,0,65)+"...";
   return a;
}

void PX_TM_SetAction(PX_TradeManagerState &tm,string action)
{
   tm.lastAction=action;
   tm.lastActionTime=TimeCurrent();
   Print("PREDICT-X TM: ",action);
}

void PX_TM_Init(PX_TradeManagerState &tm,bool enabled,double dailyLossPct)
{
   tm.enabled=enabled;
   tm.dailyHalted=false;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   tm.dayOfYear=dt.day_of_year;
   tm.dayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   tm.dailyLossPct=dailyLossPct;
   tm.dailyLossControlEnabled=false;
   tm.tp1Hit=false;
   tm.earlyStage=0;
   tm.entryTimeframe=(int)_Period;
   tm.postTP1MidLocked=false;
   tm.postTP1Best=0.0;
   tm.preTP1Best=0.0;
   tm.entry=0.0; tm.originalSL=0.0; tm.tp1=0.0; tm.tp2=0.0; tm.breakeven=0.0; tm.lastTrail=0.0;
   tm.positionTicket=0; tm.pendingTicket=0;
   tm.stateText="IDLE";
   tm.lastAction="Initialized";
   tm.lastActionTime=TimeCurrent();
   // Staircase protection state (additive). Defaults are safe no-ops; LoadPersistence
   // will overwrite them from saved values if a previous run armed them.
   tm.protectArmed=false;
   tm.triggerMoney=0.0;
   tm.currentBucket=0;
   tm.bucketPeak=0.0;
   tm.bucketEntry=0.0;
   tm.currentLock=0.0;
   tm.staircaseRisk=0.0;
   px_trade.SetExpertMagicNumber(PX_MAGIC);
   px_trade.SetDeviationInPoints(20);
   px_trade.SetTypeFillingBySymbol(_Symbol);
   PX_TM_LoadPersistence(tm);
}

void PX_TM_ResetDailyIfNeeded(PX_TradeManagerState &tm)
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(tm.dayOfYear!=dt.day_of_year)
   {
      tm.dayOfYear=dt.day_of_year;
      tm.dayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
      tm.dailyHalted=false;
      PX_TM_SetAction(tm,"New day: daily loss counter reset");
   }
}

double PX_TM_CurrentDailyLossPct(PX_TradeManagerState &tm)
{
   if(tm.dayStartBalance<=0.0) return 0.0;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double loss=tm.dayStartBalance-equity;
   if(loss<=0.0) return 0.0;
   return loss/tm.dayStartBalance*100.0;
}

bool PX_TM_DailyLimitHit(PX_TradeManagerState &tm,double dailyLossLimitPct)
{
   PX_TM_ResetDailyIfNeeded(tm);
   tm.dailyLossPct=PX_TM_CurrentDailyLossPct(tm);
   if(dailyLossLimitPct>0.0 && tm.dailyLossPct>=dailyLossLimitPct)
   {
      tm.dailyHalted=true;
      return true;
   }
   return tm.dailyHalted;
}

bool PX_TM_SelectPosition(ulong &ticket)
{
   ticket=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && (long)PositionGetInteger(POSITION_MAGIC)==PX_MAGIC)
      {
         ticket=t;
         return true;
      }
   }
   return false;
}

bool PX_TM_SelectPending(ulong &ticket)
{
   ticket=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)==_Symbol && (long)OrderGetInteger(ORDER_MAGIC)==PX_MAGIC)
      {
         ENUM_ORDER_TYPE typ=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(typ==ORDER_TYPE_BUY_LIMIT || typ==ORDER_TYPE_SELL_LIMIT || typ==ORDER_TYPE_BUY_STOP || typ==ORDER_TYPE_SELL_STOP)
         {
            ticket=t;
            return true;
         }
      }
   }
   return false;
}

bool PX_TM_HasAnyManagedTrade()
{
   ulong t;
   return PX_TM_SelectPosition(t) || PX_TM_SelectPending(t);
}

bool PX_TM_ClosePosition(PX_TradeManagerState &tm,string reason)
{
   ulong ticket;
   if(!PX_TM_SelectPosition(ticket)) return true;
   bool ok=px_trade.PositionClose(ticket);
   PX_TM_SetAction(tm,ok?"Closed position: "+reason:"Close failed: "+px_trade.ResultRetcodeDescription());
   if(ok)
   {
      tm.tp1Hit=false;
      tm.positionTicket=0;
      tm.stateText="CLOSED";
      if(!PX_TM_HasAnyManagedTrade()) PX_TM_ClearPersistence();
   }
   return ok;
}

bool PX_TM_CancelPending(PX_TradeManagerState &tm,string reason)
{
   ulong ticket;
   if(!PX_TM_SelectPending(ticket)) return true;
   bool ok=px_trade.OrderDelete(ticket);
   PX_TM_SetAction(tm,ok?"Cancelled pending: "+reason:"Cancel failed: "+px_trade.ResultRetcodeDescription());
   if(ok)
   {
      tm.pendingTicket=0;
      tm.stateText="IDLE";
      if(!PX_TM_HasAnyManagedTrade()) PX_TM_ClearPersistence();
   }
   return ok;
}

bool PX_TM_TradingAllowed(PX_TradeManagerState &tm,bool enableAutoTrading,bool applyDailyLossLimit,double dailyLossLimitPct)
{
   tm.enabled=enableAutoTrading;
   if(!enableAutoTrading) { tm.stateText="AUTO OFF"; return false; }
   if(applyDailyLossLimit && PX_TM_DailyLimitHit(tm,dailyLossLimitPct)) { tm.stateText="DAILY HALT"; return false; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      tm.stateText="TRADE DISABLED";
      return false;
   }
   return true;
}

double PX_TM_MinStopDistance()
{
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   int freeze=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   int pts=MathMax(stops,freeze);
   return pts*_Point;
}

bool PX_TM_GetTick(MqlTick &tick,string &reason)
{
   if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0.0 || tick.bid<=0.0 || tick.ask<=tick.bid)
   {
      reason="invalid live tick";
      return false;
   }
   return true;
}

bool PX_TM_CheckBrokerDistances(PX_Direction dir,bool isMarket,double entry,double sl,double tp,bool useInitialSL,string &reason)
{
   MqlTick tick;
   if(!PX_TM_GetTick(tick,reason)) return false;
   double minD=PX_TM_MinStopDistance();
   bool buy=(dir==PX_DIR_BUY);

   if(!isMarket)
   {
      if(buy && entry>tick.ask-minD) { reason="BUY LIMIT too close/above market"; return false; }
      if(!buy && entry<tick.bid+minD) { reason="SELL LIMIT too close/below market"; return false; }
   }

   // For market orders, SL/TP must be valid around the current live price.
   // For pending limit orders, SL/TP must be valid around the pending entry price.
   // This avoids falsely rejecting valid BUY LIMIT / SELL LIMIT setups whose TP is
   // on the correct side of the future entry but currently inside live price range.
   double ref=(isMarket ? (buy?tick.bid:tick.ask) : entry);
   if(useInitialSL && sl>0.0)
   {
      if(buy && sl>ref-minD) { reason="BUY SL violates broker stop distance"; return false; }
      if(!buy && sl<ref+minD) { reason="SELL SL violates broker stop distance"; return false; }
   }
   if(tp>0.0)
   {
      if(buy && tp<ref+minD) { reason="BUY TP violates broker stop distance"; return false; }
      if(!buy && tp>ref-minD) { reason="SELL TP violates broker stop distance"; return false; }
   }
   return true;
}

bool PX_TM_ValidateSetup(const PX_TradeSetup &ts,string &reason)
{
   if(!ts.valid) { reason="setup invalid"; return false; }
   if(ts.lot<=0.0) { reason="lot invalid"; return false; }
   if(ts.entry<=0.0 || ts.sl<=0.0 || ts.tp2<=0.0) { reason="price invalid"; return false; }
   if(ts.dir==PX_DIR_BUY)
   {
      if(!(ts.sl<ts.entry && ts.tp2>ts.entry)) { reason="BUY SL/TP geometry invalid"; return false; }
   }
   else if(ts.dir==PX_DIR_SELL)
   {
      if(!(ts.sl>ts.entry && ts.tp2<ts.entry)) { reason="SELL SL/TP geometry invalid"; return false; }
   }
   else { reason="no direction"; return false; }
   return true;
}

bool PX_TM_PlaceFromSetup(PX_TradeManagerState &tm,const PX_TradeSetup &ts,const PX_ScoreResult &sr,bool useInitialStopLoss)
{
   string reason;
   if(!PX_TM_ValidateSetup(ts,reason)) { PX_TM_SetAction(tm,"No order: "+reason); return false; }
   if(PX_TM_HasAnyManagedTrade()) return false;

   double lot=ts.lot;
   double entry=PX_NormPrice(ts.entry), plannedSL=PX_NormPrice(ts.sl), sl=(useInitialStopLoss?plannedSL:0.0), tp=PX_NormPrice(ts.tp2);
   bool ok=false;
   string comment=StringFormat("PREDICT-X %s %d",PX_DirectionText(ts.dir),sr.total);
   bool isMarket=(ts.method==PX_ENTRY_MARKET);

   // Broker safety: never send orders that violate stops/freeze distance.
   // If a planned LIMIT is too close to market, convert to market only when the
   // signal method already permits market-at-price-past-entry behavior.
   string distReason="";
   if(!PX_TM_CheckBrokerDistances(ts.dir,isMarket,entry,sl,tp,useInitialStopLoss,distReason))
   {
      if(!isMarket && (StringFind(distReason,"too close")>=0))
      {
         isMarket=true;
         PX_TM_SetAction(tm,"Limit too close; converting to market");
         if(!PX_TM_CheckBrokerDistances(ts.dir,true,entry,sl,tp,useInitialStopLoss,distReason))
         {
            PX_TM_SetAction(tm,"No order: "+distReason);
            return false;
         }
      }
      else
      {
         PX_TM_SetAction(tm,"No order: "+distReason);
         return false;
      }
   }

   if(isMarket)
   {
      if(ts.dir==PX_DIR_BUY) ok=px_trade.Buy(lot,_Symbol,0.0,sl,tp,comment);
      else if(ts.dir==PX_DIR_SELL) ok=px_trade.Sell(lot,_Symbol,0.0,sl,tp,comment);
   }
   else if(ts.method==PX_ENTRY_SUPERTREND_LIMIT || ts.method==PX_ENTRY_VALUE_LIMIT)
   {
      if(ts.dir==PX_DIR_BUY) ok=px_trade.BuyLimit(lot,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,comment);
      else if(ts.dir==PX_DIR_SELL) ok=px_trade.SellLimit(lot,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,comment);
   }

   if(ok)
   {
      tm.entry=entry; tm.originalSL=plannedSL; tm.tp1=PX_NormPrice(ts.tp1); tm.tp2=tp; tm.breakeven=PX_NormPrice(ts.breakeven);
      tm.tp1Hit=false; tm.earlyStage=0; tm.entryTimeframe=(int)_Period; tm.postTP1MidLocked=false; tm.postTP1Best=0.0; tm.preTP1Best=entry; tm.lastTrail=0.0;
      // Staircase protection: a fresh order means the staircase state must reset
      // (additive; no effect unless protection is enabled and staircase logic runs).
      tm.protectArmed=false; tm.triggerMoney=0.0; tm.currentBucket=0;
      tm.bucketPeak=0.0; tm.bucketEntry=0.0; tm.currentLock=0.0; tm.staircaseRisk=0.0;
      PX_TM_SelectPending(tm.pendingTicket);
      PX_TM_SelectPosition(tm.positionTicket);
      tm.stateText=(tm.positionTicket>0?"ACTIVE":"PENDING ORDER");
      PX_TM_SavePersistence(tm);
      PX_TM_SetAction(tm,"Order placed: "+ts.methodText+(useInitialStopLoss?" with initial SL":" without initial SL"));
   }
   else PX_TM_SetAction(tm,"Order placement failed: "+px_trade.ResultRetcodeDescription());
   return ok;
}

void PX_TM_SyncFromPosition(PX_TradeManagerState &tm)
{
   ulong ticket;
   if(PX_TM_SelectPosition(ticket))
   {
      tm.positionTicket=ticket;
      tm.stateText="ACTIVE";
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      if(tm.entry<=0.0) tm.entry=open;
      if(tm.originalSL<=0.0) tm.originalSL=sl;
      if(tm.tp2<=0.0) tm.tp2=tp;
      if(tm.entryTimeframe<=0) tm.entryTimeframe=(int)_Period;
      // Do NOT infer TP1 hit from SL position. Early-lock and breakeven can move
      // SL beyond entry before real TP1 is touched. TP1 is marked only by
      // PX_TM_CheckTP1() when live price actually reaches tm.tp1, or restored
      // from persisted tp1Hit after restart.
      // Safety repair: older builds could falsely persist tp1Hit=true when early
      // lock moved SL above/below entry. If the saved best post-TP1 price never
      // actually reached TP1, reset the flag so early-lock can continue correctly.
      if(tm.tp1Hit && tm.tp1>0.0)
      {
         long type=PositionGetInteger(POSITION_TYPE);
         bool invalidBuy=(type==POSITION_TYPE_BUY && (tm.postTP1Best<=0.0 || tm.postTP1Best+_Point<tm.tp1));
         bool invalidSell=(type==POSITION_TYPE_SELL && (tm.postTP1Best<=0.0 || tm.postTP1Best-_Point>tm.tp1));
         if(invalidBuy || invalidSell)
         {
            tm.tp1Hit=false;
            tm.postTP1MidLocked=false;
            PX_TM_SetAction(tm,"TP1 flag repaired: TP1 was not actually reached");
            PX_TM_SavePersistence(tm);
         }
      }
   }
   else tm.positionTicket=0;

   ulong ord;
   if(PX_TM_SelectPending(ord)) { tm.pendingTicket=ord; if(tm.positionTicket==0) tm.stateText="PENDING ORDER"; }
   else tm.pendingTicket=0;
}

bool PX_TM_MoveSL(PX_TradeManagerState &tm,double newSL,string reason)
{
   ulong ticket;
   if(!PX_TM_SelectPosition(ticket)) return false;
   double tp=PositionGetDouble(POSITION_TP);
   double curSL=PositionGetDouble(POSITION_SL);
   long type=PositionGetInteger(POSITION_TYPE);
   MqlTick tick; string tickReason="";
   if(!PX_TM_GetTick(tick,tickReason)) { PX_TM_SetAction(tm,"SL modify skipped: "+tickReason); return false; }
   double minD=PX_TM_MinStopDistance();
   newSL=PX_NormPrice(newSL);

   // Absolute safety rule: SL must never move backward after profit protection
   // has moved it in the trade's favor. This protects early-lock levels from
   // being lowered back to breakeven after TP1.
   if(curSL>0.0)
   {
      if(type==POSITION_TYPE_BUY && newSL<=curSL+_Point*0.1)
      {
         PX_TM_SetAction(tm,"SL move skipped: would move backward/unchanged");
         return true;
      }
      if(type==POSITION_TYPE_SELL && newSL>=curSL-_Point*0.1)
      {
         PX_TM_SetAction(tm,"SL move skipped: would move backward/unchanged");
         return true;
      }
   }

   if(type==POSITION_TYPE_BUY && newSL>tick.bid-minD) { PX_TM_SetAction(tm,"SL modify skipped: broker distance"); return false; }
   if(type==POSITION_TYPE_SELL && newSL<tick.ask+minD) { PX_TM_SetAction(tm,"SL modify skipped: broker distance"); return false; }
   bool ok=px_trade.PositionModify(ticket,newSL,tp);
   if(ok) { tm.lastTrail=newSL; PX_TM_SavePersistence(tm); PX_TM_SetAction(tm,"SL moved: "+reason); }
   else PX_TM_SetAction(tm,"SL modify failed: "+px_trade.ResultRetcodeDescription());
   return ok;
}

void PX_TM_CheckTP1(PX_TradeManagerState &tm)
{
   ulong ticket;
   if(tm.tp1Hit || !PX_TM_SelectPosition(ticket) || tm.tp1<=0.0) return;
   long type=PositionGetInteger(POSITION_TYPE);
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   bool hit=(type==POSITION_TYPE_BUY && tick.bid>=tm.tp1) || (type==POSITION_TYPE_SELL && tick.ask<=tm.tp1);
   if(!hit) return;

   double vol=PositionGetDouble(POSITION_VOLUME);
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0.0) step=0.01;
   double closeVol=MathFloor((vol*0.5)/step)*step;
   if(closeVol>=minLot && vol-closeVol>=minLot)
   {
      if(px_trade.PositionClosePartial(ticket,closeVol))
         PX_TM_SetAction(tm,"TP1 hit: closed 50%");
      else
         PX_TM_SetAction(tm,"TP1 partial close failed: "+px_trade.ResultRetcodeDescription());
   }
   else PX_TM_SetAction(tm,"TP1 hit: volume too small for partial close");

   tm.tp1Hit=true;
   MqlTick tpTick;
   if(SymbolInfoTick(_Symbol,tpTick))
      tm.postTP1Best=(type==POSITION_TYPE_BUY?tpTick.bid:tpTick.ask);
   else
      tm.postTP1Best=tm.tp1;
   tm.postTP1MidLocked=false;
   PX_TM_SavePersistence(tm);
   if(tm.breakeven>0.0) PX_TM_MoveSL(tm,tm.breakeven,"breakeven after TP1");
}

void PX_TM_ApplyEarlyProfitLock(PX_TradeManagerState &tm)
{
   ulong ticket;
   if(tm.tp1Hit || !PX_TM_SelectPosition(ticket)) return;
   if(tm.entry<=0.0 || tm.tp1<=0.0) return;

   long type=PositionGetInteger(POSITION_TYPE);
   bool buy=(type==POSITION_TYPE_BUY);
   double dist=MathAbs(tm.tp1-tm.entry);
   if(dist<=0.0) return;

   MqlTick tick;
   string tickReason="";
   if(!PX_TM_GetTick(tick,tickReason)) return;
   double price=(buy?tick.bid:tick.ask);

   // Critical fix: remember the best favorable price reached before TP1.
   // Early-lock stages are based on this best price, not just the current tick,
   // so fast moves through 2/3 or 3/3 cannot be missed after a pullback.
   if(tm.preTP1Best<=0.0) tm.preTP1Best=tm.entry;
   if(buy && price>tm.preTP1Best) tm.preTP1Best=price;
   if(!buy && price<tm.preTP1Best) tm.preTP1Best=price;

   double m1=(buy?tm.entry+dist/3.0:tm.entry-dist/3.0);
   double m2=(buy?tm.entry+2.0*dist/3.0:tm.entry-2.0*dist/3.0);
   double m3=(buy?tm.entry+0.90*dist:tm.entry-0.90*dist);

   bool hit1=(buy?tm.preTP1Best>=m1:tm.preTP1Best<=m1);
   bool hit2=(buy?tm.preTP1Best>=m2:tm.preTP1Best<=m2);
   bool hit3=(buy?tm.preTP1Best>=m3:tm.preTP1Best<=m3);

   // Stage 1: at 1/3 toward TP1, protect with breakeven + spread buffer.
   if(tm.earlyStage<1 && hit1)
   {
      double sl=(tm.breakeven>0.0?tm.breakeven:tm.entry);
      if(PX_TM_MoveSL(tm,sl,"early lock stage 1/3 to breakeven"))
      {
         tm.earlyStage=1;
         PX_TM_SavePersistence(tm);
      }
   }

   // Stage 2: if the best pre-TP1 price reached 2/3, lock the 1/3 milestone.
   if(tm.earlyStage<2 && hit2)
   {
      if(PX_TM_MoveSL(tm,m1,"early lock stage 2/3 locks 1/3 profit"))
      {
         tm.earlyStage=2;
         PX_TM_SavePersistence(tm);
      }
      else if((buy && price<=m1) || (!buy && price>=m1))
      {
         PX_TM_ClosePosition(tm,"early lock 1/3 virtual hit after pullback");
         return;
      }
   }

   // Stage 3: if the best pre-TP1 price reached near TP1, lock the 2/3 milestone.
   if(tm.earlyStage<3 && hit3)
   {
      if(PX_TM_MoveSL(tm,m2,"early lock stage 3/3 locks 2/3 profit"))
      {
         tm.earlyStage=3;
         PX_TM_SavePersistence(tm);
      }
      else if((buy && price<=m2) || (!buy && price>=m2))
      {
         PX_TM_ClosePosition(tm,"early lock 2/3 virtual hit after pullback");
         return;
      }
   }

   PX_TM_SavePersistence(tm);
}

void PX_TM_EnsurePostTP1BaseProtection(PX_TradeManagerState &tm)
{
   ulong ticket;
   if(!tm.tp1Hit || !PX_TM_SelectPosition(ticket)) return;
   if(tm.breakeven<=0.0) return;
   // If TP1 has been hit but broker distance prevented the first SL move,
   // keep retrying on every tick/new bar until at least breakeven/spread buffer
   // is installed. PX_TM_MoveSL itself prevents backward movement.
   PX_TM_MoveSL(tm,tm.breakeven,"post-TP1 base protection retry");
}

void PX_TM_ApplyPostTP1GivebackTrail(PX_TradeManagerState &tm)
{
   ulong ticket;
   if(!tm.tp1Hit || !PX_TM_SelectPosition(ticket)) return;
   PX_TM_EnsurePostTP1BaseProtection(tm);
   if(tm.tp1<=0.0 || tm.tp2<=0.0) return;

   long type=PositionGetInteger(POSITION_TYPE);
   bool buy=(type==POSITION_TYPE_BUY);
   double tpRange=MathAbs(tm.tp2-tm.tp1);
   if(tpRange<=0.0) return;

   MqlTick tick;
   string tickReason="";
   if(!PX_TM_GetTick(tick,tickReason)) return;
   double price=(buy?tick.bid:tick.ask);

   if(tm.postTP1Best<=0.0) tm.postTP1Best=price;
   if(buy && price>tm.postTP1Best) tm.postTP1Best=price;
   if(!buy && price<tm.postTP1Best) tm.postTP1Best=price;

   double mid=(buy?tm.tp1+0.50*tpRange:tm.tp1-0.50*tpRange);
   bool midpointHit=(buy?tm.postTP1Best>=mid:tm.postTP1Best<=mid);

   // Once price travels halfway from TP1 toward TP2, lock the remaining
   // position at TP1. This makes TP1 the floor/ceiling for the runner.
   if(!tm.postTP1MidLocked && midpointHit)
   {
      if(PX_TM_MoveSL(tm,tm.tp1,"post-TP1 midpoint reached: lock TP1"))
      {
         tm.postTP1MidLocked=true;
         PX_TM_SavePersistence(tm);
      }
   }

   // After the midpoint lock, trail by allowing only 30% giveback from the
   // best post-TP1 price. This preserves roughly 70% of the move from TP1.
   if(tm.postTP1MidLocked)
   {
      double trail=(buy ? tm.postTP1Best-0.30*MathAbs(tm.postTP1Best-tm.tp1)
                        : tm.postTP1Best+0.30*MathAbs(tm.tp1-tm.postTP1Best));
      PX_TM_MoveSL(tm,trail,"post-TP1 30% giveback trail");
   }
   else PX_TM_SavePersistence(tm);
}

//+------------------------------------------------------------------+
//| STAIRCASE PROTECTION (additive layer)                             |
//|                                                                  |
//| Runs ONLY when:                                                   |
//|   * a managed position exists,                                    |
//|   * enableTradeProtection is true (caller's responsibility),     |
//|   * tm.protectArmed is true (armed by reaching 1% of live risk).  |
//|                                                                  |
//| Until protectArmed is true, this function is a no-op. The trade   |
//| is left untouched with the broker-side initial SL as its downside |
//| (per the user's intent: never close at a loss before protection   |
//| has armed).                                                       |
//|                                                                  |
//| Once armed, every tick it:                                        |
//|   1. Determines the current bucket (0..4) by checking which      |
//|      1/3, 2/3, 90% of entry->TP1 has been reached, OR post-TP1.  |
//|   2. If a new bucket is entered, locks SL to that level (uses     |
//|      existing PX_TM_MoveSL which enforces the never-move-        |
//|      backward rule) and resets bucketPeak to current price.       |
//|   3. Updates bucketPeak.                                          |
//|   4. Closes the trade if price touches the current bucket lock    |
//|      OR if price gives back `givebackPct` from the bucket peak.   |
//|                                                                  |
//| Hard safety: only PX_TM_ClosePosition is used to actually close,  |
//| and we pre-check that the position's floating P/L is positive so  |
//| this layer can never close a losing trade.                        |
//+------------------------------------------------------------------+
void PX_TM_ApplyStaircaseProtection(PX_TradeManagerState &tm,double triggerPctOfRisk,double givebackPct)
{
   // Hard guards: any one of these makes the function a complete no-op.
   if(triggerPctOfRisk<=0.0 || givebackPct<=0.0) return;
   if(!tm.protectArmed) return;

   ulong ticket;
   if(!PX_TM_SelectPosition(ticket)) return;
   long type=PositionGetInteger(POSITION_TYPE);
   bool buy=(type==POSITION_TYPE_BUY);
   double curSL=PositionGetDouble(POSITION_SL);
   double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);

   MqlTick tick;
   string tickReason="";
   if(!PX_TM_GetTick(tick,tickReason)) return;
   double price=(buy?tick.bid:tick.ask);
   if(price<=0.0) return;

   // Bucket distance is the same 1/3, 2/3, 90% split used by the existing
   // early-lock logic. tm.tp1 is always set when protectArmed is true (an
   // order was placed and either protection was already armed or the
   // staircase has just been armed by the trigger below).
   if(tm.entry<=0.0 || tm.tp1<=0.0) return;
   double dist=MathAbs(tm.tp1-tm.entry);
   if(dist<=0.0) return;

   double m1=(buy?tm.entry+dist/3.0:tm.entry-dist/3.0);
   double m2=(buy?tm.entry+2.0*dist/3.0:tm.entry-2.0*dist/3.0);
   double m3=(buy?tm.entry+0.90*dist:tm.entry-0.90*dist);

   // Determine which bucket the live price is currently in. Post-TP1 uses a
   // separate bucket (4) with TP1 as its lock and the rest handled by the
   // existing PX_TM_ApplyPostTP1GivebackTrail logic (we only manage the
   // pre-TP1 buckets 0..3 here to avoid colliding with that function).
   int bucket=0;
   double bucketLock=0.0;
   if(tm.tp1Hit)
   {
      bucket=4; // post-TP1: handled by existing function, we only update state
   }
   else if(buy)
   {
      if(price>=m3)      { bucket=3; bucketLock=m3; }
      else if(price>=m2) { bucket=2; bucketLock=m2; }
      else if(price>=m1) { bucket=1; bucketLock=m1; }
      else               { bucket=0; bucketLock=tm.entry; }
   }
   else
   {
      if(price<=m3)      { bucket=3; bucketLock=m3; }
      else if(price<=m2) { bucket=2; bucketLock=m2; }
      else if(price<=m1) { bucket=1; bucketLock=m1; }
      else               { bucket=0; bucketLock=tm.entry; }
   }

   // Bucket transition: when price reaches a higher bucket, lock SL up to
   // the new bucket's lock level (PX_TM_MoveSL enforces the never-backward
   // rule) and reset the bucket peak/entry for fresh giveback tracking.
   // Bucket 0 has no lock by design: the user wants the only close in
   // "between entry and lock1" to be the 30% giveback, not a "touched entry"
   // close. So we keep currentLock=0 in bucket 0 on every transition.
   if(bucket!=tm.currentBucket)
   {
      tm.currentBucket=bucket;
      tm.currentLock=(bucket>0 && bucket<4 ? bucketLock : 0.0);
      // When entering a higher bucket, also try to push the broker SL to the
      // new lock so the trade is always protected by the existing SL logic
      // as well. PX_TM_MoveSL will no-op if the move would be backward.
      if(bucket>0 && bucket<4)
         PX_TM_MoveSL(tm,bucketLock,"staircase bucket transition");
      // Reset peak tracking for the new bucket. Use the live price as the
      // new bucket entry; bucketPeak follows it upward.
      tm.bucketEntry=price;
      tm.bucketPeak=price;
      PX_TM_SavePersistence(tm);
   }
   else if(tm.bucketPeak<=0.0)
   {
      // First tick in this bucket: initialize peak.
      tm.bucketEntry=price;
      tm.bucketPeak=price;
   }
   else
   {
      // Update bucket peak with the live price.
      if(buy && price>tm.bucketPeak) tm.bucketPeak=price;
      if(!buy && price<tm.bucketPeak) tm.bucketPeak=price;
   }

   // Post-TP1 bucket is managed by PX_TM_ApplyPostTP1GivebackTrail; do not
   // duplicate the close logic here. The bucket=4 transition above already
   // happened; we just return.
   if(bucket==4) return;

   // Pre-TP1 buckets: two exit conditions.
   // Exit A: price touches the current bucket's lock.
   // Exit B: price gives back `givebackPct` of the bucket's favorable move
   //         from peak.
   bool touchedLock=false;
   bool gaveBack=false;
   double givebackDist=0.0;
   if(tm.bucketPeak>0.0 && tm.bucketEntry>0.0)
      givebackDist=MathAbs(tm.bucketPeak-tm.bucketEntry)*givebackPct/100.0;

   if(buy)
   {
      if(tm.currentLock>0.0 && price<=tm.currentLock) touchedLock=true;
      if(tm.bucketPeak>0.0 && givebackDist>0.0 && price<=tm.bucketPeak-givebackDist) gaveBack=true;
   }
   else
   {
      if(tm.currentLock>0.0 && price>=tm.currentLock) touchedLock=true;
      if(tm.bucketPeak>0.0 && givebackDist>0.0 && price>=tm.bucketPeak+givebackDist) gaveBack=true;
   }

   if(touchedLock || gaveBack)
   {
      // Hard safety: never close a losing trade from this layer. If floating
      // P/L is not positive, the existing SL / early-lock will handle the
      // exit; we just skip.
      double floating=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(floating<=0.0) return;

      string reason=StringFormat("staircase %s (bucket %d)",(touchedLock?"lock hit":"giveback"),bucket);
      PX_TM_ClosePosition(tm,reason);
   }
}

//+------------------------------------------------------------------+
//| STAIRCASE ARMING                                                  |
//|                                                                  |
//| Called by the engine (caller decides the cadence: every tick,     |
//| every new bar, etc). If the position is not yet armed and the     |
//| floating P/L has reached `triggerPctOfRisk` of the live risk,     |
//| this function arms the staircase and sets up bucket 0 with the    |
//| entry price as the floor.                                         |
//|                                                                  |
//| Live risk = (entry - current broker SL) * value per unit * volume |
//| if the broker has an SL on the position. Otherwise falls back to  |
//| ts.riskMoney (the planned $ risk at setup time).                  |
//|                                                                  |
//| Safe to call every tick: it is a no-op once protectArmed is true. |
//+------------------------------------------------------------------+
void PX_TM_ArmStaircaseIfReady(PX_TradeManagerState &tm,double triggerPctOfRisk,double plannedRiskMoney)
{
   if(tm.protectArmed) return;
   if(triggerPctOfRisk<=0.0) return;

   ulong ticket;
   if(!PX_TM_SelectPosition(ticket)) return;
   long type=PositionGetInteger(POSITION_TYPE);
   bool buy=(type==POSITION_TYPE_BUY);
   double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL=PositionGetDouble(POSITION_SL);

   // Live risk in account money.
   double liveRisk=plannedRiskMoney;
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double volume=PositionGetDouble(POSITION_VOLUME);
   if(curSL>0.0 && openPrice>0.0 && tickSize>0.0 && tickValue>0.0 && volume>0.0)
   {
      double slDist=MathAbs(openPrice-curSL);
      if(slDist>0.0) liveRisk=(slDist/tickSize)*tickValue*volume;
   }
   if(liveRisk<=0.0) return;

   double triggerMoney=liveRisk*triggerPctOfRisk/100.0;
   double floating=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);

   // Floating must exceed the trigger AND be positive (so we never arm into
   // a loss even if the math is favourable). Strict >= so the very first
   // profitable tick that crosses the threshold arms it.
   if(floating<=0.0) return;
   if(floating<triggerMoney) return;

   MqlTick tick;
   string tickReason="";
   if(!PX_TM_GetTick(tick,tickReason)) return;
   double price=(buy?tick.bid:tick.ask);
   if(price<=0.0) return;

   tm.protectArmed=true;
   tm.triggerMoney=triggerMoney;
   tm.staircaseRisk=liveRisk;
   tm.currentBucket=0;
   tm.bucketEntry=tm.entry;          // bucket 0 floor = entry price
   tm.bucketPeak=price;
   tm.currentLock=0.0;               // bucket 0 has no upper lock yet
   PX_TM_SavePersistence(tm);
   PX_TM_SetAction(tm,StringFormat("Staircase armed: floating $%.2f >= trigger $%.2f (%.2f%% of risk $%.2f)",
      floating,triggerMoney,triggerPctOfRisk,liveRisk));
}

double PX_TM_ATRBufferByRegime(const PX_RegimeState &reg,double atr)
{
   double mult=0.10;
   if(reg.regime==PX_REGIME_STRONG_TREND) mult=0.15;
   else if(reg.regime==PX_REGIME_VOLATILE_TREND) mult=0.25;
   else if(reg.regime==PX_REGIME_CHOPPY) mult=0.05;
   return mult*atr;
}

void PX_TM_ApplyAdaptiveTrail(PX_TradeManagerState &tm,const PX_RegimeState &reg,const PX_TrendContext &trend,const PX_ScoreResult &sr,double atr)
{
   ulong ticket;
   if(!tm.tp1Hit || !PX_TM_SelectPosition(ticket) || atr<=0.0) return;
   long type=PositionGetInteger(POSITION_TYPE);
   double curSL=PositionGetDouble(POSITION_SL);
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   double risk=MathAbs(entry-tm.originalSL);
   if(risk<=0.0) risk=MathAbs(entry-curSL);
   if(risk<=0.0) return;

   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   double price=(type==POSITION_TYPE_BUY?tick.bid:tick.ask);
   double profitDist=(type==POSITION_TYPE_BUY?price-entry:entry-price);
   double buffer=PX_TM_ATRBufferByRegime(reg,atr);
   double stTrail=(type==POSITION_TYPE_BUY?trend.stLine-buffer:trend.stLine+buffer);
   double profitLock=tm.breakeven;

   if(profitDist>=2.0*risk) profitLock=(type==POSITION_TYPE_BUY?entry+1.0*risk:entry-1.0*risk);
   else if(profitDist>=1.5*risk) profitLock=(type==POSITION_TYPE_BUY?entry+0.5*risk:entry-0.5*risk);

   double newSL=curSL;
   if(type==POSITION_TYPE_BUY)
   {
      newSL=MathMax(newSL,tm.breakeven);
      if(stTrail<price) newSL=MathMax(newSL,stTrail);
      if(profitLock<price) newSL=MathMax(newSL,profitLock);
      if(newSL>curSL+_Point) PX_TM_MoveSL(tm,newSL,"adaptive SuperTrend/profit lock trail");
   }
   else
   {
      if(newSL<=0.0) newSL=curSL;
      newSL=MathMin(newSL,tm.breakeven);
      if(stTrail>price) newSL=MathMin(newSL,stTrail);
      if(profitLock>price) newSL=MathMin(newSL,profitLock);
      if(newSL<curSL-_Point) PX_TM_MoveSL(tm,newSL,"adaptive SuperTrend/profit lock trail");
   }
}

double PX_TM_ProfitProtectionBufferMoney()
{
   ulong ticket;
   if(!PX_TM_SelectPosition(ticket)) return 0.0;
   MqlTick tick;
   string reason="";
   if(!PX_TM_GetTick(tick,reason)) return 0.0;
   double spread=MathMax(0.0,tick.ask-tick.bid);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double volume=PositionGetDouble(POSITION_VOLUME);
   if(tickSize<=0.0 || tickValue<=0.0 || volume<=0.0) return 0.0;
   // Symbol-adaptive buffer: current spread cost for the remaining volume.
   // This prevents signal-based exits from closing at tiny/false profit after costs.
   return (spread/tickSize)*tickValue*volume;
}

bool PX_TM_ProfitBufferReached()
{
   ulong ticket;
   if(!PX_TM_SelectPosition(ticket)) return false;
   double floating=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   double buffer=PX_TM_ProfitProtectionBufferMoney();
   return (floating>buffer);
}

bool PX_TM_CloseIfProfitProtected(PX_TradeManagerState &tm,string reason)
{
   // Do not allow a different chart timeframe to signal-close a trade opened
   // from another timeframe. TP/SL/early-lock/trailing can still manage it.
   if(tm.entryTimeframe>0 && tm.entryTimeframe!=(int)_Period)
   {
      PX_TM_SetAction(tm,"Hold active trade: timeframe changed from "+IntegerToString(tm.entryTimeframe)+" to "+IntegerToString((int)_Period));
      return false;
   }
   if(PX_TM_ProfitBufferReached())
      return PX_TM_ClosePosition(tm,reason+" with profit buffer");
   PX_TM_SetAction(tm,"Hold active trade: "+reason+" but profit buffer not reached");
   return false;
}

void PX_TM_TradeHealthCheck(PX_TradeManagerState &tm,const PX_ScoreResult &sr,const PX_TrendContext &trend,const PX_RegimeState &reg,bool activePredictionMonitor)
{
   if(!activePredictionMonitor) return;

   ulong ticket;
   if(!PX_TM_SelectPosition(ticket)) return;
   long type=PositionGetInteger(POSITION_TYPE);
   bool isBuy=(type==POSITION_TYPE_BUY);
   bool stFlip=(isBuy && trend.stDir<0) || (!isBuy && trend.stDir>0);
   bool oppositeSignal=(sr.tier>=PX_TIER_MEDIUM && ((isBuy && sr.dir==PX_DIR_SELL) || (!isBuy && sr.dir==PX_DIR_BUY)));
   bool noTradeOrHeavyWeakness=(sr.dir==PX_DIR_NONE || sr.total<40 || sr.tier==PX_TIER_NO_TRADE);
   bool moderateWeakness=(sr.total>=40 && sr.total<55);

   // Active prediction monitor:
   // - small/moderate weakness = tighten only
   // - no trade/heavy weakness/opposite/reversal = close only if profit > broker buffer
   // - never force-close negative trades from prediction changes
   if(reg.blockSignals || reg.regime==PX_REGIME_DANGEROUS) { PX_TM_CloseIfProfitProtected(tm,"dangerous regime"); return; }
   if(oppositeSignal) { PX_TM_CloseIfProfitProtected(tm,"opposite signal"); return; }
   if(stFlip) { PX_TM_CloseIfProfitProtected(tm,"SuperTrend flip"); return; }
   if(noTradeOrHeavyWeakness) { PX_TM_CloseIfProfitProtected(tm,"no trade / heavy score weakness"); return; }
   if(moderateWeakness && tm.breakeven>0.0) PX_TM_MoveSL(tm,tm.breakeven,"moderate weakness: tighten to breakeven");
}

bool PX_TM_UpdatePendingOrder(PX_TradeManagerState &tm,const PX_TradeSetup &ts,bool useInitialStopLoss)
{
   ulong ticket;
   if(!PX_TM_SelectPending(ticket) || !ts.valid) return false;
   double oldPrice=OrderGetDouble(ORDER_PRICE_OPEN);
   double oldSL=OrderGetDouble(ORDER_SL);
   double oldTP=OrderGetDouble(ORDER_TP);
   double newPrice=PX_NormPrice(ts.entry), plannedSL=PX_NormPrice(ts.sl), newSL=(useInitialStopLoss?plannedSL:0.0), newTP=PX_NormPrice(ts.tp2);
   bool changed=(MathAbs(oldPrice-newPrice)>_Point || MathAbs(oldSL-newSL)>_Point || MathAbs(oldTP-newTP)>_Point);
   if(!changed) return true;
   string reason="";
   if(!PX_TM_CheckBrokerDistances(ts.dir,false,newPrice,newSL,newTP,useInitialStopLoss,reason))
   {
      PX_TM_SetAction(tm,"Pending update invalid: "+reason);
      return false;
   }
   if(px_trade.OrderModify(ticket,newPrice,newSL,newTP,ORDER_TIME_GTC,0,0.0))
   {
      tm.entry=newPrice; tm.originalSL=plannedSL; tm.tp1=PX_NormPrice(ts.tp1); tm.tp2=newTP; tm.breakeven=PX_NormPrice(ts.breakeven);
      tm.earlyStage=0; tm.entryTimeframe=(int)_Period; tm.postTP1MidLocked=false; tm.postTP1Best=0.0; tm.preTP1Best=newPrice;
      // Staircase protection: a refreshed pending order also means the staircase
      // bucket state must reset (additive; no effect unless protection is on).
      tm.protectArmed=false; tm.triggerMoney=0.0; tm.currentBucket=0;
      tm.bucketPeak=0.0; tm.bucketEntry=0.0; tm.currentLock=0.0; tm.staircaseRisk=0.0;
      PX_TM_SavePersistence(tm);
      PX_TM_SetAction(tm,"Pending order updated from latest score/setup");
      return true;
   }
   else
   {
      PX_TM_SetAction(tm,"Pending update failed: "+px_trade.ResultRetcodeDescription());
      return false;
   }
}

bool PX_TM_ShouldCancelPending(const PX_Lifecycle &lc,const PX_ScoreResult &sr,const PX_RegimeState &reg,const PX_ValueContext &vc,string &reason)
{
   if(reg.blockSignals || reg.regime==PX_REGIME_DANGEROUS) { reason="dangerous regime"; return true; }
   if(vc.spreadBlocked) { reason="spread blocked"; return true; }
   if(!vc.sessionActive) { reason="session ended/not allowed"; return true; }
   if(sr.total<40) { reason="score below 40"; return true; }
   if(lc.state!=PX_STATE_PENDING) { reason="signal no longer pending/expired"; return true; }
   if(sr.dir!=lc.pendingDir) { reason="direction changed"; return true; }
   return false;
}

// Instant (between-bar) protection, unlinked from AUTO TRADE: these are
// protective actions on EXISTING orders only - cancelling a tracked pending
// order on an instant SuperTrend flip, and profit-protecting the open position.
// Nothing here ever opens a new trade.
void PX_TM_OnInstantTick(PX_TradeManagerState &tm,bool activePredictionMonitor,int currentSTDir)
{
   PX_TM_SyncFromPosition(tm);
   ulong order;
   if(PX_TM_SelectPending(order))
   {
      ENUM_ORDER_TYPE typ=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool pendingBuy=(typ==ORDER_TYPE_BUY_LIMIT || typ==ORDER_TYPE_BUY_STOP);
      if((pendingBuy && currentSTDir<0) || (!pendingBuy && currentSTDir>0))
         PX_TM_CancelPending(tm,"instant SuperTrend flip");
   }
   ulong pos;
   if(activePredictionMonitor && PX_TM_SelectPosition(pos))
   {
      long type=PositionGetInteger(POSITION_TYPE);
      if((type==POSITION_TYPE_BUY && currentSTDir<0) || (type==POSITION_TYPE_SELL && currentSTDir>0))
         PX_TM_CloseIfProfitProtected(tm,"instant SuperTrend flip");
   }
}

void PX_TM_OnNewBar(PX_TradeManagerState &tm,bool enableAutoTrading,bool useInitialStopLoss,bool enableTradeProtection,bool applyDailyLossLimit,double dailyLossLimitPct,bool activePredictionMonitor,PX_Lifecycle &lc,const PX_ScoreResult &sr,const PX_TradeSetup &ts,const PX_RegimeState &reg,const PX_ValueContext &vc,const PX_TrendContext &trend)
{
   PX_TM_SyncFromPosition(tm);
   tm.enabled=enableAutoTrading;
   // Protection OFF means no EA-side protective exits/guards; the trade is left
   // to the broker-side TP/SL settings exactly as configured by the inputs.
   tm.dailyLossControlEnabled=(applyDailyLossLimit && enableTradeProtection);
   if(!tm.dailyLossControlEnabled) tm.dailyHalted=false;
   // The daily loss limit is a PROTECTION: it still guards existing orders when
   // AUTO TRADE is OFF (unlinked from the master switch).
   if(tm.dailyLossControlEnabled && PX_TM_DailyLimitHit(tm,dailyLossLimitPct))
   {
      PX_TM_CancelPending(tm,"daily loss limit");
      PX_TM_ClosePosition(tm,"daily loss limit");
      tm.stateText="DAILY HALT";
      return;
   }

   // AUTO TRADE governs NEW orders and the active pending-order refresh only.
   // Position protection below runs on its own switch (enableTradeProtection),
   // so a user who disabled auto trading keeps protection on live orders.
   bool autoAllowed=PX_TM_TradingAllowed(tm,enableAutoTrading,tm.dailyLossControlEnabled,dailyLossLimitPct);
   // Without terminal trade permission nothing can execute at all - the old
   // flow also stopped here, so behavior for AUTO ON is unchanged.
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

   string reason="";
   if(PX_TM_SelectPending(tm.pendingTicket))
   {
      // Protective cancel runs even with AUTO OFF: a dead, flipped or dangerous
      // signal must not fill an order the EA is still tracking.
      if(PX_TM_ShouldCancelPending(lc,sr,reg,vc,reason))
      {
         PX_TM_CancelPending(tm,reason);
         return;
      }
      // AUTO OFF: leave the pending order exactly as placed - no refresh, no
      // market conversion, no replacement.
      if(!autoAllowed) return;
      if(ts.valid && ts.method==PX_ENTRY_MARKET)
      {
         PX_TM_CancelPending(tm,"setup changed to market entry");
         PX_TM_PlaceFromSetup(tm,ts,sr,useInitialStopLoss);
         PX_TM_SyncFromPosition(tm);
         if(tm.positionTicket>0) lc.state=PX_STATE_ACTIVE;
         return;
      }
      if(!PX_TM_UpdatePendingOrder(tm,ts,useInitialStopLoss))
      {
         PX_TM_CancelPending(tm,"pending setup refresh invalid/failed");
         if(ts.valid && !PX_TM_HasAnyManagedTrade())
         {
            PX_TM_PlaceFromSetup(tm,ts,sr,useInitialStopLoss);
            PX_TM_SyncFromPosition(tm);
            if(tm.positionTicket>0) lc.state=PX_STATE_ACTIVE;
         }
         return;
      }
   }

   if(PX_TM_SelectPosition(tm.positionTicket))
   {
      lc.state=PX_STATE_ACTIVE;
      if(enableTradeProtection)
      {
         PX_TM_ApplyEarlyProfitLock(tm);
         PX_TM_CheckTP1(tm);
         PX_TM_ApplyPostTP1GivebackTrail(tm);
         PX_TM_TradeHealthCheck(tm,sr,trend,reg,activePredictionMonitor);
         PX_TM_ApplyAdaptiveTrail(tm,reg,trend,sr,vc.atr);
      }
      return;
   }

   // If broker-side TP2/SL closed the position, return lifecycle to scanning.
   if(lc.state==PX_STATE_ACTIVE && !PX_TM_HasAnyManagedTrade())
   {
      PX_TM_ClearPersistence();
      PX_LifecycleInit(lc);
   }

   // --- Everything below places or refreshes orders: AUTO TRADE switch only. ---
   if(!autoAllowed) return;
   if(reg.blockSignals || vc.spreadBlocked || !vc.sessionActive) return;
   if(lc.state==PX_STATE_PENDING && sr.tier>=PX_TIER_MEDIUM && ts.valid && !PX_TM_HasAnyManagedTrade())
   {
      if(PX_TM_PlaceFromSetup(tm,ts,sr,useInitialStopLoss))
      {
         PX_TM_SyncFromPosition(tm);
         if(tm.positionTicket>0) lc.state=PX_STATE_ACTIVE;
      }
   }
}

void PX_TM_DrawTradeLines(PX_TradeManagerState &tm)
{
   PX_TM_SyncFromPosition(tm);
   if(tm.positionTicket==0 && tm.pendingTicket==0)
   {
      ObjectDelete(0,PX2_PREFIX+"ENTRY_LINE"); ObjectDelete(0,PX2_PREFIX+"SL_LINE");
      ObjectDelete(0,PX2_PREFIX+"TP1_LINE"); ObjectDelete(0,PX2_PREFIX+"TP2_LINE");
      ObjectDelete(0,PX2_PREFIX+"BE_LINE"); ObjectDelete(0,PX2_PREFIX+"TRAIL_LINE");
      return;
   }
   PX2_HLine("ENTRY_LINE",tm.entry,clrWhite,STYLE_DASH);
   PX2_HLine("SL_LINE",tm.originalSL,clrRed,STYLE_DASH);
   PX2_HLine("TP1_LINE",tm.tp1,clrLime,STYLE_DASH);
   PX2_HLine("TP2_LINE",tm.tp2,clrLime,STYLE_SOLID,2);
   if(tm.tp1Hit) PX2_HLine("BE_LINE",tm.breakeven,clrYellow,STYLE_DASH);
   if(tm.lastTrail>0.0) PX2_HLine("TRAIL_LINE",tm.lastTrail,clrYellow,STYLE_SOLID,2);
}

void PX_TM_RenderOrderPanel(PX_TradeManagerState &tm,bool showPanel,const PX_TradeSetup &ts,const PX_ScoreResult &sr,const PX_Lifecycle &lc,const bool enableTradeProtection=true)
{
   PX_TM_SyncFromPosition(tm);
   PX_TM_DrawTradeLines(tm);
   PX_TM_DeletePanelObjectsOnly();

   bool hasManaged=(tm.positionTicket>0 || tm.pendingTicket>0);
   bool hasSetup=(ts.valid && sr.tier>=PX_TIER_MEDIUM && sr.dir!=PX_DIR_NONE && lc.state==PX_STATE_PENDING);
   if(!showPanel || (!hasManaged && !hasSetup)) return;

   // Stay glued to the dynamic left panel (width/height can grow with Aladin text).
   int x=PX_RightPanelX(),y=PX_RIGHT_PNL_Y,w=PX_RIGHT_PNL_W,h=g_pxMainPanelH;
   if(ObjectFind(0,PX_MAIN_PANEL_BG_NAME)>=0)
   {
      long leftPanelH=ObjectGetInteger(0,PX_MAIN_PANEL_BG_NAME,OBJPROP_YSIZE);
      long leftPanelW=ObjectGetInteger(0,PX_MAIN_PANEL_BG_NAME,OBJPROP_XSIZE);
      if(leftPanelH>0) h=(int)leftPanelH;
      if(leftPanelW>0) x=PX_PNL_X+(int)leftPanelW+PX_PNL_GAP;
   }
   PX2_Rect("ORDER_BG",x,y,w,h,(color)0x101010,clrDimGray);
   y+=12;
   PX2_Label("ORDER_TITLE",x+14,y,"PREDICT-X SETUP / ORDER MANAGER",(color)0xFFD8A8,12,"Segoe UI"); y+=24;

   int digs=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   // AUTO TRADE and PROTECTION are independent switches: auto off stops NEW
   // orders only; protection keeps managing the EA's existing orders.
   string protectionLine="1. AUTO TRADE "+(tm.enabled?"ON":"OFF")+"  |  PROTECTION: "+(enableTradeProtection?"ON":"OFF");
   color protectionClr=(enableTradeProtection?(color)0x90EE90:(color)0xFFD8A8);
   PX2_Label("ORDER_STATE",x+14,y,protectionLine,protectionClr,11); y+=21;

   // Signal/type is intentionally not repeated here. The left panel is the
   // single source of truth for current direction; this panel only shows the
   // setup/order/trade data tied to that signal.
   if(tm.pendingTicket>0)
   {
      PX2_Label("ORDER_TICKET",x+14,y,"ORDER: Pending #"+IntegerToString((long)tm.pendingTicket),(color)0x80D7FF,11); y+=20;
   }
   if(tm.positionTicket>0)
   {
      long type=PositionGetInteger(POSITION_TYPE);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double profit=PositionGetDouble(POSITION_PROFIT);
      PX2_Label("ORDER_POS",x+14,y,StringFormat("POSITION: %s %.2f lots #%.0f",(type==POSITION_TYPE_BUY?"BUY":"SELL"),vol,(double)tm.positionTicket),(color)0x90EE90,11); y+=20;
      PX2_Label("ORDER_PROFIT",x+14,y,StringFormat("CURRENT P/L: $%.2f",profit),(profit>=0?(color)0x90EE90:(color)0x8080FF),11); y+=20;
   }

   double entry=(hasManaged?tm.entry:ts.entry);
   double sl=(hasManaged?tm.originalSL:ts.sl);
   double tp1=(hasManaged?tm.tp1:ts.tp1);
   double tp2=(hasManaged?tm.tp2:ts.tp2);
   double be=(hasManaged?tm.breakeven:ts.breakeven);
   double lot=(hasManaged && tm.positionTicket>0?PositionGetDouble(POSITION_VOLUME):ts.lot);

   PX2_Label("SEC_SETUP",x+14,y,"2. ENTRY SETUP",(color)0xE8E8E8,11,"Segoe UI"); y+=19;
   PX2_Label("ORDER_ENTRY",x+34,y,StringFormat("ENTRY: %.*f",digs,entry),(color)0xD0D0D0,11); y+=18;
   PX2_Label("ORDER_SL",x+34,y,StringFormat("SL:    %.*f",digs,sl),(color)0xD0D0D0,11); y+=18;
   PX2_Label("ORDER_TP1",x+34,y,StringFormat("TP1:   %.*f %s",digs,tp1,(hasManaged?(tm.tp1Hit?"HIT":"WAIT"):"PLAN")),(hasManaged&&tm.tp1Hit?(color)0x90EE90:(color)0xD0D0D0),11); y+=18;
   PX2_Label("ORDER_TP2",x+34,y,StringFormat("TP2:   %.*f",digs,tp2),(color)0xD0D0D0,11); y+=18;
   PX2_Label("ORDER_BE",x+34,y,StringFormat("BREAKEVEN: %.*f",digs,be),(color)0xD0D0D0,11); y+=20;

   PX2_Label("SEC_RISK",x+14,y,"3. RISK / REWARD",(color)0xE8E8E8,11,"Segoe UI"); y+=19;
   PX2_Label("ORDER_LOT",x+34,y,StringFormat("LOT: %.2f",lot),(color)0xD0D0D0,11); y+=18;
   PX2_Label("ORDER_RISK",x+34,y,StringFormat("RISK: $%.2f | REWARD: $%.2f",ts.riskMoney,ts.rewardMoney),(color)0xD0D0D0,11); y+=18;
   PX2_Label("ORDER_RR",x+34,y,StringFormat("R:R %.2f | METHOD: %s",ts.rr,PX_TM_ShortMethod(ts.methodText)),(color)0xD0D0D0,11); y+=20;

   PX2_Label("SEC_STATUS",x+14,y,"4. POSITION STATUS",(color)0xE8E8E8,11,"Segoe UI"); y+=19;
   if(hasManaged)
      PX2_Label("ORDER_STATUS",x+34,y,StringFormat("TP1: %s | TP2: %s",(tm.tp1Hit?"HIT":"WAIT"),(tm.positionTicket>0?"WAIT":"PLAN")),(color)0xD0D0D0,11);
   else
      PX2_Label("ORDER_STATUS",x+34,y,"No order yet - setup waiting/valid",(color)0x80D7FF,11);
   y+=18;
   PX2_Label("ORDER_TF",x+34,y,StringFormat("ENTRY TF: %s | CHART TF: %s",PX_TFToString((ENUM_TIMEFRAMES)tm.entryTimeframe),PX_TFToString(_Period)),(tm.entryTimeframe>0 && tm.entryTimeframe!=(int)_Period?(color)0x80D7FF:(color)0xD0D0D0),11); y+=20;

   if(enableTradeProtection)
   {
      PX2_Label("SEC_PROTECT",x+14,y,"5. PROTECTION STATUS",(color)0xE8E8E8,11,"Segoe UI"); y+=19;
      PX2_Label("ORDER_EARLY",x+34,y,StringFormat("EARLY LOCK: %d/3 | BEST: %s",tm.earlyStage,(tm.preTP1Best>0?DoubleToString(tm.preTP1Best,digs):"-")),(color)0x80D7FF,11); y+=18;
      PX2_Label("ORDER_POSTTP1",x+34,y,StringFormat("POST-TP1: %s | BEST: %s",(tm.postTP1MidLocked?"TP1 LOCKED":"WAIT MID"),(tm.postTP1Best>0?DoubleToString(tm.postTP1Best,digs):"-")),(color)0x80D7FF,11); y+=18;
      PX2_Label("ORDER_TRAIL",x+34,y,StringFormat("TRAIL: %s",(tm.lastTrail>0?DoubleToString(tm.lastTrail,digs):"waiting/armed by stages")),(color)0x66CCFF,11); y+=18;
   }
   else
   {
      PX2_Label("SEC_PROTECT",x+14,y,"5. PROTECTION STATUS: Trade will close by TP/SL",(color)0xFFD8A8,11,"Segoe UI");
   }
}

#endif

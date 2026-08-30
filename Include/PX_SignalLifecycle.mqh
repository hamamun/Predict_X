// PREDICT-X v2.00  -  PX_SignalLifecycle.mqh
#ifndef __PX_SIGNAL_LIFECYCLE_MQH__
#define __PX_SIGNAL_LIFECYCLE_MQH__
#include "PX_Scoring.mqh"

enum PX_SignalState { PX_STATE_SCANNING=0, PX_STATE_PENDING=1, PX_STATE_ACTIVE=2 };

enum PX_EntryMethod { PX_ENTRY_NONE=0, PX_ENTRY_MARKET=1, PX_ENTRY_SUPERTREND_LIMIT=2, PX_ENTRY_VALUE_LIMIT=3 };

struct PX_TradeSetup
{
   PX_Direction dir;
   PX_EntryMethod method;
   double entry,sl,tp1,tp2,breakeven,lot,riskMoney,rewardMoney,rr;
   string methodText;
   bool valid;
};

struct PX_Lifecycle
{
   PX_SignalState state;
   PX_Direction pendingDir;
   int pendingScore;
   int barsWaiting;
   datetime signalTime;
};

void PX_LifecycleInit(PX_Lifecycle &lc)
{
   lc.state=PX_STATE_SCANNING; lc.pendingDir=PX_DIR_NONE; lc.pendingScore=0; lc.barsWaiting=0; lc.signalTime=0;
}

string PX_StateText(PX_SignalState s)
{
   if(s==PX_STATE_PENDING) return "PENDING";
   if(s==PX_STATE_ACTIVE) return "ACTIVE";
   return "SCANNING";
}

void PX_UpdateLifecycle(PX_Lifecycle &lc,const PX_ScoreResult &sr,int minScore,int expiryBars,bool spreadBlocked,bool dangerous)
{
   if(dangerous || spreadBlocked || sr.total<40 || sr.dir==PX_DIR_NONE)
   {
      PX_LifecycleInit(lc); return;
   }
   if(lc.state==PX_STATE_SCANNING)
   {
      if(sr.total>=minScore)
      {
         lc.state=PX_STATE_PENDING; lc.pendingDir=sr.dir; lc.pendingScore=sr.total; lc.barsWaiting=0; lc.signalTime=iTime(_Symbol,_Period,1);
      }
   }
   else if(lc.state==PX_STATE_PENDING)
   {
      if(sr.dir!=lc.pendingDir)
      {
         PX_LifecycleInit(lc); return;
      }
      lc.barsWaiting++;
      lc.pendingScore=sr.total;
      if(lc.barsWaiting>=expiryBars) PX_LifecycleInit(lc);
   }
}

double PX_NormalizeLots(double lots)
{
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) step=0.01;
   lots=MathMax(minLot,MathMin(maxLot,lots));
   lots=MathFloor(lots/step)*step;
   int digits=(int)MathRound(-MathLog10(step));
   if(digits<0) digits=2;
   return NormalizeDouble(lots,digits);
}

double PX_CalcLot(double riskPercent,double lotFactor,double entry,double sl)
{
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount=balance*riskPercent/100.0*lotFactor;
   double slDistance=MathAbs(entry-sl);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(slDistance<=0 || tickSize<=0 || tickValue<=0) return SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double lots=riskAmount/(slDistance/tickSize*tickValue);
   return PX_NormalizeLots(lots);
}

double PX_RecentSwingHigh(int startShift=1,int bars=12)
{
   double v=iHigh(_Symbol,_Period,startShift);
   for(int i=startShift+1;i<startShift+bars;i++)
   {
      double h=iHigh(_Symbol,_Period,i);
      if(h>v) v=h;
   }
   return v;
}

double PX_RecentSwingLow(int startShift=1,int bars=12)
{
   double v=iLow(_Symbol,_Period,startShift);
   for(int i=startShift+1;i<startShift+bars;i++)
   {
      double l=iLow(_Symbol,_Period,i);
      if(l<v) v=l;
   }
   return v;
}

void PX_ApplySmartSLTP(PX_TradeSetup &ts,PX_Tier tier,double stLine,double obTop,double obBottom,bool hasOB,double atr,double slMult,double tp1Mult,double tp2Mult)
{
   if(!ts.valid || atr<=0.0 || ts.entry<=0.0) return;
   bool buy=(ts.dir==PX_DIR_BUY);
   double buffer=0.10*atr;
   double atrSL=(buy?ts.entry-slMult*atr:ts.entry+slMult*atr);
   double swingSL=(buy?PX_RecentSwingLow(1,12)-buffer:PX_RecentSwingHigh(1,12)+buffer);
   double stSL=(stLine>0.0?(buy?stLine-buffer:stLine+buffer):atrSL);
   double obSL=atrSL;
   if(hasOB) obSL=(buy?obBottom-buffer:obTop+buffer);

   double minDist=0.80*atr;
   double maxDist=MathMax(2.50*atr,slMult*atr+0.50*atr);
   double finalSL=atrSL;
   double candidates[4]; candidates[0]=atrSL; candidates[1]=swingSL; candidates[2]=stSL; candidates[3]=obSL;
   for(int i=0;i<4;i++)
   {
      double c=candidates[i];
      double dist=MathAbs(ts.entry-c);
      bool correctSide=(buy?c<ts.entry:c>ts.entry);
      if(!correctSide || dist<minDist || dist>maxDist) continue;
      if(buy) finalSL=MathMin(finalSL,c); else finalSL=MathMax(finalSL,c);
   }
   ts.sl=finalSL;

   double risk=MathAbs(ts.entry-ts.sl);
   if(risk<=0.0) risk=slMult*atr;

   // Realistic TP1: reachable nearby target around 0.8R-1.2R, with swing target if valid.
   double defaultTP1Dist=MathMax(0.80*risk,MathMin(1.20*risk,1.10*atr));
   double swingTarget=(buy?PX_RecentSwingHigh(1,16):PX_RecentSwingLow(1,16));
   double swingDist=(buy?swingTarget-ts.entry:ts.entry-swingTarget);
   double tp1Dist=defaultTP1Dist;
   if(swingDist>=0.80*risk && swingDist<=1.50*risk) tp1Dist=MathMin(tp1Dist,swingDist);

   // Adaptive TP2: TP2 is a bonus target; trail/early lock are the main runners.
   double tp2R=1.45;
   if(tier==PX_TIER_VERY_STRONG) tp2R=2.25;
   else if(tier==PX_TIER_STRONG) tp2R=1.85;
   else if(tier==PX_TIER_MEDIUM) tp2R=1.45;
   double tp2Dist=MathMax(tp1Dist+0.30*risk,tp2R*risk);

   if(buy)
   {
      ts.tp1=ts.entry+tp1Dist;
      ts.tp2=ts.entry+tp2Dist;
   }
   else
   {
      ts.tp1=ts.entry-tp1Dist;
      ts.tp2=ts.entry-tp2Dist;
   }
}

bool PX_ApplyBrokerStopDistance(PX_TradeSetup &ts,double ask,double bid,bool useInitialSL,double riskPct,double lotFactor)
{
   if(!ts.valid || ask<=0.0 || bid<=0.0 || ask<=bid) return false;
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   int freeze=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double minD=(double)MathMax(stops,freeze)*_Point;
   double buffer=2.0*_Point;
   bool buy=(ts.dir==PX_DIR_BUY);
   bool isMarket=(ts.method==PX_ENTRY_MARKET);
   double ref=(isMarket ? (buy?bid:ask) : ts.entry);

   if(ref<=0.0 || minD<0.0) { ts.valid=false; ts.methodText="broker distance invalid"; return false; }

   // Auto-adjust planned SL/TP outward to satisfy broker minimum distance.
   // For pending limits, stops are adjusted around the future entry price.
   // For market orders, stops are adjusted around current bid/ask reference.
   if(buy)
   {
      double minTP=ref+minD+buffer;
      double maxSL=ref-minD-buffer;
      if(ts.tp2<minTP) ts.tp2=minTP;
      if(useInitialSL && ts.sl>maxSL) ts.sl=maxSL;
      // Keep TP1 logical and not beyond TP2. TP1 is internal, but should stay reachable.
      if(ts.tp1>=ts.tp2) ts.tp1=ts.entry+0.60*MathAbs(ts.tp2-ts.entry);
      if(ts.sl>=ts.entry) ts.sl=ts.entry-MathMax(minD+buffer,MathAbs(ts.entry-ref)+minD+buffer);
   }
   else
   {
      double maxTP=ref-minD-buffer;
      double minSL=ref+minD+buffer;
      if(ts.tp2>maxTP) ts.tp2=maxTP;
      if(useInitialSL && ts.sl<minSL) ts.sl=minSL;
      if(ts.tp1<=ts.tp2) ts.tp1=ts.entry-0.60*MathAbs(ts.entry-ts.tp2);
      if(ts.sl<=ts.entry) ts.sl=ts.entry+MathMax(minD+buffer,MathAbs(ts.entry-ref)+minD+buffer);
   }

   bool geometry=(buy ? (ts.sl<ts.entry && ts.tp2>ts.entry) : (ts.sl>ts.entry && ts.tp2<ts.entry));
   if(!geometry)
   {
      ts.valid=false;
      ts.methodText="broker distance invalid geometry";
      return false;
   }

   ts.lot=PX_CalcLot(riskPct,lotFactor,ts.entry,ts.sl);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE), tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   ts.riskMoney=(tickSize>0.0?MathAbs(ts.entry-ts.sl)/tickSize*tickValue*ts.lot:0.0);
   ts.rewardMoney=(tickSize>0.0?MathAbs(ts.tp2-ts.entry)/tickSize*tickValue*ts.lot:0.0);
   ts.rr=(MathAbs(ts.entry-ts.sl)>0?MathAbs(ts.tp2-ts.entry)/MathAbs(ts.entry-ts.sl):0.0);

   // Do not place extremely poor setups after broker adjustment.
   if(ts.rr<1.0)
   {
      ts.valid=false;
      ts.methodText="broker adjusted R:R too low";
      return false;
   }
   return true;
}

void PX_CalcTradeSetup(PX_TradeSetup &ts,PX_Direction dir,PX_Tier tier,double score,double ask,double bid,double stLine,double vwap,double obTop,double obBottom,bool hasOB,double atr,double slMult,double tp1Mult,double tp2Mult,double riskPct,double lotFactor,bool strongMarketAllowed=false,bool mediumMarketAllowed=false,bool useInitialSL=false)
{
   ts.dir=dir; ts.method=PX_ENTRY_NONE; ts.entry=0; ts.sl=0; ts.tp1=0; ts.tp2=0; ts.breakeven=0; ts.lot=0; ts.riskMoney=0; ts.rewardMoney=0; ts.rr=0; ts.methodText="none"; ts.valid=false;
   if(ask<=0.0 || bid<=0.0 || ask<=bid || atr<=0.0)
   {
      ts.methodText="invalid live price - no setup";
      return;
   }
   bool buy=(dir==PX_DIR_BUY);
   double market=(buy?ask:bid);
   if(tier==PX_TIER_VERY_STRONG)
   {
      ts.method=PX_ENTRY_MARKET;
      ts.entry=market;
      ts.methodText="market (very strong)";
   }
   else if(tier==PX_TIER_STRONG)
   {
      if(strongMarketAllowed)
      {
         ts.method=PX_ENTRY_MARKET;
         ts.entry=market;
         ts.methodText="market (strong momentum, not extended)";
      }
      else
      {
         ts.method=PX_ENTRY_SUPERTREND_LIMIT; ts.entry=stLine; ts.methodText="SuperTrend limit";
         if((buy && market<=ts.entry) || (!buy && market>=ts.entry)) { ts.entry=market; ts.method=PX_ENTRY_MARKET; ts.methodText="market (price past ST)"; }
      }
   }
   else if(tier==PX_TIER_MEDIUM)
   {
      if(mediumMarketAllowed)
      {
         ts.method=PX_ENTRY_MARKET;
         ts.entry=market;
         ts.methodText="market (medium strong momentum)";
      }
      else
      {
         ts.method=PX_ENTRY_VALUE_LIMIT;
         ts.entry=vwap;
         if(hasOB) ts.entry=(buy?obTop:obBottom);
         ts.methodText=(hasOB?"Order Block/VWAP limit":"VWAP limit");
         if((buy && market<=ts.entry) || (!buy && market>=ts.entry)) { ts.entry=market; ts.method=PX_ENTRY_MARKET; ts.methodText="market (price past value)"; }
      }
   }
   else return;

   if(buy)
   {
      ts.sl=ts.entry-slMult*atr; ts.tp1=ts.entry+tp1Mult*atr; ts.tp2=ts.entry+tp2Mult*atr;
      ts.breakeven=ts.entry+1.5*(ask-bid);
   }
   else
   {
      ts.sl=ts.entry+slMult*atr; ts.tp1=ts.entry-tp1Mult*atr; ts.tp2=ts.entry-tp2Mult*atr;
      ts.breakeven=ts.entry-1.5*(ask-bid);
   }
   ts.valid=true;
   PX_ApplySmartSLTP(ts,tier,stLine,obTop,obBottom,hasOB,atr,slMult,tp1Mult,tp2Mult);
   ts.lot=PX_CalcLot(riskPct,lotFactor,ts.entry,ts.sl);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE), tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   ts.riskMoney=(tickSize>0.0?MathAbs(ts.entry-ts.sl)/tickSize*tickValue*ts.lot:0.0);
   ts.rewardMoney=(tickSize>0.0?MathAbs(ts.tp2-ts.entry)/tickSize*tickValue*ts.lot:0.0);
   ts.rr=(MathAbs(ts.entry-ts.sl)>0?MathAbs(ts.tp2-ts.entry)/MathAbs(ts.entry-ts.sl):0);
   PX_ApplyBrokerStopDistance(ts,ask,bid,useInitialSL,riskPct,lotFactor);
}

#endif

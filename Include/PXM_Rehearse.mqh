//+------------------------------------------------------------------+
//|                                                  PXM_Rehearse.mqh |
//| ALADDIN-IMP Phase A, module 2: the rehearsal engine.             |
//|                                                                  |
//| Runs the scoring math over MT5's OWN past closed bars to build   |
//| the memory bank's history. Layer1 (SMC) and Layer5 (Markov) in   |
//| the live includes are hardcoded to shift 1, so they are COPIED   |
//| here with a base-shift parameter. The live functions in          |
//| PX_Layer1_SMC.mqh / PX_Layer5_Markov.mqh are NEVER modified and  |
//| the live path never calls anything in this file except the pump. |
//|                                                                  |
//| Chunked: a few hundred bars per timer pass with a time budget,   |
//| so the terminal never freezes.                                   |
//| OHLC rules: same-bar SL+TP touch counts SL first (conservative); |
//| spread is a typical constant (bid-based bars; buys pay the ask). |
//| Rehearsal rows can only ever GROW the bank; they never act.      |
//+------------------------------------------------------------------+
#ifndef __PXM_REHEARSE_MQH__
#define __PXM_REHEARSE_MQH__

#include "PXM_Book.mqh"
#include "PX_Layer1_SMC.mqh"
#include "PX_MarketRegime.mqh"
#include "PX_Layer2_Trend.mqh"
#include "PX_Layer3_Value.mqh"
#include "PX_Layer5_Markov.mqh"

#define PXM_RH_BUDGET_US 80000
#define PXM_RH_MIN_BARS  110

//--- per-bar simulated state (rehearsal private; nothing here touches live globals)
struct PXM_RhSim
{
   PX_Direction dir;
   int total,tier;
   int l1,l2,l3,l4,l5,l6,candle;
   double features[12];
   double er,ratio,adx,rsi,sqz,ttm,fired,atr100;
   int stDir;
   double stLine;
   double price,vwap,atr;
   double obTop,obBottom; bool hasOB;
   double spreadPts;
   int expiry;
   bool strongMkt,mediumMkt;
};

//--- module state
int g_pxmRhCursor=0;
int g_pxmRhBMin=0;
int g_pxmRhPrintPct=0;
int g_pxmRhStH1=INVALID_HANDLE;
int g_pxmRhStH2=INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Shift-aware buffer reads (copies of PX_Copy1/PX_Copy2 that take  |
//| an arbitrary shift; the live versions read shift 1 only)         |
//+------------------------------------------------------------------+
bool PXM_RhCopy1(const int handle,const int buffer,const int shift,double &value)
{
   double tmp[]; ArraySetAsSeries(tmp,true);
   if(handle==INVALID_HANDLE) return false;
   if(CopyBuffer(handle,buffer,shift,1,tmp)<1) return false;
   value=tmp[0];
   return true;
}

bool PXM_RhCopy2(const int handle,const int buffer,const int shift,double &v1,double &v2)
{
   double tmp[]; ArraySetAsSeries(tmp,true);
   if(handle==INVALID_HANDLE) return false;
   if(CopyBuffer(handle,buffer,shift,2,tmp)<2) return false;
   v1=tmp[0]; v2=tmp[1];
   return true;
}

int PXM_RhSTDir(const int handle,const int shift)
{
   double v=0.0;
   if(!PXM_RhCopy1(handle,1,shift,v)) return 0;
   return (v>0.0?1:(v<0.0?-1:0));
}

//+------------------------------------------------------------------+
//| COPY of PX_ScoreLayer1 (SMC) with base shift b (live uses b=1).  |
//| Math is identical; only the shift is parameterized.              |
//+------------------------------------------------------------------+
int PXM_RhScoreLayer1(const int b,const PX_Direction dir,const double price,const double atr,
                      bool &hasOB,double &obTop,double &obBottom)
{
   hasOB=false; obTop=0.0; obBottom=0.0;
   bool buy=(dir==PX_DIR_BUY);
   bool hasSweep=false;
   int pts=0;

   double h1=iHigh(_Symbol,_Period,b), l1=iLow(_Symbol,_Period,b), c1=iClose(_Symbol,_Period,b);
   double prevHigh=PX_HighestHigh(_Symbol,_Period,b+1,10);
   double prevLow=PX_LowestLow(_Symbol,_Period,b+1,10);
   if(prevHigh<=0.0 || prevLow<=0.0 || h1<=0.0 || c1<=0.0) return -1;

   int sweepPts=0;
   if(buy)
   {
      if(l1<prevLow && c1>prevLow) { sweepPts=8; hasSweep=true; }
      else if(MathAbs(l1-prevLow)<=0.2*atr) sweepPts=4;
   }
   else
   {
      if(h1>prevHigh && c1<prevHigh) { sweepPts=8; hasSweep=true; }
      else if(MathAbs(h1-prevHigh)<=0.2*atr) sweepPts=4;
   }
   pts+=sweepPts;

   int obPts=0;
   for(int i=b+1;i<b+30;i++)
   {
      double o=iOpen(_Symbol,_Period,i), c=iClose(_Symbol,_Period,i), h=iHigh(_Symbol,_Period,i), l=iLow(_Symbol,_Period,i);
      if(o<=0.0 || c<=0.0) break;
      double nC=iClose(_Symbol,_Period,i-1);
      bool impulse=(MathAbs(nC-c)>0.8*atr);
      if(buy && c<o && impulse && nC>c)
      {
         hasOB=true; obTop=h; obBottom=l;
         if(price>=l-0.5*atr && price<=h+0.5*atr) obPts=7; else obPts=3;
         break;
      }
      if(!buy && c>o && impulse && nC<c)
      {
         hasOB=true; obTop=h; obBottom=l;
         if(price>=l-0.5*atr && price<=h+0.5*atr) obPts=7; else obPts=3;
         break;
      }
   }
   pts+=obPts;

   int fvgPts=0;
   for(int i=b;i<b+20;i++)
   {
      double hOld=iHigh(_Symbol,_Period,i+2), lOld=iLow(_Symbol,_Period,i+2);
      double hNew=iHigh(_Symbol,_Period,i), lNew=iLow(_Symbol,_Period,i);
      if(hNew<=0.0 || hOld<=0.0) break;
      if(buy && lNew>hOld) { fvgPts=5; break; }
      if(!buy && hNew<lOld) { fvgPts=5; break; }
   }
   pts+=fvgPts;

   int align=(hasSweep?1:0)+(hasOB?1:0)+((fvgPts>0)?1:0);
   pts+=((align==3)?5:((align==2)?2:0));
   return pts;
}

//+------------------------------------------------------------------+
//| COPY of PX_ScoreLayer5 (Markov) with base shift b (live=1).      |
//+------------------------------------------------------------------+
int PXM_RhScoreLayer5(const int b,const PX_Direction dir,const double atr)
{
   double close[]; ArraySetAsSeries(close,true);
   if(CopyClose(_Symbol,_Period,b,102,close)<102 || atr<=0.0) return -1;
   int counts[3][3];
   for(int a=0;a<3;a++) for(int c=0;c<3;c++) counts[a][c]=0;
   double th=0.4*atr;
   int states[101];
   for(int i=0;i<101;i++) states[i]=PX_StateFromChange(close[i]-close[i+1],th);
   for(int i=100;i>=1;i--) counts[states[i]][states[i-1]]++;
   int cur=states[0];
   int rowSum=counts[cur][0]+counts[cur][1]+counts[cur][2];
   if(rowSum<=0) return 0;
   double probUp=(double)counts[cur][0]/rowSum;
   double probNeutral=(double)counts[cur][1]/rowSum;
   double probDown=(double)counts[cur][2]/rowSum;
   int predState=0; double best=probUp;
   if(probNeutral>best) { best=probNeutral; predState=1; }
   if(probDown>best) { best=probDown; predState=2; }
   int pts=0;
   bool match=(dir==PX_DIR_BUY && predState==0) || (dir==PX_DIR_SELL && predState==2);
   if(match)
   {
      if(best>0.60) pts=15; else if(best>=0.50) pts=10; else if(best>=0.40) pts=5;
   }
   else if(predState==1) pts=3;
   return pts;
}

//+------------------------------------------------------------------+
//| HTF confluence at historical bar b (live reads HTF shift 1).     |
//| The chart-bar index is mapped onto the HTF bar that was the      |
//| "last closed" HTF bar at the moment of that signal (approx).     |
//+------------------------------------------------------------------+
int PXM_RhScoreLayer4(const int b,const PX_Direction dir,const PX_Preset &ap)
{
   bool buy=(dir==PX_DIR_BUY);
   double chartSec=(double)PeriodSeconds(_Period);
   int total=0;

   double htfSec1=(double)PeriodSeconds(ap.htf1);
   int hb1=(htfSec1>chartSec? MathMax(1,(int)MathFloor((b+1)*chartSec/htfSec1)) : MathMax(1,b));
   int st1=PXM_RhSTDir(g_pxmRhStH1,hb1);
   double c1=iClose(_Symbol,ap.htf1,hb1);
   double v1=PX_CalcVWAP(_Symbol,ap.htf1,hb1);
   int agree1=0;
   if(c1>0.0 && v1>0.0)
   {
      if((buy && st1>0)||(!buy && st1<0)) agree1++;
      if((buy && c1>v1)||(!buy && c1<v1)) agree1++;
   }
   total+=(agree1==2?7:(agree1==1?3:0));

   double htfSec2=(double)PeriodSeconds(ap.htf2);
   int hb2=(htfSec2>chartSec? MathMax(1,(int)MathFloor((b+1)*chartSec/htfSec2)) : MathMax(1,b));
   int st2=PXM_RhSTDir(g_pxmRhStH2,hb2);
   double c2=iClose(_Symbol,ap.htf2,hb2);
   double v2=PX_CalcVWAP(_Symbol,ap.htf2,hb2);
   int agree2=0;
   if(c2>0.0 && v2>0.0)
   {
      if((buy && st2>0)||(!buy && st2<0)) agree2++;
      if((buy && c2>v2)||(!buy && c2<v2)) agree2++;
   }
   total+=(agree2==2?8:(agree2==1?4:0));
   return total;
}

//+------------------------------------------------------------------+
//| Candlestick confirmation COPY with base shift b (live=1).        |
//| Mirrors PX_CandleConfirmationScore(); returns bonus pts and      |
//| reports the opposite-candle warning flag used by the entry gates.|
//+------------------------------------------------------------------+
double PXM_RhBody(const int sh){ return MathAbs(iClose(_Symbol,_Period,sh)-iOpen(_Symbol,_Period,sh)); }
bool PXM_RhBull(const int sh){ return iClose(_Symbol,_Period,sh)>iOpen(_Symbol,_Period,sh); }
bool PXM_RhBear(const int sh){ return iClose(_Symbol,_Period,sh)<iOpen(_Symbol,_Period,sh); }

double PXM_RhAvgBody(const int startShift)
{
   double sum=0.0; int n=0;
   for(int i=startShift;i<startShift+10;i++)
   {
      double b=PXM_RhBody(i);
      if(b>0.0){ sum+=b; n++; }
   }
   return (n>0?sum/n:0.0);
}

bool PXM_RhBullEngulf(const int b)
{
   double o1=iOpen(_Symbol,_Period,b), c1=iClose(_Symbol,_Period,b);
   double o2=iOpen(_Symbol,_Period,b+1), c2=iClose(_Symbol,_Period,b+1);
   return (c2<o2 && c1>o1 && c1>=o2 && o1<=c2);
}
bool PXM_RhBearEngulf(const int b)
{
   double o1=iOpen(_Symbol,_Period,b), c1=iClose(_Symbol,_Period,b);
   double o2=iOpen(_Symbol,_Period,b+1), c2=iClose(_Symbol,_Period,b+1);
   return (c2>o2 && c1<o1 && c1<=o2 && o1>=c2);
}
bool PXM_RhBullPin(const int b)
{
   double o=iOpen(_Symbol,_Period,b), c=iClose(_Symbol,_Period,b), h=iHigh(_Symbol,_Period,b), l=iLow(_Symbol,_Period,b);
   double body=MathMax(_Point,MathAbs(c-o));
   double lower=MathMin(o,c)-l, upper=h-MathMax(o,c);
   return (lower>=2.0*body && upper<=1.2*body && c>l+0.55*(h-l));
}
bool PXM_RhBearPin(const int b)
{
   double o=iOpen(_Symbol,_Period,b), c=iClose(_Symbol,_Period,b), h=iHigh(_Symbol,_Period,b), l=iLow(_Symbol,_Period,b);
   double body=MathMax(_Point,MathAbs(c-o));
   double upper=h-MathMax(o,c), lower=MathMin(o,c)-l;
   return (upper>=2.0*body && lower<=1.2*body && c<l+0.45*(h-l));
}
bool PXM_RhMorning(const int b)
{
   return (PXM_RhBear(b+2) && PXM_RhBody(b+1)<0.7*PXM_RhBody(b+2) && PXM_RhBull(b) &&
           iClose(_Symbol,_Period,b)>(iOpen(_Symbol,_Period,b+2)+iClose(_Symbol,_Period,b+2))/2.0);
}
bool PXM_RhEvening(const int b)
{
   return (PXM_RhBull(b+2) && PXM_RhBody(b+1)<0.7*PXM_RhBody(b+2) && PXM_RhBear(b) &&
           iClose(_Symbol,_Period,b)<(iOpen(_Symbol,_Period,b+2)+iClose(_Symbol,_Period,b+2))/2.0);
}
bool PXM_RhStrongBull(const int b)
{
   double avg=PXM_RhAvgBody(b+1);
   double h=iHigh(_Symbol,_Period,b), l=iLow(_Symbol,_Period,b), c=iClose(_Symbol,_Period,b);
   return (PXM_RhBull(b) && PXM_RhBody(b)>=1.15*avg && c>=l+0.70*(h-l));
}
bool PXM_RhStrongBear(const int b)
{
   double avg=PXM_RhAvgBody(b+1);
   double h=iHigh(_Symbol,_Period,b), l=iLow(_Symbol,_Period,b), c=iClose(_Symbol,_Period,b);
   return (PXM_RhBear(b) && PXM_RhBody(b)>=1.15*avg && c<=l+0.30*(h-l));
}

int PXM_RhCandleScore(const int b,const PXM_RhSim &s,bool &opposite)
{
   opposite=false;
   if(s.dir==PX_DIR_NONE || s.atr<=0.0) return 0;
   bool buy=(s.dir==PX_DIR_BUY);
   int pts=0;
   if(buy)
   {
      if(PXM_RhMorning(b)) pts=MathMax(pts,4);
      if(PXM_RhBullEngulf(b)) pts=MathMax(pts,3);
      if(PXM_RhBullPin(b)) pts=MathMax(pts,2);
      if(PXM_RhStrongBull(b)) pts=MathMax(pts,2);
      if(PXM_RhBearEngulf(b) || PXM_RhEvening(b) || PXM_RhBearPin(b)) opposite=true;
   }
   else
   {
      if(PXM_RhEvening(b)) pts=MathMax(pts,4);
      if(PXM_RhBearEngulf(b)) pts=MathMax(pts,3);
      if(PXM_RhBearPin(b)) pts=MathMax(pts,2);
      if(PXM_RhStrongBear(b)) pts=MathMax(pts,2);
      if(PXM_RhBullEngulf(b) || PXM_RhMorning(b) || PXM_RhBullPin(b)) opposite=true;
   }
   if(opposite) return 0;
   if(pts>0)
   {
      bool nearValue=(MathAbs(s.price-s.vwap)<=0.35*s.atr);
      if(s.hasOB)
      {
         if(buy && s.price>=s.obBottom-0.35*s.atr && s.price<=s.obTop+0.35*s.atr) nearValue=true;
         if(!buy && s.price>=s.obBottom-0.35*s.atr && s.price<=s.obTop+0.35*s.atr) nearValue=true;
      }
      if(nearValue) pts+=1;
   }
   if(pts>5) pts=5;
   return pts;
}

//+------------------------------------------------------------------+
//| Primary direction - copy of PX_PrimaryDirection (identical math) |
//+------------------------------------------------------------------+
PX_Direction PXM_RhPrimaryDir(const int stDir,const double closePrice,const double vwap,const double rsi,const double ttm)
{
   int bull=0,bear=0;
   if(stDir>0) bull++; else if(stDir<0) bear++;
   if(closePrice>vwap) bull++; else if(closePrice<vwap) bear++;
   if(rsi>=50.0) bull++; else bear++;
   if(ttm>0.0) bull++; else if(ttm<0.0) bear++;
   if(bull>bear) return PX_DIR_BUY;
   if(bear>bull) return PX_DIR_SELL;
   return PX_DIR_NONE;
}

//+------------------------------------------------------------------+
//| Score one historical closed bar b (the bar that "just closed"    |
//| at that moment). Fills PXM_RhSim with the full live-equivalent   |
//| verdict. Returns false when the bar yields no tradeable signal.  |
//+------------------------------------------------------------------+
bool PXM_RhScoreBar(const int b,const int hST,const int hRSI,const int hADX,const int hATR14,const int hATR100,const int hKC,const int hTTM,
                    const PX_Preset &base,const double spreadPts,PXM_RhSim &s)
{
   double atr14=0.0,atr100=0.0,adx=0.0,st=0.0,stDirRaw=0.0,rsi=50.0,rsiPrev=50.0,ttm=0.0,ttmPrev=0.0,sqz=0.0,fired=0.0;
   double kcU=0.0,kcM=0.0,kcL=0.0;
   bool ok=true;
   ok=(PXM_RhCopy1(hATR14,0,b,atr14)&&ok);
   ok=(PXM_RhCopy1(hATR100,0,b,atr100)&&ok);
   ok=(PXM_RhCopy1(hADX,0,b,adx)&&ok);
   ok=(PXM_RhCopy1(hST,0,b,st)&&ok);
   ok=(PXM_RhCopy1(hST,1,b,stDirRaw)&&ok);
   ok=(PXM_RhCopy2(hRSI,0,b,rsi,rsiPrev)&&ok);
   ok=(PXM_RhCopy2(hTTM,0,b,ttm,ttmPrev)&&ok);
   ok=(PXM_RhCopy1(hTTM,1,b,sqz)&&ok);
   ok=(PXM_RhCopy1(hTTM,2,b,fired)&&ok);
   ok=(PXM_RhCopy1(hKC,0,b,kcU)&&ok);
   ok=(PXM_RhCopy1(hKC,1,b,kcM)&&ok);
   ok=(PXM_RhCopy1(hKC,2,b,kcL)&&ok);
   if(!ok) return false;
   if(atr14<=0.0 || atr100<=0.0 || adx<=0.0) return false;

   double price=iClose(_Symbol,_Period,b);
   if(price<=0.0) return false;
   double vwap=PX_CalcVWAP(_Symbol,_Period,b);
   if(vwap<=0.0) return false;

   s.price=price; s.vwap=vwap; s.atr=atr14; s.atr100=atr100;
   s.stLine=st; s.stDir=(stDirRaw>0.0?1:(stDirRaw<0.0?-1:0));
   s.rsi=rsi; s.ttm=ttm; s.fired=fired; s.sqz=sqz; s.adx=adx;
   s.spreadPts=spreadPts;
   s.strongMkt=false; s.mediumMkt=false; s.hasOB=false; s.obTop=0.0; s.obBottom=0.0;

   PX_Direction dir=PXM_RhPrimaryDir(s.stDir,price,vwap,rsi,ttm);
   s.dir=dir;
   if(dir==PX_DIR_NONE) return false;

   double er=PX_KaufmanER(_Symbol,_Period,20,b);
   double ratio=atr14/atr100;
   s.er=er; s.ratio=ratio;

   PX_RegimeState reg;
   PX_ClassifyRegime(base,er,ratio,adx,reg);
   if(!InpAutoAdjustSettings && !reg.blockSignals) { reg.adjusted=base; reg.lotFactor=1.0; }
   if(reg.blockSignals) return false;
   PX_Preset ap=reg.adjusted;
   s.expiry=ap.signalExpiryBars;

   // session gate (live: TradeManager refuses/cancels outside allowed session)
   datetime bt=iTime(_Symbol,_Period,b);
   if(bt<=0) return false;
   if(!PX_SessionAllowed(InpTradingSessions,bt)) return false;

   // --- layers 2/3: reuse the pure struct-driven live scorers with a shifted context
   PX_TrendContext tc;
   tc.stLine=st; tc.stDir=s.stDir; tc.rsi=rsi; tc.rsiPrev=rsiPrev;
   tc.ttmHist=ttm; tc.ttmHistPrev=ttmPrev; tc.ttmSqueeze=sqz; tc.ttmFiredDir=fired; tc.adx=adx;
   PX_ValueContext vc;
   vc.price=price; vc.vwap=vwap; vc.kcUpper=kcU; vc.kcMiddle=kcM; vc.kcLower=kcL;
   vc.atr=atr14; vc.spreadPoints=spreadPts; vc.avgSpreadPoints=spreadPts;
   vc.tickValid=true; vc.dataReady=true;
   vc.sessionName=PX_CurrentSessionName(bt); vc.sessionActive=true; vc.spreadBlocked=false;

   PX_ScoreDetail d2; PX_ScoreDetail d3;
   s.l2=PX_ScoreLayer2(dir,tc,d2);
   s.l3=PX_ScoreLayer3(dir,vc,d3);

   // --- layers 1/4/5: shift-aware copies (live layer functions stay untouched)
   bool hasOB=false; double obTop=0.0,obBottom=0.0;
   s.l1=PXM_RhScoreLayer1(b,dir,price,atr14,hasOB,obTop,obBottom);
   if(s.l1<0) return false;
   s.hasOB=hasOB; s.obTop=obTop; s.obBottom=obBottom;
   s.l4=PXM_RhScoreLayer4(b,dir,ap);
   s.l5=PXM_RhScoreLayer5(b,dir,atr14);
   if(s.l5<0) return false;

   // --- feature vector identical to the live g_aiFeatures layout
   int preAI=PX_AggregateScore(s.l1,s.l2,s.l3,s.l4,s.l5,0);
   s.features[0]=(double)preAI;
   s.features[1]=(double)s.l1; s.features[2]=(double)s.l2; s.features[3]=(double)s.l3;
   s.features[4]=(double)s.l4; s.features[5]=(double)s.l5;
   s.features[6]=er; s.features[7]=ratio; s.features[8]=adx; s.features[9]=rsi;
   s.features[10]=(double)s.stDir; s.features[11]=sqz;

   // --- layer 6 (online AI) replayed with the CURRENT model weights.
   // Approximation is deliberate: Phase-3 AI value measurement is the scorecard's job.
   s.l6=0;
   if(InpEnableAIEnhancement && g_px3AI.samples>=20)
   {
      double x[];
      PX3_NormalizeFeatures(s.features,dir,x);
      double p=PX3_AIProbability(x);
      if(p>0.70) s.l6=10; else if(p>=0.55) s.l6=5;
   }

   // --- candle confirmation + opposite warning (only when enabled, like live)
   bool opposite=false;
   s.candle=0;
   if(InpUseCandlestickConfirmation) s.candle=PXM_RhCandleScore(b,s,opposite);

   s.total=PX_AggregateScore(s.l1,s.l2,s.l3,s.l4,s.l5,s.l6,s.candle);
   s.tier=(int)PX_ClassifyTier(s.total);

   if(s.total<ap.minScore) return false;
   if(s.tier<PX_TIER_MEDIUM) return false;

   // --- market-entry allowance flags (mirror of PX_StrongMarketEntryAllowed /
   //     PX_MediumMarketEntryAllowed with live-tick conditions made historical:
   //     tickValid=true, spread=typical constant so spreadLow=true)
   bool buy=(dir==PX_DIR_BUY);
   bool stAgree=(buy && s.stDir>0) || (!buy && s.stDir<0);
   bool ttmAgree=(buy && ttm>0.0) || (!buy && ttm<0.0);
   bool vwapSide=(buy && price>vwap) || (!buy && price<vwap);
   bool notExtended=(MathAbs(price-vwap)<=1.0*atr14);
   bool regimeAllowsMkt=(reg.regime!=PX_REGIME_CHOPPY && reg.regime!=PX_REGIME_DANGEROUS);
   if(!opposite && regimeAllowsMkt)
   {
      if(s.total>=70 && s.total<85 && stAgree && ttmAgree && vwapSide && adx>=25.0 && (notExtended || adx>=35.0))
         s.strongMkt=true;
      if(s.total>=67 && s.total<70 && stAgree && ttmAgree && vwapSide && adx>=30.0)
         s.mediumMkt=true;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Setup replica: tier -> entry method, ATR geometry + smart SL/TP, |
//| then execution fill and bar-by-bar outcome (same-bar rule: SL    |
//| counts first). Outputs the full row payload for the bank.        |
//+------------------------------------------------------------------+
bool PXM_RhSimulate(const int b,const PXM_RhSim &s,const PX_Preset &ap,
                    double &entry,double &sl,double &tp1,double &tp2,
                    int &result,int &win,int &tp1hit,double &maeATR,double &pnlR,int &barsRes)
{
   entry=sl=tp1=tp2=0.0; result=PXM_RESULT_NONE; win=0; tp1hit=0; maeATR=0.0; pnlR=0.0; barsRes=0;
   if(b<2) return false;
   bool buy=(s.dir==PX_DIR_BUY);
   double spread=MathMax(0.0,s.spreadPts)*_Point;
   double atr=s.atr;

   // --- method like PX_CalcTradeSetup
   int method=1; // 1 market, 2 SuperTrend limit, 3 value limit
   if(s.tier==PX_TIER_VERY_STRONG) method=1;
   else if(s.tier==PX_TIER_STRONG) method=(s.strongMkt?1:2);
   else method=(s.mediumMkt?1:3);

   double level=0.0;
   if(method==2)
   {
      level=s.stLine;
      if(level<=0.0) return false;
   }
   else if(method==3)
   {
      level=s.vwap;
      if(s.hasOB) level=(buy?s.obTop:s.obBottom);
      if(level<=0.0) return false;
   }
   // price past the level -> live converts to market
   if(method!=1)
   {
      if(buy && s.price+spread<=level) method=1;
      if(!buy && s.price>=level-spread) method=1;
   }

   int expiry=MathMax(1,s.expiry);
   int fillShift=-1;
   if(method==1)
   {
      double o=iOpen(_Symbol,_Period,b-1);
      if(o<=0.0) return false;
      entry=(buy? o+spread : o);
      fillShift=b-1;
   }
   else
   {
      int jStop=MathMax(1,b-expiry);
      for(int j=b-1;j>=jStop;j--)
      {
         double o=iOpen(_Symbol,_Period,j), h=iHigh(_Symbol,_Period,j), l=iLow(_Symbol,_Period,j);
         if(o<=0.0) break;
         if(buy)
         {
            if(l+spread<=level) { entry=MathMin(level,o+spread); fillShift=j; break; }
         }
         else
         {
            if(h>=level-spread) { entry=MathMax(o,level-spread); fillShift=j; break; }
         }
      }
      if(fillShift<0) return false; // limit never filled before expiry (live cancels it)
   }

   // --- geometry like PX_CalcTradeSetup + PX_ApplySmartSLTP (shift b)
   double slMult=ap.slATRMult,tp1Mult=ap.tp1ATRMult,tp2Mult=ap.tp2ATRMult;
   if(buy){ sl=entry-slMult*atr; tp1=entry+tp1Mult*atr; tp2=entry+tp2Mult*atr; }
   else   { sl=entry+slMult*atr; tp1=entry-tp1Mult*atr; tp2=entry-tp2Mult*atr; }

   double buffer=0.10*atr;
   double atrSL=sl;
   double swingSL=(buy? PX_RecentSwingLow(b,12)-buffer : PX_RecentSwingHigh(b,12)+buffer);
   double stSL=(s.stLine>0.0?(buy?s.stLine-buffer:s.stLine+buffer):atrSL);
   double obSL=atrSL;
   if(s.hasOB) obSL=(buy? s.obBottom-buffer : s.obTop+buffer);
   double minDist=0.80*atr;
   double maxDist=MathMax(2.50*atr,slMult*atr+0.50*atr);
   double finalSL=atrSL;
   double cands[4]; cands[0]=atrSL; cands[1]=swingSL; cands[2]=stSL; cands[3]=obSL;
   for(int i=0;i<4;i++)
   {
      double c=cands[i];
      if(c<=0.0) continue;
      double dist=MathAbs(entry-c);
      bool correctSide=(buy? c<entry : c>entry);
      if(!correctSide || dist<minDist || dist>maxDist) continue;
      if(buy) finalSL=MathMin(finalSL,c); else finalSL=MathMax(finalSL,c);
   }
   sl=finalSL;

   double risk=MathAbs(entry-sl);
   if(risk<=0.0) return false;
   double defaultTP1Dist=MathMax(0.80*risk,MathMin(1.20*risk,1.10*atr));
   double swingTarget=(buy? PX_RecentSwingHigh(b,16) : PX_RecentSwingLow(b,16));
   double swingDist=(buy? swingTarget-entry : entry-swingTarget);
   double tp1Dist=defaultTP1Dist;
   if(swingTarget>0.0 && swingDist>=0.80*risk && swingDist<=1.50*risk) tp1Dist=MathMin(tp1Dist,swingDist);
   double tp2R=1.45;
   if(s.tier==PX_TIER_VERY_STRONG) tp2R=2.25;
   else if(s.tier==PX_TIER_STRONG) tp2R=1.85;
   double tp2Dist=MathMax(tp1Dist+0.30*risk,tp2R*risk);
   if(buy){ tp1=entry+tp1Dist; tp2=entry+tp2Dist; }
   else   { tp1=entry-tp1Dist; tp2=entry-tp2Dist; }

   double be=(buy? entry+1.5*spread : entry-1.5*spread);

   // broker minimum distance (light replica: enforce around entry)
   double minD=(double)MathMax((int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))*_Point+2.0*_Point;
   if(risk<minD || MathAbs(tp2-entry)<minD) return false;
   double rr=(MathAbs(tp2-entry)>0? MathAbs(tp2-entry)/risk : 0.0);
   if(rr<1.0) return false; // live rejects sub-1R after broker adjustment

   // --- outcome walk (bars are bid quotes; buys pay the ask on entry)
   int jEnd=MathMax(1,fillShift-PXM_SIM_BARS+1);
   double minLow=1e308,maxHigh=-1e308;
   bool hit1=false;
   result=PXM_RESULT_NONE;
   for(int j=fillShift;j>=jEnd;j--)
   {
      double h=iHigh(_Symbol,_Period,j), l=iLow(_Symbol,_Period,j);
      if(h<=0.0 || l<=0.0) break;
      if(h>maxHigh) maxHigh=h;
      if(l<minLow) minLow=l;
      bool slTouch,tp1Touch,tp2Touch,beTouch;
      if(buy)
      {
         slTouch=(l<=sl); tp1Touch=(h>=tp1); tp2Touch=(h>=tp2); beTouch=(l<=be);
      }
      else
      {
         slTouch=(h+spread>=sl); tp1Touch=(l+spread<=tp1); tp2Touch=(l+spread<=tp2); beTouch=(h+spread>=be);
      }
      if(!hit1 && slTouch)
      {
         result=PXM_RESULT_SL; win=0; barsRes=fillShift-j;
         maeATR=(buy? MathMax(0.0,(entry-minLow)) : MathMax(0.0,(maxHigh+spread-entry)))/atr;
         pnlR=-1.0;
         return true;
      }
      if(!hit1 && tp1Touch)
      {
         hit1=true; tp1hit=1;
      }
      if(hit1)
      {
         if(tp2Touch)
         {
            result=PXM_RESULT_TP2; win=1; barsRes=fillShift-j;
            maeATR=(buy? MathMax(0.0,(entry-minLow)) : MathMax(0.0,(maxHigh+spread-entry)))/atr;
            pnlR=0.5*tp1Dist/risk+0.5*tp2Dist/risk;
            return true;
         }
         if(beTouch)
         {
            result=PXM_RESULT_BE; win=1; barsRes=fillShift-j;
            maeATR=(buy? MathMax(0.0,(entry-minLow)) : MathMax(0.0,(maxHigh+spread-entry)))/atr;
            pnlR=0.5*tp1Dist/risk;
            return true;
         }
      }
   }
   if(hit1)
   {
      // runner still open at the end of history: TP1 banked, count as win
      result=PXM_RESULT_TP1; win=1;
      barsRes=MathMax(1,fillShift-jEnd);
      maeATR=(buy? MathMax(0.0,(entry-minLow)) : MathMax(0.0,(maxHigh+spread-entry)))/atr;
      pnlR=0.5*tp1Dist/risk;
      return true;
   }
   return false; // no touch, no fill info -> unresolved: do not pollute the bank
}

//+------------------------------------------------------------------+
//| One historical bar: score -> simulate -> append bank row         |
//+------------------------------------------------------------------+
void PXM_RhProcessBar(const int b,const int hST,const int hRSI,const int hADX,const int hATR14,const int hATR100,const int hKC,const int hTTM,const PX_Preset &base)
{
   double spreadPts=InpPXM_SpreadPoints;
   if(spreadPts<=0.0) spreadPts=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   PXM_RhSim s;
   s.dir=PX_DIR_NONE; s.total=0; s.tier=0;
   s.l1=s.l2=s.l3=s.l4=s.l5=s.l6=s.candle=0;
   s.er=s.ratio=s.adx=s.rsi=s.sqz=s.ttm=s.fired=s.atr100=0.0;
   s.stDir=0; s.stLine=0.0; s.price=s.vwap=s.atr=0.0;
   s.obTop=s.obBottom=0.0; s.hasOB=false;
   s.spreadPts=spreadPts; s.expiry=base.signalExpiryBars;
   s.strongMkt=false; s.mediumMkt=false;
   for(int i=0;i<12;i++) s.features[i]=0.0;

   if(!PXM_RhScoreBar(b,hST,hRSI,hADX,hATR14,hATR100,hKC,hTTM,base,spreadPts,s)) return;

   PX_RegimeState reg;
   PX_ClassifyRegime(base,s.er,s.ratio,s.adx,reg);
   if(!InpAutoAdjustSettings && !reg.blockSignals) reg.adjusted=base;
   PX_Preset ap=reg.adjusted;

   double entry=0.0,sl=0.0,tp1=0.0,tp2=0.0,maeATR=0.0,pnlR=0.0;
   int result=PXM_RESULT_NONE,win=0,tp1hit=0,barsRes=0;
   if(!PXM_RhSimulate(b,s,ap,entry,sl,tp1,tp2,result,win,tp1hit,maeATR,pnlR,barsRes)) return;

   PXM_Row r;
   r.kind=1;
   r.time=iTime(_Symbol,_Period,b);
   r.dir=(int)s.dir;
   r.score=s.total; r.tier=s.tier;
   r.l1=s.l1; r.l2=s.l2; r.l3=s.l3; r.l4=s.l4; r.l5=s.l5; r.l6=s.l6; r.candle=s.candle;
   r.er=s.er; r.atrRatio=s.ratio; r.adx=s.adx; r.rsi=s.rsi; r.stDir=(double)s.stDir; r.sqz=s.sqz;
   r.atrPts=s.atr/_Point; r.spreadPts=s.spreadPts;
   r.entry=entry; r.sl=sl; r.tp1=tp1; r.tp2=tp2;
   r.result=result; r.win=win; r.tp1hit=tp1hit;
   r.maeATR=maeATR; r.pnlR=pnlR; r.barsRes=barsRes;
   PXM_AppendRow(r);
   g_pxmRhRows++;
}

//+------------------------------------------------------------------+
//| Start / pump / finish                                             |
//+------------------------------------------------------------------+
void PXM_RehearseStart(const PX_Preset &base)
{
   if(!InpPXM_Enable || !InpPXM_Rehearse) return;
   if(g_pxmFile<0) return;
   if(g_pxmRhActive) return;
   if(GlobalVariableCheck(PXM_GV("rehearseDone")) || g_pxmRhRowsLoaded>0)
   {
      if(!GlobalVariableCheck(PXM_GV("rehearseDone"))) GlobalVariableSet(PXM_GV("rehearseDone"),1.0);
      Print("PREDICT-X MEM: rehearsal already completed before - skipping (bank has ",g_pxmCount," rows).");
      return;
   }
   if(InpPXM_RehearseBars<=0) return;
   int avail=iBars(_Symbol,_Period);
   int bMax=MathMin(InpPXM_RehearseBars,avail-2);
   int bMin=PXM_SIM_BARS+1;
   if(bMax<bMin+25)
   {
      Print("PREDICT-X MEM: not enough loaded history for rehearsal yet (bars=",avail,"). It will start automatically once history is loaded.");
      return;
   }
   // persistent HTF SuperTrend handles for the shifted Layer4 replica
   g_pxmRhStH1=iCustom(_Symbol,base.htf1,"PREDICT-X\\Indicators\\SuperTrend",base.stPeriod,base.stMultiplier);
   if(g_pxmRhStH1==INVALID_HANDLE) g_pxmRhStH1=iCustom(_Symbol,base.htf1,"SuperTrend",base.stPeriod,base.stMultiplier);
   g_pxmRhStH2=iCustom(_Symbol,base.htf2,"PREDICT-X\\Indicators\\SuperTrend",base.stPeriod,base.stMultiplier);
   if(g_pxmRhStH2==INVALID_HANDLE) g_pxmRhStH2=iCustom(_Symbol,base.htf2,"SuperTrend",base.stPeriod,base.stMultiplier);
   if(g_pxmRhStH1==INVALID_HANDLE || g_pxmRhStH2==INVALID_HANDLE)
      Print("PREDICT-X MEM: HTF SuperTrend handle unavailable - rehearsal HTF layer will score 0pts on this pass.");

   g_pxmRhBMin=bMin;
   g_pxmRhCursor=bMax;
   g_pxmRhPrintPct=0;
   g_pxmRhActive=true;
   g_pxmRhTotal=bMax-bMin+1;
   g_pxmRhDone=0;
   g_pxmRhRows=0;
   Print("PREDICT-X MEM: rehearsal started - ",g_pxmRhTotal," bars (shift ",bMin,"..",bMax,"), ",
         InpPXM_RehearsePerPass," bars/pass, chunked to keep the terminal responsive.");
}

void PXM_RehearseReleaseHandles()
{
   if(g_pxmRhStH1!=INVALID_HANDLE) { IndicatorRelease(g_pxmRhStH1); g_pxmRhStH1=INVALID_HANDLE; }
   if(g_pxmRhStH2!=INVALID_HANDLE) { IndicatorRelease(g_pxmRhStH2); g_pxmRhStH2=INVALID_HANDLE; }
}

void PXM_RehearseFinish()
{
   if(!g_pxmRhActive) return;
   g_pxmRhActive=false;
   g_pxmRhDone=g_pxmRhTotal;
   PXM_RehearseReleaseHandles();
   GlobalVariableSet(PXM_GV("rehearseDone"),1.0);
   Print("PREDICT-X MEM: rehearsal finished - ",g_pxmRhRows," historical outcomes added, bank now ",g_pxmCount," rows / ",g_pxmResolved," resolved.");
   ChartRedraw(0);
}

//--- single OnDeinit entry point: PXM_ objects, rehearsal handles, memory file
void PXM_OnDeinitCleanup()
{
   PXM_DeleteObjects();
   PXM_RehearseReleaseHandles();
   PXM_Cleanup();
}

//--- called from OnTimer only. Never touches live scoring/trading state.
void PXM_RehearsePump(const int hST,const int hRSI,const int hADX,const int hATR14,const int hATR100,const int hKC,const int hTTM,const PX_Preset &base)
{
   if(!InpPXM_Enable || !InpPXM_Rehearse) return;
   if(!g_pxmRhActive)
   {
      // auto-(re)start when history finished loading after init
      if(!GlobalVariableCheck(PXM_GV("rehearseDone")) && g_pxmFile>=0 && iBars(_Symbol,_Period)>PXM_SIM_BARS+30)
         PXM_RehearseStart(base);
      if(!g_pxmRhActive) return;
   }
   long t0=(long)GetMicrosecondCount();
   int processed=0;
   int avail=iBars(_Symbol,_Period);
   while(g_pxmRhActive && processed<InpPXM_RehearsePerPass && ((long)GetMicrosecondCount()-t0)<PXM_RH_BUDGET_US)
   {
      int b=g_pxmRhCursor;
      if(b<g_pxmRhBMin) break;
      if(b+PXM_RH_MIN_BARS<=avail)
         PXM_RhProcessBar(b,hST,hRSI,hADX,hATR14,hATR100,hKC,hTTM,base);
      g_pxmRhCursor--;
      processed++;
      if(g_pxmRhCursor<g_pxmRhBMin) break;
      if(((long)GetMicrosecondCount()-t0)>=PXM_RH_BUDGET_US) break;
   }
   g_pxmRhDone+=processed;
   if(g_pxmRhTotal>0)
   {
      int pct=(int)MathRound(100.0*g_pxmRhDone/(double)g_pxmRhTotal);
      if(pct>=g_pxmRhPrintPct+25)
      {
         g_pxmRhPrintPct=pct;
         Print("PREDICT-X MEM: rehearsal ",pct,"% (bank rows ",g_pxmCount,").");
      }
   }
   if(g_pxmRhCursor<g_pxmRhBMin) PXM_RehearseFinish();
}

#endif
//+------------------------------------------------------------------+

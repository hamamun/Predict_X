// PREDICT-X v2.00  -  PX_MarketRegime.mqh
#ifndef __PX_MARKETREGIME_MQH__
#define __PX_MARKETREGIME_MQH__
#include "PX_AutoPreset.mqh"

enum PX_Regime
{
   PX_REGIME_STRONG_TREND=0,
   PX_REGIME_VOLATILE_TREND=1,
   PX_REGIME_NORMAL=2,
   PX_REGIME_CALM=3,
   PX_REGIME_CHOPPY=4,
   PX_REGIME_DANGEROUS=5
};

struct PX_RegimeState
{
   PX_Regime regime;
   double er;
   double atrRatio;
   double adx;
   string name;
   string adjustments;
   color  clr;
   PX_Preset adjusted;
   double lotFactor;
   bool blockSignals;
};

double PX_KaufmanER(const string symbol, ENUM_TIMEFRAMES tf, int lookback, int shift=1)
{
   double close[]; ArraySetAsSeries(close,true);
   if(CopyClose(symbol,tf,shift,lookback+1,close)<lookback+1) return 0.0;
   double net=MathAbs(close[0]-close[lookback]);
   double denom=0.0;
   for(int i=0;i<lookback;i++) denom+=MathAbs(close[i]-close[i+1]);
   if(denom<=0.0) return 0.0;
   return net/denom;
}

void PX_ApplyRegimeAdjustments(const PX_Preset &base, PX_RegimeState &s)
{
   s.adjusted=base;
   s.lotFactor=1.0;
   s.blockSignals=false;
   s.adjustments="Standard preset values";

   if(s.regime==PX_REGIME_STRONG_TREND)
   {
      s.adjusted.stMultiplier=MathMax(0.5,base.stMultiplier-0.2);
      s.adjusted.minScore=MathMax(0,base.minScore-5);
      s.lotFactor=1.0;
      s.adjustments="Tight ST, full lots, MinScore-5";
   }
   else if(s.regime==PX_REGIME_VOLATILE_TREND)
   {
      s.adjusted.slATRMult=base.slATRMult+0.5;
      s.adjusted.minScore=base.minScore+5;
      s.lotFactor=0.8;
      s.adjustments="Wider SL, lots -20%, MinScore+5";
   }
   else if(s.regime==PX_REGIME_CALM)
   {
      s.adjusted.slATRMult=base.slATRMult+0.5;
      s.adjusted.rsiPeriod=MathMax(2,base.rsiPeriod-2);
      s.lotFactor=0.85;
      s.adjustments="Wider SL, lots -15%, faster RSI";
   }
   else if(s.regime==PX_REGIME_CHOPPY)
   {
      s.adjusted.stMultiplier=base.stMultiplier+0.5;
      s.adjusted.minScore=base.minScore+10;
      s.adjusted.rsiOB=base.rsiOB+5;
      s.adjusted.rsiOS=base.rsiOS-5;
      s.adjusted.rsiPeriod=base.rsiPeriod+2;
      s.lotFactor=0.7;
      s.adjustments="Wide ST, lots -30%, MinScore+10, wider RSI";
   }
   else if(s.regime==PX_REGIME_DANGEROUS)
   {
      s.blockSignals=true;
      s.lotFactor=0.0;
      s.adjustments="STOP TRADING - dangerous volatility/chop";
   }
}

void PX_ClassifyRegime(const PX_Preset &base, double er, double atrRatio, double adx, PX_RegimeState &s)
{
   s.er=er; s.atrRatio=atrRatio; s.adx=adx;
   if(er<0.15 || atrRatio>2.0)
   {
      s.regime=PX_REGIME_DANGEROUS; s.name="DANGEROUS / EVENT"; s.clr=clrRed;
   }
   else if(er>0.6 && adx>30.0 && atrRatio>=0.7 && atrRatio<=1.3)
   {
      s.regime=PX_REGIME_STRONG_TREND; s.name="STRONG TREND"; s.clr=clrLimeGreen;
   }
   else if(er>0.6 && adx>25.0 && atrRatio>1.3)
   {
      s.regime=PX_REGIME_VOLATILE_TREND; s.name="VOLATILE TREND"; s.clr=clrGold;
   }
   else if(er>=0.3 && er<=0.6 && atrRatio<0.7)
   {
      s.regime=PX_REGIME_CALM; s.name="CALM"; s.clr=clrDodgerBlue;
   }
   else if(er<0.3 && adx<20.0)
   {
      s.regime=PX_REGIME_CHOPPY; s.name="CHOPPY / SIDEWAYS"; s.clr=clrTomato;
   }
   else
   {
      s.regime=PX_REGIME_NORMAL; s.name="NORMAL"; s.clr=clrWhite;
   }
   PX_ApplyRegimeAdjustments(base,s);
}

#endif

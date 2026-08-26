#ifndef __PX_CANDLECONFIRM_MQH__
#define __PX_CANDLECONFIRM_MQH__

#include "PX_Scoring.mqh"

// Lightweight closed-bar candlestick confirmation.
// Purpose: small +0..+5 bonus only. It supports the main score; it never creates
// trades alone and never subtracts points.

struct PX_CandleContext
{
   int points;
   bool opposite;
   string text;
};

double PX_Body(int shift)
{
   return MathAbs(iClose(_Symbol,_Period,shift)-iOpen(_Symbol,_Period,shift));
}

double PX_Range(int shift)
{
   return MathMax(_Point,iHigh(_Symbol,_Period,shift)-iLow(_Symbol,_Period,shift));
}

double PX_AvgBody(int startShift=2,int bars=10)
{
   double sum=0.0; int count=0;
   for(int i=startShift;i<startShift+bars;i++)
   {
      double b=PX_Body(i);
      if(b>0.0) { sum+=b; count++; }
   }
   return (count>0?sum/count:0.0);
}

bool PX_BullishCandle(int shift){ return iClose(_Symbol,_Period,shift)>iOpen(_Symbol,_Period,shift); }
bool PX_BearishCandle(int shift){ return iClose(_Symbol,_Period,shift)<iOpen(_Symbol,_Period,shift); }

bool PX_BullishEngulfing()
{
   double o1=iOpen(_Symbol,_Period,1), c1=iClose(_Symbol,_Period,1);
   double o2=iOpen(_Symbol,_Period,2), c2=iClose(_Symbol,_Period,2);
   return (c2<o2 && c1>o1 && c1>=o2 && o1<=c2);
}

bool PX_BearishEngulfing()
{
   double o1=iOpen(_Symbol,_Period,1), c1=iClose(_Symbol,_Period,1);
   double o2=iOpen(_Symbol,_Period,2), c2=iClose(_Symbol,_Period,2);
   return (c2>o2 && c1<o1 && c1<=o2 && o1>=c2);
}

bool PX_BullishPinHammer()
{
   double o=iOpen(_Symbol,_Period,1), c=iClose(_Symbol,_Period,1), h=iHigh(_Symbol,_Period,1), l=iLow(_Symbol,_Period,1);
   double body=MathMax(_Point,MathAbs(c-o));
   double lower=MathMin(o,c)-l;
   double upper=h-MathMax(o,c);
   return (lower>=2.0*body && upper<=1.2*body && c>l+0.55*(h-l));
}

bool PX_BearishPinShootingStar()
{
   double o=iOpen(_Symbol,_Period,1), c=iClose(_Symbol,_Period,1), h=iHigh(_Symbol,_Period,1), l=iLow(_Symbol,_Period,1);
   double body=MathMax(_Point,MathAbs(c-o));
   double upper=h-MathMax(o,c);
   double lower=MathMin(o,c)-l;
   return (upper>=2.0*body && lower<=1.2*body && c<l+0.45*(h-l));
}

bool PX_MorningStar()
{
   return (PX_BearishCandle(3) && PX_Body(2)<0.7*PX_Body(3) && PX_BullishCandle(1) && iClose(_Symbol,_Period,1)>(iOpen(_Symbol,_Period,3)+iClose(_Symbol,_Period,3))/2.0);
}

bool PX_EveningStar()
{
   return (PX_BullishCandle(3) && PX_Body(2)<0.7*PX_Body(3) && PX_BearishCandle(1) && iClose(_Symbol,_Period,1)<(iOpen(_Symbol,_Period,3)+iClose(_Symbol,_Period,3))/2.0);
}

bool PX_StrongBullishClose()
{
   double avg=PX_AvgBody(2,10);
   double h=iHigh(_Symbol,_Period,1), l=iLow(_Symbol,_Period,1), c=iClose(_Symbol,_Period,1);
   return (PX_BullishCandle(1) && PX_Body(1)>=1.15*avg && c>=l+0.70*(h-l));
}

bool PX_StrongBearishClose()
{
   double avg=PX_AvgBody(2,10);
   double h=iHigh(_Symbol,_Period,1), l=iLow(_Symbol,_Period,1), c=iClose(_Symbol,_Period,1);
   return (PX_BearishCandle(1) && PX_Body(1)>=1.15*avg && c<=l+0.30*(h-l));
}

int PX_CandleConfirmationScore(PX_Direction dir,double price,double vwap,double atr,double obTop,double obBottom,bool hasOB,PX_CandleContext &ctx)
{
   ctx.points=0; ctx.opposite=false; ctx.text="no pattern";
   if(dir==PX_DIR_NONE || atr<=0.0) return 0;

   bool buy=(dir==PX_DIR_BUY);
   int pts=0;
   string reason="";
   bool opposite=false;

   if(buy)
   {
      if(PX_MorningStar()) { pts=MathMax(pts,4); reason="morning star"; }
      if(PX_BullishEngulfing()) { pts=MathMax(pts,3); reason="bullish engulfing"; }
      if(PX_BullishPinHammer()) { pts=MathMax(pts,2); reason=(reason==""?"hammer/pin rejection":reason); }
      if(PX_StrongBullishClose()) { pts=MathMax(pts,2); reason=(reason==""?"strong bullish close":reason); }
      if(PX_BearishEngulfing() || PX_EveningStar() || PX_BearishPinShootingStar()) opposite=true;
   }
   else
   {
      if(PX_EveningStar()) { pts=MathMax(pts,4); reason="evening star"; }
      if(PX_BearishEngulfing()) { pts=MathMax(pts,3); reason="bearish engulfing"; }
      if(PX_BearishPinShootingStar()) { pts=MathMax(pts,2); reason=(reason==""?"shooting star/pin":reason); }
      if(PX_StrongBearishClose()) { pts=MathMax(pts,2); reason=(reason==""?"strong bearish close":reason); }
      if(PX_BullishEngulfing() || PX_MorningStar() || PX_BullishPinHammer()) opposite=true;
   }

   if(opposite)
   {
      ctx.opposite=true;
      ctx.text="opposite candle warning";
      ctx.points=0;
      return 0;
   }

   if(pts>0)
   {
      bool nearValue=(MathAbs(price-vwap)<=0.35*atr);
      if(hasOB)
      {
         if(buy && price>=obBottom-0.35*atr && price<=obTop+0.35*atr) nearValue=true;
         if(!buy && price>=obBottom-0.35*atr && price<=obTop+0.35*atr) nearValue=true;
      }
      if(nearValue) pts+=1;
   }

   if(pts>5) pts=5;
   ctx.points=pts;
   ctx.text=(pts>0 ? reason+(pts>=5?" + value":"") : "no confirmation");
   return pts;
}

#endif

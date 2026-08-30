// PREDICT-X v2.00  -  PX_Layer1_SMC.mqh
#ifndef __PX_LAYER1_SMC_MQH__
#define __PX_LAYER1_SMC_MQH__
#include "PX_Scoring.mqh"

struct PX_SMCLevels
{
   double orderBlockTop;
   double orderBlockBottom;
   bool hasOB;
   bool hasFVG;
   bool hasSweep;
};

double PX_HighestHigh(const string symbol,ENUM_TIMEFRAMES tf,int startShift,int count)
{
   double high[]; ArraySetAsSeries(high,true);
   if(CopyHigh(symbol,tf,startShift,count,high)<count) return 0.0;
   double v=high[0]; for(int i=1;i<count;i++) if(high[i]>v) v=high[i]; return v;
}

double PX_LowestLow(const string symbol,ENUM_TIMEFRAMES tf,int startShift,int count)
{
   double low[]; ArraySetAsSeries(low,true);
   if(CopyLow(symbol,tf,startShift,count,low)<count) return 0.0;
   double v=low[0]; for(int i=1;i<count;i++) if(low[i]<v) v=low[i]; return v;
}

int PX_ScoreLayer1(const string symbol,ENUM_TIMEFRAMES tf,const PX_Direction dir,double price,double atr,PX_SMCLevels &levels,PX_ScoreDetail &d)
{
   PX_ResetDetail(d,"SMART MONEY",25);
   levels.hasOB=false; levels.hasFVG=false; levels.hasSweep=false; levels.orderBlockTop=0; levels.orderBlockBottom=0;
   bool buy=(dir==PX_DIR_BUY);
   int pts=0;

   double h1=iHigh(symbol,tf,1), l1=iLow(symbol,tf,1), c1=iClose(symbol,tf,1), o1=iOpen(symbol,tf,1);
   double prevHigh=PX_HighestHigh(symbol,tf,2,10);
   double prevLow=PX_LowestLow(symbol,tf,2,10);
   int sweepPts=0;
   if(buy)
   {
      if(l1<prevLow && c1>prevLow) { sweepPts=8; levels.hasSweep=true; }
      else if(MathAbs(l1-prevLow)<=0.2*atr) sweepPts=4;
   }
   else
   {
      if(h1>prevHigh && c1<prevHigh) { sweepPts=8; levels.hasSweep=true; }
      else if(MathAbs(h1-prevHigh)<=0.2*atr) sweepPts=4;
   }
   pts+=sweepPts; PX_AddDetail(d,StringFormat("Liq Sweep +%dpts",sweepPts));

   int obPts=0;
   for(int i=2;i<30;i++)
   {
      double o=iOpen(symbol,tf,i), c=iClose(symbol,tf,i), h=iHigh(symbol,tf,i), l=iLow(symbol,tf,i);
      double nC=iClose(symbol,tf,i-1);
      bool impulse=(MathAbs(nC-c)>0.8*atr);
      if(buy && c<o && impulse && nC>c)
      {
         levels.hasOB=true; levels.orderBlockTop=h; levels.orderBlockBottom=l;
         if(price>=l-0.5*atr && price<=h+0.5*atr) obPts=7; else obPts=3;
         break;
      }
      if(!buy && c>o && impulse && nC<c)
      {
         levels.hasOB=true; levels.orderBlockTop=h; levels.orderBlockBottom=l;
         if(price>=l-0.5*atr && price<=h+0.5*atr) obPts=7; else obPts=3;
         break;
      }
   }
   pts+=obPts; PX_AddDetail(d,StringFormat("Order Block +%dpts",obPts));

   int fvgPts=0;
   for(int i=1;i<20;i++)
   {
      double hOld=iHigh(symbol,tf,i+2), lOld=iLow(symbol,tf,i+2);
      double hNew=iHigh(symbol,tf,i), lNew=iLow(symbol,tf,i);
      if(buy && lNew>hOld) { fvgPts=5; levels.hasFVG=true; break; }
      if(!buy && hNew<lOld) { fvgPts=5; levels.hasFVG=true; break; }
   }
   pts+=fvgPts; PX_AddDetail(d,StringFormat("FVG +%dpts",fvgPts));

   int align=(levels.hasSweep?1:0)+(levels.hasOB?1:0)+(levels.hasFVG?1:0);
   int bonus=(align==3?5:(align==2?2:0)); pts+=bonus;
   PX_AddDetail(d,StringFormat("SMC Bonus +%dpts (%d/3 align)",bonus,align));

   d.points=pts;
   return pts;
}

#endif

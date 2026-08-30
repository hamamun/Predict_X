// PREDICT-X v2.00  -  PX_Layer2_Trend.mqh
#ifndef __PX_LAYER2_TREND_MQH__
#define __PX_LAYER2_TREND_MQH__
#include "PX_Scoring.mqh"

struct PX_TrendContext
{
   double stLine;
   int stDir;
   double rsi;
   double rsiPrev;
   double ttmHist;
   double ttmHistPrev;
   double ttmSqueeze;
   double ttmFiredDir;
   double adx;
};

int PX_ScoreLayer2(const PX_Direction dir,const PX_TrendContext &c,PX_ScoreDetail &d)
{
   PX_ResetDetail(d,"TREND/MOM",25);
   int pts=0;
   bool buy=(dir==PX_DIR_BUY);
   if((buy && c.stDir>0) || (!buy && c.stDir<0)) { pts+=8; PX_AddDetail(d,"SuperTrend +8pts (matches)"); }
   else PX_AddDetail(d,"SuperTrend +0pts (opposite/flat)");

   int rsiPts=0;
   if(buy)
   {
      if(c.rsi>=40 && c.rsi<=70 && c.rsi>=c.rsiPrev) rsiPts=6;
      else if(c.rsi>=30 && c.rsi<40) rsiPts=4;
      else if(c.rsi>75) rsiPts=-2;
      else if(c.rsi<30) rsiPts=2;
   }
   else
   {
      if(c.rsi>=30 && c.rsi<=60 && c.rsi<=c.rsiPrev) rsiPts=6;
      else if(c.rsi>60 && c.rsi<=70) rsiPts=4;
      else if(c.rsi<25) rsiPts=-2;
      else if(c.rsi>70) rsiPts=2;
   }
   pts+=rsiPts; PX_AddDetail(d,StringFormat("RSI %+dpts (%.1f)",rsiPts,c.rsi));

   int sqzPts=0;
   bool histAgree=(buy && c.ttmHist>0.0) || (!buy && c.ttmHist<0.0);
   bool firedAgree=(buy && c.ttmFiredDir>0.0) || (!buy && c.ttmFiredDir<0.0);
   if(firedAgree && histAgree) sqzPts=6;
   else if(c.ttmSqueeze>0.5) sqzPts=2;
   pts+=sqzPts; PX_AddDetail(d,StringFormat("TTM Squeeze +%dpts (hist %.5f)",sqzPts,c.ttmHist));

   int adxPts=0;
   if(c.adx>35) adxPts=5; else if(c.adx>=25) adxPts=3; else if(c.adx>=20) adxPts=1;
   pts+=adxPts; PX_AddDetail(d,StringFormat("ADX +%dpts (%.1f)",adxPts,c.adx));

   if(pts<0) pts=0;
   d.points=pts;
   return pts;
}

#endif

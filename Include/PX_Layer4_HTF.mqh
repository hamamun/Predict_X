#ifndef __PX_LAYER4_HTF_MQH__
#define __PX_LAYER4_HTF_MQH__
#include "PX_Scoring.mqh"
#include "PX_AutoPreset.mqh"
#include "PX_Layer3_Value.mqh"

int PX_GetSTDir(const string symbol, ENUM_TIMEFRAMES tf, int stPeriod, double stMult)
{
   int h=iCustom(symbol,tf,"PREDICT-X\\Indicators\\SuperTrend",stPeriod,stMult);
   if(h==INVALID_HANDLE) h=iCustom(symbol,tf,"SuperTrend",stPeriod,stMult);
   if(h==INVALID_HANDLE) return 0;
   double dir[]; ArraySetAsSeries(dir,true);
   int copied=CopyBuffer(h,1,1,1,dir);
   IndicatorRelease(h);
   if(copied<1) return 0;
   return (dir[0]>0.0?1:(dir[0]<0.0?-1:0));
}

int PX_ScoreLayer4(const string symbol,const PX_Direction dir,ENUM_TIMEFRAMES htf1,ENUM_TIMEFRAMES htf2,int stPeriod,double stMult,PX_ScoreDetail &d)
{
   PX_ResetDetail(d,"HTF CONFLUENCE",15);
   bool buy=(dir==PX_DIR_BUY);
   int total=0;

   int st1=PX_GetSTDir(symbol,htf1,stPeriod,stMult);
   double close1=iClose(symbol,htf1,1);
   double vwap1=PX_CalcVWAP(symbol,htf1,1);
   int agree1=0;
   if((buy && st1>0)||(!buy && st1<0)) agree1++;
   if((buy && close1>vwap1)||(!buy && close1<vwap1)) agree1++;
   int p1=(agree1==2?7:(agree1==1?3:0)); total+=p1;
   PX_AddDetail(d,StringFormat("%s ST+VWAP +%dpts (%d/2 agree)",PX_TFToString(htf1),p1,agree1));

   int st2=PX_GetSTDir(symbol,htf2,stPeriod,stMult);
   double close2=iClose(symbol,htf2,1);
   double vwap2=PX_CalcVWAP(symbol,htf2,1);
   int agree2=0;
   if((buy && st2>0)||(!buy && st2<0)) agree2++;
   if((buy && close2>vwap2)||(!buy && close2<vwap2)) agree2++;
   int p2=(agree2==2?8:(agree2==1?4:0)); total+=p2;
   PX_AddDetail(d,StringFormat("%s ST+VWAP +%dpts (%d/2 agree)",PX_TFToString(htf2),p2,agree2));

   d.points=total;
   return total;
}

#endif

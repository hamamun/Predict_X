#ifndef __PX_LAYER3_VALUE_MQH__
#define __PX_LAYER3_VALUE_MQH__
#include "PX_Scoring.mqh"

enum PX_SessionFilter { PX_SESSION_ASIA=0, PX_SESSION_LONDON=1, PX_SESSION_NEWYORK=2, PX_SESSION_ALL=3 };

struct PX_ValueContext
{
   double price;
   double vwap;
   double kcUpper;
   double kcMiddle;
   double kcLower;
   double atr;
   double spreadPoints;
   double avgSpreadPoints;
   bool tickValid;
   bool dataReady;
   string sessionName;
   bool sessionActive;
   bool spreadBlocked;
};

bool PX_InHourRange(int h,int start,int end)
{
   if(start<end) return (h>=start && h<end);
   return (h>=start || h<end);
}

string PX_CurrentSessionName(datetime t)
{
   MqlDateTime dt; TimeToStruct(t,dt);
   bool london=PX_InHourRange(dt.hour,7,16);
   bool ny=PX_InHourRange(dt.hour,12,21);
   bool asia=PX_InHourRange(dt.hour,0,8);
   if(london && ny) return "London-NY Overlap";
   if(london) return "London";
   if(ny) return "New York";
   if(asia) return "Asia";
   return "Off-session";
}

bool PX_SessionAllowed(PX_SessionFilter filter, datetime t)
{
   if(filter==PX_SESSION_ALL) return true;
   MqlDateTime dt; TimeToStruct(t,dt);
   if(filter==PX_SESSION_ASIA) return PX_InHourRange(dt.hour,0,8);
   if(filter==PX_SESSION_LONDON) return PX_InHourRange(dt.hour,7,16);
   if(filter==PX_SESSION_NEWYORK) return PX_InHourRange(dt.hour,12,21);
   return true;
}

double PX_CalcVWAP(const string symbol,ENUM_TIMEFRAMES tf,int shift=1)
{
   MqlRates rates[]; ArraySetAsSeries(rates,true);
   int copied=CopyRates(symbol,tf,shift,500,rates);
   if(copied<=0) return 0.0;
   datetime barTime=rates[0].time;
   MqlDateTime dt; TimeToStruct(barTime,dt);
   // NY 17:00 institutional reset, approximated in broker/server time as 17:00.
   MqlDateTime reset=dt;
   if(dt.hour<17) { datetime prev=barTime-86400; TimeToStruct(prev,reset); }
   reset.hour=17; reset.min=0; reset.sec=0;
   datetime resetTime=StructToTime(reset);
   double pv=0.0, vv=0.0;
   for(int i=0;i<copied;i++)
   {
      if(rates[i].time<resetTime) break;
      double typical=(rates[i].high+rates[i].low+rates[i].close)/3.0;
      double vol=(rates[i].real_volume>0 ? (double)rates[i].real_volume : (double)rates[i].tick_volume);
      pv+=typical*vol; vv+=vol;
   }
   if(vv<=0.0) return rates[0].close;
   return pv/vv;
}

int PX_ScoreLayer3(const PX_Direction dir,const PX_ValueContext &c,PX_ScoreDetail &d)
{
   PX_ResetDetail(d,"INST VALUE/VOL",20);
   int pts=0; bool buy=(dir==PX_DIR_BUY);

   int vwapPts=0;
   if(buy)
   {
      if(c.price>c.vwap) vwapPts=5;
      else if(MathAbs(c.price-c.vwap)<=0.2*c.atr) vwapPts=3;
   }
   else
   {
      if(c.price<c.vwap) vwapPts=5;
      else if(MathAbs(c.price-c.vwap)<=0.2*c.atr) vwapPts=3;
   }
   pts+=vwapPts; PX_AddDetail(d,StringFormat("VWAP +%dpts (%.5f)",vwapPts,c.vwap));

   int kcPts=0;
   if(c.kcUpper>c.kcLower)
   {
      if(buy)
      {
         if(c.price>=c.kcMiddle) kcPts=5;
         else if(MathAbs(c.price-c.kcMiddle)<=0.2*c.atr) kcPts=2;
      }
      else
      {
         if(c.price<=c.kcMiddle) kcPts=5;
         else if(MathAbs(c.price-c.kcMiddle)<=0.2*c.atr) kcPts=2;
      }
   }
   pts+=kcPts; PX_AddDetail(d,StringFormat("Keltner +%dpts",kcPts));

   int sessPts=c.sessionActive?5:0; pts+=sessPts;
   PX_AddDetail(d,StringFormat("Session +%dpts (%s)",sessPts,c.sessionName));

   int sprPts=0;
   if(!c.tickValid)
   {
      PX_AddDetail(d,"Spread +0pts (invalid/no live tick)");
   }
   else
   {
      if(c.avgSpreadPoints<=0 || c.spreadPoints<=c.avgSpreadPoints) sprPts=5;
      else if(c.spreadPoints<=2.0*c.avgSpreadPoints) sprPts=2;
      pts+=sprPts;
      PX_AddDetail(d,StringFormat("Spread +%dpts (%.1f pts, avg %.1f)",sprPts,c.spreadPoints,c.avgSpreadPoints));
   }

   d.points=pts;
   return pts;
}

#endif

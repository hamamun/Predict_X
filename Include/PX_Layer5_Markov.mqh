#ifndef __PX_LAYER5_MARKOV_MQH__
#define __PX_LAYER5_MARKOV_MQH__
#include "PX_Scoring.mqh"

int PX_StateFromChange(double change,double threshold)
{
   if(change>threshold) return 0;       // UP
   if(change<-threshold) return 2;      // DOWN
   return 1;                            // NEUTRAL
}

int PX_ScoreLayer5(const string symbol,ENUM_TIMEFRAMES tf,const PX_Direction dir,double atr,PX_ScoreDetail &d,double &probUp,double &probNeutral,double &probDown,int &predState)
{
   PX_ResetDetail(d,"MARKOV STATE",15);
   probUp=probNeutral=probDown=0; predState=1;
   double close[]; ArraySetAsSeries(close,true);
   if(CopyClose(symbol,tf,1,102,close)<102 || atr<=0)
   {
      PX_AddDetail(d,"Insufficient data +0pts"); return 0;
   }
   int counts[3][3];
   for(int a=0;a<3;a++) for(int b=0;b<3;b++) counts[a][b]=0;
   double th=0.4*atr;
   int states[101];
   for(int i=0;i<101;i++) states[i]=PX_StateFromChange(close[i]-close[i+1],th);
   for(int i=100;i>=1;i--) counts[states[i]][states[i-1]]++;
   int cur=states[0];
   int rowSum=counts[cur][0]+counts[cur][1]+counts[cur][2];
   if(rowSum<=0) { PX_AddDetail(d,"No transitions +0pts"); return 0; }
   probUp=(double)counts[cur][0]/rowSum;
   probNeutral=(double)counts[cur][1]/rowSum;
   probDown=(double)counts[cur][2]/rowSum;
   predState=0; double best=probUp;
   if(probNeutral>best) { best=probNeutral; predState=1; }
   if(probDown>best) { best=probDown; predState=2; }
   int pts=0;
   bool match=(dir==PX_DIR_BUY && predState==0) || (dir==PX_DIR_SELL && predState==2);
   if(match)
   {
      if(best>0.60) pts=15; else if(best>=0.50) pts=10; else if(best>=0.40) pts=5;
   }
   else if(predState==1) pts=3;
   PX_AddDetail(d,StringFormat("P(Up)=%.2f P(N)=%.2f P(Dn)=%.2f +%dpts",probUp,probNeutral,probDown,pts));
   d.points=pts;
   return pts;
}

#endif

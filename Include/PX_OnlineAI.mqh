// PREDICT-X v2.00  -  PX_OnlineAI.mqh
#ifndef __PX_ONLINEAI_MQH__
#define __PX_ONLINEAI_MQH__

#include "PX_Scoring.mqh"
#include "PX_Layer6_Neural.mqh"

// Phase 3 revised: online AI confidence model.
// This module is now a simple online AI confidence model trained only from the
// chart-symbol PREDICT-X signals. It is transparent, native MQL5, and does not
// depend on multi-symbol scanner data.

#define PX3_MAX_HISTORY 200
#define PX3_FEATURES 12

struct PX3_HistoryItem
{
   datetime signalTime;
   string symbol;
   ENUM_TIMEFRAMES tf;
   PX_Direction dir;
   int score;
   PX_Tier tier;
   string entryMethod;
   double signalClose;
   double x[PX3_FEATURES];
   bool evaluated;
   bool correct;
};

struct PX3_OnlineAI
{
   int samples;
   int correct;
   double w[PX3_FEATURES];
   double bias;
   double lastProbability;
};

PX3_HistoryItem g_px3History[PX3_MAX_HISTORY];
int g_px3HistoryCount=0;
PX3_OnlineAI g_px3AI;

string PX3_Key(string suffix)
{
   return "PREDICTX.ONLINEAI."+_Symbol+"."+suffix;
}

double PX3_Sigmoid(double z)
{
   if(z>40.0) return 1.0;
   if(z<-40.0) return 0.0;
   return 1.0/(1.0+MathExp(-z));
}

void PX3_NormalizeFeatures(const double &features[],PX_Direction dir,double &x[])
{
   ArrayResize(x,PX3_FEATURES);
   x[0]=MathMax(0.0,MathMin(1.0,features[0]/100.0)); // pre-AI total
   x[1]=MathMax(0.0,MathMin(1.0,features[1]/25.0));
   x[2]=MathMax(0.0,MathMin(1.0,features[2]/25.0));
   x[3]=MathMax(0.0,MathMin(1.0,features[3]/20.0));
   x[4]=MathMax(0.0,MathMin(1.0,features[4]/15.0));
   x[5]=MathMax(0.0,MathMin(1.0,features[5]/15.0));
   x[6]=MathMax(0.0,MathMin(1.0,features[6]));       // ER
   x[7]=MathMax(0.0,MathMin(1.0,features[7]/2.0));    // ATR ratio capped
   x[8]=MathMax(0.0,MathMin(1.0,features[8]/50.0));   // ADX
   x[9]=MathMax(0.0,MathMin(1.0,features[9]/100.0));  // RSI
   double stDir=features[10];
   x[10]=(dir==PX_DIR_NONE?0.0:(stDir*(double)dir));   // +1 ST agrees, -1 disagrees
   x[11]=MathMax(0.0,MathMin(1.0,features[11]));      // squeeze active/status
}

double PX3_AIProbability(const double &x[])
{
   double z=g_px3AI.bias;
   for(int i=0;i<PX3_FEATURES;i++) z+=g_px3AI.w[i]*x[i];
   return PX3_Sigmoid(z);
}

void PX3_SaveAI()
{
   GlobalVariableSet(PX3_Key("samples"),g_px3AI.samples);
   GlobalVariableSet(PX3_Key("correct"),g_px3AI.correct);
   GlobalVariableSet(PX3_Key("bias"),g_px3AI.bias);
   for(int i=0;i<PX3_FEATURES;i++) GlobalVariableSet(PX3_Key("w"+IntegerToString(i)),g_px3AI.w[i]);
}

void PX3_LoadAI()
{
   g_px3AI.samples=(GlobalVariableCheck(PX3_Key("samples"))?(int)GlobalVariableGet(PX3_Key("samples")):0);
   g_px3AI.correct=(GlobalVariableCheck(PX3_Key("correct"))?(int)GlobalVariableGet(PX3_Key("correct")):0);
   g_px3AI.bias=(GlobalVariableCheck(PX3_Key("bias"))?GlobalVariableGet(PX3_Key("bias")):0.0);
   g_px3AI.lastProbability=0.5;
   for(int i=0;i<PX3_FEATURES;i++)
      g_px3AI.w[i]=(GlobalVariableCheck(PX3_Key("w"+IntegerToString(i)))?GlobalVariableGet(PX3_Key("w"+IntegerToString(i))):0.0);
}

void PX3_Init()
{
   PX3_LoadAI();
}

void PX3_DeleteObjects()
{
   // No separate AI/scanner panel now. Keep function for safe OnDeinit compatibility.
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
   {
      string name=ObjectName(0,i);
      if(StringFind(name,"PX3_")==0) ObjectDelete(0,name);
   }
}

void PX3_AddHistory(datetime signalTime,string symbol,ENUM_TIMEFRAMES tf,PX_Direction dir,int score,PX_Tier tier,string entryMethod,const double &features[])
{
   if(dir==PX_DIR_NONE || tier<PX_TIER_MEDIUM) return;
   for(int i=0;i<g_px3HistoryCount;i++)
      if(g_px3History[i].signalTime==signalTime && g_px3History[i].symbol==symbol && g_px3History[i].tf==tf) return;

   if(g_px3HistoryCount>=PX3_MAX_HISTORY)
   {
      for(int i=1;i<PX3_MAX_HISTORY;i++) g_px3History[i-1]=g_px3History[i];
      g_px3HistoryCount=PX3_MAX_HISTORY-1;
   }

   int idx=g_px3HistoryCount++;
   g_px3History[idx].signalTime=signalTime;
   g_px3History[idx].symbol=symbol;
   g_px3History[idx].tf=tf;
   g_px3History[idx].dir=dir;
   g_px3History[idx].score=score;
   g_px3History[idx].tier=tier;
   g_px3History[idx].entryMethod=entryMethod;
   g_px3History[idx].signalClose=iClose(symbol,tf,1);
   g_px3History[idx].evaluated=false;
   g_px3History[idx].correct=false;
   double nx[];
   PX3_NormalizeFeatures(features,dir,nx);
   for(int j=0;j<PX3_FEATURES;j++) g_px3History[idx].x[j]=nx[j];
}

void PX3_UpdateOnlineAI(const double &x[],bool correct)
{
   double y=(correct?1.0:0.0);
   double p=PX3_AIProbability(x);
   double err=y-p;
   double lr=0.05;
   // Slightly reduce learning rate after many samples for stability.
   if(g_px3AI.samples>200) lr=0.02;
   if(g_px3AI.samples>500) lr=0.01;
   g_px3AI.bias+=lr*err;
   for(int i=0;i<PX3_FEATURES;i++) g_px3AI.w[i]+=lr*err*x[i];
   g_px3AI.samples++;
   if(correct) g_px3AI.correct++;
   g_px3AI.lastProbability=p;
   PX3_SaveAI();
}

void PX3_EvaluateHistory(int horizonBars)
{
   if(horizonBars<1) horizonBars=3;
   for(int i=0;i<g_px3HistoryCount;i++)
   {
      if(g_px3History[i].evaluated) continue;
      int shift=iBarShift(g_px3History[i].symbol,g_px3History[i].tf,g_px3History[i].signalTime,true);
      if(shift<horizonBars+1) continue;
      double signalClose=iClose(g_px3History[i].symbol,g_px3History[i].tf,shift);
      double resultClose=iClose(g_px3History[i].symbol,g_px3History[i].tf,shift-horizonBars);
      if(signalClose<=0.0 || resultClose<=0.0) continue;
      bool correct=(g_px3History[i].dir==PX_DIR_BUY ? resultClose>signalClose : resultClose<signalClose);
      g_px3History[i].evaluated=true;
      g_px3History[i].correct=correct;
      PX3_UpdateOnlineAI(g_px3History[i].x,correct);
   }
}

double PX3_Accuracy()
{
   if(g_px3AI.samples<=0) return 0.0;
   return (double)g_px3AI.correct/g_px3AI.samples;
}

void PX3_PrepareAI(PX_NeuralState &n,PX_Direction dir,PX_Tier tier,const double &features[])
{
   if(g_px3AI.samples<20)
   {
      PX_NeuralSetLearning(n,StringFormat("ONLINE AI LEARNING %d/20",g_px3AI.samples));
      return;
   }
   double x[];
   PX3_NormalizeFeatures(features,dir,x);
   double p=PX3_AIProbability(x); // probability current signal direction will be correct
   g_px3AI.lastProbability=p;

   if(p>=0.55)
   {
      double out=(dir==PX_DIR_BUY?p:1.0-p);
      PX_NeuralSetTrackerSignal(n,out,StringFormat("ONLINE AI %.0f%%",p*100.0));
   }
   else if(p<=0.45)
   {
      // AI thinks the current signal is weak/wrong. Make AI direction opposite so it gives 0 bonus.
      double opp=1.0-p;
      double out=(dir==PX_DIR_BUY?1.0-opp:opp);
      PX_NeuralSetTrackerSignal(n,out,StringFormat("ONLINE AI CAUTION %.0f%%",opp*100.0));
   }
   else
   {
      PX_NeuralSetLearning(n,StringFormat("ONLINE AI NEUTRAL %.0f%%",p*100.0));
   }
}

#endif

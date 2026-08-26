#ifndef __PX_LAYER6_NEURAL_MQH__
#define __PX_LAYER6_NEURAL_MQH__
#include "PX_Scoring.mqh"

// Phase 3 AI confirmation module.
// AI is activated only after the prediction tracker has enough measured outcomes.
// It remains a confirmation/bonus layer only; it never creates trades alone and
// never subtracts points.
struct PX_NeuralState
{
   bool trained;
   datetime lastTrain;
   double weights[12];
   double bias;
   double output;        // 0..1, >0.5 BUY, <0.5 SELL
   string status;
};

void PX_NeuralInit(PX_NeuralState &n)
{
   n.trained=false; n.lastTrain=0; n.bias=0.0; n.output=0.5; n.status="AI LEARNING";
   for(int i=0;i<12;i++) n.weights[i]=0.0;
}

void PX_NeuralSetLearning(PX_NeuralState &n,string status="AI LEARNING")
{
   n.trained=false;
   n.output=0.5;
   n.status=status;
}

void PX_NeuralSetTrackerSignal(PX_NeuralState &n,double output,string status="TRACKER TRAINED")
{
   n.trained=true;
   n.output=MathMax(0.0,MathMin(1.0,output));
   n.status=status;
   n.lastTrain=TimeCurrent();
}

int PX_ScoreLayer6(PX_NeuralState &n,const PX_Direction confluenceDir,const double &features[],PX_ScoreDetail &d,double &confidence,PX_Direction &aiDir)
{
   PX_ResetDetail(d,"AI CONFIRM",10);
   if(!n.trained)
   {
      confidence=0.0;
      aiDir=PX_DIR_NONE;
      PX_AddDetail(d,n.status+" +0pts");
      d.points=0;
      return 0;
   }

   double out=n.output;
   aiDir=(out>=0.5?PX_DIR_BUY:PX_DIR_SELL);
   confidence=(out>=0.5?out:1.0-out);
   int pts=0;
   if(aiDir==confluenceDir)
   {
      if(confidence>0.70) pts=10;
      else if(confidence>=0.55) pts=5;
   }
   PX_AddDetail(d,StringFormat("%s %.0f%% %+dpts (%s)",PX_DirectionText(aiDir),confidence*100.0,pts,n.status));
   d.points=pts;
   return pts;
}

#endif

#ifndef __PX_SCORING_MQH__
#define __PX_SCORING_MQH__

enum PX_Direction { PX_DIR_NONE=0, PX_DIR_BUY=1, PX_DIR_SELL=-1 };
enum PX_Tier { PX_TIER_NO_TRADE=0, PX_TIER_WEAK=1, PX_TIER_MEDIUM=2, PX_TIER_STRONG=3, PX_TIER_VERY_STRONG=4 };

struct PX_ScoreDetail
{
   int points;
   int maxPoints;
   string title;
   string details[8];
   int detailCount;
};

struct PX_ScoreResult
{
   PX_Direction dir;
   int layer1,layer2,layer3,layer4,layer5,layer6,candleBonus,total;
   PX_Tier tier;
   bool spreadBlocked;
   string signalText;
};

void PX_ResetDetail(PX_ScoreDetail &d,string title,int maxp)
{
   d.points=0; d.maxPoints=maxp; d.title=title; d.detailCount=0;
   for(int i=0;i<8;i++) d.details[i]="";
}

void PX_AddDetail(PX_ScoreDetail &d,string line)
{
   if(d.detailCount<8) d.details[d.detailCount++]=line;
}

PX_Tier PX_ClassifyTier(int score)
{
   if(score>=85) return PX_TIER_VERY_STRONG;
   if(score>=70) return PX_TIER_STRONG;
   if(score>=55) return PX_TIER_MEDIUM;
   if(score>=40) return PX_TIER_WEAK;
   return PX_TIER_NO_TRADE;
}

string PX_TierText(PX_Tier t)
{
   if(t==PX_TIER_VERY_STRONG) return "VERY STRONG";
   if(t==PX_TIER_STRONG) return "STRONG";
   if(t==PX_TIER_MEDIUM) return "MEDIUM";
   if(t==PX_TIER_WEAK) return "WEAK";
   return "NO TRADE";
}

string PX_DirectionText(PX_Direction d)
{
   if(d==PX_DIR_BUY) return "BUY";
   if(d==PX_DIR_SELL) return "SELL";
   return "NONE";
}

int PX_AggregateScore(int l1,int l2,int l3,int l4,int l5,int l6,int candleBonus=0)
{
   int total=l1+l2+l3+l4+l5+l6+candleBonus;
   if(total>100) total=100;
   if(total<0) total=0;
   return total;
}

#endif

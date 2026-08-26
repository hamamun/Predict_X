#ifndef __PX_AUTOPRESET_MQH__
#define __PX_AUTOPRESET_MQH__

struct PX_Preset
{
   int      stPeriod;
   double   stMultiplier;
   int      rsiPeriod;
   double   rsiOB;
   double   rsiOS;
   int      ttmBBPeriod;
   double   ttmBBDev;
   int      ttmKCPeriod;
   double   ttmKCMult;
   int      adxPeriod;
   double   adxTrendThreshold;
   int      kcEMAPeriod;
   double   kcATRMult;
   ENUM_TIMEFRAMES htf1;
   ENUM_TIMEFRAMES htf2;
   double   slATRMult;
   double   tp1ATRMult;
   double   tp2ATRMult;
   int      atrPeriod;
   int      minScore;
   int      signalExpiryBars;
   bool     unsupportedTF;
   string   warning;
};

string PX_TFToString(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      default:         return EnumToString(tf);
   }
}

void PX_SetM15Preset(PX_Preset &p)
{
   p.stPeriod=10; p.stMultiplier=3.0;
   p.rsiPeriod=14; p.rsiOB=70; p.rsiOS=30;
   p.ttmBBPeriod=20; p.ttmBBDev=2.0; p.ttmKCPeriod=20; p.ttmKCMult=1.5;
   p.adxPeriod=14; p.adxTrendThreshold=25;
   p.kcEMAPeriod=20; p.kcATRMult=2.0;
   p.htf1=PERIOD_H1; p.htf2=PERIOD_H4;
   p.slATRMult=2.0; p.tp1ATRMult=1.5; p.tp2ATRMult=3.0;
   p.atrPeriod=14; p.minScore=55; p.signalExpiryBars=3;
   p.unsupportedTF=false; p.warning="";
}

void PX_LoadPreset(const ENUM_TIMEFRAMES chartTF, PX_Preset &p)
{
   PX_SetM15Preset(p);
   if(chartTF==PERIOD_M5)
   {
      p.stMultiplier=2.0;
      p.rsiPeriod=7; p.rsiOB=75; p.rsiOS=25;
      p.adxPeriod=10;
      p.htf1=PERIOD_M15; p.htf2=PERIOD_H1;
      p.slATRMult=1.5; p.tp2ATRMult=2.5;
      p.minScore=60;
   }
   else if(chartTF==PERIOD_M15)
   {
      // already M15 preset
   }
   else if(chartTF==PERIOD_M30)
   {
      p.htf1=PERIOD_H1; p.htf2=PERIOD_H4;
   }
   else
   {
      p.unsupportedTF=true;
      p.htf1=PERIOD_H4; p.htf2=PERIOD_D1;
      p.warning="Unsupported TF "+PX_TFToString(chartTF)+"; using M15 preset.";
   }
}

#endif

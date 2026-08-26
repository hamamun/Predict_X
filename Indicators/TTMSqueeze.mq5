#property copyright "PREDICT-X"
#property version   "1.00"
#property indicator_separate_window
#property indicator_buffers 3
#property indicator_plots   3
#property indicator_label1  "Momentum"
#property indicator_type1   DRAW_HISTOGRAM
#property indicator_color1  clrLime
#property indicator_width1  2
#property indicator_label2  "SqueezeActive"
#property indicator_type2   DRAW_NONE
#property indicator_label3  "FiredDir"
#property indicator_type3   DRAW_NONE

input int InpBBPeriod=20;
input double InpBBDev=2.0;
input int InpKCPeriod=20;
input double InpKCMult=1.5;

double Hist[],Sqz[],Fired[];
int bbHandle,emaHandle,atrHandle;
int OnInit()
{
   SetIndexBuffer(0,Hist,INDICATOR_DATA); SetIndexBuffer(1,Sqz,INDICATOR_DATA); SetIndexBuffer(2,Fired,INDICATOR_DATA);
   ArraySetAsSeries(Hist,true); ArraySetAsSeries(Sqz,true); ArraySetAsSeries(Fired,true);
   bbHandle=iBands(_Symbol,_Period,InpBBPeriod,0,InpBBDev,PRICE_CLOSE);
   emaHandle=iMA(_Symbol,_Period,InpKCPeriod,0,MODE_EMA,PRICE_TYPICAL);
   atrHandle=iATR(_Symbol,_Period,InpKCPeriod);
   return(bbHandle==INVALID_HANDLE || emaHandle==INVALID_HANDLE || atrHandle==INVALID_HANDLE ? INIT_FAILED : INIT_SUCCEEDED);
}
int OnCalculate(const int rates_total,const int prev_calculated,const datetime &time[],const double &open[],const double &high[],const double &low[],const double &close[],const long &tick_volume[],const long &volume[],const int &spread[])
{
   if(rates_total<MathMax(InpBBPeriod,InpKCPeriod)+5) return 0;
   double bbU[],bbL[],ema[],atr[]; ArraySetAsSeries(bbU,true); ArraySetAsSeries(bbL,true); ArraySetAsSeries(ema,true); ArraySetAsSeries(atr,true);
   if(CopyBuffer(bbHandle,1,0,rates_total,bbU)<=0) return prev_calculated;
   if(CopyBuffer(bbHandle,2,0,rates_total,bbL)<=0) return prev_calculated;
   if(CopyBuffer(emaHandle,0,0,rates_total,ema)<=0) return prev_calculated;
   if(CopyBuffer(atrHandle,0,0,rates_total,atr)<=0) return prev_calculated;
   ArraySetAsSeries(close,true); ArraySetAsSeries(high,true); ArraySetAsSeries(low,true);
   for(int i=rates_total-3;i>=0;i--)
   {
      double kcU=ema[i]+InpKCMult*atr[i], kcL=ema[i]-InpKCMult*atr[i];
      Sqz[i]=(bbU[i]<kcU && bbL[i]>kcL)?1.0:0.0;
      // Momentum = close minus average of highest high / lowest low / ema approximation.
      double hh=high[i], ll=low[i];
      for(int j=0;j<InpKCPeriod && i+j<rates_total;j++){ if(high[i+j]>hh) hh=high[i+j]; if(low[i+j]<ll) ll=low[i+j]; }
      double mid=((hh+ll)/2.0+ema[i])/2.0;
      Hist[i]=close[i]-mid;
      Fired[i]=0.0;
      if(Sqz[i+1]>0.5 && Sqz[i]<0.5) Fired[i]=(Hist[i]>=0?1.0:-1.0);
   }
   return rates_total;
}
void OnDeinit(const int reason){ if(bbHandle!=INVALID_HANDLE) IndicatorRelease(bbHandle); if(emaHandle!=INVALID_HANDLE) IndicatorRelease(emaHandle); if(atrHandle!=INVALID_HANDLE) IndicatorRelease(atrHandle); }

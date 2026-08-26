#property copyright "PREDICT-X"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   3
#property indicator_label1  "KC Upper"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_label2  "KC Middle"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrSilver
#property indicator_label3  "KC Lower"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrDodgerBlue

input int InpEMAPeriod=20;
input double InpATRMultiplier=2.0;

double Upper[],Middle[],Lower[];
int emaHandle,atrHandle;
int OnInit()
{
   SetIndexBuffer(0,Upper,INDICATOR_DATA); SetIndexBuffer(1,Middle,INDICATOR_DATA); SetIndexBuffer(2,Lower,INDICATOR_DATA);
   ArraySetAsSeries(Upper,true); ArraySetAsSeries(Middle,true); ArraySetAsSeries(Lower,true);
   emaHandle=iMA(_Symbol,_Period,InpEMAPeriod,0,MODE_EMA,PRICE_TYPICAL);
   atrHandle=iATR(_Symbol,_Period,InpEMAPeriod);
   return(emaHandle==INVALID_HANDLE || atrHandle==INVALID_HANDLE ? INIT_FAILED : INIT_SUCCEEDED);
}
int OnCalculate(const int rates_total,const int prev_calculated,const datetime &time[],const double &open[],const double &high[],const double &low[],const double &close[],const long &tick_volume[],const long &volume[],const int &spread[])
{
   double ema[],atr[]; ArraySetAsSeries(ema,true); ArraySetAsSeries(atr,true);
   if(CopyBuffer(emaHandle,0,0,rates_total,ema)<=0) return prev_calculated;
   if(CopyBuffer(atrHandle,0,0,rates_total,atr)<=0) return prev_calculated;
   for(int i=rates_total-1;i>=0;i--){ Middle[i]=ema[i]; Upper[i]=ema[i]+InpATRMultiplier*atr[i]; Lower[i]=ema[i]-InpATRMultiplier*atr[i]; }
   return rates_total;
}
void OnDeinit(const int reason){ if(emaHandle!=INVALID_HANDLE) IndicatorRelease(emaHandle); if(atrHandle!=INVALID_HANDLE) IndicatorRelease(atrHandle); }

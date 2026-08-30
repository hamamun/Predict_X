#property copyright "PREDICT-X"
#property version   "2.00"
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   2
#property indicator_label1  "SuperTrend"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrLime
#property indicator_width1  2
#property indicator_label2  "Direction"
#property indicator_type2   DRAW_NONE

input int    InpATRPeriod=10;
input double InpMultiplier=3.0;

double ST[],Dir[],Upper[],Lower[];
int atrHandle;

int OnInit()
{
   SetIndexBuffer(0,ST,INDICATOR_DATA);
   SetIndexBuffer(1,Dir,INDICATOR_DATA);
   SetIndexBuffer(2,Upper,INDICATOR_CALCULATIONS);
   SetIndexBuffer(3,Lower,INDICATOR_CALCULATIONS);
   ArraySetAsSeries(ST,true); ArraySetAsSeries(Dir,true); ArraySetAsSeries(Upper,true); ArraySetAsSeries(Lower,true);
   atrHandle=iATR(_Symbol,_Period,InpATRPeriod);
   return(atrHandle==INVALID_HANDLE?INIT_FAILED:INIT_SUCCEEDED);
}

int OnCalculate(const int rates_total,const int prev_calculated,const datetime &time[],const double &open[],const double &high[],const double &low[],const double &close[],const long &tick_volume[],const long &volume[],const int &spread[])
{
   if(rates_total<InpATRPeriod+5) return 0;
   double atr[]; ArraySetAsSeries(atr,true);
   if(CopyBuffer(atrHandle,0,0,rates_total,atr)<=0) return prev_calculated;
   ArraySetAsSeries(high,true); ArraySetAsSeries(low,true); ArraySetAsSeries(close,true);
   int start=rates_total-2;
   for(int i=start;i>=0;i--)
   {
      double hl2=(high[i]+low[i])/2.0;
      double basicUpper=hl2+InpMultiplier*atr[i];
      double basicLower=hl2-InpMultiplier*atr[i];
      if(i==start)
      {
         Upper[i]=basicUpper; Lower[i]=basicLower; Dir[i]=(close[i]>=hl2?1:-1); ST[i]=(Dir[i]>0?Lower[i]:Upper[i]);
      }
      else
      {
         Upper[i]=(basicUpper<Upper[i+1] || close[i+1]>Upper[i+1])?basicUpper:Upper[i+1];
         Lower[i]=(basicLower>Lower[i+1] || close[i+1]<Lower[i+1])?basicLower:Lower[i+1];
         Dir[i]=Dir[i+1];
         if(Dir[i+1]<0 && close[i]>Upper[i]) Dir[i]=1;
         else if(Dir[i+1]>0 && close[i]<Lower[i]) Dir[i]=-1;
         ST[i]=(Dir[i]>0?Lower[i]:Upper[i]);
      }
   }
   return rates_total;
}

void OnDeinit(const int reason){ if(atrHandle!=INVALID_HANDLE) IndicatorRelease(atrHandle); }

//+------------------------------------------------------------------+
//|                                                     PREDICT-X.mq5 |
//| Phase 2: prediction engine + automated order management.          |
//+------------------------------------------------------------------+
#property copyright "PREDICT-X"
#property version   "1.00"
#property strict

#include "Include/PX_AutoPreset.mqh"
#include "Include/PX_MarketRegime.mqh"
#include "Include/PX_Scoring.mqh"
#include "Include/PX_Layer1_SMC.mqh"
#include "Include/PX_Layer2_Trend.mqh"
#include "Include/PX_Layer3_Value.mqh"
#include "Include/PX_Layer4_HTF.mqh"
#include "Include/PX_Layer5_Markov.mqh"
#include "Include/PX_Layer6_Neural.mqh"
#include "Include/PX_SignalLifecycle.mqh"
#include "Include/PX_TradeManager.mqh"
#include "Include/PX_Panel.mqh"
#include "Include/PX_Alerts.mqh"
#include "Include/PX_OnlineAI.mqh"
#include "Include/PX_CandleConfirm.mqh"

enum PX_TradingMode { PX_MODE_CONSERVATIVE=0, PX_MODE_NORMAL=1, PX_MODE_AGGRESSIVE=2 };

// --- Novice-friendly inputs. Auto-trading occurs only when the master switch is ON.
input bool             InpEnableAutoTrading   = false;            // Enable Auto Trading - Phase 2 master switch
input bool             InpUseInitialStopLoss  = false;            // Use Initial Stop Loss on Order Placement
input bool             InpEnableTradeProtection = true;           // Enable Trade Protection
input double           InpRiskPerTradePercent = 1.0;              // Risk Per Trade (%)
input PX_TradingMode   InpTradingMode         = PX_MODE_NORMAL;   // Trading Mode
input bool             InpAutoAdjustSettings  = true;             // Auto-Adjust Settings
input double           InpDailyLossLimitPct   = 2.0;              // Daily Loss Limit (%)
input bool             InpApplyDailyLossLimit = false;            // Apply Daily Loss Limit
input bool             InpShowPanel           = true;             // Show Panel
input bool             InpShowProjectionLines = false;            // Show Prediction Projection Lines
input PX_SessionFilter InpTradingSessions     = PX_SESSION_ALL;   // Trading Sessions
input bool             InpEnableAIEnhancement = true;             // Enable Online AI Scoring Enhancement
input bool             InpUseCandlestickConfirmation = true;       // Use Candlestick Confirmation
input bool             InpActivePredictionMonitor = true;          // Active Trade Prediction Monitor
input bool             InpPushNotifications   = false;            // Push Notifications
input bool             InpPopupAlerts         = false;            // Popup Alerts
input bool             InpSoundAlerts         = false;            // Sound Alerts
input bool             InpSignalAlerts        = false;            // Signal Alerts
input bool             InpTradeLifecycleAlerts= true;             // Trade Opened/Closed Alerts
input bool             InpTPSLAlerts          = true;             // TP1/TP2/SL Alerts

// --- ALADDIN-IMP memory bank (Phase A: show-only). All acting powers arrive in
// --- Phase B and default OFF; with everything off the EA behaves exactly as today.
input bool             InpPXM_Enable          = true;             // Memory: Enable Aladdin memory bank (show-only)
input bool             InpPXM_ShowFutureView  = true;             // Memory: Show FUTURE VIEW / scorecard / status blocks
input bool             InpPXM_Rehearse        = true;             // Memory: Build bank from past bars on first run (chunked)
input int              InpPXM_RehearseBars    = 3000;             // Memory: Rehearsal depth in closed bars
input int              InpPXM_RehearsePerPass = 200;              // Memory: Rehearsal bars per timer pass (anti-freeze)
input int              InpPXM_KNeighbors      = 50;               // Memory: k-NN similar setups per lookup
input int              InpPXM_MinSamples      = 30;               // Memory: Min resolved outcomes before the view is trusted
input double           InpPXM_SpreadPoints    = 0.0;              // Memory: Typical spread in points (0 = auto)

// ALADDIN-IMP PXM_ modules. Included here (after the inputs) so the modules can
// read the InpPXM_* inputs directly. They only ADD state + display; live functions
// are never modified by them.
#include "Include/PXM_Book.mqh"
#include "Include/PXM_Rehearse.mqh"

PX_Preset       g_basePreset;
PX_RegimeState  g_regime;
PX_Lifecycle    g_lifecycle;
PX_NeuralState  g_neural;
PX_TradeSetup   g_setup;
PX_TradeManagerState g_tm;
PX_SMCLevels    g_smc;

PX_ScoreDetail  g_d1,g_d2,g_d3,g_d4,g_d5,g_d6;
PX_ScoreResult  g_score;
PX_DisplayState g_disp;   // panel-only mirror: the REAL voting, even while blocked
PX_ValueContext g_value;
PX_TrendContext g_trend;
double          g_aiFeatures[12];

datetime g_lastBarTime=0;
int      g_hST=INVALID_HANDLE, g_hRSI=INVALID_HANDLE, g_hADX=INVALID_HANDLE, g_hATR14=INVALID_HANDLE, g_hATR100=INVALID_HANDLE, g_hKC=INVALID_HANDLE, g_hTTM=INVALID_HANDLE;
PX_Preset g_handlePreset;
double   g_spreadEMA=0.0;
int      g_signalsToday=0, g_winsToday=0, g_lossesToday=0;
int      g_dayOfYear=-1;

//+------------------------------------------------------------------+
//| Utility                                                          |
//+------------------------------------------------------------------+
bool PX_Copy1(const int handle,const int buffer,const int shift,double &value)
{
   double tmp[]; ArraySetAsSeries(tmp,true);
   if(handle==INVALID_HANDLE) return false;
   if(CopyBuffer(handle,buffer,shift,1,tmp)<1) return false;
   value=tmp[0];
   return true;
}

bool PX_Copy2(const int handle,const int buffer,const int shift,double &v1,double &v2)
{
   double tmp[]; ArraySetAsSeries(tmp,true);
   if(handle==INVALID_HANDLE) return false;
   if(CopyBuffer(handle,buffer,shift,2,tmp)<2) return false;
   v1=tmp[0]; v2=tmp[1];
   return true;
}

double PX_ModeRiskFactor()
{
   if(InpTradingMode==PX_MODE_CONSERVATIVE) return 0.5;
   if(InpTradingMode==PX_MODE_AGGRESSIVE) return 1.5;
   return 1.0;
}

string PX_IndicatorPath(string file)
{
   return "PREDICT-X\\Indicators\\"+file;
}

string PX_ShortTime(const datetime t)
{
   MqlDateTime dt; TimeToStruct(t,dt);
   return StringFormat("%02d:%02d:%02d",dt.hour,dt.min,dt.sec);
}

bool PX_CreateHandles(const PX_Preset &p)
{
   g_hST=iCustom(_Symbol,_Period,PX_IndicatorPath("SuperTrend"),p.stPeriod,p.stMultiplier);
   if(g_hST==INVALID_HANDLE) g_hST=iCustom(_Symbol,_Period,"SuperTrend",p.stPeriod,p.stMultiplier);

   g_hRSI=iRSI(_Symbol,_Period,p.rsiPeriod,PRICE_CLOSE);
   g_hADX=iADX(_Symbol,_Period,p.adxPeriod);
   g_hATR14=iATR(_Symbol,_Period,p.atrPeriod);
   g_hATR100=iATR(_Symbol,_Period,100);

   g_hKC=iCustom(_Symbol,_Period,PX_IndicatorPath("KeltnerChannel"),p.kcEMAPeriod,p.kcATRMult);
   if(g_hKC==INVALID_HANDLE) g_hKC=iCustom(_Symbol,_Period,"KeltnerChannel",p.kcEMAPeriod,p.kcATRMult);

   g_hTTM=iCustom(_Symbol,_Period,PX_IndicatorPath("TTMSqueeze"),p.ttmBBPeriod,p.ttmBBDev,p.ttmKCPeriod,p.ttmKCMult);
   if(g_hTTM==INVALID_HANDLE) g_hTTM=iCustom(_Symbol,_Period,"TTMSqueeze",p.ttmBBPeriod,p.ttmBBDev,p.ttmKCPeriod,p.ttmKCMult);

   bool ok=(g_hST!=INVALID_HANDLE && g_hRSI!=INVALID_HANDLE && g_hADX!=INVALID_HANDLE && g_hATR14!=INVALID_HANDLE && g_hATR100!=INVALID_HANDLE && g_hKC!=INVALID_HANDLE && g_hTTM!=INVALID_HANDLE);
   if(ok) g_handlePreset=p;
   if(!ok) Print("PREDICT-X: one or more indicator handles failed. Place custom indicators in Indicators/PREDICT-X/Indicators or compile them first.");
   return ok;
}

bool PX_HandlesMatchPreset(const PX_Preset &p)
{
   return (g_handlePreset.stPeriod==p.stPeriod &&
           MathAbs(g_handlePreset.stMultiplier-p.stMultiplier)<0.0001 &&
           g_handlePreset.rsiPeriod==p.rsiPeriod &&
           g_handlePreset.adxPeriod==p.adxPeriod &&
           g_handlePreset.atrPeriod==p.atrPeriod &&
           g_handlePreset.kcEMAPeriod==p.kcEMAPeriod &&
           MathAbs(g_handlePreset.kcATRMult-p.kcATRMult)<0.0001 &&
           g_handlePreset.ttmBBPeriod==p.ttmBBPeriod &&
           MathAbs(g_handlePreset.ttmBBDev-p.ttmBBDev)<0.0001 &&
           g_handlePreset.ttmKCPeriod==p.ttmKCPeriod &&
           MathAbs(g_handlePreset.ttmKCMult-p.ttmKCMult)<0.0001);
}

void PX_ReleaseHandles()
{
   if(g_hST!=INVALID_HANDLE) IndicatorRelease(g_hST);
   if(g_hRSI!=INVALID_HANDLE) IndicatorRelease(g_hRSI);
   if(g_hADX!=INVALID_HANDLE) IndicatorRelease(g_hADX);
   if(g_hATR14!=INVALID_HANDLE) IndicatorRelease(g_hATR14);
   if(g_hATR100!=INVALID_HANDLE) IndicatorRelease(g_hATR100);
   if(g_hKC!=INVALID_HANDLE) IndicatorRelease(g_hKC);
   if(g_hTTM!=INVALID_HANDLE) IndicatorRelease(g_hTTM);
   g_hST=g_hRSI=g_hADX=g_hATR14=g_hATR100=g_hKC=g_hTTM=INVALID_HANDLE;
}

void PX_RecreateHandlesIfNeeded(const PX_Preset &p)
{
   if(PX_HandlesMatchPreset(p)) return;
   Print("PREDICT-X: regime/preset changed, refreshing indicator handles.");
   PX_ReleaseHandles();
   PX_CreateHandles(p);
}

bool PX_MomentumContinuationAllowed()
{
   if(g_score.total<g_regime.adjusted.minScore) return false;
   if(g_score.dir==PX_DIR_NONE) return false;
   if(g_regime.regime==PX_REGIME_CHOPPY || g_regime.regime==PX_REGIME_DANGEROUS) return false;
   if(g_value.spreadBlocked || !g_value.tickValid || !g_value.dataReady) return false;
   if(g_value.atr<=0.0 || g_value.vwap<=0.0) return false;

   bool buy=(g_score.dir==PX_DIR_BUY);
   bool stAgree=(buy && g_trend.stDir>0) || (!buy && g_trend.stDir<0);
   bool ttmAgree=(buy && g_trend.ttmHist>0.0) || (!buy && g_trend.ttmHist<0.0);
   bool vwapSide=(buy && g_value.price>g_value.vwap) || (!buy && g_value.price<g_value.vwap);
   bool adxOk=(g_trend.adx>=25.0);
   bool notTooExtended=(MathAbs(g_value.price-g_value.vwap)<=2.0*g_value.atr);
   return (stAgree && ttmAgree && vwapSide && adxOk && notTooExtended);
}

bool PX_HasOppositeCandleWarning(PX_Direction dir)
{
   if(!InpUseCandlestickConfirmation || dir==PX_DIR_NONE) return false;
   PX_CandleContext cctx;
   PX_CandleConfirmationScore(dir,g_value.price,g_value.vwap,g_value.atr,g_smc.orderBlockTop,g_smc.orderBlockBottom,g_smc.hasOB,cctx);
   return cctx.opposite;
}

bool PX_StrongMarketEntryAllowed()
{
   // Hybrid entry rule:
   // Very Strong always uses market. Strong 70-84 may use market when either:
   // 1) momentum agrees and price is not extended, OR
   // 2) price is extended but ADX is very strong and spread is low.
   if(g_score.total<70 || g_score.total>=85) return false;
   if(g_score.dir==PX_DIR_NONE) return false;
   if(g_regime.regime==PX_REGIME_CHOPPY || g_regime.regime==PX_REGIME_DANGEROUS) return false;
   if(g_value.spreadBlocked || !g_value.tickValid) return false;
   if(g_value.atr<=0.0 || g_value.vwap<=0.0) return false;

   bool buy=(g_score.dir==PX_DIR_BUY);
   bool stAgree=(buy && g_trend.stDir>0) || (!buy && g_trend.stDir<0);
   bool ttmAgree=(buy && g_trend.ttmHist>0.0) || (!buy && g_trend.ttmHist<0.0);
   bool vwapSide=(buy && g_value.price>g_value.vwap) || (!buy && g_value.price<g_value.vwap);
   bool adxOk=(g_trend.adx>=25.0);
   bool notExtended=(MathAbs(g_value.price-g_value.vwap)<=1.0*g_value.atr);
   bool spreadLow=(g_value.avgSpreadPoints<=0.0 || g_value.spreadPoints<=g_value.avgSpreadPoints);
   bool strongExtendedAllowed=(g_trend.adx>=35.0 && spreadLow);
   if(PX_HasOppositeCandleWarning(g_score.dir)) return false;

   return (stAgree && ttmAgree && vwapSide && adxOk && (notExtended || strongExtendedAllowed));
}

bool PX_MediumMarketEntryAllowed()
{
   // Medium market entry is allowed only near the top of Medium score range
   // with very strong momentum and low spread. Normal Medium remains limit.
   if(g_score.total<67 || g_score.total>=70) return false;
   if(g_score.dir==PX_DIR_NONE) return false;
   if(g_regime.regime==PX_REGIME_CHOPPY || g_regime.regime==PX_REGIME_DANGEROUS) return false;
   if(g_value.spreadBlocked || !g_value.tickValid) return false;
   if(g_value.atr<=0.0 || g_value.vwap<=0.0) return false;

   bool buy=(g_score.dir==PX_DIR_BUY);
   bool stAgree=(buy && g_trend.stDir>0) || (!buy && g_trend.stDir<0);
   bool ttmAgree=(buy && g_trend.ttmHist>0.0) || (!buy && g_trend.ttmHist<0.0);
   bool vwapSide=(buy && g_value.price>g_value.vwap) || (!buy && g_value.price<g_value.vwap);
   bool spreadLow=(g_value.avgSpreadPoints<=0.0 || g_value.spreadPoints<=g_value.avgSpreadPoints);
   if(PX_HasOppositeCandleWarning(g_score.dir)) return false;
   return (stAgree && ttmAgree && vwapSide && g_trend.adx>=30.0 && spreadLow);
}

void PX_ForceMarketSetup(PX_TradeSetup &ts,PX_Direction dir,double ask,double bid,double atr,double slMult,double tp1Mult,double tp2Mult,double riskPct,double lotFactor,string reason)
{
   bool buy=(dir==PX_DIR_BUY);
   ts.dir=dir;
   ts.method=PX_ENTRY_MARKET;
   ts.entry=(buy?ask:bid);
   ts.methodText=reason;
   if(buy)
   {
      ts.sl=ts.entry-slMult*atr;
      ts.tp1=ts.entry+tp1Mult*atr;
      ts.tp2=ts.entry+tp2Mult*atr;
      ts.breakeven=ts.entry+1.5*(ask-bid);
   }
   else
   {
      ts.sl=ts.entry+slMult*atr;
      ts.tp1=ts.entry-tp1Mult*atr;
      ts.tp2=ts.entry-tp2Mult*atr;
      ts.breakeven=ts.entry-1.5*(ask-bid);
   }
   ts.lot=PX_CalcLot(riskPct,lotFactor,ts.entry,ts.sl);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE), tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   ts.riskMoney=(tickSize>0.0?MathAbs(ts.entry-ts.sl)/tickSize*tickValue*ts.lot:0.0);
   ts.rewardMoney=(tickSize>0.0?MathAbs(ts.tp2-ts.entry)/tickSize*tickValue*ts.lot:0.0);
   ts.rr=(MathAbs(ts.entry-ts.sl)>0?MathAbs(ts.tp2-ts.entry)/MathAbs(ts.entry-ts.sl):0);
   ts.valid=true;
}

void PX_RefreshPendingSetupToCurrentMarket(PX_TradeSetup &ts,const PX_Preset &ap,double ask,double bid,double riskPct)
{
   if(g_lifecycle.state!=PX_STATE_PENDING || !ts.valid || ts.method==PX_ENTRY_MARKET) return;
   if(!PX_MomentumContinuationAllowed()) return;
   if(g_value.atr<=0.0) return;

   bool buy=(g_score.dir==PX_DIR_BUY);
   double market=(buy?ask:bid);
   // If the market has already moved in the predicted direction away from the
   // old limit/value level, the old first-signal entry is no longer actionable.
   // Refresh to live market so entry/SL/TP/lot follow the latest closed-bar thesis.
   bool movedInFavor=(buy ? market>ts.entry+0.25*g_value.atr : market<ts.entry-0.25*g_value.atr);
   if(movedInFavor)
      PX_ForceMarketSetup(ts,g_score.dir,ask,bid,g_value.atr,ap.slATRMult,ap.tp1ATRMult,ap.tp2ATRMult,riskPct,g_regime.lotFactor,"market (pending momentum refresh)");
}

void PX_ResetDailyCountersIfNeeded()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(g_dayOfYear<0) g_dayOfYear=dt.day_of_year;
   if(dt.day_of_year!=g_dayOfYear)
   {
      g_dayOfYear=dt.day_of_year; g_signalsToday=0; g_winsToday=0; g_lossesToday=0;
   }
}

PX_Direction PX_PrimaryDirection(const PX_TrendContext &tc,double closePrice,double vwap)
{
   int bull=0,bear=0;
   if(tc.stDir>0) bull++; else if(tc.stDir<0) bear++;
   if(closePrice>vwap) bull++; else if(closePrice<vwap) bear++;
   if(tc.rsi>=50.0) bull++; else bear++;
   if(tc.ttmHist>0.0) bull++; else if(tc.ttmHist<0.0) bear++;
   if(bull>bear) return PX_DIR_BUY;
   if(bear>bull) return PX_DIR_SELL;
   return PX_DIR_NONE;
}

// Display helper: the SAME 4 votes as PX_PrimaryDirection, but exposes the
// split so the panel can show "3-1 BUY". Copy only - the live function above
// is untouched and remains the single source of the trading direction.
void PX_CountDirectionVotes(const PX_TrendContext &tc,double closePrice,double vwap,int &bull,int &bear)
{
   bull=0; bear=0;
   if(tc.stDir>0) bull++; else if(tc.stDir<0) bear++;
   if(closePrice>vwap) bull++; else if(closePrice<vwap) bear++;
   if(tc.rsi>=50.0) bull++; else bear++;
   if(tc.ttmHist>0.0) bull++; else if(tc.ttmHist<0.0) bear++;
}

void PX_ReadContexts()
{
   PX_Preset ap=g_regime.adjusted;
   double atr14=0, atr100=0, adx=0, st=0, stDir=0, rsi=50, rsiPrev=50, ttm=0, ttmPrev=0, sqz=0, fired=0;
   bool dataReady=true;
   dataReady = (PX_Copy1(g_hATR14,0,1,atr14) && dataReady);
   dataReady = (PX_Copy1(g_hATR100,0,1,atr100) && dataReady);
   dataReady = (PX_Copy1(g_hADX,0,1,adx) && dataReady);
   dataReady = (PX_Copy1(g_hST,0,1,st) && dataReady);
   dataReady = (PX_Copy1(g_hST,1,1,stDir) && dataReady);
   dataReady = (PX_Copy2(g_hRSI,0,1,rsi,rsiPrev) && dataReady);
   dataReady = (PX_Copy2(g_hTTM,0,1,ttm,ttmPrev) && dataReady);
   dataReady = (PX_Copy1(g_hTTM,1,1,sqz) && dataReady);
   dataReady = (PX_Copy1(g_hTTM,2,1,fired) && dataReady);

   g_trend.stLine=st; g_trend.stDir=(stDir>0?1:(stDir<0?-1:0)); g_trend.rsi=rsi; g_trend.rsiPrev=rsiPrev;
   g_trend.ttmHist=ttm; g_trend.ttmHistPrev=ttmPrev; g_trend.ttmSqueeze=sqz; g_trend.ttmFiredDir=fired; g_trend.adx=adx;

   double kcU=0,kcM=0,kcL=0;
   dataReady = (PX_Copy1(g_hKC,0,1,kcU) && dataReady);
   dataReady = (PX_Copy1(g_hKC,1,1,kcM) && dataReady);
   dataReady = (PX_Copy1(g_hKC,2,1,kcL) && dataReady);
   MqlTick tick;
   bool tickOk=SymbolInfoTick(_Symbol,tick) && tick.ask>0.0 && tick.bid>0.0 && tick.ask>tick.bid;
   double spreadPts=0.0;
   if(tickOk)
   {
      spreadPts=(tick.ask-tick.bid)/_Point;
      if(g_spreadEMA<=0.0) g_spreadEMA=spreadPts; else g_spreadEMA=0.95*g_spreadEMA+0.05*spreadPts;
   }

   g_value.price=iClose(_Symbol,_Period,1);
   g_value.vwap=PX_CalcVWAP(_Symbol,_Period,1);
   g_value.kcUpper=kcU; g_value.kcMiddle=kcM; g_value.kcLower=kcL;
   g_value.atr=atr14;
   g_value.spreadPoints=spreadPts; g_value.avgSpreadPoints=g_spreadEMA; g_value.tickValid=tickOk;
   g_value.dataReady=(dataReady && atr14>0.0 && atr100>0.0 && g_value.price>0.0 && g_value.vwap>0.0 && adx>0.0);
   g_value.sessionName=PX_CurrentSessionName(TimeCurrent());
   g_value.sessionActive=PX_SessionAllowed(InpTradingSessions,TimeCurrent());
   // Real-money safety: if there is no valid live bid/ask tick, block signal/setup.
   // Never fabricate or fall back to estimated prices.
   g_value.spreadBlocked=(!tickOk || (g_spreadEMA>0 && spreadPts>2.0*g_spreadEMA));

   double er=PX_KaufmanER(_Symbol,_Period,20,1);
   double ratio=(atr100>0?atr14/atr100:1.0);
   PX_ClassifyRegime(g_basePreset,er,ratio,adx,g_regime);
   // Auto-Adjust OFF means use timeframe preset only, but Dangerous still blocks trading.
   if(!InpAutoAdjustSettings && !g_regime.blockSignals)
   {
      g_regime.adjusted=g_basePreset;
      g_regime.lotFactor=1.0;
      g_regime.adjustments="Auto-adjust OFF: timeframe preset only";
   }
   // Preserve latest ATR/ADX values after classification.
   g_regime.adx=adx;
   // Auto-adjust can change ST/RSI/Keltner/TTM parameters. Refresh handles so
   // scoring truly uses the active preset/regime instead of stale init settings.
   PX_RecreateHandlesIfNeeded(g_regime.adjusted);
}

void PX_ResetScoreResult(PX_ScoreResult &sr)
{
   sr.dir=PX_DIR_NONE;
   sr.layer1=0; sr.layer2=0; sr.layer3=0; sr.layer4=0; sr.layer5=0; sr.layer6=0; sr.candleBonus=0; sr.total=0;
   sr.tier=PX_TIER_NO_TRADE;
   sr.spreadBlocked=false;
   sr.signalText="";
}

void PX_CalculateScores()
{
   PX_ResetScoreResult(g_score);
   PX_DisplayReset(g_disp);
   g_score.dir=PX_PrimaryDirection(g_trend,g_value.price,g_value.vwap);
   PX_CountDirectionVotes(g_trend,g_value.price,g_value.vwap,g_disp.bullVotes,g_disp.bearVotes);
   g_disp.dir=g_score.dir;

   // Engine veto state (dangerous regime or spread). The ENGINE path below is
   // still force-zeroed exactly as before; only the panel mirror keeps the
   // real voting so the user always sees the true score.
   bool blockedNow=(g_regime.blockSignals || g_value.spreadBlocked);
   g_disp.blocked=blockedNow;
   g_disp.blockReason=(g_regime.blockSignals?g_regime.name:(g_value.spreadBlocked?"spread too high":""));

   if(!g_value.dataReady || g_score.dir==PX_DIR_NONE)
   {
      PX_ResetDetail(g_d1,"SMART MONEY",25); PX_ResetDetail(g_d2,"TREND/MOM",25); PX_ResetDetail(g_d3,"INST VALUE/VOL",20);
      PX_ResetDetail(g_d4,"HTF CONFLUENCE",15); PX_ResetDetail(g_d5,"MARKOV STATE",15); PX_ResetDetail(g_d6,"AI CONFIRM",10);
      g_score.total=0; g_score.tier=PX_TIER_NO_TRADE; g_score.spreadBlocked=g_value.spreadBlocked;
      g_score.signalText=(!g_value.dataReady?"Blocked: data not ready":(g_regime.blockSignals?"Blocked: dangerous regime":(g_value.spreadBlocked?"Blocked: spread > 2x normal":"No directional edge")));
      return;
   }

   // The 6 layers are now computed ALWAYS (also on blocked bars) so the panel
   // can show the real voting. The ENGINE result is force-zeroed again below
   // when blocked, so every trading decision, the AI preparation, the memory
   // bank and the trade manager see byte-identical values to before.
   PX_Preset ap=g_regime.adjusted;
   g_score.layer2=PX_ScoreLayer2(g_score.dir,g_trend,g_d2);
   g_score.layer3=PX_ScoreLayer3(g_score.dir,g_value,g_d3);
   g_score.layer4=PX_ScoreLayer4(_Symbol,g_score.dir,ap.htf1,ap.htf2,ap.stPeriod,ap.stMultiplier,g_d4);
   g_score.layer1=PX_ScoreLayer1(_Symbol,_Period,g_score.dir,g_value.price,g_value.atr,g_smc,g_d1);
   double pUp,pNeu,pDn; int pred;
   g_score.layer5=PX_ScoreLayer5(_Symbol,_Period,g_score.dir,g_value.atr,g_d5,pUp,pNeu,pDn,pred);

   double features[12];
   int preAI=PX_AggregateScore(g_score.layer1,g_score.layer2,g_score.layer3,g_score.layer4,g_score.layer5,0);
   features[0]=(double)preAI;
   features[1]=(double)g_score.layer1; features[2]=(double)g_score.layer2; features[3]=(double)g_score.layer3; features[4]=(double)g_score.layer4; features[5]=(double)g_score.layer5;
   features[6]=g_regime.er; features[7]=g_regime.atrRatio; features[8]=g_regime.adx; features[9]=g_trend.rsi; features[10]=(double)g_trend.stDir; features[11]=g_trend.ttmSqueeze;
   // AI prepare only on non-blocked bars - identical to the old early-return
   // flow, where blocked bars never reached this code. This keeps the neural
   // state and g_aiFeatures learning exactly as before.
   if(!blockedNow)
   {
      for(int fi=0;fi<12;fi++) g_aiFeatures[fi]=features[fi];
      if(InpEnableAIEnhancement)
         PX3_PrepareAI(g_neural,g_score.dir,PX_ClassifyTier(preAI),features);
      else
         PX_NeuralSetLearning(g_neural,"ONLINE AI OFF");
   }
   // Layer 6 is a pure read of the neural state (no mutation), so it is safe
   // to evaluate for display on blocked bars too.
   double conf; PX_Direction aiDir;
   g_score.layer6=PX_ScoreLayer6(g_neural,g_score.dir,features,g_d6,conf,aiDir);

   if(InpUseCandlestickConfirmation)
   {
      PX_CandleContext cctx;
      g_score.candleBonus=PX_CandleConfirmationScore(g_score.dir,g_value.price,g_value.vwap,g_value.atr,g_smc.orderBlockTop,g_smc.orderBlockBottom,g_smc.hasOB,cctx);
   }

   g_score.total=PX_AggregateScore(g_score.layer1,g_score.layer2,g_score.layer3,g_score.layer4,g_score.layer5,g_score.layer6,g_score.candleBonus);
   g_score.tier=PX_ClassifyTier(g_score.total);
   g_score.spreadBlocked=g_value.spreadBlocked;
   g_score.signalText=PX_TierText(g_score.tier)+" "+PX_DirectionText(g_score.dir);

   // Panel mirror: the REAL voting, always.
   g_disp.valid=true;
   g_disp.total=g_score.total;
   g_disp.tier=g_score.tier;

   // ENGINE copy: force-zero when blocked - exactly the old behavior, field
   // by field (dir and spreadBlocked keep their live values, as before).
   if(blockedNow)
   {
      g_score.layer1=0; g_score.layer2=0; g_score.layer3=0; g_score.layer4=0; g_score.layer5=0; g_score.layer6=0; g_score.candleBonus=0;
      g_score.total=0; g_score.tier=PX_TIER_NO_TRADE;
      g_score.signalText=(g_regime.blockSignals?"Blocked: dangerous regime":"Blocked: spread > 2x normal");
   }
}

//+------------------------------------------------------------------+
//| Plain-language summary (why / what / how) for the main panel.    |
//| Built from the live context states. Show-only, continuous.       |
//+------------------------------------------------------------------+
string PX_BuildSummaryText()
{
   // WHY NOT / what's blocking
   if(g_regime.blockSignals)
      return "Watching only - the market is "+g_regime.name+". No trades right now.";
   if(g_value.spreadBlocked)
      return "Watching only - trading costs too high (spread over 2x normal).";
   if(g_score.dir==PX_DIR_NONE)
      return "Scanning - no clear direction yet.";
   if(g_score.tier<PX_TIER_MEDIUM)
      return StringFormat("Scanning - score %d/100 is below the trade threshold.",g_score.total);

   // ACTIVE
   if(g_lifecycle.state==PX_STATE_ACTIVE)
      return StringFormat("In a %s trade now. %s.",PX_DirectionText(g_score.dir),PX_StateText(g_lifecycle.state));

   // PENDING / actionable
   if(g_lifecycle.state==PX_STATE_PENDING)
   {
      string dirs=PX_DirectionText(g_score.dir);
      string how=(g_setup.valid && g_setup.methodText!="none"?PX_TM_ShortMethod(g_setup.methodText):"waiting for a safer entry");
      string fv=(g_pxmView.ready ? (g_pxmView.winPct>=55.0?"Future View supports it":"Future View is cautious") : "Future View is still learning");
      return StringFormat("A %s %s (%d/100) is forming.\nEntry: %s. %s.",
            PX_TierText(g_score.tier),dirs,g_score.total,how,fv);
   }

   // Fallback: strong score but no live setup yet (between signals / just expired).
   return StringFormat("%s %s (%d/100) - no live setup yet, waiting for a fresh signal.",
            PX_TierText(g_score.tier),PX_DirectionText(g_score.dir),g_score.total);
}

void PX_OnNewClosedBar()
{
   PX_ResetDailyCountersIfNeeded();
   PX_ReadContexts();
   PX_CalculateScores();
   PX_Preset ap=g_regime.adjusted;

   if(InpEnableAIEnhancement)
      PX3_EvaluateHistory(ap.signalExpiryBars);

   PX_SignalState before=g_lifecycle.state;
   PX_UpdateLifecycle(g_lifecycle,g_score,ap.minScore,ap.signalExpiryBars,g_value.spreadBlocked,g_regime.blockSignals);
   bool newSignal=(before==PX_STATE_SCANNING && g_lifecycle.state==PX_STATE_PENDING);
   if(newSignal) g_signalsToday++;

   // ALADDIN-IMP memory check: runs BETWEEN the lifecycle update and the trade setup.
   // Phase A: k-NN view + live signal logging + outcome bookkeeping. Show-only:
   // it cannot change scoring, setup, lots or orders.
   PX_FutureViewCheck(g_lifecycle,newSignal,g_score,g_regime,g_value,g_trend,g_aiFeatures);

   MqlTick tick;
   bool tickOk=SymbolInfoTick(_Symbol,tick) && tick.ask>0.0 && tick.bid>0.0 && tick.ask>tick.bid;
   double riskPct=InpRiskPerTradePercent*PX_ModeRiskFactor();
   bool strongMarketAllowed=PX_StrongMarketEntryAllowed();
   bool mediumMarketAllowed=PX_MediumMarketEntryAllowed();
   if(tickOk)
   {
      PX_CalcTradeSetup(g_setup,g_score.dir,g_score.tier,(double)g_score.total,tick.ask,tick.bid,g_trend.stLine,g_value.vwap,g_smc.orderBlockTop,g_smc.orderBlockBottom,g_smc.hasOB,g_value.atr,ap.slATRMult,ap.tp1ATRMult,ap.tp2ATRMult,riskPct,g_regime.lotFactor,strongMarketAllowed,mediumMarketAllowed,InpUseInitialStopLoss);
      PX_RefreshPendingSetupToCurrentMarket(g_setup,ap,tick.ask,tick.bid,riskPct);
      PXM_AttachSetup(g_setup); // memory: bind planned entry/SL/TP1/TP2 to the tracked live signal (record only)
   }
   else
      PX_CalcTradeSetup(g_setup,PX_DIR_NONE,PX_TIER_NO_TRADE,0.0,0.0,0.0,0.0,0.0,0.0,0.0,false,0.0,ap.slATRMult,ap.tp1ATRMult,ap.tp2ATRMult,riskPct,0.0,false,false,InpUseInitialStopLoss);

   if(InpEnableAIEnhancement && newSignal) PX3_AddHistory(g_lifecycle.signalTime,_Symbol,_Period,g_score.dir,g_score.total,g_score.tier,g_setup.methodText,g_aiFeatures);

   bool drawSignalMarker=(g_lifecycle.state==PX_STATE_PENDING && g_score.tier>=PX_TIER_MEDIUM);

   if(newSignal && InpSignalAlerts)
      PX4_SendAlert(InpPushNotifications,InpPopupAlerts,InpSoundAlerts,StringFormat("New %s %s signal on %s %s | Score %d | Entry %s",PX_TierText(g_score.tier),PX_DirectionText(g_score.dir),_Symbol,PX_TFToString(_Period),g_score.total,g_setup.methodText));

   // Phase 2 automated execution and management. Master switch controls all auto actions.
   PX_TM_OnNewBar(g_tm,InpEnableAutoTrading,InpUseInitialStopLoss,InpEnableTradeProtection,InpApplyDailyLossLimit,InpDailyLossLimitPct,InpActivePredictionMonitor,g_lifecycle,g_score,g_setup,g_regime,g_value,g_trend);

   if(drawSignalMarker)
   {
      datetime t=iTime(_Symbol,_Period,1);
      double y=(g_score.dir==PX_DIR_BUY?iLow(_Symbol,_Period,1)-0.5*g_value.atr:iHigh(_Symbol,_Period,1)+0.5*g_value.atr);
      PX_DrawSignalArrow(t,y,g_score.dir,g_score.tier,g_lifecycle.barsWaiting,ap.signalExpiryBars);
   }

   // Forward visual prediction projection: entry -> TP1/TP2 over active signal bars.
   if(InpShowProjectionLines)
      PX_DrawPredictionProjection(g_setup,g_score,ap.signalExpiryBars);
   else
      PX_DeleteProjectionLines();

   PX_DrawRegimeBar(g_regime);
   // Standard-interface left panel: plain-language summary + future view + last action.
   bool effectiveDailyLoss=(InpEnableTradeProtection && InpApplyDailyLossLimit);
   string toggRest=StringFormat("SL %s  ·  FUTURE VIEW %s  ·  DAILY %s",(InpUseInitialStopLoss?"ON":"OFF"),(InpPXM_ShowFutureView?"ON":"OFF"),(effectiveDailyLoss?"ON":"OFF"));
   string fvStatus=PXM_FutureViewStatus(g_value.atr,(g_setup.valid?g_setup.entry:0.0),(g_setup.valid?g_setup.sl:0.0));
   PX_RenderPanel(InpShowPanel,_Symbol,_Period,g_regime,g_d1,g_d2,g_d3,g_d4,g_d5,g_d6,g_score,g_disp,g_setup,g_value,g_trend,g_lifecycle,g_basePreset.warning,g_signalsToday,g_winsToday,g_lossesToday,0,InpEnableAutoTrading,toggRest,fvStatus,PX_BuildSummaryText(),PX_TM_ShortAction(g_tm.lastAction),PX_ShortTime(g_tm.lastActionTime));
   PX_TM_RenderOrderPanel(g_tm,InpShowPanel,g_setup,g_score,g_lifecycle,InpEnableTradeProtection);
   ChartRedraw(0);
}

void PX_CheckInstantPendingFlip()
{
   if(g_lifecycle.state!=PX_STATE_PENDING) return;
   double stDir=0;
   if(PX_Copy1(g_hST,1,0,stDir))
   {
      PX_Direction now=(stDir>0?PX_DIR_BUY:(stDir<0?PX_DIR_SELL:PX_DIR_NONE));
      if(now!=PX_DIR_NONE && now!=g_lifecycle.pendingDir)
      {
         Print("PREDICT-X: Pending signal cancelled instantly due to SuperTrend flip.");
         PX_LifecycleInit(g_lifecycle);
      }
   }
}

void PX_DeleteAllChartObjects()
{
   // Robust cleanup for all PREDICT-X visual layers: main panel/signals,
   // order manager, old scanner/AI panel, legacy controls, trade lines and badges.
   // Use both prefix deletion and manual scan because some MT5 builds handle
   // rectangle-label/button cleanup differently during EA removal.
   ObjectsDeleteAll(0,"PX_");
   ObjectsDeleteAll(0,"PX2_");
   ObjectsDeleteAll(0,"PX3_");
   ObjectsDeleteAll(0,"PX4_");
   for(int pass=0; pass<3; pass++)
   {
      for(int i=ObjectsTotal(0)-1;i>=0;i--)
      {
         string name=ObjectName(0,i);
         if(StringFind(name,"PX_")==0 || StringFind(name,"PX2_")==0 || StringFind(name,"PX3_")==0 || StringFind(name,"PX4_")==0)
            ObjectDelete(0,name);
      }
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("PREDICT-X Phase 2 initializing: auto-trading switch=",(InpEnableAutoTrading?"ON":"OFF"),". No martingale, no grid.");
   PX_LoadPreset(_Period,g_basePreset);
   PX_ClassifyRegime(g_basePreset,0.5,1.0,25.0,g_regime);
   PX_LifecycleInit(g_lifecycle);
   PX_NeuralInit(g_neural);
   if(InpEnableAIEnhancement) PX3_Init();
   PX_TM_Init(g_tm,InpEnableAutoTrading,InpDailyLossLimitPct);
   g_setup.dir=PX_DIR_NONE; g_setup.method=PX_ENTRY_NONE; g_setup.entry=0; g_setup.sl=0; g_setup.tp1=0; g_setup.tp2=0; g_setup.breakeven=0; g_setup.lot=0; g_setup.riskMoney=0; g_setup.rewardMoney=0; g_setup.rr=0; g_setup.methodText="none"; g_setup.valid=false;
   if(!PX_CreateHandles(g_basePreset)) return INIT_FAILED;
   // ALADDIN-IMP Phase A: memory bank init + chunked rehearsal start (show-only).
   PXM_Init();
   PXM_RehearseStart(g_basePreset);
   g_lastBarTime=iTime(_Symbol,_Period,0);
   EventSetTimer(5);
   PX_OnNewClosedBar();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   PXM_OnDeinitCleanup(); // ALADDIN-IMP: PXM_ objects + rehearsal handles + memory file close
   PX_ReleaseHandles();
   PX_DeleteObjects();
   PX_TM_DeleteObjects();
   PX3_DeleteObjects();
   PX4_DeleteObjects();
   PX_DeleteAllChartObjects();
   Comment("");
}

void OnTick()
{
   PX_CheckInstantPendingFlip();
   double liveSTDir=0.0;
   if(PX_Copy1(g_hST,1,0,liveSTDir)) PX_TM_OnInstantTick(g_tm,(InpEnableTradeProtection && InpActivePredictionMonitor),(liveSTDir>0?1:(liveSTDir<0?-1:0)));
   // Tick-level protection is NOT linked to AUTO TRADE: with auto OFF the EA
   // opens nothing new, but still guards its existing position.
   if(InpEnableTradeProtection)
   {
      PX_TM_ApplyEarlyProfitLock(g_tm);
      PX_TM_CheckTP1(g_tm);
      PX_TM_ApplyPostTP1GivebackTrail(g_tm);
   }
   datetime cur=iTime(_Symbol,_Period,0);
   if(InpShowPanel)
   {
      ulong liveTicket=0;
      if(PX_TM_SelectPosition(liveTicket) || PX_TM_SelectPending(liveTicket))
      {
         PX_TM_RenderOrderPanel(g_tm,InpShowPanel,g_setup,g_score,g_lifecycle,InpEnableTradeProtection);
         ChartRedraw(0);
      }
   }

   if(cur!=0 && cur!=g_lastBarTime)
   {
      g_lastBarTime=cur;
      PX_OnNewClosedBar();
   }
}

void OnTimer()
{
   // ALADDIN-IMP: chunked rehearsal pump (history building; never touches live state).
   PXM_RehearsePump(g_hST,g_hRSI,g_hADX,g_hATR14,g_hATR100,g_hKC,g_hTTM,g_basePreset);
   PX_DrawRegimeBar(g_regime);
   bool effectiveDailyLoss=(InpEnableTradeProtection && InpApplyDailyLossLimit);
   string toggRest=StringFormat("SL %s  ·  FUTURE VIEW %s  ·  DAILY %s",(InpUseInitialStopLoss?"ON":"OFF"),(InpPXM_ShowFutureView?"ON":"OFF"),(effectiveDailyLoss?"ON":"OFF"));
   string fvStatus=PXM_FutureViewStatus(g_value.atr,(g_setup.valid?g_setup.entry:0.0),(g_setup.valid?g_setup.sl:0.0));
   PX_RenderPanel(InpShowPanel,_Symbol,_Period,g_regime,g_d1,g_d2,g_d3,g_d4,g_d5,g_d6,g_score,g_disp,g_setup,g_value,g_trend,g_lifecycle,g_basePreset.warning,g_signalsToday,g_winsToday,g_lossesToday,0,InpEnableAutoTrading,toggRest,fvStatus,PX_BuildSummaryText(),PX_TM_ShortAction(g_tm.lastAction),PX_ShortTime(g_tm.lastActionTime));
   PX_TM_RenderOrderPanel(g_tm,InpShowPanel,g_setup,g_score,g_lifecycle,InpEnableTradeProtection);
   if(InpShowPanel)
      ChartRedraw(0);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol) return;
   if((long)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=PX_MAGIC) return;

   ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   ENUM_DEAL_REASON reason=(ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal,DEAL_REASON);
   long dealType=HistoryDealGetInteger(trans.deal,DEAL_TYPE);
   double price=HistoryDealGetDouble(trans.deal,DEAL_PRICE);
   double volume=HistoryDealGetDouble(trans.deal,DEAL_VOLUME);

   if(entry==DEAL_ENTRY_IN)
   {
      PXM_OnTradeOpened(price,volume); // memory: record real fill for the tracked live signal (record only)
      if(InpTradeLifecycleAlerts)
         PX4_SendAlert(InpPushNotifications,InpPopupAlerts,InpSoundAlerts,StringFormat("Trade opened on %s | %s %.2f @ %.5f",_Symbol,(dealType==DEAL_TYPE_BUY?"BUY":"SELL"),volume,price));
      return;
   }

   if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) return;

   double profit=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)+HistoryDealGetDouble(trans.deal,DEAL_SWAP)+HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
   ulong stillOpen=0;
   bool positionStillOpen=PX_TM_SelectPosition(stillOpen);

   if(positionStillOpen)
   {
      // Partial close, normally TP1.
      PXM_OnTradePartialTP1(profit); // memory: TP1 partial outcome backfill (record only)
      if(InpTPSLAlerts)
         PX4_SendAlert(InpPushNotifications,InpPopupAlerts,InpSoundAlerts,StringFormat("TP1 / partial close on %s | %.2f lots | P/L $%.2f",_Symbol,volume,profit));
      return;
   }

   if(profit>=0.0) g_winsToday++; else g_lossesToday++;
   PXM_OnTradeClosed(profit,(reason==DEAL_REASON_TP)); // memory: final outcome backfill (record only)
   PX_TM_ClearPersistence();

   bool reasonTP=(reason==DEAL_REASON_TP);
   bool reasonSL=(reason==DEAL_REASON_SL);
   if((reasonTP || reasonSL) && InpTPSLAlerts)
      PX4_SendAlert(InpPushNotifications,InpPopupAlerts,InpSoundAlerts,StringFormat("%s hit on %s | P/L $%.2f",(reasonTP?"TP":"SL"),_Symbol,profit));
   else if(InpTradeLifecycleAlerts)
      PX4_SendAlert(InpPushNotifications,InpPopupAlerts,InpSoundAlerts,StringFormat("Trade closed on %s | P/L $%.2f",_Symbol,profit));

   string badge="PX2_RESULT_"+IntegerToString((long)trans.deal);
   datetime t=(datetime)HistoryDealGetInteger(trans.deal,DEAL_TIME);
   if(ObjectFind(0,badge)<0) ObjectCreate(0,badge,OBJ_TEXT,0,t,price);
   ObjectSetString(0,badge,OBJPROP_TEXT,(profit>=0.0?"W":"L"));
   ObjectSetInteger(0,badge,OBJPROP_COLOR,(profit>=0.0?clrLime:clrTomato));
   ObjectSetInteger(0,badge,OBJPROP_FONTSIZE,10);
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   // No one-click chart controls by user decision.
}
//+------------------------------------------------------------------+

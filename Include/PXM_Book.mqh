//+------------------------------------------------------------------+
//|                                                     PXM_Book.mqh |
//| ALADDIN memory bank + Phase B trade actions.  [PREDICT-X v2.00]                     |
//|                                                                  |
//| One persistent SQLite database in Terminal Common Files stores   |
//| all symbols/timeframes, isolated by symbol+TF+feature version.   |
//| row sources: 1=rehearsal result, 2=live signal/outcome.          |
//| Grown live: every signal + setup is inserted; real trade         |
//| outcomes update that row from deal history/OHLC projection.      |
//| k-NN lookup on the SAME 12-feature vector the online AI uses    |
//| returns: win%, TP1%, typical dip (MAE in ATR), time-to-result.   |
//|                                                                  |
//| Master switch: InpEnableAladin. When ON and memory is ready,    |
//| Phase B may: smarter SL/TP, refuse weak history, resize lot,    |
//| stronger entry (GO). Database/lookup failure falls back to classic  |
//| PREDICT-X behaviour and the panel shows the failure clearly.    |
//| Uses its own GV keys (PREDICTX.MEM.*) - no collision with       |
//| PREDICTX.<magic>.* (TradeManager) or PREDICTX.ONLINEAI.* keys.  |
//+------------------------------------------------------------------+
#ifndef __PXM_BOOK_MQH__
#define __PXM_BOOK_MQH__

#include "PX_Scoring.mqh"
#include "PX_AutoPreset.mqh"
#include "PX_MarketRegime.mqh"
#include "PX_Layer2_Trend.mqh"
#include "PX_Layer3_Value.mqh"
#include "PX_SignalLifecycle.mqh"
#include "PX_OnlineAI.mqh"
#include "PX_Panel.mqh"
#include "PX_TradeManager.mqh"

//--- single-switch internal standards (no user inputs for these)
#define PXM_DB_SCHEMA_VERSION  2
#define PXM_FEATURE_VERSION    2
#define PXM_DB_RETENTION_DAYS  180
#define PXM_DB_MAX_ROWS_PER_TF 20000
#define PXM_DB_CLEAN_INTERVAL_SEC 86400
#define PXM_MAX_ROWS           PXM_DB_MAX_ROWS_PER_TF
#define PXM_SCAN_CAP           20000
#define PXM_SIM_BARS           40
#define PXM_REHEARSE_BARS      3000
#define PXM_REHEARSE_PER_PASS  200
#define PXM_K_NEIGHBORS        50
#define PXM_MIN_SAMPLES        30
#define PXM_REFUSE_WIN_PCT     45.0
#define PXM_LUKEWARM_WIN_PCT   55.0
#define PXM_GO_WIN_PCT         62.0
#define PXM_GO_TP1_PCT         70.0
#define PXM_HALF_LOT_FACTOR    0.50
#define PXM_GO_EXPIRY_BONUS    2
#define PXM_SL_DIP_PAD_ATR     0.15
#define PXM_SL_MIN_ATR         0.80
#define PXM_SL_MAX_ATR         3.20
#define PXM_RESULT_NONE        0
#define PXM_RESULT_SL          1
#define PXM_RESULT_TP1         2
#define PXM_RESULT_TP2         3
#define PXM_RESULT_BE          4
#define PXM_RESULT_TMO         5
#define PXM_DB_SOURCE_REHEARSAL 1
#define PXM_DB_SOURCE_LIVE      2

//--- action / panel mode for the Aladin section
enum PXM_Mode
{
   PXM_MODE_OFF=0,
   PXM_MODE_FAILED=1,
   PXM_MODE_LEARNING=2,
   PXM_MODE_READY=3,
   PXM_MODE_ACTIVE=4
};

//--- in-memory row (mirrors one SQLite aladin_memory row for current symbol+TF)
struct PXM_Row
{
   int      kind;      // 1 rehearsal, 2 live signal/outcome row
   datetime time;      // signal closed-bar time
   int      dir;       // 1 buy, -1 sell
   int      score;     // total score (0-100)
   int      tier;      // 0..4
   int      l1,l2,l3,l4,l5,l6,candle;
   double   er,atrRatio,adx,rsi,stDir,sqz;
   double   atrPts,spreadPts;
   double   entry,sl,tp1,tp2;
   int      result;    // 0 unknown, 1 SL, 2 TP1-ended, 3 TP2, 4 BE-stop after TP1, 5 timeout
   int      win;       // 0/1
   int      tp1hit;    // 0/1
   double   maeATR;    // max adverse excursion in ATR units
   double   pnlR;      // realized/simulated P/L in R
   int      barsRes;   // bars from entry fill to result
};

//--- k-NN result for the current bar
struct PXM_View
{
   int    n;           // similar resolved samples used
   double winPct,tp1Pct,maeATR,avgBars;
   bool   ready;
};

//--- Phase B action report for this bar (also drives the panel Aladin section)
struct PXM_Action
{
   PXM_Mode mode;
   bool   refused;          // weak history -> block this setup
   bool   resizedLot;       // lukewarm history -> half lot factor
   bool   widenedSL;        // typical dip > planned SL -> widen
   bool   smartSLTP;        // SL/TP rewritten from measured memory
   bool   goMarket;         // stronger entry: limit -> market allowed
   bool   goExpiry;         // stronger entry: extra pending bars
   bool   fellBack;         // database/lookup failed -> classic EA path
   double lotFactor;        // extra lot multiplier (<=1.0; never raises risk)
   int    expiryBonus;      // extra bars added to pending expiry
   string stepMemory;       // panel step lines
   string stepLookup;
   string stepSLTP;
   string stepRefuse;
   string stepResize;
   string stepGO;
   string headline;         // short status for the section header
   string reason;           // one-line why (also useful for Experts log)
};

//--- live signal awaiting outcome
struct PXM_LivePend
{
   datetime time;
   int      dir;
   double   entry,sl,tp1,tp2;
   double   atr,openLots;
   double   profitSum,exitPrice;
   datetime exitTime;      // kept as datetime: it feeds PXM_ScanMAE(...,datetime toT,...)
   int      tp1hit;
   int      isTP;
   int      method;   // PX_EntryMethod at plan time (1 = market)
   int      filled;   // 1 once an entry deal actually happened
};

PXM_Row    g_pxmRows[];
int        g_pxmCount=0, g_pxmResolved=0, g_pxmRhRowsLoaded=0;
int        g_pxmFile=-1;             // Aladin SQLite database handle (kept as g_pxmFile for existing guard code)
datetime   g_pxmLastPrune=0;
PXM_View   g_pxmView;
PXM_Action g_pxmAct;
PXM_LivePend g_pxmPend;
bool       g_pxmPendActive=false;
int        g_pxmErr=0;

//--- rehearsal progress (written by PXM_Rehearse.mqh, read here for the panel)
bool g_pxmRhActive=false;
int  g_pxmRhTotal=0, g_pxmRhDone=0, g_pxmRhRows=0;

void PXM_ResetView(PXM_View &v)
{
   v.n=0; v.winPct=0.0; v.tp1Pct=0.0; v.maeATR=0.0; v.avgBars=0.0; v.ready=false;
}

void PXM_ResetAction(PXM_Action &a)
{
   a.mode=PXM_MODE_OFF;
   a.refused=false; a.resizedLot=false; a.widenedSL=false;
   a.smartSLTP=false; a.goMarket=false; a.goExpiry=false; a.fellBack=false;
   a.lotFactor=1.0; a.expiryBonus=0;
   a.stepMemory=""; a.stepLookup=""; a.stepSLTP="";
   a.stepRefuse=""; a.stepResize=""; a.stepGO="";
   a.headline="Aladin off"; a.reason="";
}

// Auto spread in points for this symbol (dynamic; no user input).
double PXM_AutoSpreadPoints(const double fallbackPts=0.0)
{
   double sp=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   if(sp>0.0) return sp;
   if(fallbackPts>0.0) return fallbackPts;
   return 0.0;
}

// True when Aladin may act on trading (ON + database OK + enough similar fresh samples).
bool PXM_CanAct()
{
   return (InpEnableAladin && g_pxmFile>=0 && g_pxmView.ready && g_pxmView.n>=PXM_MIN_SAMPLES && !g_pxmAct.fellBack);
}

//+------------------------------------------------------------------+
//| Plain-language Aladin / FUTURE VIEW status for the main panel.   |
//| Shows OFF / FAILED / LEARNING / ACTIVE and the current steps.    |
//+------------------------------------------------------------------+
string PXM_FutureViewStatus(const double atr,const double entry,const double sl)
{
   if(!InpEnableAladin) return "Aladin off.";
   if(g_pxmAct.fellBack || g_pxmFile<0)
      return (g_pxmAct.reason!=""?g_pxmAct.reason:"Aladin failed - using classic EA path.");
   if(g_pxmRhActive)
   {
      int pct=(g_pxmRhTotal>0?(int)MathRound(100.0*g_pxmRhDone/(double)g_pxmRhTotal):0);
      return "Aladin learning - building history ("+IntegerToString(pct)+"% / "+IntegerToString(g_pxmCount)+" setups). Actions wait until ready.";
   }
   if(g_pxmResolved<PXM_MIN_SAMPLES)
   {
      bool done=PXM_RehearsalDoneDB();
      if(g_pxmAct.fellBack)
         return (g_pxmAct.reason!=""?g_pxmAct.reason:"Aladin failed - using classic EA path.");
      if(!g_pxmRhActive && done)
         return "Aladin rehearsal complete - bank small ("+IntegerToString(g_pxmResolved)+"/"+IntegerToString(PXM_MIN_SAMPLES)+" resolved). Actions wait for more live outcomes.";
      return "Aladin learning - needs "+IntegerToString(PXM_MIN_SAMPLES)+" resolved outcomes before actions arm. Bank: "+IntegerToString(g_pxmResolved)+".";
   }
   if(g_pxmView.n<=0)
      return "Aladin ready - no similar setups for this signal yet (classic path this bar).";

   string txt=StringFormat("Aladin active - similar %d | win %.0f%% | TP1 %.0f%% | dip %.1f ATR.",
                           g_pxmView.n,g_pxmView.winPct,g_pxmView.tp1Pct,g_pxmView.maeATR);
   if(g_pxmAct.refused) txt+=" REFUSED.";
   else
   {
      if(g_pxmAct.smartSLTP) txt+=" SL/TP tuned.";
      if(g_pxmAct.resizedLot) txt+=" Lot resized.";
      if(g_pxmAct.goMarket || g_pxmAct.goExpiry) txt+=" Stronger entry.";
      if(!g_pxmAct.smartSLTP && !g_pxmAct.resizedLot && !g_pxmAct.goMarket && !g_pxmAct.goExpiry)
         txt+=" History OK - no change needed.";
   }
   if(atr>0.0 && entry>0.0 && sl>0.0 && MathAbs(entry-sl)>0.0)
   {
      double slATR=MathAbs(entry-sl)/atr;
      if(g_pxmView.maeATR>slATR) txt+=" Dip note: history dipped past stop.";
   }
   return txt;
}

// Multi-line Aladin section body for the left panel (steps + headline).
string PXM_AladinPanelBody()
{
   if(!InpEnableAladin)
      return "Status: OFF\nFuture View off. Classic PREDICT-X only.";

   string body="Status: "+g_pxmAct.headline;
   if(g_pxmAct.stepMemory!="") body+="\n1) "+g_pxmAct.stepMemory;
   if(g_pxmAct.stepLookup!="") body+="\n2) "+g_pxmAct.stepLookup;
   if(g_pxmAct.stepRefuse!="") body+="\n3) "+g_pxmAct.stepRefuse;
   if(g_pxmAct.stepSLTP!="")   body+="\n4) "+g_pxmAct.stepSLTP;
   if(g_pxmAct.stepResize!="") body+="\n5) "+g_pxmAct.stepResize;
   if(g_pxmAct.stepGO!="")     body+="\n6) "+g_pxmAct.stepGO;
   if(g_pxmAct.reason!="")     body+="\nNote: "+g_pxmAct.reason;
   return body;
}

//+------------------------------------------------------------------+
//| Keys / database names                                             |
//+------------------------------------------------------------------+
string PXM_GV(const string suffix)
{
   return "PREDICTX.MEM."+_Symbol+"."+PX_TFToString(_Period)+"."+suffix;
}

string PXM_FileName()
{
   // One persistent SQLite database for all live symbols/timeframes. Tester uses
   // a separate file so optimization/backtest runs cannot pollute live learning.
   string suffix=((bool)MQLInfoInteger(MQL_TESTER)?"_TESTER":"");
   return "PREDICTX_ALADIN_MEMORY"+suffix+".sqlite";
}

// Pending live-outcome tracker persistence remains in terminal global variables
// because it is small scalar state for the currently open/just-closed trade. The
// actual learning bank is the SQLite database below.
double PXM_PendGet(const string suffix)
{
   string key=PXM_GV(suffix);
   if(!GlobalVariableCheck(key)) return 0.0;
   return GlobalVariableGet(key);
}

void PXM_PendDelGV()
{
   GlobalVariablesDeleteAll(PXM_GV("pend."));
}

//--- SQL number serialization helpers.  Explicit strings avoid locale/precision
//--- surprises when building SQLite statements.
string PXM_FmtD(const double v)
{
   return DoubleToString(v,12);
}
string PXM_FmtI(const long v)
{
   return IntegerToString(v);
}

//+------------------------------------------------------------------+
//| SQLite storage / load / append / update                           |
//+------------------------------------------------------------------+
string PXM_SQLText(string text)
{
   StringReplace(text,"'","''");
   return "'"+text+"'";
}

datetime PXM_Now()
{
   // Use market/chart time as the freshness reference. In Strategy Tester this
   // avoids comparing old test data against the computer's real calendar date.
   datetime chartNow=iTime(_Symbol,_Period,0);
   if((bool)MQLInfoInteger(MQL_TESTER) && chartNow>0) return chartNow;
   datetime now=TimeCurrent();
   if(now<=0 && chartNow>0) now=chartNow;
   if(now<=0) now=TimeLocal();
   return now;
}

datetime PXM_CutoffTime()
{
   return (datetime)((long)PXM_Now()-(long)PXM_DB_RETENTION_DAYS*(long)86400);
}

string PXM_SQLSymbol(){ return PXM_SQLText(_Symbol); }
string PXM_SQLTF(){ return PXM_SQLText(PX_TFToString(_Period)); }

bool PXM_DBExec(const string sql,const string context="")
{
   if(g_pxmFile<0) return false;
   ResetLastError();
   if(DatabaseExecute(g_pxmFile,sql)) return true;
   int err=GetLastError();
   g_pxmErr++;
   if(g_pxmErr<=5)
      Print("PREDICT-X ALADIN DB: ",(context!=""?context:"SQL")," failed err=",err," sql=",sql);
   return false;
}

void PXM_MarkDBFailure(const string reason)
{
   g_pxmAct.fellBack=true;
   g_pxmAct.mode=PXM_MODE_FAILED;
   g_pxmAct.headline="Aladin failed";
   g_pxmAct.reason=reason;
   g_pxmAct.stepMemory=reason;
   g_pxmRhActive=false;
}

bool PXM_EnsureDB()
{
   if(g_pxmFile<0) return false;
   // Harmless pragmas; do not fail the whole memory bank if a broker build
   // rejects either one.
   DatabaseExecute(g_pxmFile,"PRAGMA journal_mode=WAL");
   DatabaseExecute(g_pxmFile,"PRAGMA synchronous=NORMAL");
   DatabaseExecute(g_pxmFile,"PRAGMA busy_timeout=3000");

   bool ok=true;
   ok=(PXM_DBExec(
      "CREATE TABLE IF NOT EXISTS aladin_memory ("
      "id INTEGER PRIMARY KEY AUTOINCREMENT,"
      "schema_ver INTEGER NOT NULL,"
      "feature_ver INTEGER NOT NULL,"
      "source INTEGER NOT NULL,"
      "symbol TEXT NOT NULL,"
      "timeframe TEXT NOT NULL,"
      "sig_time INTEGER NOT NULL,"
      "dir INTEGER NOT NULL,"
      "score INTEGER NOT NULL,"
      "tier INTEGER NOT NULL,"
      "l1 INTEGER NOT NULL,"
      "l2 INTEGER NOT NULL,"
      "l3 INTEGER NOT NULL,"
      "l4 INTEGER NOT NULL,"
      "l5 INTEGER NOT NULL,"
      "l6 INTEGER NOT NULL,"
      "candle INTEGER NOT NULL,"
      "er REAL NOT NULL,"
      "atr_ratio REAL NOT NULL,"
      "adx REAL NOT NULL,"
      "rsi REAL NOT NULL,"
      "st_dir REAL NOT NULL,"
      "sqz REAL NOT NULL,"
      "atr_pts REAL NOT NULL,"
      "spread_pts REAL NOT NULL,"
      "entry REAL NOT NULL,"
      "sl REAL NOT NULL,"
      "tp1 REAL NOT NULL,"
      "tp2 REAL NOT NULL,"
      "result INTEGER NOT NULL,"
      "win INTEGER NOT NULL,"
      "tp1_hit INTEGER NOT NULL,"
      "mae_atr REAL NOT NULL,"
      "pnl_r REAL NOT NULL,"
      "bars_res INTEGER NOT NULL,"
      "created_at INTEGER NOT NULL,"
      "updated_at INTEGER NOT NULL,"
      "UNIQUE(symbol,timeframe,feature_ver,source,sig_time)"
      ")","create memory table") && ok);
   ok=(PXM_DBExec("CREATE INDEX IF NOT EXISTS idx_aladin_lookup ON aladin_memory(symbol,timeframe,feature_ver,dir,result,sig_time DESC)","create lookup index") && ok);
   ok=(PXM_DBExec("CREATE INDEX IF NOT EXISTS idx_aladin_roll ON aladin_memory(symbol,timeframe,feature_ver,sig_time DESC,id DESC)","create rolling index") && ok);
   ok=(PXM_DBExec(
      "CREATE TABLE IF NOT EXISTS aladin_meta ("
      "symbol TEXT NOT NULL,"
      "timeframe TEXT NOT NULL,"
      "feature_ver INTEGER NOT NULL,"
      "meta_key TEXT NOT NULL,"
      "value_int INTEGER NOT NULL,"
      "updated_at INTEGER NOT NULL,"
      "PRIMARY KEY(symbol,timeframe,feature_ver,meta_key)"
      ")","create meta table") && ok);
   return ok;
}

bool PXM_BeginDBTransaction()
{
   if(g_pxmFile<0) return false;
   ResetLastError();
   return DatabaseTransactionBegin(g_pxmFile);
}

bool PXM_CommitDBTransaction()
{
   if(g_pxmFile<0) return false;
   ResetLastError();
   return DatabaseTransactionCommit(g_pxmFile);
}

bool PXM_RollbackDBTransaction()
{
   if(g_pxmFile<0) return false;
   ResetLastError();
   return DatabaseTransactionRollback(g_pxmFile);
}

bool PXM_PruneDB(const bool force=false)
{
   if(g_pxmFile<0) return false;
   datetime now=PXM_Now();
   if(!force && g_pxmLastPrune>0 && (long)(now-g_pxmLastPrune)<PXM_DB_CLEAN_INTERVAL_SEC)
      return true;

   string sym=PXM_SQLSymbol();
   string tf=PXM_SQLTF();
   string fv=PXM_FmtI(PXM_FEATURE_VERSION);
   string sv=PXM_FmtI(PXM_DB_SCHEMA_VERSION);
   string cutoff=PXM_FmtI((long)PXM_CutoffTime());
   string nowText=PXM_FmtI((long)now);
   string maxRows=PXM_FmtI(PXM_DB_MAX_ROWS_PER_TF);

   bool txn=PXM_BeginDBTransaction();
   bool ok=true;
   // Never use stale/incompatible rows.  They are removed when possible and,
   // more importantly, all load/lookup queries filter them out even if deletion
   // fails for any reason.
   ok=(PXM_DBExec("DELETE FROM aladin_memory WHERE schema_ver<>"+sv+" OR feature_ver<>"+fv,"prune incompatible rows") && ok);
   ok=(PXM_DBExec("DELETE FROM aladin_memory WHERE source NOT IN ("+PXM_FmtI(PXM_DB_SOURCE_REHEARSAL)+","+PXM_FmtI(PXM_DB_SOURCE_LIVE)+")","prune unknown-source rows") && ok);
   ok=(PXM_DBExec("DELETE FROM aladin_memory WHERE sig_time<"+cutoff,"prune stale rows") && ok);
   ok=(PXM_DBExec("DELETE FROM aladin_memory WHERE symbol="+sym+" AND timeframe="+tf+" AND sig_time>"+nowText,"prune future rows") && ok);
   ok=(PXM_DBExec(
      "DELETE FROM aladin_memory WHERE symbol="+sym+" AND timeframe="+tf+" AND feature_ver="+fv+
      " AND id NOT IN (SELECT id FROM (SELECT id FROM aladin_memory WHERE symbol="+sym+
      " AND timeframe="+tf+" AND feature_ver="+fv+" ORDER BY sig_time DESC,id DESC LIMIT "+maxRows+"))",
      "prune rolling rows") && ok);
   ok=(PXM_DBExec("DELETE FROM aladin_meta WHERE feature_ver<>"+fv+" OR updated_at<"+cutoff,"prune stale meta") && ok);

   if(txn)
   {
      if(ok)
      {
         if(!PXM_CommitDBTransaction()) ok=false;
      }
      else PXM_RollbackDBTransaction();
   }
   if(ok) g_pxmLastPrune=now;
   return ok;
}

void PXM_AddLoadedRow(const PXM_Row &r)
{
   if(r.kind!=PXM_DB_SOURCE_REHEARSAL && r.kind!=PXM_DB_SOURCE_LIVE) return;
   if(g_pxmCount>=PXM_MAX_ROWS) return;
   ArrayResize(g_pxmRows,g_pxmCount+1,4096);
   g_pxmRows[g_pxmCount]=r;
   g_pxmCount++;
   if(r.kind==PXM_DB_SOURCE_REHEARSAL) g_pxmRhRowsLoaded++;
   if(r.result>=PXM_RESULT_SL && r.result<=PXM_RESULT_BE) g_pxmResolved++;
}

void PXM_LoadDBRow(const int q)
{
   PXM_Row r;
   int iv=0;
   long lv=0;
   double dv=0.0;
   bool ok=true;

   ok=(ok && DatabaseColumnInteger(q,0,iv));  r.kind=iv;
   ok=(ok && DatabaseColumnLong(q,1,lv));     r.time=(datetime)lv;
   ok=(ok && DatabaseColumnInteger(q,2,iv));  r.dir=iv;
   ok=(ok && DatabaseColumnInteger(q,3,iv));  r.score=iv;
   ok=(ok && DatabaseColumnInteger(q,4,iv));  r.tier=iv;
   ok=(ok && DatabaseColumnInteger(q,5,iv));  r.l1=iv;
   ok=(ok && DatabaseColumnInteger(q,6,iv));  r.l2=iv;
   ok=(ok && DatabaseColumnInteger(q,7,iv));  r.l3=iv;
   ok=(ok && DatabaseColumnInteger(q,8,iv));  r.l4=iv;
   ok=(ok && DatabaseColumnInteger(q,9,iv));  r.l5=iv;
   ok=(ok && DatabaseColumnInteger(q,10,iv)); r.l6=iv;
   ok=(ok && DatabaseColumnInteger(q,11,iv)); r.candle=iv;
   ok=(ok && DatabaseColumnDouble(q,12,dv));  r.er=dv;
   ok=(ok && DatabaseColumnDouble(q,13,dv));  r.atrRatio=dv;
   ok=(ok && DatabaseColumnDouble(q,14,dv));  r.adx=dv;
   ok=(ok && DatabaseColumnDouble(q,15,dv));  r.rsi=dv;
   ok=(ok && DatabaseColumnDouble(q,16,dv));  r.stDir=dv;
   ok=(ok && DatabaseColumnDouble(q,17,dv));  r.sqz=dv;
   ok=(ok && DatabaseColumnDouble(q,18,dv));  r.atrPts=dv;
   ok=(ok && DatabaseColumnDouble(q,19,dv));  r.spreadPts=dv;
   ok=(ok && DatabaseColumnDouble(q,20,dv));  r.entry=dv;
   ok=(ok && DatabaseColumnDouble(q,21,dv));  r.sl=dv;
   ok=(ok && DatabaseColumnDouble(q,22,dv));  r.tp1=dv;
   ok=(ok && DatabaseColumnDouble(q,23,dv));  r.tp2=dv;
   ok=(ok && DatabaseColumnInteger(q,24,iv)); r.result=iv;
   ok=(ok && DatabaseColumnInteger(q,25,iv)); r.win=iv;
   ok=(ok && DatabaseColumnInteger(q,26,iv)); r.tp1hit=iv;
   ok=(ok && DatabaseColumnDouble(q,27,dv));  r.maeATR=dv;
   ok=(ok && DatabaseColumnDouble(q,28,dv));  r.pnlR=dv;
   ok=(ok && DatabaseColumnInteger(q,29,iv)); r.barsRes=iv;

   if(ok) PXM_AddLoadedRow(r);
}

bool PXM_RehearsalDoneDB()
{
   if(g_pxmFile<0) return false;
   string sql="SELECT value_int FROM aladin_meta WHERE symbol="+PXM_SQLSymbol()+
              " AND timeframe="+PXM_SQLTF()+
              " AND feature_ver="+PXM_FmtI(PXM_FEATURE_VERSION)+
              " AND meta_key='rehearsal_done' AND updated_at>="+PXM_FmtI((long)PXM_CutoffTime())+
              " LIMIT 1";
   int q=DatabasePrepare(g_pxmFile,sql);
   if(q<0)
   {
      g_pxmErr++;
      if(g_pxmErr<=5) Print("PREDICT-X ALADIN DB: rehearsal meta prepare failed err=",GetLastError());
      PXM_MarkDBFailure("Aladin database metadata read failed - classic EA path.");
      return false;
   }
   bool done=false;
   if(DatabaseRead(q))
   {
      int v=0;
      if(DatabaseColumnInteger(q,0,v)) done=(v>0);
   }
   DatabaseFinalize(q);
   return done;
}

void PXM_SetRehearsalDoneDB()
{
   if(g_pxmFile<0) return;
   string sql="INSERT OR REPLACE INTO aladin_meta(symbol,timeframe,feature_ver,meta_key,value_int,updated_at) VALUES("+
              PXM_SQLSymbol()+","+PXM_SQLTF()+","+PXM_FmtI(PXM_FEATURE_VERSION)+
              ",'rehearsal_done',1,"+PXM_FmtI((long)PXM_Now())+")";
   if(!PXM_DBExec(sql,"set rehearsal done"))
   {
      PXM_MarkDBFailure("Aladin database metadata write failed - classic EA path.");
   }
}

bool PXM_InsertRowDB(const PXM_Row &r)
{
   if(g_pxmFile<0) return false;
   if(r.kind!=PXM_DB_SOURCE_REHEARSAL && r.kind!=PXM_DB_SOURCE_LIVE) return false;
   string now=PXM_FmtI((long)PXM_Now());
   string sql="INSERT OR IGNORE INTO aladin_memory("
      "schema_ver,feature_ver,source,symbol,timeframe,sig_time,dir,score,tier,"
      "l1,l2,l3,l4,l5,l6,candle,er,atr_ratio,adx,rsi,st_dir,sqz,atr_pts,spread_pts,"
      "entry,sl,tp1,tp2,result,win,tp1_hit,mae_atr,pnl_r,bars_res,created_at,updated_at) VALUES(";
   sql+=PXM_FmtI(PXM_DB_SCHEMA_VERSION)+","+PXM_FmtI(PXM_FEATURE_VERSION)+","+PXM_FmtI(r.kind)+","+
        PXM_SQLSymbol()+","+PXM_SQLTF()+","+PXM_FmtI((long)r.time)+","+PXM_FmtI(r.dir)+","+
        PXM_FmtI(r.score)+","+PXM_FmtI(r.tier)+","+PXM_FmtI(r.l1)+","+PXM_FmtI(r.l2)+","+
        PXM_FmtI(r.l3)+","+PXM_FmtI(r.l4)+","+PXM_FmtI(r.l5)+","+PXM_FmtI(r.l6)+","+
        PXM_FmtI(r.candle)+","+PXM_FmtD(r.er)+","+PXM_FmtD(r.atrRatio)+","+PXM_FmtD(r.adx)+","+
        PXM_FmtD(r.rsi)+","+PXM_FmtD(r.stDir)+","+PXM_FmtD(r.sqz)+","+PXM_FmtD(r.atrPts)+","+
        PXM_FmtD(r.spreadPts)+","+PXM_FmtD(r.entry)+","+PXM_FmtD(r.sl)+","+PXM_FmtD(r.tp1)+","+
        PXM_FmtD(r.tp2)+","+PXM_FmtI(r.result)+","+PXM_FmtI(r.win)+","+PXM_FmtI(r.tp1hit)+","+
        PXM_FmtD(r.maeATR)+","+PXM_FmtD(r.pnlR)+","+PXM_FmtI(r.barsRes)+","+now+","+now+")";
   return PXM_DBExec(sql,"insert memory row");
}

bool PXM_LiveRowExistsDB(const datetime time,const int dir)
{
   if(g_pxmFile<0) return false;
   string sql="SELECT id FROM aladin_memory WHERE symbol="+PXM_SQLSymbol()+
              " AND timeframe="+PXM_SQLTF()+
              " AND schema_ver="+PXM_FmtI(PXM_DB_SCHEMA_VERSION)+
              " AND feature_ver="+PXM_FmtI(PXM_FEATURE_VERSION)+
              " AND source="+PXM_FmtI(PXM_DB_SOURCE_LIVE)+
              " AND sig_time="+PXM_FmtI((long)time)+
              " AND dir="+PXM_FmtI(dir)+
              " AND sig_time>="+PXM_FmtI((long)PXM_CutoffTime())+
              " AND sig_time<="+PXM_FmtI((long)PXM_Now())+
              " LIMIT 1";
   ResetLastError();
   int q=DatabasePrepare(g_pxmFile,sql);
   if(q<0)
   {
      g_pxmErr++;
      if(g_pxmErr<=5) Print("PREDICT-X ALADIN DB: live-row check prepare failed err=",GetLastError());
      return false;
   }
   bool found=DatabaseRead(q);
   DatabaseFinalize(q);
   return found;
}

bool PXM_UpdateLiveRowDB(const datetime time,const int dir,const double entry,const double sl,const double tp1,const double tp2,
                         const int result,const int win,const int tp1hit,const double maeATR,const double pnlR,const int barsRes)
{
   if(g_pxmFile<0) return false;
   if(!PXM_LiveRowExistsDB(time,dir)) return false;
   string sql="UPDATE aladin_memory SET entry="+PXM_FmtD(entry)+
              ",sl="+PXM_FmtD(sl)+
              ",tp1="+PXM_FmtD(tp1)+
              ",tp2="+PXM_FmtD(tp2)+
              ",result="+PXM_FmtI(result)+
              ",win="+PXM_FmtI(win)+
              ",tp1_hit="+PXM_FmtI(tp1hit)+
              ",mae_atr="+PXM_FmtD(maeATR)+
              ",pnl_r="+PXM_FmtD(pnlR)+
              ",bars_res="+PXM_FmtI(barsRes)+
              ",updated_at="+PXM_FmtI((long)PXM_Now())+
              " WHERE symbol="+PXM_SQLSymbol()+
              " AND timeframe="+PXM_SQLTF()+
              " AND schema_ver="+PXM_FmtI(PXM_DB_SCHEMA_VERSION)+
              " AND feature_ver="+PXM_FmtI(PXM_FEATURE_VERSION)+
              " AND source="+PXM_FmtI(PXM_DB_SOURCE_LIVE)+
              " AND sig_time="+PXM_FmtI((long)time)+
              " AND dir="+PXM_FmtI(dir);
   return PXM_DBExec(sql,"update live outcome");
}

void PXM_RecountMemory()
{
   g_pxmResolved=0;
   g_pxmRhRowsLoaded=0;
   for(int i=0;i<g_pxmCount;i++)
   {
      if(g_pxmRows[i].kind==PXM_DB_SOURCE_REHEARSAL) g_pxmRhRowsLoaded++;
      if(g_pxmRows[i].result>=PXM_RESULT_SL && g_pxmRows[i].result<=PXM_RESULT_BE) g_pxmResolved++;
   }
}

void PXM_TrimMemoryIfNeeded()
{
   if(g_pxmCount<=PXM_MAX_ROWS) return;
   int keep=PXM_MAX_ROWS;
   int off=g_pxmCount-keep;
   for(int i=0;i<keep;i++) g_pxmRows[i]=g_pxmRows[off+i];
   ArrayResize(g_pxmRows,keep,4096);
   g_pxmCount=keep;
   PXM_RecountMemory();
}

void PXM_PruneMemoryStale()
{
   datetime cutoff=PXM_CutoffTime();
   datetime now=PXM_Now();
   int w=0;
   for(int i=0;i<g_pxmCount;i++)
   {
      if(g_pxmRows[i].time<cutoff || g_pxmRows[i].time>now) continue;
      if(g_pxmRows[i].kind!=PXM_DB_SOURCE_REHEARSAL && g_pxmRows[i].kind!=PXM_DB_SOURCE_LIVE) continue;
      if(w!=i) g_pxmRows[w]=g_pxmRows[i];
      w++;
   }
   if(w!=g_pxmCount)
   {
      ArrayResize(g_pxmRows,w,4096);
      g_pxmCount=w;
      PXM_RecountMemory();
   }
}

void PXM_Load()
{
   g_pxmCount=0; g_pxmResolved=0; g_pxmRhRowsLoaded=0;
   ArrayResize(g_pxmRows,0);
   if(g_pxmFile>=0)
   {
      if(!PXM_PruneDB(true))
      {
         PXM_MarkDBFailure("Aladin database cleanup failed - classic EA path.");
         return;
      }
      string sql="SELECT source,sig_time,dir,score,tier,l1,l2,l3,l4,l5,l6,candle,"
                 "er,atr_ratio,adx,rsi,st_dir,sqz,atr_pts,spread_pts,entry,sl,tp1,tp2,"
                 "result,win,tp1_hit,mae_atr,pnl_r,bars_res FROM ("
                 "SELECT * FROM aladin_memory WHERE symbol="+PXM_SQLSymbol()+
                 " AND timeframe="+PXM_SQLTF()+
                 " AND schema_ver="+PXM_FmtI(PXM_DB_SCHEMA_VERSION)+
                 " AND feature_ver="+PXM_FmtI(PXM_FEATURE_VERSION)+
                 " AND sig_time>="+PXM_FmtI((long)PXM_CutoffTime())+
                 " AND sig_time<="+PXM_FmtI((long)PXM_Now())+
                 " AND source IN ("+PXM_FmtI(PXM_DB_SOURCE_REHEARSAL)+","+PXM_FmtI(PXM_DB_SOURCE_LIVE)+")"
                 " ORDER BY sig_time DESC,id DESC LIMIT "+PXM_FmtI(PXM_MAX_ROWS)+") ORDER BY sig_time ASC,id ASC";
      int q=DatabasePrepare(g_pxmFile,sql);
      if(q>=0)
      {
         while(DatabaseRead(q)) PXM_LoadDBRow(q);
         DatabaseFinalize(q);
      }
      else
      {
         g_pxmErr++;
         if(g_pxmErr<=5) Print("PREDICT-X ALADIN DB: load query prepare failed err=",GetLastError());
         PXM_MarkDBFailure("Aladin database read failed - classic EA path.");
         return;
      }
   }

   g_pxmPendActive=false;
   if(GlobalVariableCheck(PXM_GV("pend.time")))
   {
      double t=PXM_PendGet("pend.time");
      if(t>0.0)
      {
         datetime pt=(datetime)(long)t;
         if(pt>=PXM_CutoffTime() && pt<=PXM_Now())
         {
            g_pxmPend.time=pt;
            g_pxmPend.dir=(int)PXM_PendGet("pend.dir");
            g_pxmPend.entry=PXM_PendGet("pend.entry");
            g_pxmPend.sl=PXM_PendGet("pend.sl");
            g_pxmPend.tp1=PXM_PendGet("pend.tp1");
            g_pxmPend.tp2=PXM_PendGet("pend.tp2");
            g_pxmPend.atr=PXM_PendGet("pend.atr");
            g_pxmPend.openLots=PXM_PendGet("pend.openLots");
            g_pxmPend.profitSum=PXM_PendGet("pend.profitSum");
            g_pxmPend.tp1hit=(int)PXM_PendGet("pend.tp1hit");
            g_pxmPend.exitPrice=PXM_PendGet("pend.exitPrice");
            g_pxmPend.exitTime=(datetime)(long)PXM_PendGet("pend.exitTime");
            g_pxmPend.isTP=(int)PXM_PendGet("pend.isTP");
            g_pxmPend.method=(int)PXM_PendGet("pend.method");
            g_pxmPend.filled=(int)PXM_PendGet("pend.filled");
            g_pxmPendActive=true;
         }
         else PXM_PendDelGV();
      }
   }
}

void PXM_SavePendGV()
{
   if(!g_pxmPendActive) { PXM_PendDelGV(); return; }
   GlobalVariableSet(PXM_GV("pend.time"),      (double)(long)g_pxmPend.time);
   GlobalVariableSet(PXM_GV("pend.dir"),       (double)g_pxmPend.dir);
   GlobalVariableSet(PXM_GV("pend.entry"),     g_pxmPend.entry);
   GlobalVariableSet(PXM_GV("pend.sl"),        g_pxmPend.sl);
   GlobalVariableSet(PXM_GV("pend.tp1"),       g_pxmPend.tp1);
   GlobalVariableSet(PXM_GV("pend.tp2"),       g_pxmPend.tp2);
   GlobalVariableSet(PXM_GV("pend.atr"),       g_pxmPend.atr);
   GlobalVariableSet(PXM_GV("pend.openLots"),  g_pxmPend.openLots);
   GlobalVariableSet(PXM_GV("pend.profitSum"), g_pxmPend.profitSum);
   GlobalVariableSet(PXM_GV("pend.tp1hit"),    (double)g_pxmPend.tp1hit);
   GlobalVariableSet(PXM_GV("pend.exitPrice"), g_pxmPend.exitPrice);
   GlobalVariableSet(PXM_GV("pend.exitTime"),  (double)(long)g_pxmPend.exitTime);
   GlobalVariableSet(PXM_GV("pend.isTP"),      (double)g_pxmPend.isTP);
   GlobalVariableSet(PXM_GV("pend.method"),    (double)g_pxmPend.method);
   GlobalVariableSet(PXM_GV("pend.filled"),    (double)g_pxmPend.filled);
}

void PXM_Init()
{
   PXM_ResetView(g_pxmView);
   PXM_ResetAction(g_pxmAct);
   g_pxmErr=0;
   g_pxmLastPrune=0;
   if(!InpEnableAladin)
   {
      g_pxmFile=-1;
      g_pxmAct.mode=PXM_MODE_OFF;
      g_pxmAct.headline="Aladin off";
      g_pxmAct.stepMemory="Master switch OFF";
      return;
   }
   string name=PXM_FileName();
   g_pxmFile=DatabaseOpen(name,DATABASE_OPEN_READWRITE|DATABASE_OPEN_CREATE|DATABASE_OPEN_COMMON);
   if(g_pxmFile<0)
   {
      g_pxmAct.mode=PXM_MODE_FAILED;
      g_pxmAct.fellBack=true;
      g_pxmAct.headline="Aladin failed";
      g_pxmAct.reason="Aladin database unavailable - classic EA path (no Aladin actions).";
      g_pxmAct.stepMemory="FAILED: cannot open database "+name;
      Print("PREDICT-X ALADIN: cannot open database '",name,"' err=",GetLastError()," - falling back to classic EA.");
      return;
   }
   if(!PXM_EnsureDB())
   {
      DatabaseClose(g_pxmFile);
      g_pxmFile=-1;
      g_pxmAct.mode=PXM_MODE_FAILED;
      g_pxmAct.fellBack=true;
      g_pxmAct.headline="Aladin failed";
      g_pxmAct.reason="Aladin database schema unavailable - classic EA path (no Aladin actions).";
      g_pxmAct.stepMemory="FAILED: cannot create/read database schema";
      return;
   }
   PXM_Load();
   if(g_pxmAct.fellBack) return;
   g_pxmAct.mode=PXM_MODE_LEARNING;
   g_pxmAct.headline="Aladin learning";
   g_pxmAct.stepMemory=StringFormat("DB loaded: %d fresh setups (%d resolved), database %s",g_pxmCount,g_pxmResolved,name);
   Print("PREDICT-X ALADIN: database loaded: ",g_pxmCount," fresh rows (",g_pxmResolved,
         " resolved outcomes), database=",name,". Strict same symbol/timeframe, feature v",PXM_FEATURE_VERSION,
         ", retention ",PXM_DB_RETENTION_DAYS," days.");
}

void PXM_Cleanup()
{
   if(g_pxmFile>=0)
   {
      DatabaseClose(g_pxmFile);
      g_pxmFile=-1;
   }
}

//+------------------------------------------------------------------+
//| Append a fully built row (used by PXM_Rehearse.mqh and live log) |
//+------------------------------------------------------------------+
bool PXM_AppendRow(const PXM_Row &r)
{
   if(!InpEnableAladin) return false;
   if(g_pxmFile<0) return false;
   if(r.kind!=PXM_DB_SOURCE_REHEARSAL && r.kind!=PXM_DB_SOURCE_LIVE) return false;
   if(r.time<PXM_CutoffTime() || r.time>PXM_Now()) return false; // never learn from stale/future history

   // Strict dedupe in RAM; DB has the same UNIQUE constraint for restart safety.
   for(int i=g_pxmCount-1;i>=0;i--)
      if(g_pxmRows[i].kind==r.kind && g_pxmRows[i].time==r.time) return true;

   if(!PXM_InsertRowDB(r))
   {
      // Do not keep acting from memory if persistence is failing.  The classic
      // EA path is safer than an Aladin bank that cannot be updated on disk.
      PXM_MarkDBFailure("Aladin database write failed - classic EA path.");
      return false;
   }

   ArrayResize(g_pxmRows,g_pxmCount+1,4096);
   g_pxmRows[g_pxmCount]=r;
   g_pxmCount++;
   if(r.kind==PXM_DB_SOURCE_REHEARSAL) g_pxmRhRowsLoaded++;
   if(r.result>=PXM_RESULT_SL && r.result<=PXM_RESULT_BE) g_pxmResolved++;
   PXM_TrimMemoryIfNeeded();
   if(!PXM_PruneDB(false))
   {
      PXM_MarkDBFailure("Aladin database cleanup failed - classic EA path.");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Persist an outcome update for the newest live row with this time |
//+------------------------------------------------------------------+
bool PXM_AppendUpdate(const datetime time,const int dir,const double entry,const double sl,const double tp1,const double tp2,
                      const int result,const int win,const int tp1hit,const double maeATR,const double pnlR,const int barsRes)
{
   if(g_pxmFile<0) return false;
   if(time<PXM_CutoffTime() || time>PXM_Now()) return false;
   if(!PXM_UpdateLiveRowDB(time,dir,entry,sl,tp1,tp2,result,win,tp1hit,maeATR,pnlR,barsRes))
   {
      PXM_MarkDBFailure("Aladin database update failed - classic EA path.");
      return false;
   }

   for(int i=g_pxmCount-1;i>=0;i--)
   {
      if(g_pxmRows[i].kind==PXM_DB_SOURCE_LIVE && g_pxmRows[i].time==time && g_pxmRows[i].dir==dir)
      {
         bool wasRes=(g_pxmRows[i].result>=PXM_RESULT_SL && g_pxmRows[i].result<=PXM_RESULT_BE);
         g_pxmRows[i].entry=entry; g_pxmRows[i].sl=sl; g_pxmRows[i].tp1=tp1; g_pxmRows[i].tp2=tp2;
         g_pxmRows[i].result=result; g_pxmRows[i].win=win; g_pxmRows[i].tp1hit=tp1hit;
         g_pxmRows[i].maeATR=maeATR; g_pxmRows[i].pnlR=pnlR; g_pxmRows[i].barsRes=barsRes;
         bool nowRes=(result>=PXM_RESULT_SL && result<=PXM_RESULT_BE);
         if(!wasRes && nowRes) g_pxmResolved++;
         if(wasRes && !nowRes) g_pxmResolved--;
         break;
      }
   }
   if(!PXM_PruneDB(false))
   {
      PXM_MarkDBFailure("Aladin database cleanup failed - classic EA path.");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| k-NN lookup. Features are the same 12-vector the online AI uses: |
//| [preAI total, l1..l5, ER, atrRatio, ADX, RSI, STdir, squeeze]    |
//+------------------------------------------------------------------+
void PXM_FeatFromRow(const PXM_Row &r,double &x[])
{
   double f[12];
   f[0]=(double)MathMax(0,r.score-r.l6-r.candle); // pre-AI total
   f[1]=(double)r.l1; f[2]=(double)r.l2; f[3]=(double)r.l3; f[4]=(double)r.l4; f[5]=(double)r.l5;
   f[6]=r.er; f[7]=r.atrRatio; f[8]=r.adx; f[9]=r.rsi; f[10]=r.stDir; f[11]=r.sqz;
   PX3_NormalizeFeatures(f,(PX_Direction)r.dir,x);
}

double PXM_Clamp01(const double v)
{
   if(v<0.0) return 0.0;
   if(v>1.0) return 1.0;
   return v;
}

double PXM_RowNormFeature(const PXM_Row &r,const int col,const int dir)
{
   if(col==0)  return PXM_Clamp01((double)MathMax(0,r.score-r.l6-r.candle)/100.0);
   if(col==1)  return PXM_Clamp01((double)r.l1/25.0);
   if(col==2)  return PXM_Clamp01((double)r.l2/25.0);
   if(col==3)  return PXM_Clamp01((double)r.l3/20.0);
   if(col==4)  return PXM_Clamp01((double)r.l4/15.0);
   if(col==5)  return PXM_Clamp01((double)r.l5/15.0);
   if(col==6)  return PXM_Clamp01(r.er);
   if(col==7)  return PXM_Clamp01(r.atrRatio/2.0);
   if(col==8)  return PXM_Clamp01(r.adx/50.0);
   if(col==9)  return PXM_Clamp01(r.rsi/100.0);
   if(col==10) return (dir==0?0.0:r.stDir*(double)dir);
   if(col==11) return PXM_Clamp01(r.sqz);
   return 0.0;
}

double PXM_RecencyWeight(const datetime sampleTime)
{
   // Fresh learning matters most.  Anything past PXM_DB_RETENTION_DAYS is not
   // used at all; rows inside the window are still down-weighted as they age.
   datetime now=PXM_Now();
   if(sampleTime<=0 || sampleTime<PXM_CutoffTime() || sampleTime>now) return 0.0;
   double ageDays=(double)((long)now-(long)sampleTime)/86400.0;
   if(ageDays<=30.0) return 1.0;
   double span=(double)PXM_DB_RETENTION_DAYS-30.0;
   if(span<=1.0) return 0.50;
   double fade=(ageDays-30.0)/span;
   if(fade<0.0) fade=0.0;
   if(fade>1.0) fade=1.0;
   return 1.0-0.75*fade; // reaches 0.25 at the edge of the freshness window
}

void PXM_LookupKNN(const double &feat[],const int dir,const int k,PXM_View &v)
{
   PXM_ResetView(v);
   if(!InpEnableAladin || k<=0 || dir==0 || g_pxmResolved<=0) return;
   double xq[];
   PX3_NormalizeFeatures(feat,(PX_Direction)dir,xq);
   if(ArraySize(xq)!=12) return;
   double d[]; int idx[];
   ArrayResize(d,k); ArrayResize(idx,k);
   int cnt=0;
   datetime cutoff=PXM_CutoffTime();
   datetime now=PXM_Now();
   int start=MathMax(0,g_pxmCount-PXM_SCAN_CAP);
   for(int i=start;i<g_pxmCount;i++)
   {
      if(g_pxmRows[i].dir!=dir) continue;
      if(g_pxmRows[i].time<cutoff || g_pxmRows[i].time>now) continue;
      if(g_pxmRows[i].result<PXM_RESULT_SL || g_pxmRows[i].result>PXM_RESULT_BE) continue;
      double dd=0.0;
      for(int c=0;c<12;c++)
      {
         double dx=xq[c]-PXM_RowNormFeature(g_pxmRows[i],c,dir);
         dd+=dx*dx;
      }
      if(cnt<k)
      {
         int pos=cnt++;
         while(pos>0 && d[pos-1]>dd) { d[pos]=d[pos-1]; idx[pos]=idx[pos-1]; pos--; }
         d[pos]=dd; idx[pos]=i;
      }
      else if(d[k-1]>dd)
      {
         int pos=k-1;
         while(pos>0 && d[pos-1]>dd) { d[pos]=d[pos-1]; idx[pos]=idx[pos-1]; pos--; }
         d[pos]=dd; idx[pos]=i;
      }
   }
   if(cnt<=0) return;
   double sumW=0.0,sumWin=0.0,sumTp1=0.0,sumMae=0.0,sumBars=0.0;
   for(int j=0;j<cnt;j++)
   {
      PXM_Row r=g_pxmRows[idx[j]];
      double w=PXM_RecencyWeight(r.time);
      if(w<=0.0) continue;
      sumW+=w;
      sumWin+=(r.win>0?w:0.0);
      sumTp1+=(r.tp1hit>0?w:0.0);
      sumMae+=r.maeATR*w;
      sumBars+=(double)r.barsRes*w;
   }
   if(sumW<=0.0) return;
   v.n=cnt;
   v.winPct=sumWin/sumW*100.0;
   v.tp1Pct=sumTp1/sumW*100.0;
   v.maeATR=sumMae/sumW;
   v.avgBars=sumBars/sumW;
   v.ready=(cnt>=PXM_MIN_SAMPLES);
}

//+------------------------------------------------------------------+
//| Live outcome helpers                                              |
//+------------------------------------------------------------------+
void PXM_ScanMAE(const int dir,const double entry,const double atr,const datetime fromT,datetime toT,double &maeATR,int &bars)
{
   maeATR=0.0; bars=0;
   if(atr<=0.0) return;
   int s0=iBarShift(_Symbol,_Period,fromT,true);
   if(s0<0) return;
   int s1=iBarShift(_Symbol,_Period,toT,true);
   if(s1<0) s1=1;
   if(s1<1) s1=1;
   if(s0<=s1) return;
   double ext=(dir>0?1e308:-1e308);
   for(int k=s0;k>=s1;k--)
   {
      if(dir>0) { double l=iLow(_Symbol,_Period,k);  if(l<ext) ext=l; }
      else      { double h=iHigh(_Symbol,_Period,k); if(h>ext) ext=h; }
   }
   bars=s0-s1;
   if(dir>0) maeATR=MathMax(0.0,(entry-ext)/atr);
   else      maeATR=MathMax(0.0,(ext-entry)/atr);
}

// resolve an unfilled/untracked live signal from OHLC projection (database memory)
void PXM_ProjectOutcome(PXM_LivePend &p,double &maeATR,int &barsRes,int &result,double &pnlR)
{
   maeATR=0.0; barsRes=0; result=PXM_RESULT_NONE; pnlR=0.0;
   if(p.entry<=0.0 || p.sl<=0.0 || p.tp1<=0.0 || p.tp2<=0.0 || p.time<=0) return;
   int s0=iBarShift(_Symbol,_Period,p.time,true);
   if(s0<0) return;
   s0-=1; // signal bar was shift s0; execution starts the next bar
   double risk=MathAbs(p.entry-p.sl);
   if(risk<=0.0) return;
   double spread=PXM_AutoSpreadPoints()*_Point;
   bool buy=(p.dir>0);
   double beLvl=(buy?p.entry+1.5*spread:p.entry-1.5*spread);
   int sEnd=MathMax(1,s0-PXM_SIM_BARS);
   double ext=(buy?1e308:-1e308);
   bool tp1=false;
   for(int s=s0;s>=sEnd;s--)
   {
      double o=iOpen(_Symbol,_Period,s), h=iHigh(_Symbol,_Period,s), l=iLow(_Symbol,_Period,s);
      if(o<=0.0) continue;
      double slT, tp1T, tp2T, beT;
      if(buy)
      {
         slT=(l<=p.sl); tp1T=(h>=p.tp1); tp2T=(h>=p.tp2); beT=(l<=beLvl);
      }
      else
      {
         slT=(h+spread>=p.sl); tp1T=(l+spread<=p.tp1); tp2T=(l+spread<=p.tp2); beT=(h+spread>=beLvl);
      }
      // same-bar rule: SL counts first
      if(!tp1 && slT)
      {
         result=PXM_RESULT_SL; barsRes=s0-s;
         maeATR=(buy?MathMax(0.0,(p.entry-MathMin(ext,l))):MathMax(0.0,(MathMax(ext,h)-p.entry)))/p.atr;
         pnlR=-1.0;
         return;
      }
      if(tp1T && !tp1)
      {
         tp1=true; p.tp1hit=1;
         result=PXM_RESULT_TP1; barsRes=s0-s;
         pnlR=0.5*MathAbs(p.tp1-p.entry)/risk;
      }
      if(tp1)
      {
         if(tp2T)
         {
            result=PXM_RESULT_TP2; barsRes=s0-s;
            pnlR=0.5*MathAbs(p.tp1-p.entry)/risk+0.5*MathAbs(p.tp2-p.entry)/risk;
            maeATR=(buy?MathMax(0.0,(p.entry-MathMin(ext,l))):MathMax(0.0,(MathMax(ext,h)-p.entry)))/p.atr;
            return;
         }
         if(beT)
         {
            result=PXM_RESULT_BE; barsRes=s0-s;
            maeATR=(buy?MathMax(0.0,(p.entry-MathMin(ext,l))):MathMax(0.0,(MathMax(ext,h)-p.entry)))/p.atr;
            pnlR=0.5*MathAbs(p.tp1-p.entry)/risk;
            return;
         }
      }
      if(buy) { if(l<ext) ext=l; } else { if(h>ext) ext=h; }
   }
   if(tp1) { return; } // still holding the runner: leave unresolved
   result=PXM_RESULT_TMO; barsRes=PXM_SIM_BARS;
   maeATR=(buy?MathMax(0.0,(p.entry-ext)):MathMax(0.0,(ext-p.entry)))/p.atr;
   pnlR=0.0;
}

void PXM_LogLiveSignal(const PX_Lifecycle &lc,const PX_ScoreResult &sr,const PX_RegimeState &reg,const PX_ValueContext &vc,const PX_TrendContext &tc)
{
   PXM_Row r;
   r.kind=PXM_DB_SOURCE_LIVE; r.time=lc.signalTime; r.dir=(int)sr.dir;
   r.score=sr.total; r.tier=(int)sr.tier;
   r.l1=sr.layer1; r.l2=sr.layer2; r.l3=sr.layer3; r.l4=sr.layer4; r.l5=sr.layer5; r.l6=sr.layer6; r.candle=sr.candleBonus;
   r.er=reg.er; r.atrRatio=reg.atrRatio; r.adx=tc.adx; r.rsi=tc.rsi; r.stDir=(double)tc.stDir; r.sqz=tc.ttmSqueeze;
   r.atrPts=(vc.atr>0.0?vc.atr/_Point:0.0);
   r.spreadPts=PXM_AutoSpreadPoints(vc.avgSpreadPoints);
   r.entry=0.0; r.sl=0.0; r.tp1=0.0; r.tp2=0.0;
   r.result=PXM_RESULT_NONE; r.win=0; r.tp1hit=0; r.maeATR=0.0; r.pnlR=0.0; r.barsRes=0;
   if(!PXM_AppendRow(r)) return;
   // start the live outcome tracker (setup fields attach after PX_CalcTradeSetup)
   g_pxmPend.time=lc.signalTime; g_pxmPend.dir=(int)sr.dir;
   g_pxmPend.entry=0.0; g_pxmPend.sl=0.0; g_pxmPend.tp1=0.0; g_pxmPend.tp2=0.0;
   g_pxmPend.atr=vc.atr; g_pxmPend.openLots=0.0; g_pxmPend.profitSum=0.0;
   g_pxmPend.tp1hit=0; g_pxmPend.exitPrice=0.0; g_pxmPend.exitTime=0; g_pxmPend.isTP=0;
   g_pxmPend.method=0; g_pxmPend.filled=0;
   g_pxmPendActive=true;
   PXM_SavePendGV();
   Print("PREDICT-X ALADIN DB: logged live signal ",PX_DirectionText(sr.dir)," score ",sr.total," tier ",PX_TierText(sr.tier)," @ ",TimeToString(lc.signalTime,TIME_DATE|TIME_MINUTES));
}

void PXM_AttachSetup(const PX_TradeSetup &ts)
{
   if(!g_pxmPendActive) return;
   if(!ts.valid) return;
   if(g_pxmPend.sl>0.0) return; // already attached
   g_pxmPend.entry=ts.entry; g_pxmPend.sl=ts.sl; g_pxmPend.tp1=ts.tp1; g_pxmPend.tp2=ts.tp2;
   g_pxmPend.method=(int)ts.method;
   if(ts.lot>0.0 && g_pxmPend.openLots<=0.0) g_pxmPend.openLots=ts.lot;
   PXM_SavePendGV();
}

void PXM_OnTradeOpened(const double fillPrice,const double volume)
{
   if(!g_pxmPendActive || g_pxmPend.filled==1) return; // track the first real fill of the tracked signal only
   g_pxmPend.entry=fillPrice;
   g_pxmPend.filled=1;
   if(volume>0.0) g_pxmPend.openLots=volume;
   PXM_SavePendGV();
   if(!PXM_AppendUpdate(g_pxmPend.time,g_pxmPend.dir,g_pxmPend.entry,g_pxmPend.sl,g_pxmPend.tp1,g_pxmPend.tp2,
                        PXM_RESULT_NONE,0,g_pxmPend.tp1hit,0.0,0.0,0))
      return;
   Print("PREDICT-X ALADIN DB: live trade opened @ ",DoubleToString(fillPrice,_Digits));
}

void PXM_OnTradePartialTP1(const double profitMoney)
{
   if(!g_pxmPendActive) return;
   g_pxmPend.tp1hit=1;
   g_pxmPend.profitSum+=profitMoney;
   PXM_SavePendGV();
   Print("PREDICT-X ALADIN DB: TP1 partial hit, profit $",DoubleToString(profitMoney,2)," recorded for outcome backfill");
}

void PXM_OnTradeClosed(const double profitMoney,const bool isTP)
{
   if(!g_pxmPendActive) return;
   g_pxmPend.profitSum+=profitMoney;
   g_pxmPend.exitTime=TimeCurrent();
   g_pxmPend.isTP=(isTP?1:0);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double risk=MathAbs(g_pxmPend.entry-g_pxmPend.sl);
   double lots=(g_pxmPend.openLots>0.0?g_pxmPend.openLots:1.0);
   double riskMoney=(risk>0.0 && tickSize>0.0 && tickValue>0.0?risk/tickSize*tickValue*lots:0.0);
   double pnlR=(riskMoney>0.0?g_pxmPend.profitSum/riskMoney:0.0);
   int win=(g_pxmPend.profitSum>=0.0?1:0);
   int res;
   if(g_pxmPend.isTP==1) res=PXM_RESULT_TP2;
   else if(win==1) res=PXM_RESULT_TP1;   // positive finish (TP1-partial/BE/manual in profit)
   else res=PXM_RESULT_SL;
   double maeATR=0.0; int bars=0;
   PXM_ScanMAE(g_pxmPend.dir,g_pxmPend.entry,g_pxmPend.atr,g_pxmPend.time,g_pxmPend.exitTime,maeATR,bars);
   if(!PXM_AppendUpdate(g_pxmPend.time,g_pxmPend.dir,g_pxmPend.entry,g_pxmPend.sl,g_pxmPend.tp1,g_pxmPend.tp2,
                        res,win,g_pxmPend.tp1hit,maeATR,pnlR,bars))
      return;
   Print("PREDICT-X ALADIN DB: live outcome backfilled: result=",res," win=",win," pnlR=",DoubleToString(pnlR,2),
         " dip=",DoubleToString(maeATR,2)," ATR over ",bars," bars");
   g_pxmPendActive=false;
   PXM_SavePendGV();
}

//+------------------------------------------------------------------+
//| PX_FutureViewCheck - called from PX_OnNewClosedBar() between     |
//| lifecycle update and PX_CalcTradeSetup(). Memory + k-NN + steps. |
//+------------------------------------------------------------------+
void PX_FutureViewCheck(const PX_Lifecycle &lc,const bool newSignal,const PX_ScoreResult &sr,const PX_RegimeState &reg,const PX_ValueContext &vc,const PX_TrendContext &tc,const double &feat[])
{
   PXM_ResetView(g_pxmView);
   // Keep failed/off flags; rebuild step lines for this bar.
   bool wasFailed=g_pxmAct.fellBack;
   string failReason=g_pxmAct.reason;
   PXM_ResetAction(g_pxmAct);
   if(wasFailed)
   {
      g_pxmAct.fellBack=true;
      g_pxmAct.mode=PXM_MODE_FAILED;
      g_pxmAct.headline="Aladin failed";
      g_pxmAct.reason=(failReason!=""?failReason:"Aladin database unavailable - classic EA path.");
      g_pxmAct.stepMemory=g_pxmAct.reason;
      return;
   }
   if(!InpEnableAladin)
   {
      g_pxmAct.mode=PXM_MODE_OFF;
      g_pxmAct.headline="Aladin off";
      g_pxmAct.stepMemory="Master switch OFF - Future View off";
      return;
   }
   if(g_pxmFile<0)
   {
      PXM_MarkDBFailure("Aladin database unavailable - classic EA path (no Aladin actions).");
      return;
   }
   PXM_PruneMemoryStale();
   if(g_pxmPendActive && (g_pxmPend.time<PXM_CutoffTime() || g_pxmPend.time>PXM_Now()))
   {
      g_pxmPendActive=false;
      PXM_SavePendGV();
   }
   if(!PXM_PruneDB(false))
   {
      PXM_MarkDBFailure("Aladin database cleanup failed - classic EA path.");
      return;
   }

   // 1) settle unfinished live trackers
   if(g_pxmPendActive && g_pxmPend.filled==1 && g_pxmPend.entry>0.0 && lc.state!=PX_STATE_ACTIVE && lc.state!=PX_STATE_PENDING && !PX_TM_HasAnyManagedTrade())
   {
      if(TimeCurrent()>(datetime)((long)g_pxmPend.time+2*(long)PeriodSeconds(_Period)))
      {
         double mae=0.0,pnl=0.0; int bres=0,res=PXM_RESULT_NONE;
         PXM_ProjectOutcome(g_pxmPend,mae,bres,res,pnl);
         if(res!=PXM_RESULT_NONE)
         {
            int win=(res==PXM_RESULT_TP1||res==PXM_RESULT_TP2||res==PXM_RESULT_BE)?1:0;
            if(res==PXM_RESULT_TMO) win=0;
            if(!PXM_AppendUpdate(g_pxmPend.time,g_pxmPend.dir,g_pxmPend.entry,g_pxmPend.sl,g_pxmPend.tp1,g_pxmPend.tp2,
                                 res,win,g_pxmPend.tp1hit,mae,pnl,bres))
               return;
            Print("PREDICT-X ALADIN: unfilled/live-expired signal settled by OHLC projection.");
            g_pxmPendActive=false;
            PXM_SavePendGV();
         }
      }
   }
   else if(g_pxmPendActive && g_pxmPend.filled==0 && TimeCurrent()>(datetime)((long)g_pxmPend.time+(long)(2+PXM_SIM_BARS)*(long)PeriodSeconds(_Period)))
   {
      if(g_pxmPend.atr>0.0 && (g_pxmPend.method==0 || g_pxmPend.method==1))
      {
         int s0=iBarShift(_Symbol,_Period,g_pxmPend.time,true);
         if(s0>1)
         {
            if(g_pxmPend.entry<=0.0)
            {
               double entry0=iOpen(_Symbol,_Period,s0-1);
               double spread=PXM_AutoSpreadPoints()*_Point;
               if(g_pxmPend.dir>0)
               {
                  g_pxmPend.entry=entry0+spread;
                  g_pxmPend.sl=g_pxmPend.entry-2.0*g_pxmPend.atr;
                  g_pxmPend.tp1=g_pxmPend.entry+1.5*g_pxmPend.atr;
                  g_pxmPend.tp2=g_pxmPend.entry+3.0*g_pxmPend.atr;
               }
               else
               {
                  g_pxmPend.entry=entry0;
                  g_pxmPend.sl=g_pxmPend.entry+2.0*g_pxmPend.atr;
                  g_pxmPend.tp1=g_pxmPend.entry-1.5*g_pxmPend.atr;
                  g_pxmPend.tp2=g_pxmPend.entry-3.0*g_pxmPend.atr;
               }
            }
            if(g_pxmPend.sl>0.0 && g_pxmPend.tp1>0.0 && g_pxmPend.tp2>0.0)
            {
               g_pxmPend.openLots=(g_pxmPend.openLots>0.0?g_pxmPend.openLots:1.0);
               double mae=0.0,pnl=0.0; int bres=0,res=PXM_RESULT_NONE;
               PXM_ProjectOutcome(g_pxmPend,mae,bres,res,pnl);
               if(res!=PXM_RESULT_NONE)
               {
                  int win=(res==PXM_RESULT_TP1||res==PXM_RESULT_TP2||res==PXM_RESULT_BE)?1:0;
                  if(res==PXM_RESULT_TMO) win=0;
                  if(!PXM_AppendUpdate(g_pxmPend.time,g_pxmPend.dir,g_pxmPend.entry,g_pxmPend.sl,g_pxmPend.tp1,g_pxmPend.tp2,
                                       res,win,g_pxmPend.tp1hit,mae,pnl,bres))
                     return;
                  Print("PREDICT-X ALADIN: signal-not-traded settled by projection.");
                  g_pxmPendActive=false;
                  PXM_SavePendGV();
               }
            }
         }
      }
      else
      {
         g_pxmPendActive=false;
         PXM_SavePendGV();
      }
   }

   // Memory status step
   if(g_pxmRhActive)
   {
      int pct=(g_pxmRhTotal>0?(int)MathRound(100.0*g_pxmRhDone/(double)g_pxmRhTotal):0);
      g_pxmAct.stepMemory=StringFormat("Building fresh DB history %d%% (%d setups, %d resolved)",pct,g_pxmCount,g_pxmResolved);
      g_pxmAct.mode=PXM_MODE_LEARNING;
      g_pxmAct.headline="Aladin learning";
   }
   else
   {
      g_pxmAct.stepMemory=StringFormat("Fresh DB bank %d setups (%d resolved, %d-day window)",g_pxmCount,g_pxmResolved,PXM_DB_RETENTION_DAYS);
   }

   // 2) k-NN lookup for the CURRENT bar
   if(!g_pxmRhActive && g_pxmResolved>0 && sr.dir!=PX_DIR_NONE && ArraySize(feat)==12)
      PXM_LookupKNN(feat,(int)sr.dir,PXM_K_NEIGHBORS,g_pxmView);

   if(g_pxmRhActive)
   {
      g_pxmAct.mode=PXM_MODE_LEARNING;
      g_pxmAct.headline="Aladin learning";
      g_pxmAct.stepLookup=StringFormat("Rehearsing history - waiting for %d resolved outcomes before actions arm (have %d)",PXM_MIN_SAMPLES,g_pxmResolved);
      g_pxmAct.stepRefuse="Idle - learning";
      g_pxmAct.stepSLTP="Idle - learning";
      g_pxmAct.stepResize="Idle - learning";
      g_pxmAct.stepGO="Idle - learning";
   }
   else if(g_pxmResolved<PXM_MIN_SAMPLES)
   {
      g_pxmAct.mode=PXM_MODE_READY;
      g_pxmAct.headline="Aladin ready - small bank";
      g_pxmAct.stepLookup=StringFormat("Rehearsal complete; bank has %d/%d resolved outcomes. Actions wait for more live outcomes.",g_pxmResolved,PXM_MIN_SAMPLES);
      g_pxmAct.stepRefuse="Idle - small bank";
      g_pxmAct.stepSLTP="Idle - small bank";
      g_pxmAct.stepResize="Idle - small bank";
      g_pxmAct.stepGO="Idle - small bank";
   }
   else if(sr.dir==PX_DIR_NONE)
   {
      g_pxmAct.mode=PXM_MODE_READY;
      g_pxmAct.headline="Aladin ready";
      g_pxmAct.stepLookup="No direction this bar - no similar lookup";
      g_pxmAct.stepRefuse="Idle";
      g_pxmAct.stepSLTP="Idle";
      g_pxmAct.stepResize="Idle";
      g_pxmAct.stepGO="Idle";
   }
   else if(g_pxmView.n<=0)
   {
      // empty lookup: fall back quietly (do not freeze trading)
      g_pxmAct.mode=PXM_MODE_READY;
      g_pxmAct.headline="Aladin ready (no match)";
      g_pxmAct.stepLookup="No similar setups - classic EA path this bar";
      g_pxmAct.stepRefuse="Skipped - no similar history";
      g_pxmAct.stepSLTP="Skipped - classic SL/TP";
      g_pxmAct.stepResize="Skipped - full plan lot";
      g_pxmAct.stepGO="Skipped - classic entry rules";
      g_pxmAct.reason="Lookup empty - using classic PREDICT-X behaviour.";
   }
   else if(!g_pxmView.ready)
   {
      g_pxmAct.mode=PXM_MODE_LEARNING;
      g_pxmAct.headline="Aladin learning";
      g_pxmAct.stepLookup=StringFormat("Similar %d (need %d) - actions still off",g_pxmView.n,PXM_MIN_SAMPLES);
      g_pxmAct.stepRefuse="Idle - not enough similar samples";
      g_pxmAct.stepSLTP="Idle - not enough similar samples";
      g_pxmAct.stepResize="Idle - not enough similar samples";
      g_pxmAct.stepGO="Idle - not enough similar samples";
   }
   else
   {
      g_pxmAct.mode=PXM_MODE_ACTIVE;
      g_pxmAct.headline="Aladin active - all powers armed";
      g_pxmAct.stepLookup=StringFormat("Similar %d | Win %.0f%% | TP1 %.0f%% | dip %.1f ATR | ~%.1f bars",
                                       g_pxmView.n,g_pxmView.winPct,g_pxmView.tp1Pct,g_pxmView.maeATR,g_pxmView.avgBars);

      // Pre-decide refuse / resize / GO flags (applied after setup is built)
      if(g_pxmView.winPct<PXM_REFUSE_WIN_PCT)
      {
         g_pxmAct.refused=true;
         g_pxmAct.stepRefuse=StringFormat("REFUSE - win %.0f%% < %.0f%% on %d similar",g_pxmView.winPct,PXM_REFUSE_WIN_PCT,g_pxmView.n);
         g_pxmAct.reason=g_pxmAct.stepRefuse;
      }
      else
         g_pxmAct.stepRefuse=StringFormat("Allow - win %.0f%% >= %.0f%%",g_pxmView.winPct,PXM_REFUSE_WIN_PCT);

      if(!g_pxmAct.refused && g_pxmView.winPct<PXM_LUKEWARM_WIN_PCT)
      {
         g_pxmAct.resizedLot=true;
         g_pxmAct.lotFactor=PXM_HALF_LOT_FACTOR;
         g_pxmAct.stepResize=StringFormat("RESIZE lot x%.2f - lukewarm win %.0f%%",PXM_HALF_LOT_FACTOR,g_pxmView.winPct);
      }
      else if(!g_pxmAct.refused)
         g_pxmAct.stepResize="Lot plan unchanged (history not lukewarm)";
      else
         g_pxmAct.stepResize="Skipped - refused";

      if(!g_pxmAct.refused && g_pxmView.winPct>=PXM_GO_WIN_PCT && g_pxmView.tp1Pct>=PXM_GO_TP1_PCT)
      {
         g_pxmAct.goMarket=true;
         g_pxmAct.goExpiry=true;
         g_pxmAct.expiryBonus=PXM_GO_EXPIRY_BONUS;
         g_pxmAct.stepGO=StringFormat("GO - stronger entry + +%d expiry bars (win %.0f%% / TP1 %.0f%%)",
                                      PXM_GO_EXPIRY_BONUS,g_pxmView.winPct,g_pxmView.tp1Pct);
      }
      else if(!g_pxmAct.refused)
         g_pxmAct.stepGO="Standard entry rules (history not strong enough for GO)";
      else
         g_pxmAct.stepGO="Skipped - refused";

      g_pxmAct.stepSLTP="Pending setup - will tune SL/TP from measured dip if needed";
   }

   // 3) log a fresh live signal into the bank
   if(newSignal && lc.state==PX_STATE_PENDING && sr.tier>=PX_TIER_MEDIUM && vc.sessionActive && ArraySize(feat)==12)
      PXM_LogLiveSignal(lc,sr,reg,vc,tc);
}

//+------------------------------------------------------------------+
//| Phase B: apply Aladin actions onto the live trade setup.         |
//| Called AFTER PX_CalcTradeSetup / pending refresh.                |
//| Never invents a trade. Never raises lot above the risk plan.     |
//| On any problem -> leave setup as classic and mark fallback note. |
//+------------------------------------------------------------------+
void PXM_ApplyTradeActions(PX_TradeSetup &ts,const PX_ScoreResult &sr,const double atr,const double riskPct,const double baseLotFactor,const bool useInitialSL,const double ask,const double bid)
{
   // Default step text if Apply is called without a ready active view
   if(!InpEnableAladin || g_pxmAct.fellBack || g_pxmAct.mode==PXM_MODE_OFF)
      return;
   if(g_pxmAct.mode==PXM_MODE_LEARNING || g_pxmAct.mode==PXM_MODE_FAILED)
      return;
   if(!g_pxmView.ready || g_pxmView.n<PXM_MIN_SAMPLES)
   {
      // already documented in FutureViewCheck
      return;
   }
   if(sr.dir==PX_DIR_NONE || sr.tier<PX_TIER_MEDIUM)
   {
      g_pxmAct.stepSLTP="No tradeable setup this bar";
      return;
   }

   // REFUSE: invalidate setup so TradeManager places nothing new
   if(g_pxmAct.refused)
   {
      ts.valid=false;
      ts.method=PX_ENTRY_NONE;
      ts.methodText="aladin refused (weak history)";
      ts.lot=0.0;
      g_pxmAct.stepSLTP="Skipped - refused";
      g_pxmAct.stepResize="Skipped - refused";
      g_pxmAct.stepGO="Skipped - refused";
      Print("PREDICT-X ALADIN: REFUSE - ",g_pxmAct.reason);
      return;
   }

   if(!ts.valid || atr<=0.0 || ts.entry<=0.0)
   {
      g_pxmAct.stepSLTP="No valid setup to tune - classic path";
      return;
   }

   bool buy=(ts.dir==PX_DIR_BUY);
   double oldSL=ts.sl, oldTP1=ts.tp1, oldTP2=ts.tp2, oldLot=ts.lot;
   double oldRisk=MathAbs(ts.entry-ts.sl);
   if(oldRisk<=0.0) oldRisk=atr;

   // 1) smarter SL/TP from measured dip + typical run
   double needSL_ATR=MathMax(PXM_SL_MIN_ATR, MathMin(PXM_SL_MAX_ATR, g_pxmView.maeATR + PXM_SL_DIP_PAD_ATR));
   double curSL_ATR=MathAbs(ts.entry-ts.sl)/atr;
   bool widened=false;
   if(g_pxmView.maeATR>0.0 && needSL_ATR>curSL_ATR+0.05)
   {
      if(buy) ts.sl=ts.entry - needSL_ATR*atr;
      else    ts.sl=ts.entry + needSL_ATR*atr;
      widened=true;
      g_pxmAct.widenedSL=true;
   }

   // Rebuild TP distances from (possibly new) risk, guided by history TP1 rate
   double risk=MathAbs(ts.entry-ts.sl);
   if(risk<=0.0) risk=oldRisk;
   double tp1R=1.00;
   if(g_pxmView.tp1Pct>=80.0) tp1R=0.90;
   else if(g_pxmView.tp1Pct>=65.0) tp1R=1.00;
   else tp1R=1.10;
   double tp2R=1.60;
   if(sr.tier==PX_TIER_VERY_STRONG) tp2R=2.20;
   else if(sr.tier==PX_TIER_STRONG) tp2R=1.85;
   // If history is strong, allow a slightly more ambitious TP2
   if(g_pxmView.winPct>=PXM_GO_WIN_PCT) tp2R=MathMax(tp2R,1.90);
   double tp1Dist=MathMax(0.80*risk, tp1R*risk);
   double tp2Dist=MathMax(tp1Dist+0.30*risk, tp2R*risk);
   if(buy){ ts.tp1=ts.entry+tp1Dist; ts.tp2=ts.entry+tp2Dist; }
   else   { ts.tp1=ts.entry-tp1Dist; ts.tp2=ts.entry-tp2Dist; }
   g_pxmAct.smartSLTP=true;
   if(widened)
      g_pxmAct.stepSLTP=StringFormat("SL widened to %.2f ATR (dip %.2f) | TP1 %.2fR TP2 %.2fR",
                                     needSL_ATR,g_pxmView.maeATR,tp1R,tp2R);
   else
      g_pxmAct.stepSLTP=StringFormat("SL OK (%.2f ATR covers dip %.2f) | TP1 %.2fR TP2 %.2fR",
                                     curSL_ATR,g_pxmView.maeATR,tp1R,tp2R);

   // 2) GO-A: stronger entry - convert limit to market when history is strong
   if(g_pxmAct.goMarket && ts.method!=PX_ENTRY_MARKET && ask>0.0 && bid>0.0 && ask>bid)
   {
      ts.method=PX_ENTRY_MARKET;
      ts.entry=(buy?ask:bid);
      double slATRUse=(widened?needSL_ATR:MathMax(curSL_ATR,needSL_ATR));
      if(buy)
      {
         ts.sl=ts.entry-slATRUse*atr;
         ts.breakeven=ts.entry+1.5*(ask-bid);
      }
      else
      {
         ts.sl=ts.entry+slATRUse*atr;
         ts.breakeven=ts.entry-1.5*(ask-bid);
      }
      risk=MathAbs(ts.entry-ts.sl);
      if(risk<=0.0) risk=slATRUse*atr;
      tp1Dist=MathMax(0.80*risk, tp1R*risk);
      tp2Dist=MathMax(tp1Dist+0.30*risk, tp2R*risk);
      if(buy){ ts.tp1=ts.entry+tp1Dist; ts.tp2=ts.entry+tp2Dist; }
      else   { ts.tp1=ts.entry-tp1Dist; ts.tp2=ts.entry-tp2Dist; }
      ts.methodText="market (Aladin GO - strong history)";
      Print("PREDICT-X ALADIN: GO-A limit->market (win ",DoubleToString(g_pxmView.winPct,0),"% TP1 ",DoubleToString(g_pxmView.tp1Pct,0),"%)");
   }

   // 3) RESIZE lot (never above base plan)
   double lf=baseLotFactor * MathMin(1.0, g_pxmAct.lotFactor);
   if(lf<=0.0) lf=baseLotFactor;
   // Snapshot classic geometry so a failed Aladin tweak can fall back safely.
   PX_TradeSetup classic;
   classic=ts;
   classic.sl=oldSL; classic.tp1=oldTP1; classic.tp2=oldTP2; classic.lot=oldLot;
   // After SL change, lot is recomputed from risk money target
   if(!PX_ApplyBrokerStopDistance(ts,ask,bid,useInitialSL,riskPct,lf))
   {
      // Broker rejected Aladin geometry -> restore classic setup (do not freeze trading).
      ts=classic;
      ts.valid=true;
      // Re-apply classic broker distance with full base lot factor.
      if(!PX_ApplyBrokerStopDistance(ts,ask,bid,useInitialSL,riskPct,baseLotFactor))
      {
         // Classic also failed (rare) - leave invalid.
         g_pxmAct.stepSLTP="Aladin + classic broker distance failed - no setup this bar";
         g_pxmAct.reason="Broker distance failed after Aladin tweak and classic restore.";
         Print("PREDICT-X ALADIN: broker distance failed (Aladin + classic).");
         return;
      }
      g_pxmAct.smartSLTP=false;
      g_pxmAct.widenedSL=false;
      g_pxmAct.goMarket=false;
      g_pxmAct.resizedLot=false;
      g_pxmAct.lotFactor=1.0;
      g_pxmAct.stepSLTP="Aladin SL/TP failed broker rules - restored classic SL/TP";
      g_pxmAct.stepResize="Classic lot restored";
      g_pxmAct.stepGO="Classic entry restored";
      g_pxmAct.reason="Aladin tweak failed broker distance - classic path this bar.";
      Print("PREDICT-X ALADIN: fell back to classic setup after broker distance fail.");
      return;
   }
   // Explicit lot recompute with capped factor (safety: never raise above base)
   double baseLot=PX_CalcLot(riskPct,baseLotFactor,ts.entry,ts.sl);
   double actLot=PX_CalcLot(riskPct,lf,ts.entry,ts.sl);
   if(actLot>baseLot) actLot=baseLot;
   ts.lot=actLot;
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE), tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   ts.riskMoney=(tickSize>0.0?MathAbs(ts.entry-ts.sl)/tickSize*tickValue*ts.lot:0.0);
   ts.rewardMoney=(tickSize>0.0?MathAbs(ts.tp2-ts.entry)/tickSize*tickValue*ts.lot:0.0);
   ts.rr=(MathAbs(ts.entry-ts.sl)>0?MathAbs(ts.tp2-ts.entry)/MathAbs(ts.entry-ts.sl):0.0);

   if(g_pxmAct.resizedLot)
      g_pxmAct.stepResize=StringFormat("RESIZE lot %.2f -> %.2f (x%.2f, lukewarm win %.0f%%)",
                                       oldLot,ts.lot,g_pxmAct.lotFactor,g_pxmView.winPct);
   else
      g_pxmAct.stepResize=StringFormat("Lot %.2f (full plan)",ts.lot);

   if(g_pxmAct.goMarket || g_pxmAct.goExpiry)
   {
      string goBits="";
      if(g_pxmAct.goMarket) goBits+="market entry";
      if(g_pxmAct.goExpiry) goBits+=(goBits==""?"":" + ")+StringFormat("+%d expiry bars",g_pxmAct.expiryBonus);
      g_pxmAct.stepGO="GO active: "+goBits;
   }

   // Final headline when any power actually changed something
   if(g_pxmAct.refused || g_pxmAct.smartSLTP || g_pxmAct.resizedLot || g_pxmAct.goMarket || g_pxmAct.goExpiry)
   {
      g_pxmAct.mode=PXM_MODE_ACTIVE;
      g_pxmAct.headline="Aladin active - actions applied";
      Print("PREDICT-X ALADIN: applied - SL ",DoubleToString(oldSL,_Digits),"->",DoubleToString(ts.sl,_Digits),
            " TP1 ",DoubleToString(oldTP1,_Digits),"->",DoubleToString(ts.tp1,_Digits),
            " lot ",DoubleToString(oldLot,2),"->",DoubleToString(ts.lot,2),
            " goMkt=",g_pxmAct.goMarket," refuse=",g_pxmAct.refused);
   }
}

// Effective pending expiry = base + Aladin GO-B bonus (0 when not active).
int PXM_EffectiveExpiry(const int baseExpiry)
{
   int exp=MathMax(1,baseExpiry);
   if(PXM_CanAct() && g_pxmAct.goExpiry && g_pxmAct.expiryBonus>0 && !g_pxmAct.refused)
      exp+=g_pxmAct.expiryBonus;
   return exp;
}

// Stronger market-entry OR: classic flags OR Aladin GO-A.
bool PXM_BoostMarketAllowed(const bool classicAllowed)
{
   if(classicAllowed) return true;
   return (PXM_CanAct() && g_pxmAct.goMarket && !g_pxmAct.refused);
}

//+------------------------------------------------------------------+
//| Display helpers (legacy PXM_ labels kept for cleanup)            |
//+------------------------------------------------------------------+
void PXM_DelBlock(const string prefix)
{
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
   {
      string name=ObjectName(0,i);
      if(StringFind(name,"PXM_"+prefix)==0) ObjectDelete(0,name);
   }
}

void PXM_DeleteObjects()
{
   PXM_DelBlock("FV_");
   PXM_DelBlock("SC_");
   PXM_DelBlock("MS_");
   PXM_DelBlock("AL_");
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
   {
      string name=ObjectName(0,i);
      if(StringFind(name,"PXM_")==0) ObjectDelete(0,name);
   }
}

#endif
//+------------------------------------------------------------------+

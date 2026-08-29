//+------------------------------------------------------------------+
//|                                                     PXM_Book.mqh |
//| ALADDIN-IMP Phase A, module 1: the memory bank.                  |
//|                                                                  |
//| One plain CSV file per symbol+TF in MQL5\Files:                  |
//|   row kinds: 1=rehearsal result (PXM_Rehearse),                  |
//|              2=live signal (logged by PX_FutureViewCheck),       |
//|              3=outcome backfill update for a live row.           |
//| Grown live: every signal + setup is appended; real trade        |
//| outcomes are backfilled from deal history or OHLC projection.    |
//| k-NN lookup on the SAME 12-feature vector the online AI uses    |
//| returns: win%, TP1%, typical dip (MAE in ATR), time-to-result.   |
//|                                                                  |
//| PHASE A IS SHOW-ONLY. Nothing in this module changes scoring,   |
//| setup, lots or orders. Live functions are never modified.       |
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

#define PXM_NCOLS        30
#define PXM_MAX_ROWS     200000
#define PXM_SCAN_CAP     60000
#define PXM_SIM_BARS     40
#define PXM_RESULT_NONE  0
#define PXM_RESULT_SL    1
#define PXM_RESULT_TP1   2
#define PXM_RESULT_TP2   3
#define PXM_RESULT_BE    4
#define PXM_RESULT_TMO   5

//--- in-memory row (matches the CSV layout one-to-one)
struct PXM_Row
{
   int      kind;      // 1 rehearsal, 2 live signal, 3 outcome update
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
int        g_pxmFile=-1;
string     g_pxmFileDisplay="";
PXM_View   g_pxmView;
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

//+------------------------------------------------------------------+
//| Plain-language FUTURE VIEW status for the main panel (item 9).   |
//| Tells the user what condition the memory view is in right now.   |
//| Show-only; never changes a trade.                                |
//+------------------------------------------------------------------+
string PXM_FutureViewStatus(const double atr,const double entry,const double sl)
{
   if(!InpPXM_Enable) return "Future view is off.";
   if(!InpPXM_ShowFutureView) return "Future view display off.";
   if(g_pxmRhActive)
   {
      int pct=(g_pxmRhTotal>0?(int)MathRound(100.0*g_pxmRhDone/(double)g_pxmRhTotal):0);
      return "Learning - building history ("+IntegerToString(pct)+"% / "+IntegerToString(g_pxmCount)+" setups).";
   }
   if(g_pxmResolved<InpPXM_MinSamples)
      return "Learning - needs "+IntegerToString(InpPXM_MinSamples)+" similar outcomes before it gives a view.";
   if(g_pxmView.n<=0)
      return "No similar setups found for this signal yet.";

   string txt=StringFormat("Confident - similar %d won %d of 100.",g_pxmView.n,(int)MathRound(g_pxmView.winPct));
   if(atr>0.0 && entry>0.0 && sl>0.0 && MathAbs(entry-sl)>0.0)
   {
      double slATR=MathAbs(entry-sl)/atr;
      if(g_pxmView.maeATR>slATR)
         txt+="  Caution: dips past stop.";
      else
         txt+="  Usual dip fits the stop.";
   }
   return txt;
}

//+------------------------------------------------------------------+
//| Keys / file names                                                 |
//+------------------------------------------------------------------+
string PXM_GV(const string suffix)
{
   return "PREDICTX.MEM."+_Symbol+"."+PX_TFToString(_Period)+"."+suffix;
}

string PXM_FileName()
{
   return "PREDICTX-MEM_"+_Symbol+"_"+PX_TFToString(_Period)+".csv";
}

//--- single source of truth for the CSV header (written on create and rewrite)
string PXM_HeaderLine()
{
   return "PXMV1,PXM memory bank (show-only). kind,time,dir,score,tier,l1..l6,candle,er,atrRatio,adx,rsi,stDir,sqz,atrPts,spreadPts,entry,sl,tp1,tp2,result,win,tp1hit,maeATR,pnlR,barsRes";
}

//+------------------------------------------------------------------+
//| Pending-tracker persistence.                                      |
//| A terminal global variable holds exactly ONE double - there is no |
//| array overload of GlobalVariableSet/Get - so the live tracker is  |
//| stored as one scalar GV per field (same pattern as PX_TradeManager|
//| ). All keys stay under PREDICTX.MEM.<sym>.<tf>.pend.* so nothing  |
//| collides with the TradeManager or OnlineAI keys.                  |
//+------------------------------------------------------------------+
double PXM_PendGet(const string suffix)
{
   string key=PXM_GV(suffix);
   if(!GlobalVariableCheck(key)) return 0.0;
   return GlobalVariableGet(key);
}

void PXM_PendDelGV()
{
   // every tracker field lives under "...<tf>.pend." - one prefix sweep clears
   // them all and touches nothing else (rehearseDone and other keys are safe).
   GlobalVariablesDeleteAll(PXM_GV("pend."));
}

//+------------------------------------------------------------------+
//| Number (de)serialization helpers - strings avoid CSV precision    |
//| surprises and keep empty cells meaningful for update rows.        |
//+------------------------------------------------------------------+
string PXM_FmtD(const double v)
{
   return DoubleToString(v,8);
}
string PXM_FmtI(const long v)
{
   return IntegerToString(v);
}
double PXM_GetD(const string &fields[],const int col)
{
   if(col<0 || col>=PXM_NCOLS) return 0.0;
   if(fields[col]=="") return 0.0;
   return StringToDouble(fields[col]);
}
int PXM_GetI(const string &fields[],const int col)
{
   return (int)MathRound(PXM_GetD(fields,col));
}
double PXM_GetDDefault(const string &fields[],const int col,const double def)
{
   if(col<0 || col>=PXM_NCOLS) return def;
   if(fields[col]=="") return def;
   return StringToDouble(fields[col]);
}

string PXM_RowLine(const int kind,const datetime time,const int dir,const int score,const int tier,
                   const int l1,const int l2,const int l3,const int l4,const int l5,const int l6,const int candle,
                   const double er,const double atrRatio,const double adx,const double rsi,const double stDir,const double sqz,
                   const double atrPts,const double spreadPts,
                   const double entry,const double sl,const double tp1,const double tp2,
                   const int result,const int win,const int tp1hit,
                   const double maeATR,const double pnlR,const int barsRes)
{
   string line=PXM_FmtI(kind);
   line+=","+PXM_FmtI((long)time);
   line+=","+PXM_FmtI(dir);
   line+=","+PXM_FmtI(score);
   line+=","+PXM_FmtI(tier);
   line+=","+PXM_FmtI(l1)+","+PXM_FmtI(l2)+","+PXM_FmtI(l3)+","+PXM_FmtI(l4)+","+PXM_FmtI(l5)+","+PXM_FmtI(l6)+","+PXM_FmtI(candle);
   line+=","+PXM_FmtD(er)+","+PXM_FmtD(atrRatio)+","+PXM_FmtD(adx)+","+PXM_FmtD(rsi)+","+PXM_FmtD(stDir)+","+PXM_FmtD(sqz);
   line+=","+PXM_FmtD(atrPts)+","+PXM_FmtD(spreadPts);
   line+=","+PXM_FmtD(entry)+","+PXM_FmtD(sl)+","+PXM_FmtD(tp1)+","+PXM_FmtD(tp2);
   line+=","+PXM_FmtI(result)+","+PXM_FmtI(win)+","+PXM_FmtI(tp1hit);
   line+=","+PXM_FmtD(maeATR)+","+PXM_FmtD(pnlR)+","+PXM_FmtI(barsRes);
   return line;
}

//+------------------------------------------------------------------+
//| File open / load / append / rewrite                               |
//+------------------------------------------------------------------+
void PXM_WriteLine(const string line)
{
   if(g_pxmFile<0) return;
   FileSeek(g_pxmFile,0,SEEK_END);
   if(FileWriteString(g_pxmFile,line+"\n")<=0)
   {
      g_pxmErr++;
      if(g_pxmErr<=3) Print("PREDICT-X MEM: file write failed err=",GetLastError());
   }
}

void PXM_ParseInto(string &fields[])
{
   PXM_Row r;
   r.kind=PXM_GetI(fields,0);
   r.time=(datetime)PXM_GetD(fields,1);
   r.dir=PXM_GetI(fields,2);
   r.score=PXM_GetI(fields,3);
   r.tier=PXM_GetI(fields,4);
   r.l1=PXM_GetI(fields,5);   r.l2=PXM_GetI(fields,6);   r.l3=PXM_GetI(fields,7);
   r.l4=PXM_GetI(fields,8);   r.l5=PXM_GetI(fields,9);   r.l6=PXM_GetI(fields,10);
   r.candle=PXM_GetI(fields,11);
   r.er=PXM_GetD(fields,12);  r.atrRatio=PXM_GetD(fields,13); r.adx=PXM_GetD(fields,14);
   r.rsi=PXM_GetD(fields,15); r.stDir=PXM_GetD(fields,16);    r.sqz=PXM_GetD(fields,17);
   r.atrPts=PXM_GetD(fields,18); r.spreadPts=PXM_GetD(fields,19);
   r.entry=PXM_GetD(fields,20);  r.sl=PXM_GetD(fields,21);
   r.tp1=PXM_GetD(fields,22);    r.tp2=PXM_GetD(fields,23);
   r.result=PXM_GetI(fields,24); r.win=PXM_GetI(fields,25);  r.tp1hit=PXM_GetI(fields,26);
   r.maeATR=PXM_GetD(fields,27); r.pnlR=PXM_GetD(fields,28); r.barsRes=PXM_GetI(fields,29);
   if(r.kind==3)
   {
      // outcome backfill: merge onto the newest live row with the same bar time
      for(int i=g_pxmCount-1;i>=0;i--)
      {
         if(g_pxmRows[i].kind==2 && g_pxmRows[i].time==r.time)
         {
            bool wasRes=(g_pxmRows[i].result>=PXM_RESULT_SL && g_pxmRows[i].result<=PXM_RESULT_BE);
            g_pxmRows[i].entry=r.entry;    g_pxmRows[i].sl=r.sl;
            g_pxmRows[i].tp1=r.tp1;        g_pxmRows[i].tp2=r.tp2;
            g_pxmRows[i].result=r.result;  g_pxmRows[i].win=r.win;
            g_pxmRows[i].tp1hit=r.tp1hit;  g_pxmRows[i].maeATR=r.maeATR;
            g_pxmRows[i].pnlR=r.pnlR;      g_pxmRows[i].barsRes=r.barsRes;
            bool nowRes=(r.result>=PXM_RESULT_SL && r.result<=PXM_RESULT_BE);
            if(!wasRes && nowRes) g_pxmResolved++;
            if(wasRes && !nowRes) g_pxmResolved--;
            return;
         }
      }
      return;
   }
   if(r.kind!=1 && r.kind!=2) return;
   if(g_pxmCount>=PXM_MAX_ROWS) return; // trimmed in rehearsal; live rows still rare
   ArrayResize(g_pxmRows,g_pxmCount+1);
   g_pxmRows[g_pxmCount]=r;
   g_pxmCount++;
   if(r.result>=PXM_RESULT_SL && r.result<=PXM_RESULT_BE) g_pxmResolved++;
}

void PXM_ParseLine(const string line)
{
   if(StringLen(line)<3) return;
   if(StringFind(line,"PXMV1")==0) return; // header comment line
   string fields[];
   int n=StringSplit(line,',',fields);
   if(n<PXM_NCOLS) return;
   if(!(fields[0]=="1" || fields[0]=="2" || fields[0]=="3")) return;
   PXM_ParseInto(fields);
}

void PXM_Load()
{
   g_pxmCount=0; g_pxmResolved=0; g_pxmRhRowsLoaded=0;
   ArrayResize(g_pxmRows,0);
   int h=FileOpen(PXM_FileName(),FILE_READ|FILE_TXT|FILE_SHARE_READ);
   if(h>=0)
   {
      while(!FileIsEnding(h))
      {
         string line=FileReadString(h);
         if(line=="") break;
         PXM_ParseLine(line);
      }
      FileClose(h);
   }
   g_pxmPendActive=false;
   if(GlobalVariableCheck(PXM_GV("pend.time")))
   {
      double t=PXM_PendGet("pend.time");
      if(t>0.0)
      {
         g_pxmPend.time=(datetime)(long)t;
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

bool PXM_RewriteFile()
{
   // MQL5 has no FileTruncate(). Opening with FILE_WRITE and WITHOUT FILE_READ
   // recreates the file at zero length, which is the supported way to truncate.
   // The live append handle must be closed first or the reopen can fail.
   string name=PXM_FileName();
   if(g_pxmFile>=0) { FileClose(g_pxmFile); g_pxmFile=-1; }
   int h=FileOpen(name,FILE_WRITE|FILE_TXT|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h<0)
   {
      Print("PREDICT-X MEM: rewrite failed to open '",name,"' err=",GetLastError());
      // try to restore the append handle so logging survives a failed rewrite
      g_pxmFile=FileOpen(name,FILE_READ|FILE_WRITE|FILE_TXT|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(g_pxmFile>=0) FileSeek(g_pxmFile,0,SEEK_END);
      return false;
   }
   FileWriteString(h,PXM_HeaderLine()+"\n");
   for(int i=0;i<g_pxmCount;i++)
   {
      PXM_Row r=g_pxmRows[i];
      string line=PXM_RowLine(r.kind,r.time,r.dir,r.score,r.tier,r.l1,r.l2,r.l3,r.l4,r.l5,r.l6,r.candle,
                              r.er,r.atrRatio,r.adx,r.rsi,r.stDir,r.sqz,r.atrPts,r.spreadPts,
                              r.entry,r.sl,r.tp1,r.tp2,r.result,r.win,r.tp1hit,r.maeATR,r.pnlR,r.barsRes);
      FileWriteString(h,line+"\n");
   }
   FileFlush(h);
   FileClose(h);
   // reopen read/write so PXM_WriteLine() can keep appending
   g_pxmFile=FileOpen(name,FILE_READ|FILE_WRITE|FILE_TXT|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(g_pxmFile<0)
   {
      Print("PREDICT-X MEM: rewrite done but reopen failed err=",GetLastError(),
            " - memory logging disabled this session.");
      return false;
   }
   FileSeek(g_pxmFile,0,SEEK_END);
   return true;
}

void PXM_Init()
{
   PXM_ResetView(g_pxmView);
   g_pxmErr=0;
   if(!InpPXM_Enable) { g_pxmFile=-1; return; }
   string name=PXM_FileName();
   g_pxmFileDisplay=name;
   if(!FileIsExist(name))
   {
      int h=FileOpen(name,FILE_READ|FILE_WRITE|FILE_TXT);
      if(h>=0)
      {
         FileWriteString(h,PXM_HeaderLine()+"\n");
         FileClose(h);
      }
   }
   g_pxmFile=FileOpen(name,FILE_READ|FILE_WRITE|FILE_TXT|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(g_pxmFile<0)
   {
      Print("PREDICT-X MEM: cannot open memory file '",name,"' err=",GetLastError()," - memory disabled this session.");
      return;
   }
   PXM_Load();
   Print("PREDICT-X MEM: bank loaded: ",g_pxmCount," rows (",g_pxmResolved," resolved outcomes), file=",name);
}

void PXM_Cleanup()
{
   if(g_pxmFile>=0) { FileClose(g_pxmFile); g_pxmFile=-1; }
}

//+------------------------------------------------------------------+
//| Append a fully built row (used by PXM_Rehearse.mqh and live log) |
//+------------------------------------------------------------------+
void PXM_AppendRow(const PXM_Row &r)
{
   if(!InpPXM_Enable) return;
   if(g_pxmFile<0) return;
   if(r.kind==2 || r.kind==1)
   {
      if(g_pxmCount>=PXM_MAX_ROWS)
      {
         // drop the oldest third, keeping the newest data and all live rows
         int keep=(int)(PXM_MAX_ROWS*0.66);
         PXM_Row trimmed[];
         ArrayResize(trimmed,keep);
         int off=g_pxmCount-keep;
         for(int i=0;i<keep;i++) trimmed[i]=g_pxmRows[off+i];
         ArrayResize(g_pxmRows,keep);
         for(int i=0;i<keep;i++) g_pxmRows[i]=trimmed[i];
         g_pxmCount=keep;
         g_pxmResolved=0;
         for(int i=0;i<g_pxmCount;i++)
            if(g_pxmRows[i].result>=PXM_RESULT_SL && g_pxmRows[i].result<=PXM_RESULT_BE) g_pxmResolved++;
         PXM_RewriteFile();
         Print("PREDICT-X MEM: bank full - trimmed to ",g_pxmCount," rows (rewrite).");
         if(r.kind==1) return; // never displace live data for more rehearsal data
      }
      // dedupe: same bar time and kind already stored -> skip
      for(int i=g_pxmCount-1;i>=0 && i>g_pxmCount-5000;i--)
      {
         if(g_pxmRows[i].kind==r.kind && g_pxmRows[i].time==r.time) return;
      }
   }
   ArrayResize(g_pxmRows,g_pxmCount+1);
   g_pxmRows[g_pxmCount]=r;
   g_pxmCount++;
   if(r.result>=PXM_RESULT_SL && r.result<=PXM_RESULT_BE) g_pxmResolved++;
   string line=PXM_RowLine(r.kind,r.time,r.dir,r.score,r.tier,r.l1,r.l2,r.l3,r.l4,r.l5,r.l6,r.candle,
                           r.er,r.atrRatio,r.adx,r.rsi,r.stDir,r.sqz,r.atrPts,r.spreadPts,
                           r.entry,r.sl,r.tp1,r.tp2,r.result,r.win,r.tp1hit,r.maeATR,r.pnlR,r.barsRes);
   PXM_WriteLine(line);
}

//+------------------------------------------------------------------+
//| Append an outcome update for the newest live row with this time  |
//+------------------------------------------------------------------+
void PXM_AppendUpdate(const datetime time,const int dir,const double entry,const double sl,const double tp1,const double tp2,
                      const int result,const int win,const int tp1hit,const double maeATR,const double pnlR,const int barsRes)
{
   if(g_pxmFile<0) return;
   string line=PXM_FmtI(3)+","+PXM_FmtI((long)time)+","+PXM_FmtI(dir);
   for(int c=3;c<20;c++) line+=",0";
   line+=","+PXM_FmtD(entry)+","+PXM_FmtD(sl)+","+PXM_FmtD(tp1)+","+PXM_FmtD(tp2);
   line+=","+PXM_FmtI(result)+","+PXM_FmtI(win)+","+PXM_FmtI(tp1hit);
   line+=","+PXM_FmtD(maeATR)+","+PXM_FmtD(pnlR)+","+PXM_FmtI(barsRes);
   PXM_WriteLine(line);
   for(int i=g_pxmCount-1;i>=0;i--)
   {
      if(g_pxmRows[i].kind==2 && g_pxmRows[i].time==time)
      {
         bool wasRes=(g_pxmRows[i].result>=PXM_RESULT_SL && g_pxmRows[i].result<=PXM_RESULT_BE);
         g_pxmRows[i].entry=entry; g_pxmRows[i].sl=sl; g_pxmRows[i].tp1=tp1; g_pxmRows[i].tp2=tp2;
         g_pxmRows[i].result=result; g_pxmRows[i].win=win; g_pxmRows[i].tp1hit=tp1hit;
         g_pxmRows[i].maeATR=maeATR; g_pxmRows[i].pnlR=pnlR; g_pxmRows[i].barsRes=barsRes;
         bool nowRes=(result>=PXM_RESULT_SL && result<=PXM_RESULT_BE);
         if(!wasRes && nowRes) g_pxmResolved++;
         break;
      }
   }
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

void PXM_LookupKNN(const double &feat[],const int dir,const int k,PXM_View &v)
{
   PXM_ResetView(v);
   if(!InpPXM_Enable || k<=0 || dir==0 || g_pxmResolved<=0) return;
   double xq[];
   PX3_NormalizeFeatures(feat,(PX_Direction)dir,xq);
   if(ArraySize(xq)!=12) return;
   double d[]; int idx[];
   ArrayResize(d,k); ArrayResize(idx,k);
   int cnt=0;
   int start=MathMax(0,g_pxmCount-PXM_SCAN_CAP);
   for(int i=start;i<g_pxmCount;i++)
   {
      if(g_pxmRows[i].dir!=dir) continue;
      if(g_pxmRows[i].result<PXM_RESULT_SL || g_pxmRows[i].result>PXM_RESULT_BE) continue;
      double xr[];
      PXM_FeatFromRow(g_pxmRows[i],xr);
      double dd=0.0;
      for(int c=0;c<12;c++)
      {
         double dx=xq[c]-xr[c];
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
   double sumWin=0.0,sumTp1=0.0,sumMae=0.0,sumBars=0.0;
   for(int j=0;j<cnt;j++)
   {
      PXM_Row r=g_pxmRows[idx[j]];
      sumWin+=(r.win>0?1.0:0.0);
      sumTp1+=(r.tp1hit>0?1.0:0.0);
      sumMae+=r.maeATR;
      sumBars+=(double)r.barsRes;
   }
   v.n=cnt;
   v.winPct=sumWin/cnt*100.0;
   v.tp1Pct=sumTp1/cnt*100.0;
   v.maeATR=sumMae/cnt;
   v.avgBars=sumBars/cnt;
   v.ready=(cnt>=InpPXM_MinSamples);
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

// resolve an unfilled/untracked live signal from OHLC projection (show-only)
void PXM_ProjectOutcome(PXM_LivePend &p,double &maeATR,int &barsRes,int &result,double &pnlR)
{
   maeATR=0.0; barsRes=0; result=PXM_RESULT_NONE; pnlR=0.0;
   if(p.entry<=0.0 || p.sl<=0.0 || p.tp1<=0.0 || p.tp2<=0.0 || p.time<=0) return;
   int s0=iBarShift(_Symbol,_Period,p.time,true);
   if(s0<0) return;
   s0-=1; // signal bar was shift s0; execution starts the next bar
   double risk=MathAbs(p.entry-p.sl);
   if(risk<=0.0) return;
   double spread=(InpPXM_SpreadPoints>0.0?InpPXM_SpreadPoints:(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD))*_Point;
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
   r.kind=2; r.time=lc.signalTime; r.dir=(int)sr.dir;
   r.score=sr.total; r.tier=(int)sr.tier;
   r.l1=sr.layer1; r.l2=sr.layer2; r.l3=sr.layer3; r.l4=sr.layer4; r.l5=sr.layer5; r.l6=sr.layer6; r.candle=sr.candleBonus;
   r.er=reg.er; r.atrRatio=reg.atrRatio; r.adx=tc.adx; r.rsi=tc.rsi; r.stDir=(double)tc.stDir; r.sqz=tc.ttmSqueeze;
   r.atrPts=(vc.atr>0.0?vc.atr/_Point:0.0);
   r.spreadPts=(InpPXM_SpreadPoints>0.0?InpPXM_SpreadPoints:vc.avgSpreadPoints);
   r.entry=0.0; r.sl=0.0; r.tp1=0.0; r.tp2=0.0;
   r.result=PXM_RESULT_NONE; r.win=0; r.tp1hit=0; r.maeATR=0.0; r.pnlR=0.0; r.barsRes=0;
   PXM_AppendRow(r);
   // start the live outcome tracker (setup fields attach after PX_CalcTradeSetup)
   g_pxmPend.time=lc.signalTime; g_pxmPend.dir=(int)sr.dir;
   g_pxmPend.entry=0.0; g_pxmPend.sl=0.0; g_pxmPend.tp1=0.0; g_pxmPend.tp2=0.0;
   g_pxmPend.atr=vc.atr; g_pxmPend.openLots=0.0; g_pxmPend.profitSum=0.0;
   g_pxmPend.tp1hit=0; g_pxmPend.exitPrice=0.0; g_pxmPend.exitTime=0; g_pxmPend.isTP=0;
   g_pxmPend.method=0; g_pxmPend.filled=0;
   g_pxmPendActive=true;
   PXM_SavePendGV();
   Print("PREDICT-X MEM: logged live signal ",PX_DirectionText(sr.dir)," score ",sr.total," tier ",PX_TierText(sr.tier)," @ ",TimeToString(lc.signalTime,TIME_DATE|TIME_MINUTES));
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
   if(!g_pxmPendActive || g_pxmPend.entry>0.0) return; // track the first entry of the tracked signal only
   g_pxmPend.entry=fillPrice;
   g_pxmPend.filled=1;
   if(volume>0.0) g_pxmPend.openLots=volume;
   PXM_SavePendGV();
   PXM_AppendUpdate(g_pxmPend.time,g_pxmPend.dir,g_pxmPend.entry,g_pxmPend.sl,g_pxmPend.tp1,g_pxmPend.tp2,
                    PXM_RESULT_NONE,0,g_pxmPend.tp1hit,0.0,0.0,0);
   Print("PREDICT-X MEM: live trade opened @ ",DoubleToString(fillPrice,_Digits));
}

void PXM_OnTradePartialTP1(const double profitMoney)
{
   if(!g_pxmPendActive) return;
   g_pxmPend.tp1hit=1;
   g_pxmPend.profitSum+=profitMoney;
   PXM_SavePendGV();
   Print("PREDICT-X MEM: TP1 partial hit, profit $",DoubleToString(profitMoney,2)," backfilled to memory");
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
   PXM_AppendUpdate(g_pxmPend.time,g_pxmPend.dir,g_pxmPend.entry,g_pxmPend.sl,g_pxmPend.tp1,g_pxmPend.tp2,
                    res,win,g_pxmPend.tp1hit,maeATR,pnlR,bars);
   Print("PREDICT-X MEM: live outcome backfilled: result=",res," win=",win," pnlR=",DoubleToString(pnlR,2),
         " dip=",DoubleToString(maeATR,2)," ATR over ",bars," bars");
   g_pxmPendActive=false;
   PXM_SavePendGV();
}

//+------------------------------------------------------------------+
//| PX_FutureViewCheck - called from PX_OnNewClosedBar() between     |
//| the lifecycle update and PX_CalcTradeSetup(). Show-only in A.    |
//+------------------------------------------------------------------+
void PX_FutureViewCheck(const PX_Lifecycle &lc,const bool newSignal,const PX_ScoreResult &sr,const PX_RegimeState &reg,const PX_ValueContext &vc,const PX_TrendContext &tc,const double &feat[])
{
   PXM_ResetView(g_pxmView);
   if(!InpPXM_Enable || g_pxmFile<0) return;

   // 1) tracked live trade is over but no close deal was seen (e.g. restart):
   //    settle it by projection so the bank does not keep a forever-open row.
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
            PXM_AppendUpdate(g_pxmPend.time,g_pxmPend.dir,g_pxmPend.entry,g_pxmPend.sl,g_pxmPend.tp1,g_pxmPend.tp2,
                             res,win,g_pxmPend.tp1hit,mae,pnl,bres);
            Print("PREDICT-X MEM: unfilled/live-expired signal settled by OHLC projection (show-only).");
            g_pxmPendActive=false;
            PXM_SavePendGV();
         }
      }
   }
   else if(g_pxmPendActive && g_pxmPend.filled==0 && TimeCurrent()>(datetime)((long)g_pxmPend.time+(long)(2+PXM_SIM_BARS)*(long)PeriodSeconds(_Period)))
   {
      // No trade was opened for this signal. Market setups (the ones that would
      // have executed immediately) are settled by projection so the bank still
      // grows while auto-trading is OFF; unfilled limits are simply dropped.
      if(g_pxmPend.atr>0.0 && (g_pxmPend.method==0 || g_pxmPend.method==1))
      {
         int s0=iBarShift(_Symbol,_Period,g_pxmPend.time,true);
         if(s0>1)
         {
            if(g_pxmPend.entry<=0.0)
            {
               // never got a planned setup (e.g. signals before attach existed): approximate one
               double entry0=iOpen(_Symbol,_Period,s0-1);
               double spread=(InpPXM_SpreadPoints>0.0?InpPXM_SpreadPoints:(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD))*_Point;
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
                  PXM_AppendUpdate(g_pxmPend.time,g_pxmPend.dir,g_pxmPend.entry,g_pxmPend.sl,g_pxmPend.tp1,g_pxmPend.tp2,
                                   res,win,g_pxmPend.tp1hit,mae,pnl,bres);
                  Print("PREDICT-X MEM: signal-not-traded settled by projection (show-only).");
                  g_pxmPendActive=false;
                  PXM_SavePendGV();
               }
            }
         }
      }
      else
      {
         // limit that never filled or no data to settle: drop the tracker, keep the
         // signal row unresolved (excluded from stats, still visible in the file).
         g_pxmPendActive=false;
         PXM_SavePendGV();
      }
   }

   // 2) k-NN lookup for the CURRENT bar (drives the Future View block, show-only)
   if(g_pxmResolved>0 && sr.dir!=PX_DIR_NONE && ArraySize(feat)==12)
      PXM_LookupKNN(feat,(int)sr.dir,InpPXM_KNeighbors,g_pxmView);

   // 3) log a fresh live signal into the bank
   if(newSignal && lc.state==PX_STATE_PENDING && sr.tier>=PX_TIER_MEDIUM && vc.sessionActive && ArraySize(feat)==12)
      PXM_LogLiveSignal(lc,sr,reg,vc,tc);
}

//+------------------------------------------------------------------+
//| Display: three movable block-functions (labels use PXM_ names,   |
//| never touched by PX_DeletePanelObjects). Reposition by changing  |
//| the x/y passed into PXM_DrawFutureViewStack() in PREDICT-X.mq5.  |
//+------------------------------------------------------------------+
void PXM_DelBlock(const string prefix)
{
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
   {
      string name=ObjectName(0,i);
      if(StringFind(name,"PXM_"+prefix)==0) ObjectDelete(0,name);
   }
}

void PXM_Label(string name,const int x,const int y,const string text,const color clr,const int fs,string tooltip)
{
   name="PXM_"+name;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fs);
   ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,PX_WrapTooltip(tooltip));
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}

void PXM_Rect(string name,const int x,const int y,const int w,const int h,const color bg)
{
   name="PXM_"+name;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,clrDimGray);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
}

//--- block 1: FUTURE VIEW (left panel, the memory verdict for this bar)
void PXM_DrawFutureViewBlock(const int x,const int y,const double atrPrice,const double entryPrice,const double slPrice)
{
   PXM_DelBlock("FV_");
   if(!InpPXM_Enable || !InpPXM_ShowFutureView) return;
   PXM_Rect("FV_BG",x,y,455,64,(color)0x101010);
   int yy=y+6;
   PXM_Label("FV_H",x+11,yy,"FUTURE VIEW",clrAqua,10,"Aladdin memory: how similar past setups on this symbol+TF ended. Show-only in Phase A - it never changes a trade.");
   yy+=17;
   int minNeed=InpPXM_MinSamples;
   if(g_pxmResolved<minNeed)
   {
      int show=MathMin(g_pxmResolved,minNeed);
      PXM_Label("FV_1",x+11,yy,StringFormat("Memory gathering %d/%d",show,minNeed),clrGray,10,"Rehearsal + live logging is building the bank.");
      yy+=16;
      PXM_Label("FV_2",x+11,yy,"Similar setups appear here once the bank is large enough",clrGray,9,"Show-only display.");
      return;
   }
   if(g_pxmView.n<=0)
   {
      PXM_Label("FV_1",x+11,yy,"Similar 0 | - | -",clrGray,10,"No similar past setups for the current direction/features yet.");
      yy+=16;
      PXM_Label("FV_2",x+11,yy,"Bank: "+IntegerToString(g_pxmResolved)+" resolved outcomes",clrGray,9,"");
      return;
   }
   color clrWin=(g_pxmView.winPct>=55.0?clrLime:(g_pxmView.winPct>=45.0?clrGold:clrTomato));
   PXM_Label("FV_1",x+11,yy,StringFormat("Similar %d | Win %.0f%% | TP1 %.0f%% | dip %.1f ATR | ~%.1f bars",
            g_pxmView.n,g_pxmView.winPct,g_pxmView.tp1Pct,g_pxmView.maeATR,g_pxmView.avgBars),clrWin,10,
            "k-NN over similar resolved setups. Win = finished positive (TP1+), TP1 = reached TP1 first, dip = typical MAE in ATR.");
   yy+=16;
   if(atrPrice>0.0 && entryPrice>0.0 && slPrice>0.0 && MathAbs(entryPrice-slPrice)>0.0)
   {
      double slATR=MathAbs(entryPrice-slPrice)/atrPrice;
      if(g_pxmView.maeATR>slATR)
         PXM_Label("FV_2",x+11,yy,StringFormat("Typical dip %.1f ATR > planned SL %.1f ATR - similar trades got wider dips",
                  g_pxmView.maeATR,slATR),clrOrange,9,"Phase A: note only. (RESIZE power comes in Phase B and defaults OFF.)");
      else
         PXM_Label("FV_2",x+11,yy,StringFormat("Planned SL %.1f ATR covers typical dip %.1f ATR - OK",
                  slATR,g_pxmView.maeATR),clrSilver,9,"Typical adverse excursion of similar setups fits inside the planned stop.");
   }
   else
      PXM_Label("FV_2",x+11,yy,"No active setup this bar - dip vs SL shown when a setup is planned",clrGray,9,"");
}

//--- block 2: scorecard line (last 30 resolved outcomes per tier + AI flag)
void PXM_DrawScorecardLine(const int x,const int y)
{
   PXM_DelBlock("SC_");
   if(!InpPXM_Enable || !InpPXM_ShowFutureView || g_pxmResolved<=0) return;
   int nMed=0,nStr=0,nV=0; double wMed=0.0,wStr=0.0,wV=0.0;
   for(int i=g_pxmCount-1;i>=0;i--)
   {
      PXM_Row r=g_pxmRows[i];
      if(r.kind==3) continue;
      if(r.result<PXM_RESULT_SL || r.result>PXM_RESULT_BE) continue;
      if(r.tier==PX_TIER_MEDIUM && nMed<30) { nMed++; wMed+=(r.win>0?1.0:0.0); }
      else if(r.tier==PX_TIER_STRONG && nStr<30) { nStr++; wStr+=(r.win>0?1.0:0.0); }
      else if(r.tier==PX_TIER_VERY_STRONG && nV<30) { nV++; wV+=(r.win>0?1.0:0.0); }
      if(nMed>=30 && nStr>=30 && nV>=30) break;
   }
   string txt="Last 30: ";
   txt+=(nMed>0 ? StringFormat("MED %.0f%% (%d) | ",wMed/nMed*100.0,nMed) : "MED - | ");
   txt+=(nStr>0 ? StringFormat("STR %.0f%% (%d) | ",wStr/nStr*100.0,nStr) : "STR - | ");
   txt+=(nV>0   ? StringFormat("VSTR %.0f%% (%d) | ",wV/nV*100.0,nV) : "VSTR - | ");
   txt+=(InpEnableAIEnhancement?"AI on":"AI off");
   PXM_Label("SC_1",x,y,txt,clrSilver,9,"Measured win-rate per tier over the last 30 resolved outcomes in the memory bank (rehearsal + live). Display only - no auto weight tuning.");
}

//--- block 3: memory status line
void PXM_DrawMemoryStatus(const int x,const int y)
{
   PXM_DelBlock("MS_");
   if(!InpPXM_Enable) return;
   string txt;
   color clr=clrSilver;
   if(g_pxmRhActive)
   {
      int pct=(g_pxmRhTotal>0?(int)MathRound(100.0*g_pxmRhDone/(double)g_pxmRhTotal):0);
      txt=StringFormat("Memory: building %d%% (%d setups)",pct,g_pxmCount);
      clr=clrGray;
   }
   else if(g_pxmFile<0)
   {
      txt="Memory: file unavailable - show-only stats off";
      clr=clrOrange;
   }
   else
   {
      txt=StringFormat("Memory: %d setups (%d resolved)",g_pxmCount,g_pxmResolved);
      if(g_pxmErr>0) txt+=" [io errors "+IntegerToString(g_pxmErr)+"]";
   }
   PXM_Label("MS_1",x,y,txt,clr,9,"Memory file: MQL5\\Files\\"+g_pxmFileDisplay+". Rehearsal builds history; live signals append on every new signal.");
}

void PXM_DrawFutureViewStack(const int x,const int y,const double atrPrice,const double entryPrice,const double slPrice)
{
   if(!InpPXM_Enable || !InpPXM_ShowFutureView) return;
   PXM_DrawFutureViewBlock(x,y,atrPrice,entryPrice,slPrice);          // block 1 (under SIGNAL)
   PXM_DrawScorecardLine(x,y+68);                                     // block 2 (scorecard)
   PXM_DrawMemoryStatus(x,y+84);                                      // block 3 (memory status)
}

void PXM_DeleteObjects()
{
   PXM_DelBlock("FV_");
   PXM_DelBlock("SC_");
   PXM_DelBlock("MS_");
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
   {
      string name=ObjectName(0,i);
      if(StringFind(name,"PXM_")==0) ObjectDelete(0,name);
   }
}

#endif
//+------------------------------------------------------------------+

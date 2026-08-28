# ALADDIN-IMP — plan note (for future agent sessions)

## What we have
PREDICT-X: MQL5 EA (MT5). 6-layer confluence score 0-100. Tiers:
MEDIUM 55-69 (limit entries), STRONG 70-84 (market only w/ momentum),
VERY STRONG 85+ (market). One position per symbol. TP1 = 50% partial +
breakeven, early profit lock, post-TP1 trail. Regime engine (DANGEROUS
blocks all). Daily loss halt. User reports it works well (~98% win rate).

## Goal
"Aladdin-lite": adapt BlackRock Aladdin process (one data record,
continuous risk view, what-if testing on own history, enforced pre-trade
gates) to single-user level for better prediction + trade accuracy.

## Build plan (in order)
1. **PX_BookOfRecord.mqh** — append-only file: full snapshot per closed
   bar (feature vector, 6 layer scores, regime, setup) + outcome
   backfill (SL / TP1 / TP2, MAE/MFE, P/L in R). Pure logging, no
   trading change.
2. **PX_PreTradeGate.mqh** — one ordered veto list, every reason logged.
   Add: consecutive-loss breaker, max signals/day, data freshness check.
3. **PX_StateMemory.mqh** — k-NN over book of record: for current signal,
   find last ~50 similar setups (same symbol+TF); use P(TP1/TP2), avg MAE
   to veto / adjust SL / shrink lot. Needs ~100-200 recorded signals.
4. **PX_Calibration.mqh** — realized win-rate per score band, per layer,
   per regime. DISPLAY first; auto weight tuning only slow + capped
   (small-sample overfit risk = the dangerous one).
5. **Position health score 0-100** recomputed per bar; bands =
   hold / tighten / close-if-profit-protected. Protection ladder keeps
   priority.
6. **Daily statement file** — trades, P/L, band accuracy, veto log.

## Rules
- Single symbol, single position. Native MQL5 only, no external APIs.
- Every new feature: own input switch, default OFF, run in shadow mode
  (log only) before it may act. Current EA works — changes must be
  additive and safe.
- Do NOT remove Phase-3 online AI now. Feed it the book of record; let
  calibration data (2-3 months) decide if it keeps its 10 bonus points.
  Off switch already exists: InpEnableAIEnhancement.

## Status
- Note created 2026-08-28. Implementation not started.

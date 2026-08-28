# ALADDIN-IMP — implementation note (for a new chat)

## What we have
PREDICT-X MT5 EA: 6-layer score 0-100 -> tier -> signal (PENDING) ->
setup (entry/SL/TP1/TP2/lot) -> trade manager (TP1 50% + BE, early
lock, post-TP1 trail). Regime engine (DANGEROUS blocks all), daily
loss halt. User reports ~98% win rate. Current EA WORKS — all changes
must be additive, never rewrite the trading brain.

## Goal (user-confirmed)
A more accurate FUTURE VIEW of the prediction. Existing trade
functions unchanged. Keep it LIGHT — no heavy functionality.

## What the new part IS (and is NOT)
- NOT another scoring layer. The 6-layer score still picks the trade.
- It is a MEMORY CHECK on an already-born signal: "how did similar
  past setups on this symbol+TF actually end?"
- It outputs 3-4 numbers: similar count, win-rate, TP1-rate, typical
  adverse dip (vs planned SL distance).
- Powers, each with its own input (same style as risk inputs):
  * SHOW   — default ON. One panel line, zero effect on trading.
  * REFUSE — default OFF. Cancel signal if similar win-rate badly low
    (need min similar count, e.g. 30; threshold e.g. 45%).
  * RESIZE — default OFF. Widen SL if typical dip > planned SL;
    halve lot if win-rate lukewarm (45-55%).
  * GO     — default OFF. "Go ahead" power:
    GO-A: limit -> market entry when similar setups show strong
      continuation (high TP1-rate, small typical dip) — take the
      trade now instead of waiting at the limit level.
    GO-B: extend pending expiry (3 bars -> N) when similar setups
      usually need more time to play out.
- Line it can never cross: the 6-layer score still decides IF a
  trade exists (score < minScore = no trade, memory cannot invent
  one). GO changes TIMING only, never lot size beyond the risk plan.
- It can say "no", "less", or "faster" — never "new trade" or
  "bigger". Every action logged to the memory file with reason.

## Integration point (exact)
PREDICT-X.mq5 -> PX_OnNewClosedBar(): BETWEEN lifecycle update
(signal PENDING) and PX_CalcTradeSetup() -> call one new function
PX_FutureViewCheck(). Its result feeds:
  * panel line (always, SHOW),
  * veto -> lifecycle reset, same mechanism as the SuperTrend-flip
    pending-cancel, with logged reason,
  * tune -> SL distance / lotFactor arguments of PX_CalcTradeSetup.
Everything after (setup validation, broker distance, trade manager,
TP1/locks/trail) stays untouched.

## Build order
A. Memory file (append-only, native MQL5 files):
   A1 LIVE: every PENDING signal + full setup -> file; outcome
      (SL / TP1 / TP2 hit, P/L in R) backfilled later.
   A2 REHEARSAL: on first run, run the existing scoring functions on
      MT5's own past bars (same symbol+TF) -> bank of past setups +
      real outcomes. OHLC rules: same-bar SL+TP touch -> count SL
      first (conservative); spread -> typical constant. This also
      doubles as a past test of the current EA logic.
B. PX_FutureViewCheck(): k-NN (top ~50 similar by feature distance)
   over the bank -> the numbers -> SHOW panel line.
C. REFUSE / RESIZE / GO inputs (default OFF), actions logged.
D. Tiny scorecard (display only): last-30 win-rate per tier +
   whether AI bonus was on. Lets data decide Phase-3 AI's worth
   in 2-3 months. NO auto weight tuning.

## Cuts (user said: not so heavy)
No position health score. No auto weight calibration. No daily
statement (memory file is the log). No gate subsystem (simple inputs
only).

## Rules
Single symbol, single position. Native MQL5 only, no external APIs.
Every new feature: own input, default OFF, display before acting.
Keep Phase-3 online AI (switch: InpEnableAIEnhancement).

## Status
Note v4, 2026-08-28. Implementation not started. Start with A
(memory + rehearsal + SHOW line only).

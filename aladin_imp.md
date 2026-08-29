# ALADDIN-IMP — todo for a new chat (v5, 2026-08-28)

## Context
PREDICT-X (MT5 EA): 6-layer score 0-100 -> tier -> signal -> setup ->
trade manager (TP1 50% + BE, locks, trail). Regime engine, daily halt.
User: working EA (~95%+ win rate). Changes must be ADDITIVE ONLY.

## User's 3 intentions — all served by ONE memory bank
1. Smarter prediction (keep + push the existing high win rate).
2. More accurate entry/SL/TP placement -> each trade's best chance
   to hit TP (measured, realistic distances per situation).
3. Better order-placement decision (the moment before the order).

## THE CORE (one thing, not three)
Memory bank = "how did similar past setups on this symbol+TF end".
- Built by REHEARSAL: run the scoring on MT5's own past bars (first
  run, chunked so the terminal does not freeze).
- Grown by LIVE logging: every signal + setup + real outcome
  (SL / TP1 / TP2 hit, P/L in R) appended to the same file.
Per live signal (k-NN top ~50 similar) it outputs: win-rate,
TP1-rate, typical dip (MAE), time-to-result.

## Todo (in order)
1. **PXM_Book.mqh** — memory file (per symbol+TF): schema, append,
   outcome backfill, k-NN lookup. New module, PXM_ prefix, own
   GV keys — no collision with existing PX_ objects / PREDICTX.* keys.
2. **PXM_Rehearse.mqh** — shift-aware COPIES of the scoring math.
   (Layer1 SMC and Layer5 Markov are hardcoded to shift 1 -> copy
   them with a base-shift param. NEVER modify the live functions.)
   OHLC rules: same-bar SL+TP touch -> count SL first; spread =
   typical constant.
3. **PX_FutureViewCheck()** — call in PX_OnNewClosedBar() BETWEEN
   lifecycle update and PX_CalcTradeSetup(). Three uses:
   - SHOW (default ON): panel line "Similar 50 | Win 68% | TP1 81%
     | dip 0.6 ATR". Zero effect on trading.
   - USE 2 (own input, default OFF): SL/TP1/TP2 distances from the
     measured dip/run of similar setups instead of fixed ATR
     multiples.
   - USE 3 door check (own inputs, default OFF): REFUSE (win-rate
     <45% with >=30 similar); RESIZE (dip > SL -> widen SL; lukewarm
     win-rate -> half lot); GO (GO-A: limit->market via the EXISTING
     strong/mediumMarketAllowed flags; GO-B: extend pending expiry —
     the only power needing a small ordering tweak in
     PX_OnNewClosedBar).
4. **Tiny scorecard (display only)**: last-30 win-rate per tier +
   whether AI bonus was on. NO auto weight tuning. The data decides
   the Phase-3 AI's worth in 2-3 months.

## Conflicts checked against the code (2026-08-28)
- Layer1/Layer5 shift-1 hardcoding -> rehearsal uses COPIES; live
  path untouched.
- GO-A reuses existing market-entry flags inside PX_CalcTradeSetup
  (already built in) — no new mechanism.
- GO-B is the only power needing a small ordering change in
  PX_OnNewClosedBar.
- OnDeinit: add PXM_ object cleanup (one line).
- Memory = separate file + new GV keys — no key collisions.
- All powers default OFF => with everything off the EA behaves
  exactly as today.
- Rehearsal must run chunked (a few hundred bars per pass) so the
  terminal never freezes.

## Interface (what the user sees)
No new window/panel. Additions to the EXISTING two panels only, each
built as one movable block-function (the user plans a full layout
change later — blocks just get repositioned then, no rewrite):
- Left panel, under SIGNAL: "FUTURE VIEW" block:
  line 1: Similar N | Win % | TP1 %
  line 2: typical dip vs planned SL (OK / widen note)
  gray while bank < 30: "Memory gathering x/30"
- Left panel, bottom: scorecard line (upgrades the existing
  "SIGNALS TODAY" line): "Last 30: MED 64% | STR 71% | VSTR 78% | AI on"
- Left panel, status: "Memory: 1,240 setups" or "building 45%"
- Right panel: NO new section — REFUSE/RESIZE/GO reasons flow through
  the EXISTING STATE + LAST ACTION lines (already plumbed).
Chart objects (arrows/lines) unchanged.

## Hard rules
Single symbol, single position. Native MQL5, no external APIs. New
module prefix PXM_. Own input per power, default OFF, SHOW before
acting. Keep Phase-3 AI (switch: InpEnableAIEnhancement). Memory may
never invent a trade (score < minScore = no trade) nor raise the lot
beyond the risk plan. Every action logged with reason.

## Status
Plan final for build. Not started. Start: tasks 1+2 + SHOW only.

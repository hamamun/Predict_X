# ALADDIN-IMP — plan note (for future agent sessions)

## What we have
PREDICT-X: MQL5 EA (MT5). 6-layer confluence score 0-100. Tiers:
MEDIUM 55-69 (limit entries), STRONG 70-84 (market w/ momentum),
VERY STRONG 85+ (market). One position/symbol. TP1 50% partial + BE,
early lock, post-TP1 trail, regime engine (DANGEROUS blocks all),
daily loss halt. User reports ~98% win rate.

## Goal (user-confirmed 2026-08-28)
A more accurate FUTURE VIEW of the prediction. Existing trade functions
(entries, TP1/trail, protection ladder) stay UNCHANGED. Keep it LIGHT —
no heavy functionality.

## Plan (light version)
A. **Memory**
  A1: live log — each live signal + setup -> small file; outcome
      (SL/TP1/TP2, P/L in R) filled in later. Pure logging.
  A2: history rehearsal — on first run, run the SAME scoring on MT5's
      own past bars (same symbol+TF; history is available on chart)
      -> bank of past setups + real outcomes (OHLC-based).
      Approximations: typical spread constant (no historical spread);
      same-bar SL+TP touch -> count SL first (conservative).
B. **Future view (the deliverable)**
  B1: live signal -> k-NN over bank -> panel line:
      "Similar 50 | Win 68% | TP1 82% | typical dip 0.7 ATR".
      Display-only by default.
  B2 (own input, default OFF, same override style as existing risk
      inputs): act on it — veto if similar win-rate < X; shrink lot /
      widen SL when typical dip > planned SL distance.
C. **Simple scorecard (display only)**
  Panel: last-30-signal win rate per tier + AI bonus on/off.
  Data decides AI's worth in 2-3 months. NO auto weight tuning.

## Cut (user: "not so heavy")
- Position health score — cut
- Auto weight calibration — cut (display only)
- Daily statement — reduced to the memory file itself
- Pre-trade gate — not a subsystem; only B2-style simple inputs

## Rules
- Single symbol, single position. Native MQL5. No external APIs.
- Every new feature: own input, default OFF, display before acting.
- Keep Phase-3 online AI; scorecard decides later
  (switch: InpEnableAIEnhancement).
- Working EA — additive changes only.

## Status
- Note updated 2026-08-28 (light plan). Implementation not started.

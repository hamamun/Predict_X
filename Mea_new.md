# MEA — Core Design and Operating Flow

> **Source:** distilled from `Mea_Imp.md` as a compact reference. This document records the intended MEA design; it is not, by itself, evidence that every requirement is implemented, tested, or ready for live trading.

## 1. Purpose and boundaries

MEA is intended to be one universal MetaTrader 5 Expert Advisor that prepares a model for the symbol and timeframe of the chart where it is attached. It uses MT5 history and live data directly; the user does not supply a trained model, CSV, Python service, or ONNX file.

- Supported initial timeframes: **M5, M15, and M30**.
- Each instance analyzes only its attached `_Symbol` and `_Period`.
- Predictions use closed bars only; higher-timeframe features use fully closed higher-timeframe bars.
- Main results: **BUY, SELL, or NO TRADE**, with entry, TP, protective SL, calibrated confidence, expected duration, and expiry.
- **NO TRADE is valid and required** when evidence is ambiguous, insufficient, poorly calibrated, or unsafe.
- The initial build is **prediction-only (shadow mode)**. Order submission, position modification, and position closing are disabled.
- No forecast or readiness result guarantees profitability.

## 2. Core components

| Component | Responsibility |
|---|---|
| **MMFE — Market Feature Engine** | Create causal, normalized features from the attached symbol's chart timeframe and approved higher-timeframe context. Include market structure, momentum, volatility, spread, volume/session context, support/resistance, breakouts/rejections, and data-health flags. |
| **HSMM — Hidden Semi-Markov Model** | Estimate Trend Up, Trend Down, Range, or High-Volatility Chop, plus state probabilities and duration estimates. Fit internally using deterministic multiple starts and chronological evaluation. |
| **RBFE — Regime-Aware Barrier Forecasting Engine** | Label historical paths with volatility-scaled upper, lower, and time barriers; store features, regime, outcome, MFE/MAE, and time-to-event; retrieve similar historical paths to estimate barrier probabilities and excursions. |
| **ARCF — Adaptive Regime Conformal Filter** | Calibrate uncertainty by regime using genuinely out-of-sample predictions whose outcomes have matured. Refuse directional forecasts when uncertainty is too high or calibration support is inadequate. |
| **VMGE — Walk-Forward Validation and Readiness Engine** | Test the fitted system chronologically, purge overlapping events, compare baselines, measure quality after costs, and allow READY only if the internal gates pass. |
| **DSCA — Drift Sentinel and Controlled Adaptation** | Monitor feature drift, prediction/calibration deterioration, regime novelty/duration, data health, and spread. Apply persistent-state/hysteresis rules to set MODEL TRUST and request a candidate rebuild when needed. |
| **SREE — Safe Risk and Execution Engine** | Designed for a later execution release. Validate fresh forecasts, entry/TP/SL geometry, broker constraints, spread/slippage, volume, margin, and risk limits before an order. **Locked off in the shadow build.** |
| **POL — Prediction and Outcome Ledger** | Record forecasts—including NO TRADE—and their matured outcomes. Support restart recovery and duplicate prevention. Only matured outcomes update calibration and drift monitoring. |
| **Cache** | Save compatible, validated internal state by symbol/timeframe/version so later starts can load it automatically. The user does not manage the cache. |

## 3. First-attach preparation flow

1. **Start and validate the chart context.** Check the attached symbol, supported timeframe, history state, and relevant broker metadata.
2. **Try the local cache.** Load only a cache compatible with the symbol, timeframe, and algorithm version. Even a valid cache requires current history checks before forecasts start.
3. **Acquire history from MT5.** Explicitly request closed bars for the chart timeframe and its required higher timeframe. Check ordering, synchronization, continuity, and usable history. Do not use a forming bar.
4. **Prepare indicators and higher-timeframe context.** Compute the data required by the feature engine, aligning higher-timeframe context without using a still-forming higher-timeframe bar.
5. **Build features.** Produce the same causal feature definitions for historical preparation, testing, and live use. Mark missing, stale, unsynchronized, or abnormal data rather than silently treating it as normal.
6. **Normalize features.** Estimate robust symbol-specific scales from the fitting data and use those same fitted scales for the rest of preparation and live inference.
7. **Fit the HSMM.** Fit candidate state parameters on the chronological fitting region; use deterministic multiple starts and chronological evaluation to select a stable fit. Assign regime context to historical feature rows.
8. **Build historical barrier events.** For each eligible historical start bar, define volatility-scaled upper/lower barriers and a time expiry. Scan the future path to record which barrier was reached first or whether the event timed out. Store the start-bar features and regime with the label, excursions, and duration.
9. **Create calibration data.** Generate historical forecasts out of sample. Add their calibration scores only after their full outcome windows mature.
10. **Run walk-forward validation.** Keep fitting, calibration, and untouched validation chronological. Purge/embargo overlapping barrier windows. Compare against simple baselines; measure directional quality, calibration, TP/SL/timeout results, entry validity, duration error, and costs. Use ablation to remove feature families without stable incremental value.
11. **Apply readiness gates.** If the sample is insufficient or a quality/calibration gate fails, report NOT READY / NO TRADE with the reason. Do not save an unvalidated cache as ready.
12. **Save only a passing state.** If all gates pass, store the fitted parameters, analogue memory, calibration state, validation summary, and drift baseline; enter READY.

History synchronization is a live condition. Empty, partial, unsorted, or still-downloading history should be re-probed and described using current counts/status. It should not be treated as a permanent model-quality verdict.

## 4. Barrier analogue workflow

The barrier model is a **historical path-analogue model**, not a next-candle direction classifier.

For each historical event it keeps, conceptually:

- The normalized state/features at the event start.
- The HSMM regime at that start.
- Upper-first, lower-first, or timeout outcome.
- Maximum favourable/adverse excursion (MFE/MAE).
- Bars to the barrier or expiry.
- Net result after the assumed spread/slippage costs.

For a current query, RBFE:

1. Removes events whose complete label window would overlap the query's future.
2. Restricts analogues to the same or explicitly compatible regime.
3. Weights the remaining events by feature similarity and recency.
4. Requires enough effective analogue evidence; a raw neighbour count alone is not sufficient.
5. Estimates TP-first, SL-first, and timeout probabilities, excursion quantiles, and time-to-event.
6. Evaluates the eligible entry/TP candidates after spread and expected slippage.
7. Returns a direction and defensible levels only if its probability and uncertainty gates pass; otherwise returns NO TRADE.

## 5. Live function and event responsibilities

These are lifecycle responsibilities, not a promise that every internal helper has a particular signature.

### `OnInit`

- Validate symbol and timeframe.
- Initialize the panel, ledger, and runtime state.
- Look for a compatible fitted cache.
- If a cache is usable, verify current chart and higher-timeframe history before READY.
- Otherwise start first-attach preparation.

### `OnTimer`

- Advance preparation or candidate rebuilding in bounded chunks.
- Update heartbeat and panel status.
- Re-probe history when MT5 series are pending or short.
- Apply retry timing for expensive preparation failures.
- Handle time-based expiry/housekeeping as specified by the runtime policy.

### New closed-bar processing (`OnTick` / bar detection)

- Detect that a new chart bar has opened, so the prior bar is now closed.
- Update quotes and compute current causal features from closed chart/HTF bars.
- Infer regime and expected remaining duration with the fitted HSMM.
- Ask RBFE for the regime-conditioned barrier forecast.
- Apply ARCF confidence/calibration rules, spread checks, and DSCA trust restrictions.
- Publish BUY, SELL, or NO TRADE; record the forecast and its eventual outcome in POL.

### `OnTradeTransaction`

- Reserved for the later execution-enabled release. The shadow build does not submit or manage orders.

## 6. Forecast decision and safety

A directional forecast is permitted only when all relevant layers agree:

1. The data and forecast are fresh and valid.
2. The HSMM prediction set identifies a single supported directional regime.
3. RBFE has enough compatible, matured analogues and a sufficient TP-vs-SL probability margin.
4. ARCF has enough matured calibration observations and acceptable coverage/confidence.
5. DSCA trust is not PAUSED, and data/spread checks pass.
6. The entry, TP, SL, duration, and expiry can be stated consistently.

If any required layer is ambiguous, unsupported, stale, under-sampled, or unsafe, the result is **NO TRADE** with a specific reason.

## 7. Runtime states and failure behavior

Main lifecycle:

**NOT READY → PREPARING MODEL → READY → CANDIDATE → ORDER PENDING → POSITION OPEN → COOLDOWN**

Safety states: **PAUSED** and **ERROR**. In the shadow build, execution stops before ORDER PENDING.

- **Cache hit:** verify current history, then READY if checks pass.
- **History pending/short:** stay NOT READY, show the live data condition, and retry; do not imply the model is currently prepared.
- **Preparation or validation failure:** remain NOT READY / NO TRADE and show the exact failure reason.
- **Candidate rebuild:** keep the trusted model active while building. Replace it only if the candidate passes the same validation; otherwise keep the trusted state or pause according to trust policy.
- **Retry policy:** the specification calls for retries based on new data or elapsed time, so recovery does not depend only on waiting for a large number of new bars.

## 8. User inputs and panel

Minimal inputs from the specification:

- AUTO enable/disable (defaults OFF in the shadow build).
- Fixed lot (used when percentage sizing is not enabled).
- Optional risk-per-trade percentage.
- Optional maximum portfolio risk.
- Optional daily loss stop.

Symbol, timeframe, model path, history path, feature/indicator definitions, thresholds, timer, panel layout, and logging mode are not user-supplied controls. The chart panel should show direction, levels, confidence, duration/expiry, regime/trust/state, activity, last action, reason, and risk/open-position context. AUTO OFF blocks new orders in a future execution build but does not stop prediction/monitoring.

## 9. Required acceptance checks before execution is enabled

1. Unit tests for features, barriers, HSMM, analogue selection, conformal calibration, and state transitions.
2. Strategy Tester checks on structurally different symbols and all supported timeframes.
3. Purged walk-forward and baseline comparisons, including spread/slippage stress.
4. Cache save/load, invalidation, restart, and version-migration checks.
5. Missing/short history, abnormal spread, and disconnected-terminal checks.
6. Demo shadow-forward evidence by regime for direction, TP/SL/time, and calibration.
7. Broker constraint, risk toggle, fixed-lot, duplicate-order, and protective-order checks before any execution release.

## 10. One-line system flow

**MT5 closed history → data readiness → MMFE features → normalization → HSMM regime → RBFE historical path analogues → ARCF uncertainty filter → DSCA trust gate → BUY / SELL / NO TRADE → POL outcome ledger → controlled cache/drift refresh**

Only after prediction reliability passes its acceptance gates may a later release add **SREE → broker execution**.

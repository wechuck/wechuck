#property strict
#property version   "2.32"
#property description "WeChuck EA – Multi-Timeframe Exhaustion & Range Scalp Strategy"
// Changelog:
//   v2.32 – Fixed same-second open/close on Setup C: max-profit cap (InpSetupCMaxProfitDollar)
//           is now placed AFTER the min-hold gate instead of before it.  Previously the cap
//           bypassed InpMinHoldSeconds and closed GOLD trades within the same second because a
//           $5 price move on 0.03 lots was enough to reach the $15 cap instantly.  Moving it
//           after min-hold gives the trailing stop logic time to activate first.
//   v2.31 – Setup C entry now requires RSI confirmation in addition to Stochastic K
//           extreme: BUY needs rsiPrev < rsiOversold AND rsiCur > rsiPrev; SELL needs
//           rsiPrev > rsiOverbought AND rsiCur < rsiPrev.  Stochastic/ADX-based dynamic
//           exit is disabled for Setup C trades – they only close by TP, SL, time exit,
//           or max-profit cap.  Trailing SL (RRMin trigger) already applied to all setups.
//   v2.30 – Per-setup enable/disable switches (InpEnableSetupA/B/C) for isolated
//           backtesting. Improvement recommendations block added below.
//   v2.20 – Setup C "HFT Range Scalp" added. Two-layer slippage protection (pre-entry
//           + post-fill) for Setup B and C. $15 max-profit guard for Setup C.
//           Stochastic-extreme gate moved inside A/B only; Setup C uses K-at-extreme.
//           ADX gate for Setup C is optional (off by default). OnePipPrice() helper.
//   v2.00 – Full strategy rework. Replaced generic score-based system with the
//           two master setups: Setup A "Rubber Band" (high-ADX exhaustion reversal)
//           and Setup B "Range Scalp" (low-ADX box bounce). Signal logic delegated
//           to StrategyCore.mqh. Zone gating via ZoneDetector.mqh. Stochastic
//           parameters aligned to strategy spec (14,1,3). RSI added as
//           confirmation for Setup A. Setup B TP targets opposite box wall.
//   v1.00 – Initial release.
//
// ──────────────────────────────────────────────────────────────────────────────
// IMPROVEMENT RECOMMENDATIONS (not yet implemented – future work)
// ──────────────────────────────────────────────────────────────────────────────
//
// 1. SESSION FILTER PER SETUP
//    - Setup A (exhaustion reversal) works best during London/NY overlap where
//      volume causes real ADX spikes. Filter it to 07:00-17:00 UTC only.
//    - Setup C (HFT scalp) should be further restricted to avoid the first 15
//      minutes of London open when boxes break more than they bounce.
//    - Recommended inputs: InpSetupA_SessionStartHour, InpSetupA_SessionEndHour
//      (and equivalent for C). Already have InpLowLiqStartHour/EndHour but it is
//      global – per-setup session filtering would be more precise.
//
// 2. BREAKEVEN STOP (SETUP C)
//    - Once Setup C profit exceeds 50% of the box range, move SL to breakeven.
//      Prevents a winner turning into a loser on a sudden box break.
//    - Recommended input: InpSetupC_BreakevenAtPct (default 50)
//
// 3. MULTI-TIMEFRAME BOX CONFIRMATION
//    - Before entering Setup B or C, confirm the 5M box is also visible on 15M
//      (i.e. price has been consolidating for at least 3 x 15M bars).
//      This avoids entering boxes that are too fresh and likely to break.
//    - Would require adding a 15M bar-consolidation check in StrategyCore.
//
// 4. VOLUME / TICK-DENSITY FILTER
//    - On Setup C, if the tick count during the last 1M bar is below a threshold
//      the "touch" may be a ghost spike with no real buyers/sellers at the wall.
//    - Recommended input: InpSetupC_MinTicksPerBar (default 30)
//    - Requires OnChartEvent tick counting or an auxiliary tick counter.
//
// 5. ATR-BASED DYNAMIC SL FOR SETUP A
//    - Current SL uses the wick of the signal bar, which can be very tight on
//      low-volatility symbols. Replace or blend with a 1M ATR(14) × multiplier
//      so the SL breathes with volatility rather than being fixed to one candle.
//    - Recommended inputs: InpSetupA_SLMode (WICK / ATR / MAX_OF_BOTH),
//      InpSetupA_AtrMultiplier (default 1.5)
//
// 6. DRAWDOWN-ADAPTIVE LOT SIZING
//    - Current dynamic lot already scales by equity. Add a second layer: if the
//      account has lost more than X% from its peak (intra-session drawdown), cut
//      lot size to 50% automatically until a win recovers it.
//    - Recommended inputs: InpDDScalePct (default 5), InpDDLotFactor (default 0.5)
//
// 7. CORRELATION / SAME-DIRECTION GUARD
//    - When running the EA on multiple pairs simultaneously (e.g. EURUSD + GBPAUD),
//      prevent opening two positions in the same direction at the same time.
//      Reduces hidden correlated drawdown.
//    - Would need a cross-symbol position scan in CanTradeNow() inside RiskManager.
//
// 8. BOX INVALIDATION ON BREAK
//    - If a new 5M candle closes outside the box while a Setup B/C position is open,
//      the structural premise is broken. Close immediately instead of waiting for TP/SL.
//    - Recommended input: InpCloseOnBoxBreak (default true)
//    - Would be checked inside ManageOpenPosition().
//
// ──────────────────────────────────────────────────────────────────────────────

#include "include/Types.mqh"
#include "include/DiagnosticsLogger.mqh"
#include "include/MarketStructureFilter.mqh"
#include "include/EntryScoring.mqh"
#include "include/RiskManager.mqh"
#include "include/ExecutionManager.mqh"

//──────────────────────────────────────────────────────────────────────────────
// Inputs
//──────────────────────────────────────────────────────────────────────────────
input group "General"
input long   InpMagicNumber = 20260421;
input double InpFixedLot    = 0.01;
input bool   InpDebugMode   = true;

input group "Spread and Session"
input int    InpMaxForexSpreadPoints = 15;
input int    InpMaxGoldSpreadPoints  = 30;
input int    InpLowLiqStartHour      = 22;
input int    InpLowLiqEndHour        = 1;
input double InpMinBodyRangeRatio    = 0.30;

input group "Bias Filter (M15) – optional alignment check"
input int    InpEmaFast              = 50;
input int    InpEmaSlow              = 200;
input int    InpStructureLookback    = 10;
input bool   InpRequireM15Alignment  = false;  // When true, M15 bias must match signal direction

input group "ADX – Environment Filter (14-period)"
input int    InpAdxPeriod            = 14;
// Setup A – Rubber Band
input double InpAdxExhaustionLevel   = 40.0;   // 1M ADX must exceed this to qualify Setup A
// Invalidation gate – expanding momentum (do not fade a breakout)
input double InpAdxExpandingMin      = 25.0;   // ADX expanding zone lower bound
input double InpAdxExpandingMax      = 35.0;   // ADX expanding zone upper bound
// Setup B – Range Scalp
input double InpAdxRangingThreshold  = 20.0;   // 5M ADX must be below this for Setup B
// Dynamic exit
input double InpAdxExitWeakThreshold = 18.0;   // Close trade when 1M ADX drops below this

input group "RSI – Pressure Gauge (14-period)"
input int    InpRsiPeriod            = 14;
input double InpRsiOversold          = 30.0;   // Setup A/C BUY: RSI must be below this
input double InpRsiOverbought        = 70.0;   // Setup A/C SELL: RSI must be above this

input group "Stochastic (14,1,3) – The Trigger"
input int    InpStochK               = 14;
input int    InpStochD               = 3;
input int    InpStochSlowing         = 1;
input double InpStochOversold        = 20.0;   // Oversold extreme for BUY trigger
input double InpStochOverbought      = 80.0;   // Overbought extreme for SELL trigger

input group "5M Range Box (Setup B)"
input int    InpM5RangeLookback      = 50;     // Closed 5M bars used to build the structural box
input double InpBoxTolerancePct      = 15.0;   // % of box size that counts as "near the edge"

input group "Zone Detector – No Zone, No Trade"
input bool   InpRequireZone          = true;   // Enforce H1/M15 zone check for Setup A
input int    InpZoneLookback         = 200;    // Bars of history to scan for zones
input int    InpZoneWingBars         = 3;      // Bars on each side required to confirm swing
input int    InpZoneMinTouches       = 2;      // Minimum zone touches for structural validity
input double InpZoneTolerancePct     = 0.05;  // Zone band width as % of price

input group "Risk Guards"
input int    InpMinSecondsBetweenEntries    = 10;
input int    InpMaxTradesPerSymbolPerHour   = 15;
input int    InpMaxOpenPositionsGlobal      = 3;
input int    InpConsecutiveLossPauseCount   = 3;
input int    InpConsecutiveLossPauseMinutes = 30;
input double InpDailyLossCapHighPct         = 5.0;
input double InpDailyLossCapLowPct          = 2.0;
input bool   InpUseDailyProfitStop          = false;
input double InpDailyProfitStopPct          = 3.0;

input group "Risk Sizing"
input bool   InpUseDynamicLot    = true;
input double InpRiskPctPerTrade  = 1.0;
input double InpRiskPctFloor     = 0.3;
input double InpEquityScaleStart = 300.0;
input double InpEquityScaleFull  = 5000.0;

input group "Stops and Targets"
input double InpSlBufferPips         = 2.0;   // Extra pips beyond wick/box edge when placing SL
input double InpFallbackSlPips       = 8.0;   // Minimum SL pips (forex) / fallback when bar data missing
input int    InpGoldSlPoints         = 150;   // Minimum SL points for gold / fallback
input double InpRRMin                = 4.7;   // R:R multiple at which trailing stop activates (conservative TP)
input double InpRRMax                = 10.0;  // R:R multiple for hard TP on Setup A
input int    InpTimeExitBars         = 15;    // Force close after N 1M bars
input int    InpMinHoldSeconds       = 60;    // Suppress all soft exits for N seconds after entry
input double InpTrailingDistancePips = 3.0;   // Trail step size (pips) once RRMin profit is reached

input group "Execution"
input int  InpMaxDeviationPoints = 10;
input int  InpOrderRetries       = 3;
input bool InpAutoAttachSignal   = true;  // Attach WeChuckSignal indicator to the visual chart on init

input group "Setup Enable / Disable – toggle individual setups for isolated testing"
input bool   InpEnableSetupA          = true;   // Setup A ON/OFF (Rubber Band – high-ADX exhaustion reversal)
input bool   InpEnableSetupB          = true;   // Setup B ON/OFF (Range Scalp – low-ADX box bounce with Stoch cross)
// NOTE: disable A+B and enable C alone to backtest Setup C in isolation, or any combination

input group "Setup C – HFT Range Scalp"
input bool   InpEnableSetupC          = true;   // Master switch for Setup C
input bool   InpSetupCRequireADX      = false;  // Require 5M ADX < threshold (off = Stoch alone gates entry)
input double InpSetupCMinBoxSizePips  = 30.0;   // Minimum box size in pips – below this skip C (spread guard)
input double InpSetupCSLBufferPips    = 1.5;    // SL buffer beyond box edge for Setup C
input double InpSetupCMaxProfitDollar = 15.0;   // Close Setup C when floating profit reaches this dollar amount
input double InpSetupCMaxSlippagePips     = 2.0;   // Slippage protection: max pips from box edge at fill (Forex)
input double InpSetupCMaxSlippagePipsGold = 50.0;  // Slippage protection: max pips from box edge at fill (Gold/XAUUSD)

//──────────────────────────────────────────────────────────────────────────────
// Globals
//──────────────────────────────────────────────────────────────────────────────
CDiagnosticsLogger     g_logger;
CMarketStructureFilter g_bias;
CEntryScoring          g_scoring;
CRiskManager           g_risk;
CExecutionManager      g_exec;

datetime  g_lastM1BarTime      = 0;
datetime  g_lastEntrySignalBar = 0;
bool      g_orderInFlight      = false;
SetupType g_openPositionSetup  = SETUP_NONE;  // tracks which setup opened the current position

//──────────────────────────────────────────────────────────────────────────────
// Helpers
//──────────────────────────────────────────────────────────────────────────────
bool IsAllowedSymbol(const string symbol)
{
   return (StringFind(symbol, "EURUSD") >= 0 ||
           StringFind(symbol, "GBPAUD") >= 0 ||
           StringFind(symbol, "AUDNZD") >= 0 ||
           StringFind(symbol, "AUDJPY") >= 0 ||
           StringFind(symbol, "XAUUSD") >= 0 ||
           StringFind(symbol, "GOLD")   >= 0);
}

bool IsGold(const string symbol)
{
   return (StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0);
}

// Returns the price distance of one pip for the given symbol.
// Forex 5/3-digit: 1 pip = 10 points.  Everything else: 1 pip = 1 point.
double OnePipPrice(const string symbol)
{
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double mult   = (digits == 3 || digits == 5) ? 10.0 : 1.0;
   return point * mult;
}

int ForexPipsToPoints(const string symbol, const double pips)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double mult = (digits == 3 || digits == 5) ? 10.0 : 1.0;
   return (int)MathRound(pips * mult);
}

bool InLowLiquidityWindow(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   if(InpLowLiqStartHour == InpLowLiqEndHour) return false;
   if(InpLowLiqStartHour < InpLowLiqEndHour)
      return (dt.hour >= InpLowLiqStartHour && dt.hour < InpLowLiqEndHour);
   return (dt.hour >= InpLowLiqStartHour || dt.hour < InpLowLiqEndHour);
}

bool CandleBodyIsHealthy(const string symbol)
{
   MqlRates rates[2];
   ArraySetAsSeries(rates, true);
   if(CopyRates(symbol, PERIOD_M1, 1, 2, rates) < 2) return false;
   double range = rates[0].high - rates[0].low;
   if(range <= 0.0) return false;
   double body = MathAbs(rates[0].close - rates[0].open);
   return ((body / range) >= InpMinBodyRangeRatio);
}

bool NewM1Bar(const string symbol)
{
   datetime t = iTime(symbol, PERIOD_M1, 0);
   if(t == 0) return false;
   if(t != g_lastM1BarTime)
   {
      g_lastM1BarTime = t;
      return true;
   }
   return false;
}

bool CheckSpreadOk(const string symbol, int &spreadPts)
{
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return false;
   spreadPts = (int)MathRound((tick.ask - tick.bid) / SymbolInfoDouble(symbol, SYMBOL_POINT));
   int maxSpread = IsGold(symbol) ? InpMaxGoldSpreadPoints : InpMaxForexSpreadPoints;
   return (spreadPts <= maxSpread);
}

bool PositionExistsForSymbol(const string symbol)
{
   return PositionSelect(symbol);
}

double LinearScaleEquity(const double equity, const double hiVal, const double loVal)
{
   if(InpEquityScaleStart <= 0.0 || InpEquityScaleFull <= InpEquityScaleStart) return hiVal;
   if(equity <= InpEquityScaleStart) return hiVal;
   if(equity >= InpEquityScaleFull)  return loVal;
   double t = (equity - InpEquityScaleStart) / (InpEquityScaleFull - InpEquityScaleStart);
   return MathMax(hiVal - t * (hiVal - loVal), loVal);
}

double GetScaledRiskPct(const double equity)
{
   if(!InpUseDynamicLot) return InpRiskPctPerTrade;
   return LinearScaleEquity(equity, InpRiskPctPerTrade, InpRiskPctFloor);
}

double GetScaledDailyLossCapPct(const double equity)
{
   return LinearScaleEquity(equity, InpDailyLossCapHighPct, InpDailyLossCapLowPct);
}

double ComputeLotSize(const string symbol, const int slPoints)
{
   if(!InpUseDynamicLot) return InpFixedLot;
   double equity       = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskPct      = GetScaledRiskPct(equity);
   double riskAmount   = equity * riskPct / 100.0;
   double point        = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tickSize     = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue    = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || point <= 0.0) return InpFixedLot;
   double pointValuePerLot = (point / tickSize) * tickValue;
   if(pointValuePerLot <= 0.0) return InpFixedLot;
   double slValue = slPoints * pointValuePerLot;
   if(slValue <= 0.0) return InpFixedLot;
   double rawLot     = riskAmount / slValue;
   double minVolume  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxVolume  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(stepVolume <= 0.0) stepVolume = (minVolume > 0.0 ? minVolume : 0.01);
   double lot    = MathFloor(rawLot / stepVolume) * stepVolume;
   double safeMin = (minVolume > 0.0 ? minVolume : 0.01);
   double safeMax = (maxVolume > 0.0 ? maxVolume : 100.0);
   lot = MathMax(safeMin, MathMin(lot, safeMax));
   return NormalizeDouble(lot, 2);
}

//──────────────────────────────────────────────────────────────────────────────
// ManageOpenPosition – trailing stop + time-based exit + dynamic exit
//──────────────────────────────────────────────────────────────────────────────
void ManageOpenPosition(const string symbol)
{
   if(!PositionSelect(symbol)) return;

   long posType = PositionGetInteger(POSITION_TYPE);
   int  dir     = (posType == POSITION_TYPE_BUY) ? STRAT_DIR_BUY : STRAT_DIR_SELL;

   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

   // Minimum hold time – suppress all soft exits until elapsed (broker SL always active)
   if(InpMinHoldSeconds > 0 && TimeCurrent() - openTime < (datetime)InpMinHoldSeconds)
      return;

   // ── Setup C max-profit guard – close once floating P&L reaches the dollar cap ─
   // Placed AFTER the min-hold gate so it cannot fire on the same second as entry,
   // giving the trailing stop logic a fair chance to activate first.
   if(g_openPositionSetup == SETUP_HFT_RANGE_SCALP && InpEnableSetupC &&
      InpSetupCMaxProfitDollar > 0.0)
   {
      double posProfit = PositionGetDouble(POSITION_PROFIT);
      if(posProfit >= InpSetupCMaxProfitDollar)
      {
         g_logger.LogDecision(symbol, false,
            StringFormat("Setup C max-profit $%.2f reached (profit=$%.2f) – closing",
                         InpSetupCMaxProfitDollar, posProfit));
         g_exec.CloseSymbolPosition(symbol, g_logger);
         return;
      }
   }

   // Time-based exit
   int      barsSinceOpen = iBarShift(symbol, PERIOD_M1, openTime, true);
   if(barsSinceOpen >= InpTimeExitBars && InpTimeExitBars > 0)
   {
      g_logger.LogDecision(symbol, false, "Time-based exit");
      g_exec.CloseSymbolPosition(symbol, g_logger);
      return;
   }

   // Dynamic exit (only when in profit – protect winners)
   // Skipped for Setup C – those trades close only by TP, SL, time exit,
   // or max-profit cap; the Stochastic/ADX-based exit is intentionally disabled.
   double posProfit = PositionGetDouble(POSITION_PROFIT);
   if(g_openPositionSetup != SETUP_HFT_RANGE_SCALP &&
      posProfit > 0.0 &&
      g_scoring.ShouldExitByDynamics(symbol, dir,
                                     InpAdxPeriod, InpAdxExitWeakThreshold,
                                     InpStochK, InpStochD, InpStochSlowing,
                                     InpStochOversold, InpStochOverbought))
   {
      g_logger.LogDecision(symbol, false, "Dynamic exit condition");
      g_exec.CloseSymbolPosition(symbol, g_logger);
      return;
   }

   // R:R-aware trailing stop – activates once profit reaches InpRRMin × entry SL distance
   double openPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
   double entrySL      = PositionGetDouble(POSITION_SL);
   double currentSL    = entrySL;
   double currentTP    = PositionGetDouble(POSITION_TP);
   double slDist       = MathAbs(openPrice - entrySL);
   double trailTrigger = slDist * InpRRMin;   // e.g. 4.7× SL distance

   double point        = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double trailingDist = (IsGold(symbol) ? InpTrailingDistancePips * 10.0
                                         : ForexPipsToPoints(symbol, InpTrailingDistancePips)) * point;

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return;

   if(dir == STRAT_DIR_BUY)
   {
      double profitMove = tick.bid - openPrice;
      if(slDist > 0.0 && profitMove >= trailTrigger)
      {
         double newSL = tick.bid - trailingDist;
         if(newSL > currentSL)
            g_exec.ModifyPosition(symbol, newSL, currentTP);
      }
   }
   else
   {
      double profitMove = openPrice - tick.ask;
      if(slDist > 0.0 && profitMove >= trailTrigger)
      {
         double newSL = tick.ask + trailingDist;
         if(currentSL == 0.0 || newSL < currentSL)
            g_exec.ModifyPosition(symbol, newSL, currentTP);
      }
   }
}

//──────────────────────────────────────────────────────────────────────────────
// TryEntry – evaluates all conditions and opens a position when appropriate
//──────────────────────────────────────────────────────────────────────────────
void TryEntry(const string symbol)
{
   if(g_orderInFlight) return;

   // ── Risk guards ──────────────────────────────────────────────────────────
   string reason;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!g_risk.CanTradeNow(symbol,
                          InpMinSecondsBetweenEntries,
                          InpMaxTradesPerSymbolPerHour,
                          InpMaxOpenPositionsGlobal,
                          InpConsecutiveLossPauseCount,
                          InpConsecutiveLossPauseMinutes,
                          GetScaledDailyLossCapPct(equity),
                          InpUseDailyProfitStop,
                          InpDailyProfitStopPct,
                          reason))
   {
      g_logger.LogDecision(symbol, false, reason);
      return;
   }

   // ── Strategy signal evaluation ────────────────────────────────────────────
   // Evaluated first so Setup C (Stoch+RSI filtered, box-unrestricted) can bypass the
   // pre-conditions below that apply only to Setups A and B.
   double setupCMinBoxSize = InpSetupCMinBoxSizePips * OnePipPrice(symbol);

   EntryScoreBreakdown score;
   if(!g_scoring.Evaluate(symbol,
                           InpAdxPeriod,
                           InpAdxExhaustionLevel,
                           InpAdxExpandingMin,
                           InpAdxExpandingMax,
                           InpAdxRangingThreshold,
                           InpAdxExitWeakThreshold,
                           InpRsiPeriod,
                           InpRsiOversold,
                           InpRsiOverbought,
                           InpStochK,
                           InpStochD,
                           InpStochSlowing,
                           InpStochOversold,
                           InpStochOverbought,
                           InpM5RangeLookback,
                           InpBoxTolerancePct / 100.0,
                           InpRequireZone,
                           InpZoneLookback,
                           InpZoneWingBars,
                           InpZoneMinTouches,
                           InpZoneTolerancePct,
                           InpEnableSetupA,
                           InpEnableSetupB,
                           InpEnableSetupC,
                           InpSetupCRequireADX,
                           setupCMinBoxSize,
                           score))
   {
      g_logger.LogDecision(symbol, false, "Signal evaluation failed");
      return;
   }

   g_logger.LogScore(symbol, (int)score.setup, score.direction,
                     score.adx1M, score.adx5M, score.stochK, score.rsiCur,
                     score.details);

   g_logger.TrackContribution(score.setup == SETUP_RUBBER_BAND,
                               score.setup == SETUP_RANGE_SCALP,
                               score.setup == SETUP_HFT_RANGE_SCALP);

   if(!score.valid)
   {
      g_logger.LogDecision(symbol, false, "No valid signal: " + score.details);
      return;
   }

   // ── Pre-conditions (skipped entirely for Setup C – box-unrestricted mode) ──
   // Setup C bypasses spread, low-liquidity, and candle-body filters so that
   // pure Stochastic extreme entries are never blocked by market-structure gates.
   if(score.setup != SETUP_HFT_RANGE_SCALP)
   {
      int spreadPts = 0;
      if(!CheckSpreadOk(symbol, spreadPts))
      {
         g_logger.LogDecision(symbol, false, "Spread too high");
         return;
      }

      if(InLowLiquidityWindow(TimeCurrent()))
      {
         g_logger.LogDecision(symbol, false, "Low-liquidity session block");
         return;
      }

      if(!CandleBodyIsHealthy(symbol))
      {
         g_logger.LogDecision(symbol, false, "Body/range ratio too small");
         return;
      }
   }

   // ── Optional M15 bias alignment (skipped for Setup C) ────────────────────
   BiasResult bias;
   if(InpRequireM15Alignment && score.setup != SETUP_HFT_RANGE_SCALP)
   {
      if(!g_bias.Evaluate(symbol, InpEmaFast, InpEmaSlow, InpStructureLookback, bias))
      {
         g_logger.LogDecision(symbol, false, "M15 bias evaluation failed");
         return;
      }

      if(bias.direction != DIR_NONE)
      {
         int biasDir = (bias.direction == DIR_BUY) ? STRAT_DIR_BUY : STRAT_DIR_SELL;
         if(biasDir != score.direction)
         {
            g_logger.LogDecision(symbol, false, "Signal direction conflicts with M15 bias");
            return;
         }
      }
   }

   // ── Duplicate signal guard ────────────────────────────────────────────────
   datetime signalBar = iTime(symbol, PERIOD_M1, 1);
   if(signalBar == g_lastEntrySignalBar)
   {
      g_logger.LogDecision(symbol, false, "Duplicate signal on same bar blocked");
      return;
   }

   if(PositionExistsForSymbol(symbol))
   {
      g_logger.LogDecision(symbol, false, "Symbol position already exists");
      return;
   }

   // ── Compute price levels ──────────────────────────────────────────────────
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return;
   double point   = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double pipSize = OnePipPrice(symbol);              // price distance of 1 pip
   double price   = (score.direction == STRAT_DIR_BUY) ? tick.ask : tick.bid;

   // ── Slippage Protection: pre-entry box-edge distance check ───────────────
   // Applies to Setup B only.  Setup C is box-unrestricted so
   // the slippage gate is intentionally bypassed – price can be anywhere.
   if(score.setup == SETUP_RANGE_SCALP)
   {
      if(score.boxHigh > 0.0 && score.boxLow > 0.0)
      {
         double maxSlipPips = IsGold(symbol) ? InpSetupCMaxSlippagePipsGold : InpSetupCMaxSlippagePips;
         double slipLimit   = maxSlipPips * pipSize;
         bool   priceOk     = false;
         if(score.direction == STRAT_DIR_BUY)
            priceOk = (tick.ask <= score.boxLow + slipLimit);   // BUY near low
         else
            priceOk = (tick.bid >= score.boxHigh - slipLimit);  // SELL near high

         if(!priceOk)
         {
            g_logger.LogDecision(symbol, false,
               StringFormat("Slippage gate: price %.5f drifted >%.1f pips from box edge "
                            "(boxLow=%.5f boxHigh=%.5f) – entry skipped",
                            price, maxSlipPips,
                            score.boxLow, score.boxHigh));
            return;
         }
      }
   }

   // Pip-sized buffer beyond the wick / box edge (Setups A and B)
   int    slBufPoints = IsGold(symbol)
                        ? (int)(InpSlBufferPips * 10.0)
                        : ForexPipsToPoints(symbol, InpSlBufferPips);
   double slBuf       = slBufPoints * point;

   // Minimum SL distance (prevents oversized lots when wick is very tight)
   int    minSlPoints = IsGold(symbol)
                        ? InpGoldSlPoints
                        : ForexPipsToPoints(symbol, InpFallbackSlPips);
   double minSlDist   = minSlPoints * point;

   // ── SL Placement ──────────────────────────────────────────────────────────
   double sl;
   if(score.setup == SETUP_RUBBER_BAND &&
      score.signalBarHigh > 0.0 && score.signalBarLow > 0.0)
   {
      // Setup A – SL just beyond the exhaustion sweep wick of the signal bar
      sl = (score.direction == STRAT_DIR_BUY)
           ? score.signalBarLow  - slBuf
           : score.signalBarHigh + slBuf;
   }
   else if(score.setup == SETUP_RANGE_SCALP &&
           score.boxHigh > 0.0 && score.boxLow > 0.0)
   {
      // Setup B – SL just outside the 5M structural box edge
      sl = (score.direction == STRAT_DIR_BUY)
           ? score.boxLow  - slBuf
           : score.boxHigh + slBuf;
   }
   else if(score.setup == SETUP_HFT_RANGE_SCALP &&
           score.boxHigh > 0.0 && score.boxLow > 0.0)
   {
      // Setup C – SL just outside box edge using the tighter Setup-C-specific buffer
      double slCBuf = InpSetupCSLBufferPips * pipSize;
      sl = (score.direction == STRAT_DIR_BUY)
           ? score.boxLow  - slCBuf
           : score.boxHigh + slCBuf;
   }
   else
   {
      // Fallback – fixed pip distance
      sl = (score.direction == STRAT_DIR_BUY)
           ? price - minSlDist
           : price + minSlDist;
   }

   // Enforce minimum SL distance (avoids dangerously large lots from tiny wicks)
   double slDist = MathAbs(price - sl);
   if(slDist < minSlDist)
   {
      sl    = (score.direction == STRAT_DIR_BUY) ? price - minSlDist : price + minSlDist;
      slDist = minSlDist;
   }
   int slPoints = (int)MathRound(slDist / point);
   if(slPoints < 1) slPoints = 1;

   // ── TP Placement ──────────────────────────────────────────────────────────
   // Setup C (Stoch+RSI filtered, box-unrestricted): large TP = InpRRMax × SL distance.
   //   The box opposite wall is available but we use the full RRMax distance so
   //   the trade rides the move as far as possible ("large TP" mode).
   // Setup B: opposite box wall (natural range target); trailing then extends it.
   // Setup A: hard TP at InpRRMax × SL distance; trailing activates at InpRRMin.
   double tp;
   if(score.setup == SETUP_HFT_RANGE_SCALP)
   {
      tp = (score.direction == STRAT_DIR_BUY)
           ? price + slDist * InpRRMax
           : price - slDist * InpRRMax;
   }
   else if(score.setup == SETUP_RANGE_SCALP &&
           score.boxHigh > 0.0 && score.boxLow > 0.0)
   {
      tp = (score.direction == STRAT_DIR_BUY) ? score.boxHigh : score.boxLow;
   }
   else
   {
      tp = (score.direction == STRAT_DIR_BUY)
           ? price + slDist * InpRRMax
           : price - slDist * InpRRMax;
   }

   // ── Execute ───────────────────────────────────────────────────────────────
   g_orderInFlight = true;
   double lotSize = ComputeLotSize(symbol, slPoints);
   bool   opened  = g_exec.Open(symbol, score.direction, lotSize,
                                InpMaxDeviationPoints, InpOrderRetries,
                                sl, tp, g_logger);
   g_orderInFlight = false;

   // ── Post-fill slippage validation (Setup B only) ─────────────────────────
   // Setup C is box-unrestricted – post-fill check skipped.
   if(opened && score.setup == SETUP_RANGE_SCALP)
   {
      if(score.boxHigh > 0.0 && score.boxLow > 0.0 && PositionSelect(symbol))
      {
         double fillPrice   = PositionGetDouble(POSITION_PRICE_OPEN);
         double boxEdge     = (score.direction == STRAT_DIR_BUY) ? score.boxLow : score.boxHigh;
         double maxSlipPips = IsGold(symbol) ? InpSetupCMaxSlippagePipsGold : InpSetupCMaxSlippagePips;
         double slipLimit   = maxSlipPips * pipSize;
         bool   fillOk;
         // BUY filled from below: fill should not be far above boxLow
         // SELL filled from above: fill should not be far below boxHigh
         if(score.direction == STRAT_DIR_BUY)
            fillOk = (fillPrice <= boxEdge + slipLimit);
         else
            fillOk = (fillPrice >= boxEdge - slipLimit);

         if(!fillOk)
         {
            g_logger.LogDecision(symbol, false,
               StringFormat("Post-fill slip: fill=%.5f edge=%.5f slip=%.1f pips > limit %.1f – closing bad fill",
                            fillPrice, boxEdge,
                            MathAbs(fillPrice - boxEdge) / pipSize,
                            maxSlipPips));
            g_exec.CloseSymbolPosition(symbol, g_logger);
            opened = false;
         }
      }
   }

   if(opened)
   {
      g_openPositionSetup  = (SetupType)score.setup;
      g_lastEntrySignalBar = signalBar;
      g_risk.RegisterEntry(TimeCurrent());

      string setupName = (score.setup == SETUP_RUBBER_BAND)    ? "RubberBand"
                       : (score.setup == SETUP_RANGE_SCALP)    ? "RangeScalp"
                                                                : "HFTRangeScalp";
      g_logger.LogDecision(symbol, true,
                           StringFormat("Entry executed | setup=%s dir=%d",
                                        setupName, score.direction));
   }
   else
   {
      g_logger.LogDecision(symbol, false, "Execution failed after retries");
   }
}

//──────────────────────────────────────────────────────────────────────────────
// Event handlers
//──────────────────────────────────────────────────────────────────────────────
int OnInit()
{
   g_logger.Init(InpDebugMode);
   g_risk.Init();
   g_exec.Init(InpMagicNumber);
   g_scoring.Init();

   if(!IsAllowedSymbol(_Symbol))
   {
      g_logger.Log("Unsupported symbol for this EA");
      return INIT_FAILED;
   }

   // Attach WeChuckSignal to the visual chart so the dashboard is visible in
   // both live trading and Strategy Tester visual mode.
   if(InpAutoAttachSignal)
   {
      bool alreadyAttached = false;
      int  indTotal = ChartIndicatorsTotal(ChartID(), 0);
      for(int i = 0; i < indTotal; i++)
      {
         if(StringFind(ChartIndicatorName(ChartID(), 0, i), "WeChuckSignal") >= 0)
         { alreadyAttached = true; break; }
      }
      if(!alreadyAttached)
      {
         int sigHandle = iCustom(_Symbol, PERIOD_M1, "WeChuck\\WeChuckSignal",
                                 InpAdxPeriod, InpAdxExhaustionLevel,
                                 InpAdxExpandingMin, InpAdxExpandingMax,
                                 InpAdxRangingThreshold, InpAdxExitWeakThreshold,
                                 InpRsiPeriod, InpRsiOversold, InpRsiOverbought,
                                 InpStochK, InpStochD, InpStochSlowing,
                                 InpStochOversold, InpStochOverbought,
                                 InpM5RangeLookback, InpBoxTolerancePct,
                                 InpZoneLookback, InpZoneWingBars,
                                 InpZoneMinTouches, InpZoneTolerancePct,
                                 (int)CORNER_LEFT_UPPER, 12, 22);
         if(sigHandle != INVALID_HANDLE)
            ChartIndicatorAdd(ChartID(), 0, sigHandle);
      }
   }

   g_logger.Log(StringFormat(
      "EA initialized (v2.30) | A=%s B=%s C=%s(adx=%s minBox=%.0fpips slipForex=%.1fpips slipGold=%.1fpips maxP=$%.0f)",
      InpEnableSetupA ? "ON" : "OFF",
      InpEnableSetupB ? "ON" : "OFF",
      InpEnableSetupC ? "ON" : "OFF",
      InpSetupCRequireADX ? "ON" : "OFF",
      InpSetupCMinBoxSizePips, InpSetupCMaxSlippagePips, InpSetupCMaxSlippagePipsGold, InpSetupCMaxProfitDollar));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   g_logger.DumpStats();
}

void OnTick()
{
   if(!IsAllowedSymbol(_Symbol)) return;

   // Reset setup tracker when no position is open so the next entry starts clean
   if(!PositionExistsForSymbol(_Symbol))
      g_openPositionSetup = SETUP_NONE;

   ManageOpenPosition(_Symbol);

   if(!NewM1Bar(_Symbol)) return;
   TryEntry(_Symbol);
}

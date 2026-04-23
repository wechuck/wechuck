#property strict
#property version   "3.00"
#property description "WeChuck EA – Multi-Timeframe Exhaustion & Range Scalp Strategy"
// Changelog:
//   v3.00 – Full Layer 1-5 strategy upgrade (PhD/Expert-grade win-rate plan 2026):
//           • Per-setup session windows (A: 07-17, B: 07-16, C: 07:15-15 UTC)
//           • News Event Hard Block (hardcoded FOMC/NFP/CPI/BOE/ECB + recurring windows)
//           • Box Age Minimum + Max Touches filter (B/C)
//           • Wick Sweep Confirmation "Stop Hunt Trap" entry (B/C; SL on sweep wick)
//           • Dual M1+M5 Stochastic gate
//           • Rejection Candle (pin bar) gate (A/C)
//           • ATR Compression / Expansion filter (M5)
//           • H4 EMA Trend Alignment for Setup A
//           • Fibonacci Confluence gate (B/C, optional)
//           • Round-number magnet avoidance
//           • Tick-volume minimum + Liquidity-void filter
//           • Box Invalidation Close (B/C: close immediately when 5M closes outside box)
//           • Breakeven Stop trigger (% of box range)
//           • 3-Target Partial Close system (T1/T2/T3)
//           • Adaptive Entry Strictness based on rolling win rate
//           • Drawdown-Adaptive Lot Sizing (session-peak based)
//           • Daily session reset (rolling buffer + peak equity + DD scale)
//   v2.32 – Fixed same-second open/close on Setup C: max-profit cap placed AFTER min-hold.
//   v2.31 – Setup C entry now requires RSI confirmation. Dynamic exit disabled for Setup C.
//   v2.30 – Per-setup enable/disable switches.
//   v2.20 – Setup C "HFT Range Scalp" added.
//   v2.00 – Full strategy rework: Setup A (Rubber Band) + Setup B (Range Scalp).
//   v1.00 – Initial release.

#include "include/Types.mqh"
#include "include/DiagnosticsLogger.mqh"
#include "include/MarketStructureFilter.mqh"
#include "include/EntryScoring.mqh"
#include "include/RiskManager.mqh"
#include "include/ExecutionManager.mqh"
#include "include/NewsFilter.mqh"
#include "include/PartialCloseManager.mqh"

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

input group "Per-Setup Session Windows (UTC)"
input int    InpSetupA_StartHour  = 7;   // Setup A trading start hour (default 07:00 UTC)
input int    InpSetupA_EndHour    = 17;  // Setup A trading end hour   (default 17:00 UTC)
input int    InpSetupB_StartHour  = 7;   // Setup B trading start hour (default 07:00 UTC)
input int    InpSetupB_EndHour    = 16;  // Setup B trading end hour   (default 16:00 UTC)
input int    InpSetupC_StartHour  = 7;   // Setup C trading start hour (default 07:00 UTC)
input int    InpSetupC_EndHour    = 15;  // Setup C trading end hour   (default 15:00 UTC)
input int    InpSetupC_SkipLondonOpenMinutes = 15; // Skip first N minutes of London open (07:00+N)

input group "News Event Hard Block"
input bool   InpEnableNewsFilter  = true;  // Block entries around high-impact news events
input int    InpNewsWindowMinutes = 30;    // ± window in minutes around each event

input group "Bias Filter (M15) – optional alignment check"
input int    InpEmaFast              = 50;
input int    InpEmaSlow              = 200;
input int    InpStructureLookback    = 10;
input bool   InpRequireM15Alignment  = false;

input group "ADX – Environment Filter (14-period)"
input int    InpAdxPeriod            = 14;
input double InpAdxExhaustionLevel   = 40.0;
input double InpAdxExpandingMin      = 25.0;
input double InpAdxExpandingMax      = 35.0;
input double InpAdxRangingThreshold  = 20.0;
input double InpAdxExitWeakThreshold = 18.0;

input group "RSI – Pressure Gauge (14-period)"
input int    InpRsiPeriod            = 14;
input double InpRsiOversold          = 30.0;
input double InpRsiOverbought        = 70.0;

input group "Stochastic (14,1,3) – The Trigger"
input int    InpStochK               = 14;
input int    InpStochD               = 3;
input int    InpStochSlowing         = 1;
input double InpStochOversold        = 20.0;
input double InpStochOverbought      = 80.0;

input group "5M Range Box (Setup B)"
input int    InpM5RangeLookback      = 50;
input double InpBoxTolerancePct      = 15.0;

input group "Zone Detector – No Zone, No Trade"
input bool   InpRequireZone          = true;
input int    InpZoneLookback         = 200;
input int    InpZoneWingBars         = 3;
input int    InpZoneMinTouches       = 2;
input double InpZoneTolerancePct     = 0.05;

input group "Box Quality Filters (Setup B/C)"
input int    InpMinBoxAgeMinutes     = 45;   // Minimum box age in minutes (0 = off)
input int    InpMinBoxTouches        = 3;    // Minimum wall touches required (0 = off)
input int    InpMaxBoxTouches        = 6;    // Maximum wall touches – wall weakening (0 = off)

input group "Wick Sweep Confirmation – Stop Hunt Trap (Setup B/C)"
input bool   InpRequireWickSweep        = true;  // Require pierce-and-close-back beyond box wall
input double InpSweepBufferPipsForex    = 5.0;   // Max sweep depth in pips (Forex)
input double InpSweepBufferPipsGold     = 50.0;  // Max sweep depth in pips (Gold/XAUUSD)

input group "Dual Timeframe Stochastic Gate"
input bool   InpRequireM5StochConfirm  = true;  // M5 Stoch K must also be at extreme

input group "Rejection Candle Gate (Setup A/C)"
input bool   InpRequireRejectionCandle = false;  // Require pin bar / hammer on signal bar
input double InpMinWickBodyRatio       = 2.0;    // Min (wick / body) ratio

input group "ATR Expansion Filter (M5)"
input bool   InpRequireATRExpansion    = false;  // M5 ATR must be rising vs prior bar
input int    InpATRPeriod              = 14;     // ATR period

input group "H4 EMA Trend Alignment (Setup A)"
input bool   InpRequireH4TrendAlign    = true;   // Only take Setup A in H4 EMA trend direction
input int    InpH4EmaFast              = 50;     // H4 fast EMA period
input int    InpH4EmaSlow              = 200;    // H4 slow EMA period

input group "Fibonacci Confluence Gate (Setup B/C, optional)"
input bool   InpRequireFibConfluence   = false;  // Box wall must coincide with H1 Fib level
input double InpFibTolerancePct        = 0.10;   // Fib band tolerance as % of price

input group "Expert-Grade Entry Filters"
input bool   InpAvoidRoundNumbers      = true;   // Skip entries near round-number magnets
input double InpRoundNumRadiusPipsForex = 3.0;   // Round-number avoidance radius (Forex pips)
input double InpRoundNumRadiusPipsGold  = 30.0;  // Round-number avoidance radius (Gold pips)
input int    InpMinTickVolume           = 0;      // Min tick volume on signal bar (0 = off)
input bool   InpLiquidityVoidFilter     = false;  // Block if bar range > 3× M1 ATR

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

input group "Drawdown-Adaptive Lot Sizing"
input bool   InpDDAdaptiveLots   = true;   // Halve lot size after session drawdown > InpDDScalePct
input double InpDDScalePct       = 5.0;    // Drawdown % from session peak that triggers halving
input double InpDDLotFactor      = 0.5;    // Lot multiplier when scaling is active

input group "Adaptive Entry Strictness (Rolling Win Rate)"
input bool   InpAdaptiveMode          = true;   // Raise all confirmation thresholds after a bad streak
input int    InpRollingWindowTrades   = 20;     // Number of recent trades to monitor
input double InpAdaptiveLowWinRate    = 55.0;   // Below this → force all optional gates ON

input group "Stops and Targets"
input double InpSlBufferPips         = 2.0;
input double InpFallbackSlPips       = 8.0;
input double InpGoldSlPoints         = 150;
input double InpRRMin                = 4.7;
input double InpRRMax                = 10.0;
input int    InpTimeExitBars         = 15;
input int    InpMinHoldSeconds       = 60;
input double InpTrailingDistancePips = 3.0;

input group "Partial Close System"
input bool   InpUsePartialClose  = true;   // Enable 3-target partial close
input double InpT1RR             = 1.0;    // R:R to trigger T1 close
input double InpT2RR             = 2.0;    // R:R to trigger T2 close
input double InpT1ClosePct       = 33.0;   // % of position closed at T1
input double InpT2ClosePct       = 33.0;   // % of position closed at T2

input group "Breakeven Stop"
input bool   InpUseBreakeven     = true;   // Move SL to BE after profit reaches threshold
input double InpBreakevenAtPct   = 50.0;   // % of box range at which BE triggers (B/C)

input group "Box Invalidation"
input bool   InpCloseOnBoxBreak  = true;   // Close B/C trade if 5M candle closes outside box

input group "Execution"
input int  InpMaxDeviationPoints = 10;
input int  InpOrderRetries       = 3;
input bool InpAutoAttachSignal   = true;

input group "Setup Enable / Disable"
input bool   InpEnableSetupA          = true;
input bool   InpEnableSetupB          = true;

input group "Setup C – HFT Range Scalp"
input bool   InpEnableSetupC          = true;
input bool   InpSetupCRequireADX      = false;
input double InpSetupCMinBoxSizePips  = 30.0;
input double InpSetupCSLBufferPips    = 1.5;
input double InpSetupCMaxProfitDollar = 15.0;
input double InpSetupCMaxSlippagePips     = 2.0;
input double InpSetupCMaxSlippagePipsGold = 50.0;

input group "Setup F – Weekly Precision Scalp"
input bool   InpEnableSetupF             = true;   // Enable Setup F (20-pip challenge)
input int    InpSetupFPipTarget          = 20;     // Net pip target per trade (20 or 50)
input double InpSetupFSpreadCommPips     = 2.0;    // Extra pips added to TP to cover spread+commission
input double InpSetupFWeeklySweepBufPips = 15.0;  // Max wick pierce beyond weekly level (pips)
input bool   InpSetupFRequireH4Align     = true;   // H4 EMA must not oppose direction
input bool   InpSetupFRequireM15Stoch    = true;   // M15 Stochastic must cross from extreme
input int    InpSetupFMaxWeeklyTrades    = 3;      // Max Setup F trades per calendar week (Mon–Sun)
input double InpSetupFSLBufferPips       = 3.0;    // SL buffer beyond the weekly sweep wick (pips)
input double InpSetupFRiskPct            = 30.0;   // Risk % per trade (20-pip challenge table: 30%)
input int    InpSetupF_StartHour         = 2;      // Setup F session start hour UTC
input int    InpSetupF_EndHour           = 21;     // Setup F session end hour UTC

//──────────────────────────────────────────────────────────────────────────────
// Globals
//──────────────────────────────────────────────────────────────────────────────
CDiagnosticsLogger     g_logger;
CMarketStructureFilter g_bias;
CEntryScoring          g_scoring;
CRiskManager           g_risk;
CExecutionManager      g_exec;
CNewsFilter            g_news;
CPartialCloseManager   g_partial;

datetime  g_lastM1BarTime      = 0;
datetime  g_lastEntrySignalBar = 0;
bool      g_orderInFlight      = false;
SetupType g_openPositionSetup  = SETUP_NONE;  // tracks which setup opened the current position

// Entry box levels – stored when a position is opened for box-invalidation / BE checks
double    g_entryBoxHigh       = 0.0;
double    g_entryBoxLow        = 0.0;
bool      g_breakevenApplied   = false;

// Position state for win/loss outcome detection
bool      g_prevPositionOpen   = false;
double    g_prevPositionProfit = 0.0;

// Setup F – weekly trade counter (reset each Mon 00:00 UTC)
int       g_setupFWeeklyTradeCount = 0;
datetime  g_setupFWeekStart        = 0;

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

//──────────────────────────────────────────────────────────────────────────────
// IsInSetupSessionWindow
// Returns true when the current UTC time is within the allowed trading window
// for the given setup.
// Setup C avoids the first InpSetupC_SkipLondonOpenMinutes of London open.
//──────────────────────────────────────────────────────────────────────────────
bool IsInSetupSessionWindow(const SetupType setup, const datetime now)
{
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int hour = dt.hour;
   int min  = dt.min;

   if(setup == SETUP_RUBBER_BAND)
   {
      return (hour >= InpSetupA_StartHour && hour < InpSetupA_EndHour);
   }
   if(setup == SETUP_RANGE_SCALP)
   {
      return (hour >= InpSetupB_StartHour && hour < InpSetupB_EndHour);
   }
   if(setup == SETUP_HFT_RANGE_SCALP)
   {
      if(hour < InpSetupC_StartHour || hour >= InpSetupC_EndHour) return false;
      // Skip the first N minutes of London open (avoid box-break period)
      if(hour == InpSetupC_StartHour && min < InpSetupC_SkipLondonOpenMinutes) return false;
      return true;
   }
   if(setup == SETUP_WEEKLY_PRECISION)
   {
      return (hour >= InpSetupF_StartHour && hour < InpSetupF_EndHour);
   }
   return true;
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
   // Apply drawdown-adaptive lot factor
   if(InpDDAdaptiveLots)
   {
      double ddFactor = g_risk.GetLotFactor(equity, InpDDScalePct, InpDDLotFactor);
      lot = MathMax(safeMin, MathFloor((lot * ddFactor) / stepVolume) * stepVolume);
   }
   return NormalizeDouble(lot, 2);
}

//──────────────────────────────────────────────────────────────────────────────
// ResetSetupFWeeklyCounterIfNeeded
// Detects Monday 00:00 UTC rollover and zeros the weekly trade counter.
//──────────────────────────────────────────────────────────────────────────────
void ResetSetupFWeeklyCounterIfNeeded()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   // day_of_week: 0=Sunday, 1=Monday … 6=Saturday
   int      daysSinceMon = (dt.day_of_week == 0) ? 6 : dt.day_of_week - 1;
   datetime curWeekMon   = TimeCurrent() -
                           (datetime)((long)daysSinceMon * 86400 +
                                      dt.hour * 3600 + dt.min * 60 + dt.sec);
   if(curWeekMon > g_setupFWeekStart)
   {
      g_setupFWeekStart        = curWeekMon;
      g_setupFWeeklyTradeCount = 0;
   }
}

//──────────────────────────────────────────────────────────────────────────────
// ComputeSetupFLotSize
// Sizes the lot for Setup F using the 20-pip challenge risk table:
// risk = InpSetupFRiskPct (default 30%) of current account equity.
//──────────────────────────────────────────────────────────────────────────────
double ComputeSetupFLotSize(const string symbol, const int slPoints)
{
   double equity           = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount       = equity * InpSetupFRiskPct / 100.0;
   double point            = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tickSize         = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue        = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
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
   double lot     = MathFloor(rawLot / stepVolume) * stepVolume;
   double safeMin = (minVolume > 0.0 ? minVolume : 0.01);
   double safeMax = (maxVolume > 0.0 ? maxVolume : 100.0);
   return NormalizeDouble(MathMax(safeMin, MathMin(lot, safeMax)), 2);
}

//──────────────────────────────────────────────────────────────────────────────
// ManageOpenPosition – trailing stop + time-based exit + dynamic exit
//  + partial close + breakeven + box invalidation close
//──────────────────────────────────────────────────────────────────────────────
void ManageOpenPosition(const string symbol)
{
   if(!PositionSelect(symbol)) return;

   long posType = PositionGetInteger(POSITION_TYPE);
   int  dir     = (posType == POSITION_TYPE_BUY) ? STRAT_DIR_BUY : STRAT_DIR_SELL;

   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

   // Minimum hold time – suppress all soft exits until elapsed
   if(InpMinHoldSeconds > 0 && TimeCurrent() - openTime < (datetime)InpMinHoldSeconds)
      return;

   // ── Partial close (T1 / T2) ──────────────────────────────────────────────
   g_partial.Manage(symbol,
                    InpT1RR, InpT2RR, InpT1ClosePct, InpT2ClosePct,
                    InpUsePartialClose);

   // Re-check position still exists after partial close
   if(!PositionSelect(symbol)) return;

   // ── Breakeven stop (box-range percentage trigger) ─────────────────────────
   // Fires when price has moved InpBreakevenAtPct% of the entry box range in profit.
   // Only for box-setups (B/C) where the box range is meaningful.
   if(InpUseBreakeven && !g_breakevenApplied &&
      (g_openPositionSetup == SETUP_RANGE_SCALP ||
       g_openPositionSetup == SETUP_HFT_RANGE_SCALP) &&
      g_entryBoxHigh > g_entryBoxLow)
   {
      double openPrice   = PositionGetDouble(POSITION_PRICE_OPEN);
      double boxRange    = g_entryBoxHigh - g_entryBoxLow;
      double beThreshold = boxRange * (InpBreakevenAtPct / 100.0);

      MqlTick tick;
      if(SymbolInfoTick(symbol, tick))
      {
         double profitMove = (dir == STRAT_DIR_BUY)
                             ? tick.bid - openPrice
                             : openPrice - tick.ask;

         if(profitMove >= beThreshold)
         {
            double currentSL = PositionGetDouble(POSITION_SL);
            double currentTP = PositionGetDouble(POSITION_TP);
            double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
            double onePip    = OnePipPrice(symbol);
            double newSL     = (dir == STRAT_DIR_BUY)
                               ? openPrice + onePip
                               : openPrice - onePip;

            bool beNeeded = (dir == STRAT_DIR_BUY)
                            ? (newSL > currentSL)
                            : (currentSL == 0.0 || newSL < currentSL);

            if(beNeeded && g_exec.ModifyPosition(symbol, newSL, currentTP))
            {
               g_breakevenApplied = true;
               g_logger.LogDecision(symbol, false,
                  StringFormat("Breakeven applied | profit=%.5f threshold=%.5f newSL=%.5f",
                               profitMove, beThreshold, newSL));
            }
         }
      }
   }

   // Re-check position still exists
   if(!PositionSelect(symbol)) return;

   // ── News window: tighten SL to breakeven for open positions ──────────────
   if(InpEnableNewsFilter && !g_breakevenApplied && g_news.IsNewsWindow(TimeCurrent()))
   {
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double onePip    = OnePipPrice(symbol);
      double newSL     = (dir == STRAT_DIR_BUY) ? openPrice + onePip : openPrice - onePip;
      bool   beNeeded  = (dir == STRAT_DIR_BUY)
                         ? (newSL > currentSL)
                         : (currentSL == 0.0 || newSL < currentSL);
      if(beNeeded)
      {
         g_exec.ModifyPosition(symbol, newSL, currentTP);
         g_breakevenApplied = true;
         g_logger.LogDecision(symbol, false, "News window: SL moved to breakeven");
      }
   }

   // Re-check position still exists
   if(!PositionSelect(symbol)) return;

   // ── Box invalidation close (Setup B/C only) ───────────────────────────────
   // If a 5M candle closes outside the box, the structural premise is broken.
   if(InpCloseOnBoxBreak &&
      (g_openPositionSetup == SETUP_RANGE_SCALP ||
       g_openPositionSetup == SETUP_HFT_RANGE_SCALP) &&
      g_entryBoxHigh > g_entryBoxLow)
   {
      MqlRates m5bar[1];
      ArraySetAsSeries(m5bar, true);
      if(CopyRates(symbol, PERIOD_M5, 1, 1, m5bar) == 1)
      {
         bool invalidated = false;
         if(dir == STRAT_DIR_BUY  && m5bar[0].close < g_entryBoxLow)  invalidated = true;
         if(dir == STRAT_DIR_SELL && m5bar[0].close > g_entryBoxHigh) invalidated = true;

         if(invalidated)
         {
            g_logger.LogDecision(symbol, false,
               StringFormat("Box invalidation close | 5M close=%.5f box=[%.5f,%.5f]",
                            m5bar[0].close, g_entryBoxLow, g_entryBoxHigh));
            g_exec.CloseSymbolPosition(symbol, g_logger);
            return;
         }
      }
   }

   // Re-check position still exists
   if(!PositionSelect(symbol)) return;

   // ── Setup C max-profit guard ──────────────────────────────────────────────
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

   // ── Time-based exit ───────────────────────────────────────────────────────
   // Setup F uses a longer timeout (pip-target may take several hours to hit).
   // 480 M1 bars ≈ 8 hours, giving enough time to reach 20 or 50 pips.
   if(!PositionSelect(symbol)) return;
   int barsSinceOpen = iBarShift(symbol, PERIOD_M1, openTime, true);
   int timeExitBars  = (g_openPositionSetup == SETUP_WEEKLY_PRECISION) ? 480 : InpTimeExitBars;
   if(barsSinceOpen >= timeExitBars && timeExitBars > 0)
   {
      g_logger.LogDecision(symbol, false, "Time-based exit");
      g_exec.CloseSymbolPosition(symbol, g_logger);
      return;
   }

   // ── Dynamic exit (only when in profit – protect winners) ─────────────────
   // Skipped for Setup C – those trades close only by TP, SL, time exit, or max-profit cap.
   // Skipped for Setup F – fixed pip-target TP handles the exit.
   if(!PositionSelect(symbol)) return;
   double posProfit = PositionGetDouble(POSITION_PROFIT);
   if(g_openPositionSetup != SETUP_HFT_RANGE_SCALP &&
      g_openPositionSetup != SETUP_WEEKLY_PRECISION && posProfit > 0.0)
   {
      StrategyParams exitP;
      exitP.adxPeriod            = InpAdxPeriod;
      exitP.adxExhaustionLevel   = InpAdxExhaustionLevel;
      exitP.adxExpandingMin      = InpAdxExpandingMin;
      exitP.adxExpandingMax      = InpAdxExpandingMax;
      exitP.adxRangingThreshold  = InpAdxRangingThreshold;
      exitP.adxExitWeakThreshold = InpAdxExitWeakThreshold;
      exitP.rsiPeriod            = InpRsiPeriod;
      exitP.rsiOversold          = InpRsiOversold;
      exitP.rsiOverbought        = InpRsiOverbought;
      exitP.stochKPeriod         = InpStochK;
      exitP.stochDPeriod         = InpStochD;
      exitP.stochSlowing         = InpStochSlowing;
      exitP.stochOversold        = InpStochOversold;
      exitP.stochOverbought      = InpStochOverbought;
      exitP.m5RangeLookback      = InpM5RangeLookback;
      exitP.boxTouchTolerancePct = InpBoxTolerancePct / 100.0;

      if(g_scoring.ShouldExitByDynamics(symbol, dir, exitP))
      {
         g_logger.LogDecision(symbol, false, "Dynamic exit condition");
         g_exec.CloseSymbolPosition(symbol, g_logger);
         return;
      }
   }

   // ── R:R-aware trailing stop ───────────────────────────────────────────────
   if(!PositionSelect(symbol)) return;
   double openPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
   double entrySL      = PositionGetDouble(POSITION_SL);
   double currentSL    = entrySL;
   double currentTP    = PositionGetDouble(POSITION_TP);
   double slDist       = MathAbs(openPrice - entrySL);
   double trailTrigger = slDist * InpRRMin;

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

   // ── News filter ──────────────────────────────────────────────────────────
   if(InpEnableNewsFilter && g_news.IsNewsWindow(TimeCurrent()))
   {
      g_logger.LogDecision(symbol, false, "News event hard block – no new entries");
      return;
   }

   // ── Build StrategyParams with all gate fields ─────────────────────────────
   double setupCMinBoxSize       = InpSetupCMinBoxSizePips * OnePipPrice(symbol);
   double sweepBufPrice          = (IsGold(symbol) ? InpSweepBufferPipsGold
                                                   : InpSweepBufferPipsForex) * OnePipPrice(symbol);
   double roundNumRadiusPrice    = (IsGold(symbol) ? InpRoundNumRadiusPipsGold
                                                   : InpRoundNumRadiusPipsForex) * OnePipPrice(symbol);

   // Determine if adaptive mode is forcing stricter gates
   double rollingWR = g_risk.RollingWinRatePct();
   bool   lowWR     = (InpAdaptiveMode && rollingWR < InpAdaptiveLowWinRate);
   if(lowWR)
      g_logger.LogDecision(symbol, false,
         StringFormat("Adaptive mode ACTIVE – rolling WR %.0f%% < %.0f%% threshold, "
                      "forcing M5Stoch + RejCandle + H4Align + M15Bias ON",
                      rollingWR, InpAdaptiveLowWinRate));

   StrategyParams p;
   p.adxPeriod              = InpAdxPeriod;
   p.adxExhaustionLevel     = InpAdxExhaustionLevel;
   p.adxExpandingMin        = InpAdxExpandingMin;
   p.adxExpandingMax        = InpAdxExpandingMax;
   p.adxRangingThreshold    = InpAdxRangingThreshold;
   p.adxExitWeakThreshold   = InpAdxExitWeakThreshold;
   p.rsiPeriod              = InpRsiPeriod;
   p.rsiOversold            = InpRsiOversold;
   p.rsiOverbought          = InpRsiOverbought;
   p.stochKPeriod           = InpStochK;
   p.stochDPeriod           = InpStochD;
   p.stochSlowing           = InpStochSlowing;
   p.stochOversold          = InpStochOversold;
   p.stochOverbought        = InpStochOverbought;
   p.m5RangeLookback        = InpM5RangeLookback;
   p.boxTouchTolerancePct   = InpBoxTolerancePct / 100.0;
   p.setupAEnabled          = InpEnableSetupA;
   p.setupBEnabled          = InpEnableSetupB;
   p.setupCEnabled          = InpEnableSetupC;
   p.setupCRequireADX       = InpSetupCRequireADX;
   p.setupCMinBoxSize       = setupCMinBoxSize;
   // Box quality
   p.minBoxAgeMinutes       = InpMinBoxAgeMinutes;
   p.minBoxTouches          = InpMinBoxTouches;
   p.maxBoxTouches          = InpMaxBoxTouches;
   // Wick sweep
   p.requireWickSweep       = InpRequireWickSweep;
   p.sweepBufferPrice       = sweepBufPrice;
   // Dual M5 Stoch – forced on when in adaptive low-WR mode
   p.requireM5StochConfirm  = InpRequireM5StochConfirm || lowWR;
   // Rejection candle – forced on when in adaptive low-WR mode
   p.requireRejectionCandle = InpRequireRejectionCandle || lowWR;
   p.minWickBodyRatio       = InpMinWickBodyRatio;
   // ATR expansion
   p.requireATRExpansion    = InpRequireATRExpansion;
   p.atrPeriod              = InpATRPeriod;
   // H4 trend – forced on for Setup A when in adaptive low-WR mode
   p.requireH4TrendAlign    = InpRequireH4TrendAlign || lowWR;
   p.h4EmaFast              = InpH4EmaFast;
   p.h4EmaSlow              = InpH4EmaSlow;
   // Fib confluence
   p.requireFibConfluence   = InpRequireFibConfluence;
   p.fibTolerancePct        = InpFibTolerancePct;
   // Expert filters
   p.avoidRoundNumbers      = InpAvoidRoundNumbers;
   p.roundNumRadiusPrice    = roundNumRadiusPrice;
   p.minTickVolume          = InpMinTickVolume;
   p.liquidityVoidFilter    = InpLiquidityVoidFilter;
   // Setup F – Weekly Precision Scalp
   p.setupFEnabled          = InpEnableSetupF;
   p.setupFWeeklySweepBuf   = InpSetupFWeeklySweepBufPips * OnePipPrice(symbol);
   p.setupFRequireH4Align   = InpSetupFRequireH4Align;
   p.setupFRequireM15Stoch  = InpSetupFRequireM15Stoch;

   // ── Strategy signal evaluation ────────────────────────────────────────────
   EntryScoreBreakdown score;
   if(!g_scoring.Evaluate(symbol, p,
                          InpRequireZone,
                          InpZoneLookback,
                          InpZoneWingBars,
                          InpZoneMinTouches,
                          InpZoneTolerancePct,
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
                               score.setup == SETUP_HFT_RANGE_SCALP,
                               score.setup == SETUP_WEEKLY_PRECISION);

   if(!score.valid)
   {
      g_logger.LogDecision(symbol, false, "No valid signal: " + score.details);
      return;
   }

   // ── Per-setup session window check ────────────────────────────────────────
   if(!IsInSetupSessionWindow((SetupType)score.setup, TimeCurrent()))
   {
      g_logger.LogDecision(symbol, false,
         StringFormat("Setup %d blocked outside session window", (int)score.setup));
      return;
   }

   // ── Setup F: weekly trade cap ─────────────────────────────────────────────
   if(score.setup == SETUP_WEEKLY_PRECISION)
   {
      ResetSetupFWeeklyCounterIfNeeded();
      if(InpSetupFMaxWeeklyTrades > 0 && g_setupFWeeklyTradeCount >= InpSetupFMaxWeeklyTrades)
      {
         g_logger.LogDecision(symbol, false,
            StringFormat("Setup F weekly cap reached (%d/%d) – waiting for next week",
                         g_setupFWeeklyTradeCount, InpSetupFMaxWeeklyTrades));
         return;
      }
   }

   // ── Pre-conditions (skipped entirely for Setup C and F – box-unrestricted mode) ──
   if(score.setup != SETUP_HFT_RANGE_SCALP && score.setup != SETUP_WEEKLY_PRECISION)
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
   // Also forced ON when in adaptive low-WR mode
   bool requireBias = InpRequireM15Alignment || lowWR;
   BiasResult bias;
   if(requireBias && score.setup != SETUP_HFT_RANGE_SCALP &&
      score.setup != SETUP_WEEKLY_PRECISION)
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
   double pipSize = OnePipPrice(symbol);
   double price   = (score.direction == STRAT_DIR_BUY) ? tick.ask : tick.bid;

   // ── Slippage Protection: pre-entry box-edge distance check (Setup B) ──────
   if(score.setup == SETUP_RANGE_SCALP)
   {
      if(score.boxHigh > 0.0 && score.boxLow > 0.0)
      {
         double maxSlipPips = IsGold(symbol) ? InpSetupCMaxSlippagePipsGold : InpSetupCMaxSlippagePips;
         double slipLimit   = maxSlipPips * pipSize;
         bool   priceOk     = false;
         if(score.direction == STRAT_DIR_BUY)
            priceOk = (tick.ask <= score.boxLow + slipLimit);
         else
            priceOk = (tick.bid >= score.boxHigh - slipLimit);

         if(!priceOk)
         {
            g_logger.LogDecision(symbol, false,
               StringFormat("Slippage gate: price %.5f drifted >%.1f pips from box edge "
                            "(boxLow=%.5f boxHigh=%.5f) – entry skipped",
                            price, maxSlipPips, score.boxLow, score.boxHigh));
            return;
         }
      }
   }

   // Pip-sized buffer beyond the wick / box edge (Setups A and B)
   int    slBufPoints = IsGold(symbol)
                        ? (int)(InpSlBufferPips * 10.0)
                        : ForexPipsToPoints(symbol, InpSlBufferPips);
   double slBuf       = slBufPoints * point;

   int    minSlPoints = IsGold(symbol)
                        ? InpGoldSlPoints
                        : ForexPipsToPoints(symbol, InpFallbackSlPips);
   double minSlDist   = minSlPoints * point;

   // ── SL Placement ──────────────────────────────────────────────────────────
   double sl;
   if(score.setup == SETUP_RUBBER_BAND &&
      score.signalBarHigh > 0.0 && score.signalBarLow > 0.0)
   {
      sl = (score.direction == STRAT_DIR_BUY)
           ? score.signalBarLow  - slBuf
           : score.signalBarHigh + slBuf;
   }
   else if(score.setup == SETUP_RANGE_SCALP &&
           score.boxHigh > 0.0 && score.boxLow > 0.0)
   {
      // If wick sweep was confirmed, use the sweep wick as the SL anchor (tighter)
      if(score.wickSweepConfirmed && score.sweepWickLow > 0.0 && score.direction == STRAT_DIR_BUY)
         sl = score.sweepWickLow - slBuf;
      else if(score.wickSweepConfirmed && score.sweepWickHigh > 0.0 && score.direction == STRAT_DIR_SELL)
         sl = score.sweepWickHigh + slBuf;
      else
         sl = (score.direction == STRAT_DIR_BUY)
              ? score.boxLow  - slBuf
              : score.boxHigh + slBuf;
   }
   else if(score.setup == SETUP_HFT_RANGE_SCALP &&
           score.boxHigh > 0.0 && score.boxLow > 0.0)
   {
      double slCBuf = InpSetupCSLBufferPips * pipSize;
      // If wick sweep was confirmed, use the sweep wick as the SL anchor
      if(score.wickSweepConfirmed && score.sweepWickLow > 0.0 && score.direction == STRAT_DIR_BUY)
         sl = score.sweepWickLow - slCBuf;
      else if(score.wickSweepConfirmed && score.sweepWickHigh > 0.0 && score.direction == STRAT_DIR_SELL)
         sl = score.sweepWickHigh + slCBuf;
      else
         sl = (score.direction == STRAT_DIR_BUY)
              ? score.boxLow  - slCBuf
              : score.boxHigh + slCBuf;
   }
   else if(score.setup == SETUP_WEEKLY_PRECISION)
   {
      // SL placed beyond the M15 weekly-level sweep wick plus a configurable buffer.
      // The sweep wick anchors are stored in sweepWickLow (BUY) / sweepWickHigh (SELL).
      double slFBuf = InpSetupFSLBufferPips * pipSize;
      if(score.direction == STRAT_DIR_BUY && score.sweepWickLow > 0.0)
         sl = score.sweepWickLow - slFBuf;
      else if(score.direction == STRAT_DIR_SELL && score.sweepWickHigh > 0.0)
         sl = score.sweepWickHigh + slFBuf;
      else
         sl = (score.direction == STRAT_DIR_BUY) ? price - minSlDist : price + minSlDist;
   }
   else
   {
      sl = (score.direction == STRAT_DIR_BUY)
           ? price - minSlDist
           : price + minSlDist;
   }

   // Enforce minimum SL distance
   double slDist = MathAbs(price - sl);
   if(slDist < minSlDist)
   {
      sl    = (score.direction == STRAT_DIR_BUY) ? price - minSlDist : price + minSlDist;
      slDist = minSlDist;
   }
   int slPoints = (int)MathRound(slDist / point);
   if(slPoints < 1) slPoints = 1;

   // ── TP Placement ──────────────────────────────────────────────────────────
   double tp;
   if(score.setup == SETUP_HFT_RANGE_SCALP)
   {
      tp = (score.direction == STRAT_DIR_BUY)
           ? price + slDist * InpRRMax
           : price - slDist * InpRRMax;
   }
   else if(score.setup == SETUP_WEEKLY_PRECISION)
   {
      // Fixed pip-target TP (net after spread/commission).
      // Gross pips = pipTarget + spreadCommPips so the NET gain equals pipTarget.
      double grossTPPips = InpSetupFPipTarget + InpSetupFSpreadCommPips;
      double grossTPDist = grossTPPips * pipSize;
      tp = (score.direction == STRAT_DIR_BUY)
           ? price + grossTPDist
           : price - grossTPDist;
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
   double lotSize = (score.setup == SETUP_WEEKLY_PRECISION)
                    ? ComputeSetupFLotSize(symbol, slPoints)
                    : ComputeLotSize(symbol, slPoints);
   bool   opened  = g_exec.Open(symbol, score.direction, lotSize,
                                InpMaxDeviationPoints, InpOrderRetries,
                                sl, tp, g_logger);
   g_orderInFlight = false;

   // ── Post-fill slippage validation (Setup B only) ─────────────────────────
   if(opened && score.setup == SETUP_RANGE_SCALP)
   {
      if(score.boxHigh > 0.0 && score.boxLow > 0.0 && PositionSelect(symbol))
      {
         double fillPrice   = PositionGetDouble(POSITION_PRICE_OPEN);
         double boxEdge     = (score.direction == STRAT_DIR_BUY) ? score.boxLow : score.boxHigh;
         double maxSlipPips = IsGold(symbol) ? InpSetupCMaxSlippagePipsGold : InpSetupCMaxSlippagePips;
         double slipLimit   = maxSlipPips * pipSize;
         bool   fillOk;
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
      g_entryBoxHigh       = score.boxHigh;
      g_entryBoxLow        = score.boxLow;
      g_breakevenApplied   = false;
      g_risk.RegisterEntry(TimeCurrent());

      // Increment weekly trade counter for Setup F
      if(score.setup == SETUP_WEEKLY_PRECISION)
         g_setupFWeeklyTradeCount++;

      // Notify partial close manager of new position
      if(PositionSelect(symbol))
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         g_partial.OnNewPosition(ticket);
      }

      string setupName = (score.setup == SETUP_RUBBER_BAND)       ? "RubberBand"
                       : (score.setup == SETUP_RANGE_SCALP)       ? "RangeScalp"
                       : (score.setup == SETUP_HFT_RANGE_SCALP)   ? "HFTRangeScalp"
                                                                   : "WeeklyPrecision";
      g_logger.LogDecision(symbol, true,
                           StringFormat("Entry executed | setup=%s dir=%d sweep=%s wr=%.0f%%",
                                        setupName, score.direction,
                                        score.wickSweepConfirmed ? "Y" : "N",
                                        rollingWR));
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
   g_risk.SetRollingWindowSize(InpRollingWindowTrades);
   g_exec.Init(InpMagicNumber);
   g_scoring.Init();
   g_news.Init(InpNewsWindowMinutes);
   g_partial.Init(InpMagicNumber);

   // Initialise session peak equity on startup
   g_risk.UpdateSessionPeak(AccountInfoDouble(ACCOUNT_EQUITY));

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
      "EA initialized (v3.10) | A=%s B=%s C=%s F=%s(target=%dpips,risk=%.0f%%,maxWkly=%d)"
      " | news=%s wickSweep=%s m5Stoch=%s h4Align=%s | adaptiveMode=%s",
      InpEnableSetupA ? "ON" : "OFF",
      InpEnableSetupB ? "ON" : "OFF",
      InpEnableSetupC ? "ON" : "OFF",
      InpEnableSetupF ? "ON" : "OFF",
      InpSetupFPipTarget, InpSetupFRiskPct, InpSetupFMaxWeeklyTrades,
      InpEnableNewsFilter     ? "ON" : "OFF",
      InpRequireWickSweep     ? "ON" : "OFF",
      InpRequireM5StochConfirm ? "ON" : "OFF",
      InpRequireH4TrendAlign  ? "ON" : "OFF",
      InpAdaptiveMode         ? "ON" : "OFF"));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   g_logger.DumpStats();
}

void OnTick()
{
   if(!IsAllowedSymbol(_Symbol)) return;

   // Update session peak equity on every tick
   g_risk.UpdateSessionPeak(AccountInfoDouble(ACCOUNT_EQUITY));

   bool posOpen = PositionExistsForSymbol(_Symbol);

   // Detect position close → record win/loss outcome for rolling win rate.
   // A trade is a "win" when gross profit exceeds a minimum positive threshold
   // (avoids counting breakeven / commission-only closes as wins).
   if(g_prevPositionOpen && !posOpen)
   {
      bool wasWin = (g_prevPositionProfit > 0.50);   // at least $0.50 net profit = true win
      g_risk.RecordTradeOutcome(wasWin);
      g_partial.OnPositionClosed();
      g_entryBoxHigh = 0.0;
      g_entryBoxLow  = 0.0;
      g_breakevenApplied = false;
   }
   g_prevPositionOpen = posOpen;
   if(posOpen)
      g_prevPositionProfit = PositionGetDouble(POSITION_PROFIT);

   // Reset setup tracker when no position is open
   if(!posOpen)
      g_openPositionSetup = SETUP_NONE;

   ManageOpenPosition(_Symbol);

   if(!NewM1Bar(_Symbol)) return;

   // Daily session reset (rolling buffer + peak equity) at 00:00 UTC
   g_risk.CheckDailyReset(TimeCurrent());

   // Setup F weekly counter rollover check (Mon 00:00 UTC)
   ResetSetupFWeeklyCounterIfNeeded();

   TryEntry(_Symbol);
}

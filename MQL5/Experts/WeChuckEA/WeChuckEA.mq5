#property strict
#property version   "4.00"
#property description "WeChuck EA – Institutional Edge Engine: London Sweep, OB Retest, FVG Fill, Pivot Bounce, MSS Retest, Weekly Sniper"
// Changelog:
//   v4.00 – Complete redesign. Old ADX/Stoch/RSI range-scalp logic removed.
//           New institutional-grade setups based on liquidity, structure, and session mechanics:
//           Setup A: London Liquidity Sweep (Asian-range stop-hunt reversal)
//           Setup B: H4 Order Block Retest (institutional demand/supply zone)
//           Setup C: Fair Value Gap Fill (H1 imbalance in H4 trend direction)
//           Setup D: Daily Classic Pivot Bounce
//           Setup E: Market Structure Shift (MSS) Retest
//           Setup F: Weekly High/Low Sniper (20-pip challenge, $20→$40k compounding)
//   v3.10 – Setup F (Weekly Precision Scalp) added.
//   v3.00 – Expert-grade filter upgrade.

#include "include/Types.mqh"
#include "include/DiagnosticsLogger.mqh"
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
input int    InpLowLiqStartHour      = 22;  // Low-liquidity block start hour UTC
input int    InpLowLiqEndHour        = 1;   // Low-liquidity block end hour UTC
input double InpMinBodyRangeRatio    = 0.20; // Min candle body/range ratio for entry bar

input group "News Event Hard Block"
input bool   InpEnableNewsFilter  = true;  // Block all new entries around high-impact news
input int    InpNewsWindowMinutes = 30;    // ± window in minutes around each event

input group "H4 Trend Filter (Shared by all setups)"
input int    InpH4EmaFast = 50;   // H4 fast EMA period
input int    InpH4EmaSlow = 200;  // H4 slow EMA period

input group "Stochastic (M15 – used by Setup F confirmation)"
input int    InpStochK         = 14;
input int    InpStochD         = 3;
input int    InpStochSlowing   = 1;
input double InpStochOversold  = 20.0;
input double InpStochOverbought = 80.0;

input group "Setup A – London Liquidity Sweep"
input bool   InpEnableSetupA          = true;
input int    InpAsianStartHour        = 0;    // Asian session start UTC (midnight)
input int    InpAsianEndHour          = 7;    // Asian session end UTC
input int    InpLondonStartHour       = 7;    // London open start UTC
input int    InpLondonEndHour         = 10;   // London window end UTC
input double InpSetupASweepBufPips    = 20.0; // Max wick depth beyond Asian H/L (pips)
input double InpSetupAMinRangePips    = 15.0; // Min Asian session range size (pips)

input group "Setup B – H4 Order Block Retest"
input bool   InpEnableSetupB          = true;
input int    InpSetupBH4Lookback      = 50;   // H4 bars to scan for order blocks
input double InpSetupBImpulseFactor   = 1.5;  // Impulse candle must be >= X × avg range
input double InpSetupBRetestPct       = 0.30; // Retest zone as fraction of OB body size
input int    InpSetupBMaxAgeHours     = 48;   // OB expires after this many hours
input int    InpSetupB_StartHour      = 7;    // Session start UTC
input int    InpSetupB_EndHour        = 20;   // Session end UTC

input group "Setup C – Fair Value Gap Fill"
input bool   InpEnableSetupC          = true;
input int    InpSetupCH1Lookback      = 20;   // H1 bars to scan for FVGs
input double InpSetupCMinFVGPips      = 5.0;  // Min FVG size (pips)
input int    InpSetupC_StartHour      = 7;    // Session start UTC
input int    InpSetupC_EndHour        = 20;   // Session end UTC

input group "Setup D – Daily Pivot Bounce"
input bool   InpEnableSetupD          = true;
input double InpSetupDPivotTolPips    = 5.0;  // Max distance from pivot to qualify (pips)
input int    InpSetupD_StartHour      = 7;    // Session start UTC
input int    InpSetupD_EndHour        = 20;   // Session end UTC

input group "Setup E – Market Structure Shift Retest"
input bool   InpEnableSetupE          = true;
input int    InpSetupESwingLookback   = 30;   // H1 bars to scan for swing points
input double InpSetupERetestBufPips   = 5.0;  // Retest zone half-width (pips)
input int    InpSetupE_StartHour      = 7;    // Session start UTC
input int    InpSetupE_EndHour        = 20;   // Session end UTC

input group "Setup F – Weekly High/Low Sniper (20-pip challenge)"
input bool   InpEnableSetupF             = true;
input int    InpSetupFPipTarget          = 20;    // Net pip target per trade (20 or 50)
input double InpSetupFSpreadCommPips     = 2.0;   // Gross TP buffer for spread + commission
input double InpSetupFWeeklySweepBufPips = 15.0;  // Max wick depth beyond weekly level (pips)
input bool   InpSetupFRequireH4Align     = true;  // H4 EMA must not oppose direction
input bool   InpSetupFRequireM15Stoch    = true;  // M15 Stoch must cross from extreme
input int    InpSetupFMaxWeeklyTrades    = 3;     // Hard cap: trades per Mon–Sun week
input double InpSetupFSLBufferPips       = 3.0;   // Extra SL buffer beyond sweep wick (pips)
input double InpSetupFRiskPct            = 30.0;  // Risk % per trade (challenge table: 30%)
input int    InpSetupF_StartHour         = 2;     // Session start UTC
input int    InpSetupF_EndHour           = 21;    // Session end UTC
input int    InpSetupFTimeExitBars       = 480;   // M1 bar timeout (~8h)

input group "Risk Guards"
input int    InpMinSecondsBetweenEntries    = 10;
input int    InpMaxTradesPerSymbolPerHour   = 5;
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
input bool   InpDDAdaptiveLots = true;    // Halve lots when session DD > threshold
input double InpDDScalePct     = 5.0;     // DD% from session peak that triggers halving
input double InpDDLotFactor    = 0.5;     // Lot multiplier when DD scaling is active

input group "Adaptive Entry Strictness (Rolling Win Rate)"
input bool   InpAdaptiveMode        = true;
input int    InpRollingWindowTrades = 20;
input double InpAdaptiveLowWinRate  = 55.0; // Below this WR → suspend lower-confidence setups

input group "Stops and Targets"
input double InpSlBufferPips        = 2.0;   // Buffer added to all SL placements (pips)
input double InpFallbackSlPips      = 8.0;   // Fallback SL if no structural anchor (Forex pips)
input double InpGoldSlPoints        = 150;   // Fallback SL for Gold (points)
input double InpRRMin               = 1.5;   // Min R:R for RR-based TP (TP = slDist × RR)
input double InpRRMax               = 2.5;   // Max R:R cap (used for setups without fixed TP)
input int    InpTimeExitBars        = 60;    // M1 bars before time-based exit (non-F setups)
input int    InpMinHoldSeconds      = 60;    // Min hold before soft exits activate
input double InpTrailingDistancePips = 3.0;  // Trailing stop distance once at RRMin (pips)

input group "Partial Close System"
input bool   InpUsePartialClose = true;
input double InpT1RR            = 1.0;   // R:R to trigger T1 close
input double InpT2RR            = 2.0;   // R:R to trigger T2 close
input double InpT1ClosePct      = 33.0;  // % of position to close at T1
input double InpT2ClosePct      = 33.0;  // % of position to close at T2

input group "Breakeven Stop"
input bool   InpUseBreakeven   = true;
input double InpBreakevenAtRR  = 1.0;   // Move SL to BE after profit reaches 1:1 R:R

input group "Execution"
input int  InpMaxDeviationPoints = 10;
input int  InpOrderRetries       = 3;
input bool InpAutoAttachSignal   = false; // Attach WeChuckSignal indicator to chart

//──────────────────────────────────────────────────────────────────────────────
// Globals
//──────────────────────────────────────────────────────────────────────────────
CDiagnosticsLogger     g_logger;
CEntryScoring          g_scoring;
CRiskManager           g_risk;
CExecutionManager      g_exec;
CNewsFilter            g_news;
CPartialCloseManager   g_partial;

datetime  g_lastM1BarTime      = 0;
datetime  g_lastEntrySignalBar = 0;
bool      g_orderInFlight      = false;
SetupType g_openPositionSetup  = SETUP_NONE;

// Entry key level stored when a position opens (used for management)
double    g_entryKeyLevel      = 0.0;
double    g_entrySlDist        = 0.0;  // |open – SL| at entry time
bool      g_breakevenApplied   = false;

// Position state for win/loss outcome detection
bool      g_prevPositionOpen   = false;
double    g_prevPositionProfit = 0.0;

// Setup F – weekly trade counter (reset each Mon 00:00 UTC)
int       g_setupFWeeklyTradeCount = 0;
datetime  g_setupFWeekStart        = 0;

//──────────────────────────────────────────────────────────────────────────────
// Utility helpers
//──────────────────────────────────────────────────────────────────────────────
bool IsAllowedSymbol(const string symbol)
{
   string upper = symbol;
   StringToUpper(upper);
   return (StringFind(upper, "EURUSD") >= 0 ||
           StringFind(upper, "GBPUSD") >= 0 ||
           StringFind(upper, "GBPAUD") >= 0 ||
           StringFind(upper, "AUDNZD") >= 0 ||
           StringFind(upper, "AUDJPY") >= 0 ||
           StringFind(upper, "XAUUSD") >= 0 ||
           StringFind(upper, "GOLD")   >= 0);
}

bool IsGold(const string symbol)
{
   return (StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0);
}

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

// Returns true if the current UTC hour is within [startHour, endHour).
bool IsInHourWindow(const int startHour, const int endHour)
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   if(startHour <= endHour)
      return (dt.hour >= startHour && dt.hour < endHour);
   return (dt.hour >= startHour || dt.hour < endHour);
}

bool IsInSetupSessionWindow(const SetupType setup)
{
   switch(setup)
   {
      case SETUP_LONDON_SWEEP:     return IsInHourWindow(InpLondonStartHour, InpLondonEndHour);
      case SETUP_ORDER_BLOCK:      return IsInHourWindow(InpSetupB_StartHour, InpSetupB_EndHour);
      case SETUP_FVG_FILL:         return IsInHourWindow(InpSetupC_StartHour, InpSetupC_EndHour);
      case SETUP_PIVOT_BOUNCE:     return IsInHourWindow(InpSetupD_StartHour, InpSetupD_EndHour);
      case SETUP_MSS_RETEST:       return IsInHourWindow(InpSetupE_StartHour, InpSetupE_EndHour);
      case SETUP_WEEKLY_PRECISION: return IsInHourWindow(InpSetupF_StartHour, InpSetupF_EndHour);
      default:                     return true;
   }
}

bool NewM1Bar(const string symbol)
{
   datetime t = iTime(symbol, PERIOD_M1, 0);
   if(t == 0) return false;
   if(t != g_lastM1BarTime) { g_lastM1BarTime = t; return true; }
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
   if(InpDDAdaptiveLots)
   {
      double ddFactor = g_risk.GetLotFactor(equity, InpDDScalePct, InpDDLotFactor);
      lot = MathMax(safeMin, MathFloor((lot * ddFactor) / stepVolume) * stepVolume);
   }
   return NormalizeDouble(lot, 2);
}

// Setup F: risk = InpSetupFRiskPct% of equity (challenge compounding table, 30%)
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
   double slValue    = slPoints * pointValuePerLot;
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

// Detect Monday 00:00 UTC rollover and zero the Setup F weekly trade counter.
void ResetSetupFWeeklyCounterIfNeeded()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int      daysSinceMon = (dt.day_of_week == 0) ? 6 : dt.day_of_week - 1;
   datetime curWeekMon   = TimeGMT() -
                           (datetime)((long)daysSinceMon * 86400 +
                                      dt.hour * 3600 + dt.min * 60 + dt.sec);
   if(curWeekMon > g_setupFWeekStart)
   {
      g_setupFWeekStart        = curWeekMon;
      g_setupFWeeklyTradeCount = 0;
   }
}

string SetupName(const SetupType s)
{
   switch(s)
   {
      case SETUP_LONDON_SWEEP:     return "LondonSweep(A)";
      case SETUP_ORDER_BLOCK:      return "OBRetest(B)";
      case SETUP_FVG_FILL:         return "FVGFill(C)";
      case SETUP_PIVOT_BOUNCE:     return "PivotBounce(D)";
      case SETUP_MSS_RETEST:       return "MSSRetest(E)";
      case SETUP_WEEKLY_PRECISION: return "WeeklySniper(F)";
      default:                     return "Unknown";
   }
}

//──────────────────────────────────────────────────────────────────────────────
// ManageOpenPosition – trailing stop + time exit + dynamic exit + partial + BE
//──────────────────────────────────────────────────────────────────────────────
void ManageOpenPosition(const string symbol)
{
   if(!PositionSelect(symbol)) return;

   long posType  = PositionGetInteger(POSITION_TYPE);
   int  dir      = (posType == POSITION_TYPE_BUY) ? STRAT_DIR_BUY : STRAT_DIR_SELL;
   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

   // Minimum hold time – suppress all soft exits until elapsed
   if(InpMinHoldSeconds > 0 && TimeCurrent() - openTime < (datetime)InpMinHoldSeconds)
      return;

   // ── Partial close (T1 / T2) ──────────────────────────────────────────────
   g_partial.Manage(symbol,
                    InpT1RR, InpT2RR, InpT1ClosePct, InpT2ClosePct,
                    InpUsePartialClose);
   if(!PositionSelect(symbol)) return;

   // ── Breakeven stop (RR-based trigger) ────────────────────────────────────
   if(InpUseBreakeven && !g_breakevenApplied && g_entrySlDist > 0.0)
   {
      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL  = PositionGetDouble(POSITION_SL);
      double currentTP  = PositionGetDouble(POSITION_TP);
      double onePip     = OnePipPrice(symbol);
      double beThreshold = g_entrySlDist * InpBreakevenAtRR;

      MqlTick tick;
      if(SymbolInfoTick(symbol, tick))
      {
         double profitMove = (dir == STRAT_DIR_BUY) ? tick.bid - openPrice
                                                     : openPrice - tick.ask;
         if(profitMove >= beThreshold)
         {
            double newSL    = (dir == STRAT_DIR_BUY) ? openPrice + onePip
                                                      : openPrice - onePip;
            bool   beNeeded = (dir == STRAT_DIR_BUY)
                              ? (newSL > currentSL)
                              : (currentSL == 0.0 || newSL < currentSL);
            if(beNeeded && g_exec.ModifyPosition(symbol, newSL, currentTP))
            {
               g_breakevenApplied = true;
               g_logger.LogDecision(symbol, false,
                  StringFormat("Breakeven | profit=%.5f>=%.5f newSL=%.5f",
                               profitMove, beThreshold, newSL));
            }
         }
      }
   }
   if(!PositionSelect(symbol)) return;

   // ── News window: tighten SL to breakeven for open positions ──────────────
   if(InpEnableNewsFilter && !g_breakevenApplied && g_news.IsNewsWindow(TimeCurrent()))
   {
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double onePip    = OnePipPrice(symbol);
      double newSL     = (dir == STRAT_DIR_BUY) ? openPrice + onePip : openPrice - onePip;
      bool   beNeeded  = (dir == STRAT_DIR_BUY) ? (newSL > currentSL)
                                                 : (currentSL == 0.0 || newSL < currentSL);
      if(beNeeded)
      {
         g_exec.ModifyPosition(symbol, newSL, currentTP);
         g_breakevenApplied = true;
         g_logger.LogDecision(symbol, false, "News window: SL moved to breakeven");
      }
   }
   if(!PositionSelect(symbol)) return;

   // ── Time-based exit ───────────────────────────────────────────────────────
   int barsSinceOpen = iBarShift(symbol, PERIOD_M1, openTime, true);
   int timeExitBars  = (g_openPositionSetup == SETUP_WEEKLY_PRECISION)
                       ? InpSetupFTimeExitBars : InpTimeExitBars;
   if(timeExitBars > 0 && barsSinceOpen >= timeExitBars)
   {
      g_logger.LogDecision(symbol, false,
         StringFormat("Time exit | bars=%d >= %d", barsSinceOpen, timeExitBars));
      g_exec.CloseSymbolPosition(symbol, g_logger);
      return;
   }
   if(!PositionSelect(symbol)) return;

   // ── Dynamic exit: H4 EMA flip against position (all setups except F) ─────
   // Only when in profit to protect winners; skip Setup F (fixed-TP trade).
   double posProfit = PositionGetDouble(POSITION_PROFIT);
   if(g_openPositionSetup != SETUP_WEEKLY_PRECISION && posProfit > 0.0)
   {
      StrategyParams exitP;
      exitP.h4EmaFast = InpH4EmaFast;
      exitP.h4EmaSlow = InpH4EmaSlow;
      if(g_scoring.ShouldExit(symbol, dir, exitP))
      {
         g_logger.LogDecision(symbol, false, "Dynamic exit: H4 EMA flipped");
         g_exec.CloseSymbolPosition(symbol, g_logger);
         return;
      }
   }
   if(!PositionSelect(symbol)) return;

   // ── R:R-aware trailing stop ───────────────────────────────────────────────
   double openPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL    = PositionGetDouble(POSITION_SL);
   double currentTP    = PositionGetDouble(POSITION_TP);
   double trailTrigger = g_entrySlDist * InpRRMin;
   double point        = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double trailingDist = (IsGold(symbol) ? InpTrailingDistancePips * 10.0
                                         : ForexPipsToPoints(symbol, InpTrailingDistancePips)) * point;

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return;

   if(dir == STRAT_DIR_BUY)
   {
      double profitMove = tick.bid - openPrice;
      if(g_entrySlDist > 0.0 && profitMove >= trailTrigger)
      {
         double newSL = tick.bid - trailingDist;
         if(newSL > currentSL) g_exec.ModifyPosition(symbol, newSL, currentTP);
      }
   }
   else
   {
      double profitMove = openPrice - tick.ask;
      if(g_entrySlDist > 0.0 && profitMove >= trailTrigger)
      {
         double newSL = tick.ask + trailingDist;
         if(currentSL == 0.0 || newSL < currentSL) g_exec.ModifyPosition(symbol, newSL, currentTP);
      }
   }
}

//──────────────────────────────────────────────────────────────────────────────
// TryEntry – evaluates signal and opens a position when all conditions pass
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
      g_logger.LogDecision(symbol, false, "News hard block");
      return;
   }

   // ── Adaptive mode: suspend lower-confidence setups after bad streak ───────
   double rollingWR = g_risk.RollingWinRatePct();
   bool   lowWR     = (InpAdaptiveMode && rollingWR < InpAdaptiveLowWinRate);
   if(lowWR)
      g_logger.LogDecision(symbol, false,
         StringFormat("Adaptive mode: WR %.0f%% < %.0f%% – only Setup F allowed",
                      rollingWR, InpAdaptiveLowWinRate));

   // ── Build StrategyParams ─────────────────────────────────────────────────
   double pipSize = OnePipPrice(symbol);

   StrategyParams p;
   // Shared
   p.h4EmaFast = InpH4EmaFast;
   p.h4EmaSlow = InpH4EmaSlow;
   // Stoch (Setup F)
   p.stochKPeriod    = InpStochK;
   p.stochDPeriod    = InpStochD;
   p.stochSlowing    = InpStochSlowing;
   p.stochOversold   = InpStochOversold;
   p.stochOverbought = InpStochOverbought;
   // Setup A
   p.setupAEnabled     = InpEnableSetupA && !lowWR;
   p.asianStartHour    = InpAsianStartHour;
   p.asianEndHour      = InpAsianEndHour;
   p.londonStartHour   = InpLondonStartHour;
   p.londonEndHour     = InpLondonEndHour;
   p.setupASweepBuf    = InpSetupASweepBufPips * pipSize;
   p.setupAMinRange    = InpSetupAMinRangePips  * pipSize;
   // Setup B
   p.setupBEnabled       = InpEnableSetupB && !lowWR;
   p.setupBH4Lookback    = InpSetupBH4Lookback;
   p.setupBImpulseFactor = InpSetupBImpulseFactor;
   p.setupBRetestPct     = InpSetupBRetestPct;
   p.setupBMaxAgeHours   = InpSetupBMaxAgeHours;
   // Setup C
   p.setupCEnabled     = InpEnableSetupC && !lowWR;
   p.setupCH1Lookback  = InpSetupCH1Lookback;
   p.setupCMinFVGSize  = InpSetupCMinFVGPips * pipSize;
   // Setup D
   p.setupDEnabled          = InpEnableSetupD && !lowWR;
   p.setupDPivotTolerance   = InpSetupDPivotTolPips * pipSize;
   // Setup E
   p.setupEEnabled       = InpEnableSetupE && !lowWR;
   p.setupESwingLookback = InpSetupESwingLookback;
   p.setupERetestBuffer  = InpSetupERetestBufPips * pipSize;
   // Setup F (always enabled if user turned it on)
   p.setupFEnabled          = InpEnableSetupF;
   p.setupFWeeklySweepBuf   = InpSetupFWeeklySweepBufPips * pipSize;
   p.setupFRequireH4Align   = InpSetupFRequireH4Align;
   p.setupFRequireM15Stoch  = InpSetupFRequireM15Stoch;

   // ── Signal evaluation ────────────────────────────────────────────────────
   EntryScoreBreakdown score;
   if(!g_scoring.Evaluate(symbol, p, score))
   {
      g_logger.LogDecision(symbol, false, "Signal evaluation failed");
      return;
   }

   // Log contribution for diagnostics
   g_logger.TrackContribution(
      score.setup == SETUP_LONDON_SWEEP,
      score.setup == SETUP_ORDER_BLOCK,
      score.setup == SETUP_FVG_FILL,
      score.setup == SETUP_PIVOT_BOUNCE,
      score.setup == SETUP_MSS_RETEST,
      score.setup == SETUP_WEEKLY_PRECISION);

   if(!score.valid)
   {
      g_logger.LogDecision(symbol, false, "No signal: " + score.details);
      return;
   }

   // ── Session window check ─────────────────────────────────────────────────
   if(!IsInSetupSessionWindow(score.setup))
   {
      g_logger.LogDecision(symbol, false,
         StringFormat("%s blocked: outside session window", SetupName(score.setup)));
      return;
   }

   // ── Setup F: weekly cap ──────────────────────────────────────────────────
   if(score.setup == SETUP_WEEKLY_PRECISION)
   {
      ResetSetupFWeeklyCounterIfNeeded();
      if(InpSetupFMaxWeeklyTrades > 0 &&
         g_setupFWeeklyTradeCount >= InpSetupFMaxWeeklyTrades)
      {
         g_logger.LogDecision(symbol, false,
            StringFormat("Setup F weekly cap %d/%d – waiting for next week",
                         g_setupFWeeklyTradeCount, InpSetupFMaxWeeklyTrades));
         return;
      }
   }

   // ── Spread and low-liquidity checks (all setups) ─────────────────────────
   int spreadPts = 0;
   if(!CheckSpreadOk(symbol, spreadPts))
   {
      g_logger.LogDecision(symbol, false,
         StringFormat("Spread %d pts > max – skipped", spreadPts));
      return;
   }

   if(InLowLiquidityWindow(TimeCurrent()))
   {
      g_logger.LogDecision(symbol, false, "Low-liquidity session block");
      return;
   }

   // ── Duplicate signal guard (M15 bar) ─────────────────────────────────────
   datetime signalBar = iTime(symbol, PERIOD_M15, 1);
   if(signalBar == g_lastEntrySignalBar)
   {
      g_logger.LogDecision(symbol, false, "Duplicate signal on same M15 bar blocked");
      return;
   }

   if(PositionExistsForSymbol(symbol))
   {
      g_logger.LogDecision(symbol, false, "Position already open");
      return;
   }

   // ── Price and distance helpers ────────────────────────────────────────────
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return;
   double point   = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double price   = (score.direction == STRAT_DIR_BUY) ? tick.ask : tick.bid;

   double slBufPts = IsGold(symbol)
                     ? (int)(InpSlBufferPips * 10.0)
                     : ForexPipsToPoints(symbol, InpSlBufferPips);
   double slBuf    = slBufPts * point;

   int    minSlPts = IsGold(symbol)
                     ? (int)InpGoldSlPoints
                     : ForexPipsToPoints(symbol, InpFallbackSlPips);
   double minSlDist = minSlPts * point;

   // ── SL Placement ──────────────────────────────────────────────────────────
   // Setup A/F: SL anchored to sweep wick with configurable buffer.
   // Setup B/C/D/E: SL from strategy core's suggestedSL ± buffer.
   // Setup F: uses its own buffer (InpSetupFSLBufferPips).
   double sl;

   if(score.setup == SETUP_WEEKLY_PRECISION)
   {
      double fBuf = InpSetupFSLBufferPips * pipSize;
      if(score.direction == STRAT_DIR_BUY && score.sweepWickLow > 0.0)
         sl = score.sweepWickLow - fBuf;
      else if(score.direction == STRAT_DIR_SELL && score.sweepWickHigh > 0.0)
         sl = score.sweepWickHigh + fBuf;
      else
         sl = (score.direction == STRAT_DIR_BUY) ? price - minSlDist : price + minSlDist;
   }
   else if(score.suggestedSL > 0.0)
   {
      // Use core's structural SL + buffer
      if(score.direction == STRAT_DIR_BUY)
         sl = score.suggestedSL - slBuf;
      else
         sl = score.suggestedSL + slBuf;
   }
   else
   {
      sl = (score.direction == STRAT_DIR_BUY) ? price - minSlDist : price + minSlDist;
   }

   // Enforce minimum SL distance
   double slDist = MathAbs(price - sl);
   if(slDist < minSlDist)
   {
      sl     = (score.direction == STRAT_DIR_BUY) ? price - minSlDist : price + minSlDist;
      slDist = minSlDist;
   }
   int slPoints = (int)MathRound(slDist / point);
   if(slPoints < 1) slPoints = 1;

   // ── TP Placement ──────────────────────────────────────────────────────────
   double tp;

   if(score.setup == SETUP_WEEKLY_PRECISION)
   {
      // Fixed pip-target gross of spread/commission → net equals InpSetupFPipTarget
      double grossTPDist = (InpSetupFPipTarget + InpSetupFSpreadCommPips) * pipSize;
      tp = (score.direction == STRAT_DIR_BUY) ? price + grossTPDist : price - grossTPDist;
   }
   else if(score.suggestedTP > 0.0)
   {
      // Use structural TP from the signal (e.g., opposite Asian range wall, pivot level)
      tp = score.suggestedTP;
      // Validate TP gives at least InpRRMin reward relative to our SL
      double tpDist = MathAbs(tp - price);
      if(tpDist < slDist * InpRRMin)
         tp = (score.direction == STRAT_DIR_BUY)
              ? price + slDist * InpRRMin
              : price - slDist * InpRRMin;
   }
   else
   {
      // Default: R:R-based TP
      tp = (score.direction == STRAT_DIR_BUY)
           ? price + slDist * InpRRMax
           : price - slDist * InpRRMax;
   }

   // ── Execute ───────────────────────────────────────────────────────────────
   g_orderInFlight = true;
   double lotSize = (score.setup == SETUP_WEEKLY_PRECISION)
                    ? ComputeSetupFLotSize(symbol, slPoints)
                    : ComputeLotSize(symbol, slPoints);

   bool opened = g_exec.Open(symbol, score.direction, lotSize,
                              InpMaxDeviationPoints, InpOrderRetries,
                              sl, tp, g_logger);
   g_orderInFlight = false;

   if(opened)
   {
      g_openPositionSetup  = (SetupType)score.setup;
      g_lastEntrySignalBar = signalBar;
      g_entryKeyLevel      = score.keyLevel;
      g_entrySlDist        = slDist;
      g_breakevenApplied   = false;
      g_risk.RegisterEntry(TimeCurrent());

      if(score.setup == SETUP_WEEKLY_PRECISION)
         g_setupFWeeklyTradeCount++;

      if(PositionSelect(symbol))
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         g_partial.OnNewPosition(ticket);
      }

      g_logger.LogDecision(symbol, true,
         StringFormat("ENTRY | setup=%s dir=%d sl=%.5f tp=%.5f lot=%.2f slPts=%d wr=%.0f%%",
                      SetupName(score.setup), score.direction,
                      sl, tp, lotSize, slPoints, rollingWR));
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
   g_news.Init(InpNewsWindowMinutes);
   g_partial.Init(InpMagicNumber);
   g_risk.UpdateSessionPeak(AccountInfoDouble(ACCOUNT_EQUITY));

   if(!IsAllowedSymbol(_Symbol))
   {
      g_logger.Log("Symbol not in allowed list – EA not starting");
      return INIT_FAILED;
   }

   g_logger.Log(StringFormat(
      "WeChuck EA v4.00 | "
      "A(LondonSweep)=%s B(OBRetest)=%s C(FVGFill)=%s "
      "D(PivotBounce)=%s E(MSSRetest)=%s "
      "F(WeeklySniper)=%s(pip=%d,risk=%.0f%%,maxWkly=%d) | "
      "news=%s adaptiveMode=%s h4EMA=%d/%d",
      InpEnableSetupA ? "ON" : "OFF",
      InpEnableSetupB ? "ON" : "OFF",
      InpEnableSetupC ? "ON" : "OFF",
      InpEnableSetupD ? "ON" : "OFF",
      InpEnableSetupE ? "ON" : "OFF",
      InpEnableSetupF ? "ON" : "OFF",
      InpSetupFPipTarget, InpSetupFRiskPct, InpSetupFMaxWeeklyTrades,
      InpEnableNewsFilter ? "ON" : "OFF",
      InpAdaptiveMode     ? "ON" : "OFF",
      InpH4EmaFast, InpH4EmaSlow));

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   g_logger.DumpStats();
}

void OnTick()
{
   if(!IsAllowedSymbol(_Symbol)) return;

   g_risk.UpdateSessionPeak(AccountInfoDouble(ACCOUNT_EQUITY));

   bool posOpen = PositionExistsForSymbol(_Symbol);

   // Detect position close → record win/loss for rolling WR
   if(g_prevPositionOpen && !posOpen)
   {
      bool wasWin = (g_prevPositionProfit > 0.50);
      g_risk.RecordTradeOutcome(wasWin);
      g_partial.OnPositionClosed();
      g_entryKeyLevel    = 0.0;
      g_entrySlDist      = 0.0;
      g_breakevenApplied = false;
   }
   g_prevPositionOpen = posOpen;
   if(posOpen)
      g_prevPositionProfit = PositionGetDouble(POSITION_PROFIT);

   if(!posOpen)
      g_openPositionSetup = SETUP_NONE;

   ManageOpenPosition(_Symbol);

   if(!NewM1Bar(_Symbol)) return;

   g_risk.CheckDailyReset(TimeCurrent());
   ResetSetupFWeeklyCounterIfNeeded();

   TryEntry(_Symbol);
}

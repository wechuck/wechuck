#property strict
#property version   "2.00"
#property description "WeChuck EA – Multi-Timeframe Exhaustion & Range Scalp Strategy"

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
input double InpRsiOversold          = 30.0;   // Setup A BUY: RSI must be below this
input double InpRsiOverbought        = 70.0;   // Setup A SELL: RSI must be above this

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
input double InpForexSlPips         = 8.0;
input int    InpGoldSlPoints        = 150;
input double InpRiskReward          = 1.3;   // Used for Setup A TP (Setup B TP = opposite box side)
input int    InpTimeExitBars        = 15;
input double InpTrailingStartPips   = 5.0;
input double InpTrailingDistancePips = 3.0;

input group "Execution"
input int InpMaxDeviationPoints = 10;
input int InpOrderRetries       = 3;

//──────────────────────────────────────────────────────────────────────────────
// Globals
//──────────────────────────────────────────────────────────────────────────────
CDiagnosticsLogger     g_logger;
CMarketStructureFilter g_bias;
CEntryScoring          g_scoring;
CRiskManager           g_risk;
CExecutionManager      g_exec;

datetime g_lastM1BarTime      = 0;
datetime g_lastEntrySignalBar = 0;
bool     g_orderInFlight      = false;

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

double ComputeLotSize(const string symbol)
{
   if(!InpUseDynamicLot) return InpFixedLot;
   double equity       = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskPct      = GetScaledRiskPct(equity);
   double riskAmount   = equity * riskPct / 100.0;
   double point        = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tickSize     = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue    = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   int    slPoints     = IsGold(symbol) ? InpGoldSlPoints : ForexPipsToPoints(symbol, InpForexSlPips);
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

   // Time-based exit
   datetime openTime    = (datetime)PositionGetInteger(POSITION_TIME);
   int      barsSinceOpen = iBarShift(symbol, PERIOD_M1, openTime, true);
   if(barsSinceOpen >= InpTimeExitBars && InpTimeExitBars > 0)
   {
      g_logger.LogDecision(symbol, false, "Time-based exit");
      g_exec.CloseSymbolPosition(symbol, g_logger);
      return;
   }

   // Dynamic exit (only when in profit – protect winners)
   double posProfit = PositionGetDouble(POSITION_PROFIT);
   if(posProfit > 0.0 &&
      g_scoring.ShouldExitByDynamics(symbol, dir,
                                     InpAdxPeriod, InpAdxExitWeakThreshold,
                                     InpStochK, InpStochD, InpStochSlowing,
                                     InpStochOversold, InpStochOverbought))
   {
      g_logger.LogDecision(symbol, false, "Dynamic exit condition");
      g_exec.CloseSymbolPosition(symbol, g_logger);
      return;
   }

   // Trailing stop
   double point        = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double trailingStart = (IsGold(symbol) ? InpTrailingStartPips * 10.0
                                          : ForexPipsToPoints(symbol, InpTrailingStartPips)) * point;
   double trailingDist  = (IsGold(symbol) ? InpTrailingDistancePips * 10.0
                                          : ForexPipsToPoints(symbol, InpTrailingDistancePips)) * point;

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return;

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);

   if(dir == STRAT_DIR_BUY)
   {
      double profitMove = tick.bid - openPrice;
      if(profitMove >= trailingStart)
      {
         double newSL = tick.bid - trailingDist;
         if(newSL > currentSL)
            g_exec.ModifyPosition(symbol, newSL, currentTP);
      }
   }
   else
   {
      double profitMove = openPrice - tick.ask;
      if(profitMove >= trailingStart)
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

   // ── Pre-conditions ────────────────────────────────────────────────────────
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

   // ── Optional M15 bias alignment ──────────────────────────────────────────
   BiasResult bias;
   if(InpRequireM15Alignment)
   {
      if(!g_bias.Evaluate(symbol, InpEmaFast, InpEmaSlow, InpStructureLookback, bias))
      {
         g_logger.LogDecision(symbol, false, "M15 bias evaluation failed");
         return;
      }
   }

   // ── Strategy signal evaluation ────────────────────────────────────────────
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
                           score))
   {
      g_logger.LogDecision(symbol, false, "Signal evaluation failed");
      return;
   }

   g_logger.LogScore(symbol, (int)score.setup, score.direction,
                     score.adx1M, score.adx5M, score.stochK, score.rsiCur,
                     score.details);

   g_logger.TrackContribution(score.setup == SETUP_RUBBER_BAND,
                               score.setup == SETUP_RANGE_SCALP);

   if(!score.valid)
   {
      g_logger.LogDecision(symbol, false, "No valid signal: " + score.details);
      return;
   }

   // ── Optional M15 direction alignment check ────────────────────────────────
   if(InpRequireM15Alignment && bias.direction != DIR_NONE)
   {
      int biasDir = (bias.direction == DIR_BUY) ? STRAT_DIR_BUY : STRAT_DIR_SELL;
      if(biasDir != score.direction)
      {
         g_logger.LogDecision(symbol, false, "Signal direction conflicts with M15 bias");
         return;
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
   int    slPoints = IsGold(symbol) ? InpGoldSlPoints : ForexPipsToPoints(symbol, InpForexSlPips);
   double price   = (score.direction == STRAT_DIR_BUY) ? tick.ask : tick.bid;
   double sl      = (score.direction == STRAT_DIR_BUY)
                    ? price - slPoints * point
                    : price + slPoints * point;

   // Setup B TP = opposite side of the 5M structural box.
   // Setup A TP = fixed risk-to-reward ratio from the SL distance.
   double tp;
   if(score.setup == SETUP_RANGE_SCALP &&
      score.boxHigh > 0.0 && score.boxLow > 0.0)
   {
      tp = (score.direction == STRAT_DIR_BUY) ? score.boxHigh : score.boxLow;
   }
   else
   {
      double tpDistancePoints = slPoints * InpRiskReward;
      tp = (score.direction == STRAT_DIR_BUY)
           ? price + tpDistancePoints * point
           : price - tpDistancePoints * point;
   }

   // ── Execute ───────────────────────────────────────────────────────────────
   g_orderInFlight = true;
   double lotSize = ComputeLotSize(symbol);
   bool   opened  = g_exec.Open(symbol, score.direction, lotSize,
                                InpMaxDeviationPoints, InpOrderRetries,
                                sl, tp, g_logger);
   g_orderInFlight = false;

   if(opened)
   {
      g_lastEntrySignalBar = signalBar;
      g_risk.RegisterEntry(TimeCurrent());
      g_logger.LogDecision(symbol, true,
                           StringFormat("Entry executed | setup=%s dir=%d",
                                        score.setup == SETUP_RUBBER_BAND
                                           ? "RubberBand" : "RangeScalp",
                                        score.direction));
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

   g_logger.Log("EA initialized (v2.00 – Exhaustion & Range Scalp Strategy)");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   g_logger.DumpStats();
}

void OnTick()
{
   if(!IsAllowedSymbol(_Symbol)) return;

   ManageOpenPosition(_Symbol);

   if(!NewM1Bar(_Symbol)) return;
   TryEntry(_Symbol);
}

//+------------------------------------------------------------------+
//|                        RegimeAdaptiveEA.mq5                      |
//|   Final Refined 10/10 Regime-Adaptive Ensemble Meta-Filter EA    |
//|   Copyright 2026, Trading Pro                                    |
//|   V1.0 – Strict Regime-First Architecture                        |
//+------------------------------------------------------------------+
//
// FOUNDATION RULE:
//   Signal generation, signal approval, risk permission, and execution
//   are separate layers. Meta-labeling works best when raw setups are
//   filtered by context before action is taken.
//
// MASTER DECISION PRINCIPLE (4 questions, answered in order):
//   Q1: What regime is active?
//   Q2: Which engines are allowed?
//   Q3: Which candidates survive hard filters?
//   Q4: Which one valid candidate is best?
//
// 17-STEP DECISION FLOW:
//   STEP  1 – Exclusive Regime Engine   (TREND / RANGE / TRANSITION / CHAOS)
//   STEP  2 – Regime Confidence Threshold  (below min → force NO TRADE)
//   STEP  3 – Engine Activation by Regime  (only allowed engines fire)
//   STEP  4 – Transition Regime Safety     (stricter rules in TRANSITION)
//   STEP  5 – Candidate Generation         (structured output, no direct trade)
//   STEP  6 – Hard Filters                 (absolute rejection, no exceptions)
//   STEP  7 – Late Entry Protection        (distance from signal origin price)
//   STEP  8 – Retry with Full Revalidation (all hard rules re-checked each retry)
//   STEP  9 – Bounded Execution Window     (max lifetime per candidate)
//   STEP 10 – Soft Scoring (survivors only)
//   STEP 11 – Score Normalization          (same scale before weighting)
//   STEP 12 – Deterministic Ranking        (fixed tie-break order, no random)
//   STEP 13 – Directional Conflict Rule    (BUY vs SELL explicit resolution)
//   STEP 14 – Risk Engine Final Authority  (score decides quality; risk decides permission)
//   STEP 15 – Engine Shutdown Rule         (failure threshold → temporary disable)
//   STEP 16 – Engine Recovery Rule         (explicit, deterministic, gradual)
//   STEP 17 – Structured Module Output     (allowed/direction/score/veto/tag)
//+------------------------------------------------------------------+

#property copyright "Copyright 2026, Trading Pro"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| COMPILE-TIME CONSTANT                                            |
//+------------------------------------------------------------------+
#define REGIME_EA_ENGINE_COUNT 3

//+------------------------------------------------------------------+
//| ENUMERATIONS                                                     |
//+------------------------------------------------------------------+

enum ENUM_MKT_REGIME
{
   MKT_TREND      = 0,  // Strong directional move, ADX dominant
   MKT_RANGE      = 1,  // Price oscillating inside defined band
   MKT_TRANSITION = 2,  // Regime is shifting — increased false-signal risk
   MKT_CHAOS      = 3   // ATR spike / news event / undefined — stand down
};

enum ENUM_RA_ENGINE
{
   ENG_TREND_MOMENTUM = 0,  // EMA crossover + ADX — active in TREND only
   ENG_MEAN_REVERSION = 1,  // BB touch + RSI extreme — active in RANGE only
   ENG_TREND_BREAKOUT = 2   // BB breakout + structure — TREND or TRANSITION (strict)
};

//+------------------------------------------------------------------+
//| STEP 17: STRUCTURED CANDIDATE OUTPUT                             |
//| Each engine returns this struct. The rest of the framework       |
//| evaluates, filters, ranks, and executes from it consistently.    |
//+------------------------------------------------------------------+
struct TradeCandidate
{
   bool          allowed;               // True = engine produced a usable candidate
   int           direction;             // +1=BUY, -1=SELL, 0=none
   ENUM_RA_ENGINE engine_id;            // Which engine generated this candidate
   string        engine_name;           // Human-readable label
   datetime      signal_time;           // Server time when the signal was detected
   double        signal_origin_price;   // Ask (BUY) or Bid (SELL) at signal moment
   string        hard_veto_reason;      // Empty if no veto; filled on any hard rejection
   double        strength_0_100;        // Raw unnormalized signal strength
   double        confidence_0_1;        // Setup confidence: 0=none, 1=maximum
   string        context_tag;           // e.g. "TREND_BUY_EMA", "RANGE_SELL_BB"
   double        score_normalized;      // Final weighted score after normalization (0–100)
   datetime      retry_deadline;        // Step 9: candidate permanently discarded after this
   int           retry_count;           // Number of retry ticks used so far
};

//+------------------------------------------------------------------+
//| STEPS 15-16: ENGINE HEALTH TRACKER                               |
//+------------------------------------------------------------------+
struct EngineHealth
{
   int      consecutive_losses;      // Current unbroken loss streak
   int      rolling_trades;          // Trades counted in the current rolling window
   int      rolling_losses;          // Losses in the current rolling window
   bool     is_shutdown;             // True = engine is temporarily disabled
   datetime shutdown_until;          // Time-based recovery: engine re-enabled after this
   int      bars_since_shutdown;     // Bar count elapsed since last shutdown
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+

input group "=== STEP 1-2: REGIME ENGINE ==="
input double   InpMinRegimeConfidence  = 0.60;  // Min confidence to trade (below = NO TRADE)
input int      InpADXPeriod            = 14;    // ADX period
input int      InpBBPeriod             = 20;    // Bollinger Band period
input double   InpBBDeviation          = 2.0;   // BB standard deviation multiplier
input int      InpATRPeriod            = 14;    // ATR period
input double   InpChaosATRMult         = 3.0;   // ATR > N×average = CHAOS
input double   InpTrendADXMin          = 25.0;  // ADX above this = TREND
input double   InpRangeADXMax          = 20.0;  // ADX below this = RANGE

input group "=== STEP 3: ENGINE SWITCHES ==="
input bool     InpUseTrendMomentum     = true;  // Enable Trend+Momentum engine (TREND regime)
input bool     InpUseMeanReversion     = true;  // Enable Mean Reversion engine (RANGE regime)
input bool     InpUseTrendBreakout     = true;  // Enable Trend+Breakout engine (TREND/TRANSITION)

input group "=== MEAN REVERSION SETTINGS (RANGE) ==="
input int      InpRSIPeriod            = 14;    // RSI period
input double   InpRSIOversold          = 35.0;  // RSI below this → BUY candidate
input double   InpRSIOverbought        = 65.0;  // RSI above this → SELL candidate

input group "=== TREND MOMENTUM SETTINGS (TREND) ==="
input int      InpFastEMAPeriod        = 21;    // Fast EMA period
input int      InpSlowEMAPeriod        = 50;    // Slow EMA period

input group "=== HTF MACRO FILTER ==="
input ENUM_TIMEFRAMES InpHTF           = PERIOD_H4; // Higher timeframe for directional bias
input int      InpHTF_FastEMA          = 50;    // HTF fast EMA
input int      InpHTF_SlowEMA          = 200;   // HTF slow EMA

input group "=== STEP 6: HARD FILTERS ==="
input int      InpMaxSpread            = 45;    // Max spread in points
input int      InpMaxSlippage          = 30;    // Max slippage in points
input int      InpSessionStart         = 1;     // Session start hour (server time)
input int      InpSessionEnd           = 22;    // Session end hour (server time)
input bool     InpUseFridayClose       = true;  // Auto-close all on Friday evening
input int      InpFridayCloseHour      = 21;    // Friday closing hour
input int      InpMondayOpenHour       = 1;     // Monday resume hour
input int      InpMaxDailyTrades       = 10;    // Hard daily trade cap

input group "=== STEP 7: LATE ENTRY PROTECTION ==="
input double   InpMaxChaseATR          = 0.50;  // Reject if price moved > N×ATR from origin

input group "=== STEP 8-9: RETRY + BOUNDED WINDOW ==="
input int      InpMaxRetryBars         = 4;     // Candidate expires after this many bars
input int      InpMaxRetryTicks        = 30;    // Max retry attempts per candidate

input group "=== STEP 11: SCORING WEIGHTS ==="
input double   InpWtTrigger            = 0.30;  // Trigger quality weight
input double   InpWtMomentum           = 0.25;  // Momentum strength weight
input double   InpWtTiming             = 0.25;  // Timing quality weight
input double   InpWtConfirmation       = 0.20;  // Confirmation quality weight
input double   InpMinScore             = 45.0;  // Minimum final score (0–100) to execute

input group "=== STEP 13: DIRECTIONAL CONFLICT ==="
input bool     InpHTFBiasBreaksTie     = true;  // HTF bias resolves BUY/SELL conflict (false = score only)

input group "=== STEP 14: RISK ENGINE ==="
input double   InpRiskPct              = 2.0;   // Base risk % per trade
input double   InpMaxDailyLossPct      = 5.0;   // Halt if daily balance loss exceeds this %
input double   InpMaxPeakDDPct         = 15.0;  // Halt if balance drops this % from peak
input int      InpDDHaltHours          = 12;    // Hours to halt after peak DD breach
input double   InpMaxEquityDDPct       = 10.0;  // Force-close open trades if equity drops this %
input bool     InpUseLossScaler        = true;  // Reduce risk after consecutive losses
input int      InpMagic                = 9901;  // EA magic number

input group "=== STOP / TARGET / TRAIL ==="
input double   InpSLPips               = 80.0;  // Stop loss in pips
input double   InpTPPips               = 200.0; // Take profit in pips
input double   InpBETriggerPips        = 40.0;  // Breakeven trigger in pips
input double   InpBELockPips           = 10.0;  // Pips to lock at breakeven
input double   InpTrailDistPips        = 60.0;  // Trailing stop distance in pips
input double   InpTrailStepPips        = 15.0;  // Trailing stop minimum step
input double   InpPipMult              = 10.0;  // Points per pip (10 = Gold / 5-digit forex)

input group "=== STEP 15-16: ENGINE HEALTH ==="
input int      InpShutdownLosses       = 3;     // Consecutive losses to shut engine down
input int      InpRecoveryBars         = 50;    // Bars before engine may recover
input int      InpRollingWindow        = 20;    // Rolling window size for loss-rate check
input double   InpMaxRollingLossRate   = 0.60;  // Loss rate above this shuts engine down

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+

CTrade trade;

// Indicator handles
int hBB, hRSI, hADX, hATR, hFastEMA, hSlowEMA, hHTFast, hHTSlow;

// Lot / volume constants
double g_StepVol, g_MinVol, g_MaxVol, g_PipMult;

// Step 8-9: One retry candidate slot per engine
TradeCandidate g_Candidates[REGIME_EA_ENGINE_COUNT];

// Steps 15-16: Health record per engine
EngineHealth g_Health[REGIME_EA_ENGINE_COUNT];

// Step 14: Risk / protection state
double   g_PeakBalance;
double   g_DayOpenBalance;
datetime g_DayOpenTime;
datetime g_DDHaltUntil;
double   g_PeakEquity;
datetime g_EquityHaltUntil;
int      g_ConsecLosses;

// Diagnostics (logged via Print on regime change)
ENUM_MKT_REGIME g_LastLoggedRegime;
double          g_LastLoggedConf;

// Bar tracking for Step 16
datetime g_LastBarTime;

// Closed-deal scan state
datetime g_LastDealScan;

//+------------------------------------------------------------------+
//| FORWARD DECLARATIONS                                             |
//+------------------------------------------------------------------+
void   ClassifyRegime(ENUM_MKT_REGIME &regime, double &confidence);
void   GenerateTrendMomentum(TradeCandidate &c, double Ask, double Bid);
void   GenerateMeanReversion(TradeCandidate &c, double Ask, double Bid);
void   GenerateTrendBreakout(TradeCandidate &c, double Ask, double Bid, ENUM_MKT_REGIME regime);
void   ApplyHardFilters(TradeCandidate &c, double Ask, double Bid, double spread, ENUM_MKT_REGIME regime);
bool   IsLateEntryOK(double direction, double originPrice);
void   NormalizeAndScore(TradeCandidate &c);
bool   SelectWinner(TradeCandidate &arr[], ENUM_MKT_REGIME regime, TradeCandidate &winner);
bool   RiskEngineApprove(TradeCandidate &c, double Ask, double Bid, double spread, double &lot);
void   ExecuteTrade(TradeCandidate &c, double lot, double Ask, double Bid);
void   StoreRetryCandidate(TradeCandidate &c);
bool   ProcessRetryCandidates(double Ask, double Bid, double spread, ENUM_MKT_REGIME regime, double conf);
void   ManageExits();
void   CheckFridayClose();
void   CheckEquityGuard();
bool   IsEquityGuardTriggered();
bool   IsDrawdownHalted();
bool   IsSessionTime();
bool   IsWeekendBlocked();
bool   IsDailyLimitReached();
bool   IsEngineShutdown(ENUM_RA_ENGINE id);
void   ShutdownEngine(ENUM_RA_ENGINE id, string reason);
void   RecoverEngine(ENUM_RA_ENGINE id, string reason);
void   UpdateBarCounter();
void   ScanClosedDeals();
void   UpdateEngineHealth(ENUM_RA_ENGINE id, bool isLoss);
double GetRiskScaler();
void   ResetCandidate(TradeCandidate &c);
string EngineName(ENUM_RA_ENGINE id);

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpMaxSlippage);
   trade.SetTypeFilling(SYMBOL_FILLING_IOC);

   g_StepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_MinVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_MaxVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_PipMult = InpPipMult;

   // Indicator handles
   hBB      = iBands(_Symbol, _Period, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
   hADX     = iADX(_Symbol, _Period, InpADXPeriod);
   hATR     = iATR(_Symbol, _Period, InpATRPeriod);
   hFastEMA = iMA(_Symbol, _Period, InpFastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol, _Period, InpSlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hHTFast  = iMA(_Symbol, InpHTF, InpHTF_FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hHTSlow  = iMA(_Symbol, InpHTF, InpHTF_SlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(hBB == INVALID_HANDLE || hRSI == INVALID_HANDLE || hADX == INVALID_HANDLE ||
      hATR == INVALID_HANDLE || hFastEMA == INVALID_HANDLE || hSlowEMA == INVALID_HANDLE ||
      hHTFast == INVALID_HANDLE || hHTSlow == INVALID_HANDLE)
   {
      Print("RegimeAdaptiveEA: Indicator init failed – EA will not start.");
      return INIT_FAILED;
   }

   // Reset candidate slots
   for(int i = 0; i < REGIME_EA_ENGINE_COUNT; i++)
      ResetCandidate(g_Candidates[i]);

   // Reset engine health
   for(int i = 0; i < REGIME_EA_ENGINE_COUNT; i++)
   {
      g_Health[i].consecutive_losses  = 0;
      g_Health[i].rolling_trades      = 0;
      g_Health[i].rolling_losses      = 0;
      g_Health[i].is_shutdown         = false;
      g_Health[i].shutdown_until      = 0;
      g_Health[i].bars_since_shutdown = 0;
   }

   // Risk state
   g_PeakBalance     = AccountInfoDouble(ACCOUNT_BALANCE);
   g_DayOpenBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
   g_DayOpenTime     = 0;
   g_DDHaltUntil     = 0;
   g_PeakEquity      = AccountInfoDouble(ACCOUNT_EQUITY);
   g_EquityHaltUntil = 0;
   g_ConsecLosses    = 0;

   g_LastLoggedRegime = MKT_CHAOS;
   g_LastLoggedConf   = 0.0;
   g_LastBarTime      = 0;
   g_LastDealScan     = 0;

   Print("RegimeAdaptiveEA V1.0 initialized. Symbol=", _Symbol,
         " TF=", EnumToString(_Period), " HTF=", EnumToString(InpHTF));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hBB);
   IndicatorRelease(hRSI);
   IndicatorRelease(hADX);
   IndicatorRelease(hATR);
   IndicatorRelease(hFastEMA);
   IndicatorRelease(hSlowEMA);
   IndicatorRelease(hHTFast);
   IndicatorRelease(hHTSlow);
}

//+------------------------------------------------------------------+
//| OnTick — MASTER DECISION FLOW (all 17 steps)                     |
//+------------------------------------------------------------------+
void OnTick()
{
   // Tracking: new-bar detection drives engine recovery (Step 16)
   UpdateBarCounter();

   // Position management always runs — exits are never blocked
   ManageExits();
   CheckFridayClose();

   // ── Entry guards (block new trades, exits already run above) ─────
   if(IsEquityGuardTriggered()) return;
   if(IsDrawdownHalted())       return;
   if(IsWeekendBlocked())       return;
   if(!IsSessionTime())         return;
   if(IsDailyLimitReached())    return;
   if(PositionsTotal() > 0)     return;   // one position at a time

   double Ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double Bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = (Ask - Bid) / _Point;

   // ── STEPS 1 + 2: Classify regime; enforce confidence threshold ────
   ENUM_MKT_REGIME regime;
   double          conf;
   ClassifyRegime(regime, conf);

   // Log regime changes for transparency
   if(regime != g_LastLoggedRegime || MathAbs(conf - g_LastLoggedConf) > 0.10)
   {
      PrintFormat("RegimeAdaptiveEA: Regime=%s  Conf=%.2f",
                  EnumToString(regime), conf);
      g_LastLoggedRegime = regime;
      g_LastLoggedConf   = conf;
   }

   // STEP 2: confidence below threshold → NO TRADE
   if(conf < InpMinRegimeConfidence) return;

   // CHAOS always means stand down
   if(regime == MKT_CHAOS) return;

   // ── STEP 8-9: Retry existing candidates first ─────────────────────
   if(ProcessRetryCandidates(Ask, Bid, spread, regime, conf)) return;
   if(PositionsTotal() > 0) return;

   // ── STEPS 3 + 4: Activate only regime-appropriate engines ─────────
   bool useTM = InpUseTrendMomentum &&
                (regime == MKT_TREND) &&
                !IsEngineShutdown(ENG_TREND_MOMENTUM);

   bool useMR = InpUseMeanReversion &&
                (regime == MKT_RANGE) &&
                !IsEngineShutdown(ENG_MEAN_REVERSION);

   // Step 4: Breakout runs in TREND or TRANSITION, but TRANSITION adds stricter rules
   bool useTB = InpUseTrendBreakout &&
                (regime == MKT_TREND || regime == MKT_TRANSITION) &&
                !IsEngineShutdown(ENG_TREND_BREAKOUT);

   // Step 3: Mean Reversion is hard-blocked in a strong trend — no override
   if(regime == MKT_TREND) useMR = false;

   // ── STEP 5: Generate candidates from active engines ────────────────
   TradeCandidate cands[REGIME_EA_ENGINE_COUNT];
   for(int i = 0; i < REGIME_EA_ENGINE_COUNT; i++)
      ResetCandidate(cands[i]);

   if(useTM) GenerateTrendMomentum(cands[ENG_TREND_MOMENTUM], Ask, Bid);
   if(useMR) GenerateMeanReversion(cands[ENG_MEAN_REVERSION], Ask, Bid);
   if(useTB) GenerateTrendBreakout(cands[ENG_TREND_BREAKOUT], Ask, Bid, regime);

   // ── STEP 6: Hard filters — absolute rejection, no exceptions ──────
   for(int i = 0; i < REGIME_EA_ENGINE_COUNT; i++)
   {
      if(cands[i].allowed)
         ApplyHardFilters(cands[i], Ask, Bid, spread, regime);
   }

   // ── STEPS 10-13: Score, rank, resolve conflict, pick winner ───────
   TradeCandidate winner;
   ResetCandidate(winner);
   if(!SelectWinner(cands, regime, winner)) return;

   // ── STEP 14: Risk engine — final authority ─────────────────────────
   double lot = 0.0;
   if(!RiskEngineApprove(winner, Ask, Bid, spread, lot))
   {
      // Temporary block (spread/margin) → store for retry
      if(winner.allowed)
         StoreRetryCandidate(winner);
      return;
   }

   // ── EXECUTE ────────────────────────────────────────────────────────
   ExecuteTrade(winner, lot, Ask, Bid);
}

//+------------------------------------------------------------------+
//| STEP 1: EXCLUSIVE REGIME CLASSIFICATION ENGINE                   |
//| Mutually exclusive, priority-ordered, deterministic.             |
//| Same inputs always produce the same regime label.                |
//+------------------------------------------------------------------+
void ClassifyRegime(ENUM_MKT_REGIME &regime, double &confidence)
{
   regime     = MKT_CHAOS;
   confidence = 0.0;

   const int NEEDED = 10;
   double adxMain[], adxPlus[], adxMinus[];
   double bbU[], bbM[], bbL[];
   double atr[];
   ArraySetAsSeries(adxMain, true); ArraySetAsSeries(adxPlus, true); ArraySetAsSeries(adxMinus, true);
   ArraySetAsSeries(bbU, true);     ArraySetAsSeries(bbM, true);     ArraySetAsSeries(bbL, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(hADX, 0, 0, NEEDED, adxMain)  < NEEDED) return;
   if(CopyBuffer(hADX, 1, 0, NEEDED, adxPlus)  < NEEDED) return;
   if(CopyBuffer(hADX, 2, 0, NEEDED, adxMinus) < NEEDED) return;
   if(CopyBuffer(hBB,  1, 0, NEEDED, bbU)      < NEEDED) return;
   if(CopyBuffer(hBB,  0, 0, NEEDED, bbM)      < NEEDED) return;
   if(CopyBuffer(hBB,  2, 0, NEEDED, bbL)      < NEEDED) return;
   if(CopyBuffer(hATR, 0, 0, NEEDED, atr)      < NEEDED) return;

   double adx     = adxMain[1];
   double adxPrev = adxMain[2];
   double plus    = adxPlus[1];
   double minus   = adxMinus[1];
   double curATR  = atr[1];

   // Average ATR over look-back window (skip bar[0] — forming)
   double avgATR = 0;
   for(int i = 1; i < NEEDED; i++) avgATR += atr[i];
   avgATR /= (NEEDED - 1.0);

   // Average BB width
   double bbWidthAvg = 0;
   for(int i = 1; i < NEEDED; i++) bbWidthAvg += (bbU[i] - bbL[i]);
   bbWidthAvg /= (NEEDED - 1.0);
   double bbWidthRatio = (bbWidthAvg > 0) ? (bbU[1] - bbL[1]) / bbWidthAvg : 1.0;

   // ── PRIORITY 1: CHAOS ─────────────────────────────────────────────
   // ATR spike: current bar's range far exceeds the recent average
   if(curATR > avgATR * InpChaosATRMult)
   {
      regime     = MKT_CHAOS;
      confidence = MathMin(1.0, curATR / (avgATR * InpChaosATRMult));
      return;
   }

   // ── PRIORITY 2: TREND ─────────────────────────────────────────────
   // ADX clearly above trend threshold
   if(adx > InpTrendADXMin)
   {
      double diDiff = MathAbs(plus - minus);
      double conf   = 0.0;
      conf += MathMin(0.50, (adx - InpTrendADXMin) / 20.0 * 0.50); // ADX above threshold
      conf += MathMin(0.30, diDiff / 20.0 * 0.30);                  // DI separation clarity
      conf += (adx > adxPrev) ? 0.20 : 0.0;                         // ADX still rising
      regime     = MKT_TREND;
      confidence = MathMin(1.0, conf);
      return;
   }

   // ── PRIORITY 3: RANGE ─────────────────────────────────────────────
   // ADX clearly below range threshold
   if(adx < InpRangeADXMax)
   {
      double conf = 0.0;
      conf += MathMin(0.40, (InpRangeADXMax - adx) / 15.0 * 0.40);    // How far below threshold
      conf += MathMin(0.30, (1.0 / MathMax(0.1, bbWidthRatio)) * 0.30);// Narrow BB = tighter range
      conf += (adx < adxPrev) ? 0.30 : 0.0;                            // ADX still falling
      regime     = MKT_RANGE;
      confidence = MathMin(1.0, conf);
      return;
   }

   // ── PRIORITY 4: TRANSITION ────────────────────────────────────────
   // ADX in the grey zone between RangeADXMax and TrendADXMin
   {
      double span          = InpTrendADXMin - InpRangeADXMax;
      double mid           = (InpTrendADXMin + InpRangeADXMax) / 2.0;
      double distFromCentre= MathAbs(adx - mid);
      double conf          = 0.40 + 0.25 * (distFromCentre / (span / 2.0));
      conf += (adx > adxPrev) ? 0.10 : 0.05;   // rising → edging toward TREND
      conf  = MathMin(0.80, conf);              // capped: TRANSITION is inherently uncertain
      regime     = MKT_TRANSITION;
      confidence = conf;
   }
}

//+------------------------------------------------------------------+
//| STEP 5: TREND MOMENTUM ENGINE — active in TREND regime only      |
//| EMA crossover + ADX momentum + HTF directional alignment         |
//+------------------------------------------------------------------+
void GenerateTrendMomentum(TradeCandidate &c, double Ask, double Bid)
{
   c.engine_id   = ENG_TREND_MOMENTUM;
   c.engine_name = "TrendMomentum";

   double fEMA[], sEMA[], adxM[], adxP[], adxN[], atr[];
   double htfF[], htfS[];
   ArraySetAsSeries(fEMA, true); ArraySetAsSeries(sEMA, true);
   ArraySetAsSeries(adxM, true); ArraySetAsSeries(adxP, true); ArraySetAsSeries(adxN, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(htfF, true); ArraySetAsSeries(htfS, true);

   if(CopyBuffer(hFastEMA, 0, 0, 3, fEMA) < 3) return;
   if(CopyBuffer(hSlowEMA, 0, 0, 3, sEMA) < 3) return;
   if(CopyBuffer(hADX, 0, 0, 3, adxM)    < 3) return;
   if(CopyBuffer(hADX, 1, 0, 3, adxP)    < 3) return;
   if(CopyBuffer(hADX, 2, 0, 3, adxN)    < 3) return;
   if(CopyBuffer(hATR, 0, 0, 2, atr)     < 2) return;
   if(CopyBuffer(hHTFast, 0, 0, 2, htfF) < 2) return;
   if(CopyBuffer(hHTSlow, 0, 0, 2, htfS) < 2) return;

   double adx      = adxM[1];
   double plus     = adxP[1];
   double minus    = adxN[1];
   bool   rising   = (adxM[1] > adxM[2]);
   bool   htfBull  = (htfF[1] > htfS[1]);
   bool   htfBear  = (htfF[1] < htfS[1]);

   // EMA crossover on closed bar[1] (bar[2]→bar[1] transition)
   bool emaBullCross = (fEMA[1] > sEMA[1]) && (fEMA[2] <= sEMA[2]);
   bool emaBearCross = (fEMA[1] < sEMA[1]) && (fEMA[2] >= sEMA[2]);
   // EMA sustained alignment (no fresh cross but direction confirmed)
   bool emaBullAlign = (fEMA[1] > sEMA[1]) && (plus > minus);
   bool emaBearAlign = (fEMA[1] < sEMA[1]) && (minus > plus);

   bool buySignal  = (emaBullCross || emaBullAlign) && htfBull && rising && (plus > minus);
   bool sellSignal = (emaBearCross || emaBearAlign) && htfBear && rising && (minus > plus);

   if(buySignal)
   {
      c.allowed             = true;
      c.direction           = 1;
      c.signal_time         = TimeCurrent();
      c.signal_origin_price = Ask;
      c.context_tag         = "TREND_BUY_EMA";
      c.strength_0_100      = MathMin(100.0, (adx / InpTrendADXMin) * 50.0 + (plus - minus));
      c.confidence_0_1      = MathMin(1.0, (adx - InpTrendADXMin) / 20.0 * 0.60 +
                                           (emaBullCross ? 0.40 : 0.20));
      c.hard_veto_reason    = "";
   }
   else if(sellSignal)
   {
      c.allowed             = true;
      c.direction           = -1;
      c.signal_time         = TimeCurrent();
      c.signal_origin_price = Bid;
      c.context_tag         = "TREND_SELL_EMA";
      c.strength_0_100      = MathMin(100.0, (adx / InpTrendADXMin) * 50.0 + (minus - plus));
      c.confidence_0_1      = MathMin(1.0, (adx - InpTrendADXMin) / 20.0 * 0.60 +
                                           (emaBearCross ? 0.40 : 0.20));
      c.hard_veto_reason    = "";
   }
}

//+------------------------------------------------------------------+
//| STEP 5: MEAN REVERSION ENGINE — active in RANGE regime only      |
//| BB band touch + RSI extreme + reversal candle confirmation       |
//| Hard-blocked during strong trends — no score or timing override  |
//+------------------------------------------------------------------+
void GenerateMeanReversion(TradeCandidate &c, double Ask, double Bid)
{
   c.engine_id   = ENG_MEAN_REVERSION;
   c.engine_name = "MeanReversion";

   double bbU[], bbL[], rsi[], adxM[], atr[];
   ArraySetAsSeries(bbU, true); ArraySetAsSeries(bbL, true);
   ArraySetAsSeries(rsi, true); ArraySetAsSeries(adxM, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(hBB,  1, 0, 3, bbU)  < 3) return;
   if(CopyBuffer(hBB,  2, 0, 3, bbL)  < 3) return;
   if(CopyBuffer(hRSI, 0, 0, 3, rsi)  < 3) return;
   if(CopyBuffer(hADX, 0, 0, 3, adxM) < 3) return;
   if(CopyBuffer(hATR, 0, 0, 2, atr)  < 2) return;

   double adx    = adxM[1];
   double atrVal = atr[1];

   // STEP 3 / hard-block: mean reversion is forbidden during a strong trend
   if(adx > InpTrendADXMin)
   {
      c.hard_veto_reason = "MR_BLOCKED_STRONG_TREND";
      return;
   }

   double close1 = iClose(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol,  _Period, 1);
   double low1   = iLow(_Symbol,   _Period, 1);
   double high1  = iHigh(_Symbol,  _Period, 1);
   double close2 = iClose(_Symbol, _Period, 2);
   double high2  = iHigh(_Symbol,  _Period, 2);
   double low2   = iLow(_Symbol,   _Period, 2);

   bool bullCandle  = (close1 > open1);
   bool bearCandle  = (close1 < open1);
   bool buyReversal = (close1 > close2) && (high1 > high2);  // Price recovering
   bool selReversal = (close1 < close2) && (low1  < low2);   // Price rolling over

   double atrDiv = (atrVal > 0) ? atrVal : 1.0;

   if(low1 <= bbL[1] && rsi[1] < InpRSIOversold && bullCandle && buyReversal)
   {
      double rsiStr = MathMin(100.0, (InpRSIOversold - rsi[1]) / InpRSIOversold * 200.0);
      double bbStr  = MathMin(100.0, (bbL[1] - low1) / atrDiv * 100.0);

      c.allowed             = true;
      c.direction           = 1;
      c.signal_time         = TimeCurrent();
      c.signal_origin_price = Ask;
      c.context_tag         = "RANGE_BUY_BB";
      c.strength_0_100      = MathMin(100.0, rsiStr * 0.50 + bbStr * 0.50);
      c.confidence_0_1      = MathMin(1.0, 0.50 + (InpRSIOversold - rsi[1]) / 30.0 * 0.50);
      c.hard_veto_reason    = "";
   }
   else if(high1 >= bbU[1] && rsi[1] > InpRSIOverbought && bearCandle && selReversal)
   {
      double rsiStr = MathMin(100.0, (rsi[1] - InpRSIOverbought) / (100.0 - InpRSIOverbought) * 200.0);
      double bbStr  = MathMin(100.0, (high1 - bbU[1]) / atrDiv * 100.0);

      c.allowed             = true;
      c.direction           = -1;
      c.signal_time         = TimeCurrent();
      c.signal_origin_price = Bid;
      c.context_tag         = "RANGE_SELL_BB";
      c.strength_0_100      = MathMin(100.0, rsiStr * 0.50 + bbStr * 0.50);
      c.confidence_0_1      = MathMin(1.0, 0.50 + (rsi[1] - InpRSIOverbought) / 30.0 * 0.50);
      c.hard_veto_reason    = "";
   }
}

//+------------------------------------------------------------------+
//| STEP 5: TREND BREAKOUT ENGINE — TREND or TRANSITION              |
//| BB breakout + DI dominance + ADX rising + HTF alignment          |
//| STEP 4: In TRANSITION the rules are significantly stricter        |
//+------------------------------------------------------------------+
void GenerateTrendBreakout(TradeCandidate &c, double Ask, double Bid, ENUM_MKT_REGIME regime)
{
   c.engine_id   = ENG_TREND_BREAKOUT;
   c.engine_name = "TrendBreakout";

   double bbU[], bbL[], adxM[], adxP[], adxN[], atr[];
   double htfF[], htfS[];
   ArraySetAsSeries(bbU, true); ArraySetAsSeries(bbL, true);
   ArraySetAsSeries(adxM, true); ArraySetAsSeries(adxP, true); ArraySetAsSeries(adxN, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(htfF, true); ArraySetAsSeries(htfS, true);

   if(CopyBuffer(hBB,  1, 0, 3, bbU)  < 3) return;
   if(CopyBuffer(hBB,  2, 0, 3, bbL)  < 3) return;
   if(CopyBuffer(hADX, 0, 0, 3, adxM) < 3) return;
   if(CopyBuffer(hADX, 1, 0, 3, adxP) < 3) return;
   if(CopyBuffer(hADX, 2, 0, 3, adxN) < 3) return;
   if(CopyBuffer(hATR, 0, 0, 2, atr)  < 2) return;
   if(CopyBuffer(hHTFast, 0, 0, 2, htfF) < 2) return;
   if(CopyBuffer(hHTSlow, 0, 0, 2, htfS) < 2) return;

   double adx   = adxM[1];
   double plus  = adxP[1];
   double minus = adxN[1];
   bool rising  = (adxM[1] > adxM[2]);
   bool htfBull = (htfF[1] > htfS[1]);
   bool htfBear = (htfF[1] < htfS[1]);

   double close1 = iClose(_Symbol, _Period, 1);
   double atrDiv = (atr[1] > 0) ? atr[1] : 1.0;

   // STEP 4: TRANSITION requires tighter ADX, larger DI spread, and mandatory HTF alignment
   bool   inTransition   = (regime == MKT_TRANSITION);
   double minADX         = inTransition ? (InpTrendADXMin + 5.0) : (InpTrendADXMin * 0.90);
   double minDISpread    = inTransition ? 15.0 : 8.0;
   bool   htfMandatory   = inTransition;   // HTF optional in TREND, required in TRANSITION

   if(!rising || adx < minADX) return;  // Not enough momentum regardless of direction

   // BUY breakout: close breaks above upper BB with bullish DI dominance
   if(close1 > bbU[1] && plus > minus && (plus - minus) >= minDISpread)
   {
      if(htfMandatory && !htfBull)
      {
         c.hard_veto_reason = "TRANS_BUY_NO_HTF";
         return;
      }
      double breakStr = MathMin(100.0, (close1 - bbU[1]) / atrDiv * 100.0);

      c.allowed             = true;
      c.direction           = 1;
      c.signal_time         = TimeCurrent();
      c.signal_origin_price = Ask;
      c.context_tag         = inTransition ? "TRANS_BUY_BREAK" : "TREND_BUY_BREAK";
      c.strength_0_100      = MathMin(100.0, breakStr + adx);
      c.confidence_0_1      = MathMin(1.0, 0.40 + (rising ? 0.30 : 0.0) + (htfBull ? 0.30 : 0.0));
      c.hard_veto_reason    = "";
   }
   // SELL breakout: close breaks below lower BB with bearish DI dominance
   else if(close1 < bbL[1] && minus > plus && (minus - plus) >= minDISpread)
   {
      if(htfMandatory && !htfBear)
      {
         c.hard_veto_reason = "TRANS_SELL_NO_HTF";
         return;
      }
      double breakStr = MathMin(100.0, (bbL[1] - close1) / atrDiv * 100.0);

      c.allowed             = true;
      c.direction           = -1;
      c.signal_time         = TimeCurrent();
      c.signal_origin_price = Bid;
      c.context_tag         = inTransition ? "TRANS_SELL_BREAK" : "TREND_SELL_BREAK";
      c.strength_0_100      = MathMin(100.0, breakStr + adx);
      c.confidence_0_1      = MathMin(1.0, 0.40 + (rising ? 0.30 : 0.0) + (htfBear ? 0.30 : 0.0));
      c.hard_veto_reason    = "";
   }
}

//+------------------------------------------------------------------+
//| STEP 6: HARD FILTERS — absolute rejection, no exceptions         |
//| If any filter fails, the candidate is immediately vetoed.        |
//| Score calculation is never reached for vetoed candidates.        |
//+------------------------------------------------------------------+
void ApplyHardFilters(TradeCandidate &c, double Ask, double Bid,
                      double spread, ENUM_MKT_REGIME regime)
{
   if(!c.allowed) return;

   // 1. Regime mismatch (double-check — engine may have been called in wrong regime)
   if(c.engine_id == ENG_MEAN_REVERSION && regime == MKT_TREND)
   {
      c.allowed          = false;
      c.hard_veto_reason = "HF_REGIME_MR_IN_TREND";
      return;
   }

   // 2. Engine shutdown state (Step 15)
   if(IsEngineShutdown(c.engine_id))
   {
      c.allowed          = false;
      c.hard_veto_reason = "HF_ENGINE_SHUTDOWN";
      return;
   }

   // 3. Spread limit
   if(spread > InpMaxSpread)
   {
      c.allowed          = false;
      c.hard_veto_reason = "HF_SPREAD";
      return;
   }

   // 4. Session window
   if(!IsSessionTime())
   {
      c.allowed          = false;
      c.hard_veto_reason = "HF_SESSION";
      return;
   }

   // 5. Weekend / Friday protection
   if(IsWeekendBlocked())
   {
      c.allowed          = false;
      c.hard_veto_reason = "HF_WEEKEND";
      return;
   }

   // 6. Drawdown halt
   if(IsDrawdownHalted())
   {
      c.allowed          = false;
      c.hard_veto_reason = "HF_DD_HALT";
      return;
   }

   // 7. Daily trade cap
   if(IsDailyLimitReached())
   {
      c.allowed          = false;
      c.hard_veto_reason = "HF_DAILY_CAP";
      return;
   }

   // 8. Late entry protection (Step 7) — hard rule based on distance from origin
   if(!IsLateEntryOK(c.direction, c.signal_origin_price))
   {
      c.allowed          = false;
      c.hard_veto_reason = "HF_LATE_ENTRY";
      return;
   }
}

//+------------------------------------------------------------------+
//| STEP 7: LATE ENTRY PROTECTION                                    |
//| Reject setup if current price has already moved more than        |
//| InpMaxChaseATR × ATR away from the signal origin.                |
//| A good setup becomes a bad trade if chased too far.              |
//+------------------------------------------------------------------+
bool IsLateEntryOK(double direction, double originPrice)
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR, 0, 0, 2, atr) < 2) return true;  // ATR unavailable → allow

   double maxChase = atr[1] * InpMaxChaseATR;
   double curAsk   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double curBid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(direction > 0 && curAsk > originPrice + maxChase) return false;  // BUY chased too high
   if(direction < 0 && curBid < originPrice - maxChase) return false;  // SELL chased too low
   return true;
}

//+------------------------------------------------------------------+
//| STEPS 10-11: SCORE NORMALIZATION + WEIGHTING                     |
//| All components normalized to 0–100 before weighting.            |
//| Weights are applied transparently so no component dominates      |
//| through range size — only through intentional design.            |
//+------------------------------------------------------------------+
void NormalizeAndScore(TradeCandidate &c)
{
   if(!c.allowed) return;

   // Component 1 – Trigger quality: how strong/extreme is the signal?
   double triggerScore = MathMin(100.0, c.strength_0_100);

   // Component 2 – Momentum strength: ADX-based (ADX 50 = full score 100)
   double momScore = 50.0;
   double adxBuf[];
   ArraySetAsSeries(adxBuf, true);
   if(CopyBuffer(hADX, 0, 0, 2, adxBuf) >= 2)
      momScore = MathMin(100.0, adxBuf[1] / 50.0 * 100.0);

   // Component 3 – Timing quality: derived from engine confidence (0–1 → 0–100)
   double timingScore = c.confidence_0_1 * 100.0;

   // Component 4 – Confirmation quality: HTF alignment
   double confirmScore = 50.0;  // Neutral default when HTF unreadable
   double htfF[], htfS[];
   ArraySetAsSeries(htfF, true); ArraySetAsSeries(htfS, true);
   if(CopyBuffer(hHTFast, 0, 0, 2, htfF) >= 2 && CopyBuffer(hHTSlow, 0, 0, 2, htfS) >= 2)
   {
      bool aligned = (c.direction ==  1 && htfF[1] > htfS[1]) ||
                     (c.direction == -1 && htfF[1] < htfS[1]);
      confirmScore  = aligned ? 90.0 : 20.0;
   }

   // Weighted final score — weights normalised so they always sum to 100%
   double wTotal = InpWtTrigger + InpWtMomentum + InpWtTiming + InpWtConfirmation;
   if(wTotal <= 0) wTotal = 1.0;

   c.score_normalized = (triggerScore * InpWtTrigger   +
                         momScore     * InpWtMomentum  +
                         timingScore  * InpWtTiming    +
                         confirmScore * InpWtConfirmation) / wTotal;
}

//+------------------------------------------------------------------+
//| STEPS 12-13: DETERMINISTIC RANKING + DIRECTIONAL CONFLICT        |
//| Step 13: BUY/SELL conflict resolved before final ranking.        |
//| Step 12: Tie-break order — score → engine priority → signal time |
//+------------------------------------------------------------------+
bool SelectWinner(TradeCandidate &arr[], ENUM_MKT_REGIME regime,
                  TradeCandidate &winner)
{
   // Score all allowed candidates (Step 10-11)
   for(int i = 0; i < REGIME_EA_ENGINE_COUNT; i++)
   {
      if(arr[i].allowed)
         NormalizeAndScore(arr[i]);
   }

   // Drop candidates below the minimum score threshold (Step 10)
   for(int i = 0; i < REGIME_EA_ENGINE_COUNT; i++)
   {
      if(arr[i].allowed && arr[i].score_normalized < InpMinScore)
      {
         arr[i].allowed          = false;
         arr[i].hard_veto_reason = "SCORE_LOW_" + DoubleToString(arr[i].score_normalized, 1);
      }
   }

   // Count surviving BUY and SELL candidates
   int buys = 0, sells = 0;
   for(int i = 0; i < REGIME_EA_ENGINE_COUNT; i++)
   {
      if(!arr[i].allowed) continue;
      if(arr[i].direction ==  1) buys++;
      if(arr[i].direction == -1) sells++;
   }

   // STEP 13: Resolve directional conflict when both BUY and SELL survivors exist
   if(buys > 0 && sells > 0)
   {
      if(InpHTFBiasBreaksTie)
      {
         // Use HTF bias to eliminate the opposing direction
         double htfF[], htfS[];
         ArraySetAsSeries(htfF, true); ArraySetAsSeries(htfS, true);
         if(CopyBuffer(hHTFast, 0, 0, 2, htfF) >= 2 && CopyBuffer(hHTSlow, 0, 0, 2, htfS) >= 2)
         {
            int htfBias = (htfF[1] > htfS[1]) ? 1 : ((htfF[1] < htfS[1]) ? -1 : 0);
            if(htfBias == 1)
            {  // HTF bullish → keep only BUY candidates
               for(int i = 0; i < REGIME_EA_ENGINE_COUNT; i++)
                  if(arr[i].allowed && arr[i].direction == -1) arr[i].allowed = false;
            }
            else if(htfBias == -1)
            {  // HTF bearish → keep only SELL candidates
               for(int i = 0; i < REGIME_EA_ENGINE_COUNT; i++)
                  if(arr[i].allowed && arr[i].direction ==  1) arr[i].allowed = false;
            }
            // htfBias == 0 → no clear bias → let score decide below
         }
      }
      // InpHTFBiasBreaksTie = false → both directions compete in score ranking (no filtering)
   }

   // STEP 12: Deterministic ranking — pick the single best candidate
   // Tie-break order: 1) score  2) engine priority (lower ID = higher priority)  3) signal_time
   int bestIdx = -1;
   for(int i = 0; i < REGIME_EA_ENGINE_COUNT; i++)
   {
      if(!arr[i].allowed) continue;

      if(bestIdx == -1) { bestIdx = i; continue; }

      double scoreDiff = arr[i].score_normalized - arr[bestIdx].score_normalized;

      if(scoreDiff > 0.01)
      {
         bestIdx = i;  // Higher score wins
      }
      else if(scoreDiff >= -0.01)  // Scores are within 0.01 — apply tie-break
      {
         // Tie-break 2: lower engine ID = higher declared engine priority
         if((int)arr[i].engine_id < (int)arr[bestIdx].engine_id)
            bestIdx = i;
         // Tie-break 3: earlier signal timestamp (fresher context)
         else if(arr[i].engine_id == arr[bestIdx].engine_id &&
                 arr[i].signal_time < arr[bestIdx].signal_time)
            bestIdx = i;
      }
   }

   if(bestIdx == -1) return false;  // No valid candidate
   winner = arr[bestIdx];
   return true;
}

//+------------------------------------------------------------------+
//| STEP 14: RISK ENGINE — FINAL AUTHORITY                           |
//| Score decides quality. Risk decides permission and size.         |
//| Risk engine overrides score whenever protection rules demand it. |
//+------------------------------------------------------------------+
bool RiskEngineApprove(TradeCandidate &c, double Ask, double Bid,
                       double spread, double &lot)
{
   lot = 0.0;

   // Re-check spread at the exact execution moment
   if(spread > InpMaxSpread)
   {
      c.hard_veto_reason = "RISK_SPREAD_AT_EXEC";
      return false;   // Retry allowed: candidate stays alive
   }

   // Re-check late entry at execution moment (Step 7 re-validated at Step 14)
   if(!IsLateEntryOK(c.direction, c.signal_origin_price))
   {
      c.allowed          = false;   // Permanently cancel — do NOT retry
      c.hard_veto_reason = "RISK_LATE_ENTRY_AT_EXEC";
      return false;
   }

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double freeMargin = AccountInfoDouble(ACCOUNT_FREEMARGIN);

   // Apply consecutive-loss scaler (Kelly-inspired, Step 14)
   double riskPct   = InpRiskPct * GetRiskScaler();
   double moneyRisk = balance * (riskPct / 100.0);

   double slPoints   = InpSLPips * g_PipMult;
   double tickVal    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lossPerLot = (slPoints * _Point / tickSz) * tickVal;
   if(lossPerLot <= 0) return false;

   double raw = moneyRisk / lossPerLot;
   lot = MathFloor(raw / g_StepVol) * g_StepVol;
   if(lot < g_MinVol) lot = g_MinVol;
   if(lot > g_MaxVol) lot = g_MaxVol;

   // Margin safety: never risk more than 90% of free margin
   double price = (c.direction == 1) ? Ask : Bid;
   double marginNeeded = 0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, price, marginNeeded))
   {
      if(marginNeeded > freeMargin * 0.90)
      {
         double reduction = (freeMargin * 0.90) / marginNeeded;
         lot = MathFloor((lot * reduction) / g_StepVol) * g_StepVol;
         if(lot < g_MinVol)
         {
            c.hard_veto_reason = "RISK_INSUFFICIENT_MARGIN";
            return false;   // Cannot trade safely → retry
         }
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| EXECUTE — Place the order for the winning candidate              |
//+------------------------------------------------------------------+
void ExecuteTrade(TradeCandidate &c, double lot, double Ask, double Bid)
{
   double slPts = InpSLPips * g_PipMult * _Point;
   double tpPts = InpTPPips * g_PipMult * _Point;
   string cmt   = c.engine_name + "|" + c.context_tag +
                  "|S" + DoubleToString(c.score_normalized, 1);

   if(c.direction == 1)
   {
      double sl = Ask - slPts;
      double tp = Ask + tpPts;
      trade.Buy(lot, _Symbol, Ask, sl, tp, cmt);
   }
   else
   {
      double sl = Bid + slPts;
      double tp = Bid - tpPts;
      trade.Sell(lot, _Symbol, Bid, sl, tp, cmt);
   }

   PrintFormat("RegimeAdaptiveEA EXEC: %s | Engine:%s | Score:%.1f | Lot:%.2f | Tag:%s",
               (c.direction == 1 ? "BUY" : "SELL"), c.engine_name,
               c.score_normalized, lot, c.context_tag);

   // Clear the retry slot for this engine so it doesn't fire again
   ResetCandidate(g_Candidates[c.engine_id]);
}

//+------------------------------------------------------------------+
//| STEP 8: STORE RETRY CANDIDATE                                    |
//| A candidate blocked by temporary conditions (spread / margin)    |
//| is stored for retry. Permanent vetoes (late entry etc.) do NOT   |
//| reach this function — they are discarded at the call site.       |
//+------------------------------------------------------------------+
void StoreRetryCandidate(TradeCandidate &c)
{
   // STEP 9: Set the bounded lifetime on first storage
   if(c.retry_count == 0)
      c.retry_deadline = TimeCurrent() + (long)InpMaxRetryBars * PeriodSeconds(_Period);

   g_Candidates[c.engine_id] = c;
}

//+------------------------------------------------------------------+
//| STEPS 8-9: PROCESS RETRY CANDIDATES                              |
//| Every hard filter is re-applied on each retry tick.              |
//| Late entry failure during retry → permanent discard (Step 8).   |
//| Bounded window expiry → permanent discard (Step 9).              |
//| Returns true if a trade was executed from a retry candidate.     |
//+------------------------------------------------------------------+
bool ProcessRetryCandidates(double Ask, double Bid, double spread,
                            ENUM_MKT_REGIME regime, double conf)
{
   for(int i = 0; i < REGIME_EA_ENGINE_COUNT; i++)
   {
      if(!g_Candidates[i].allowed) continue;

      // STEP 9: Bounded window check — permanently discard if expired
      if(TimeCurrent() > g_Candidates[i].retry_deadline)
      {
         PrintFormat("RegimeAdaptiveEA: Candidate %s expired (%d retries)",
                     g_Candidates[i].engine_name, g_Candidates[i].retry_count);
         ResetCandidate(g_Candidates[i]);
         continue;
      }

      // Max retry tick count guard
      if(g_Candidates[i].retry_count >= InpMaxRetryTicks)
      {
         ResetCandidate(g_Candidates[i]);
         continue;
      }

      g_Candidates[i].retry_count++;

      // STEP 8: Re-apply ALL hard filters including late entry on every retry
      ApplyHardFilters(g_Candidates[i], Ask, Bid, spread, regime);

      // If late entry failed → permanently discard (price has drifted too far)
      if(!g_Candidates[i].allowed &&
         StringFind(g_Candidates[i].hard_veto_reason, "LATE_ENTRY") >= 0)
      {
         PrintFormat("RegimeAdaptiveEA: Retry cancelled — late entry for %s",
                     g_Candidates[i].engine_name);
         ResetCandidate(g_Candidates[i]);
         continue;
      }

      // Still blocked by a different hard filter — try again next tick
      if(!g_Candidates[i].allowed)
      {
         g_Candidates[i].allowed = true;  // Restore allowed for next tick retry
         continue;
      }

      // Survivor: re-score with current market data
      NormalizeAndScore(g_Candidates[i]);
      if(g_Candidates[i].score_normalized < InpMinScore)
         continue;  // Score degraded — skip this tick, keep in retry slot

      // Risk engine check
      double lot = 0.0;
      if(!RiskEngineApprove(g_Candidates[i], Ask, Bid, spread, lot))
      {
         // If permanently vetoed (late entry at risk check), discard
         if(!g_Candidates[i].allowed) ResetCandidate(g_Candidates[i]);
         continue;
      }

      ExecuteTrade(g_Candidates[i], lot, Ask, Bid);
      return true;   // One trade at a time
   }
   return false;
}

//+------------------------------------------------------------------+
//| POSITION MANAGEMENT — Always runs, never blocked                 |
//| Breakeven, trailing stop. Applied to every open position.        |
//+------------------------------------------------------------------+
void ManageExits()
{
   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double beTrigDist = InpBETriggerPips * g_PipMult * _Point;
   double beLockDist = InpBELockPips   * g_PipMult * _Point;
   double trailDist  = InpTrailDistPips * g_PipMult * _Point;
   double trailStep  = InpTrailStepPips * g_PipMult * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      double sl        = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      long   posType   = PositionGetInteger(POSITION_TYPE);

      if(posType == POSITION_TYPE_BUY)
      {
         // Move to breakeven
         if(Bid >= openPrice + beTrigDist)
         {
            double beSL = openPrice + beLockDist;
            if(sl < beSL - _Point * 10)
               { trade.PositionModify(ticket, beSL, tp); continue; }
         }
         // Trail once already in profit zone
         if(sl >= openPrice + beLockDist)
         {
            double newSL = Bid - trailDist;
            if(newSL > sl + trailStep) trade.PositionModify(ticket, newSL, tp);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         // Move to breakeven
         if(Ask <= openPrice - beTrigDist)
         {
            double beSL = openPrice - beLockDist;
            if(sl > beSL + _Point * 10 || sl == 0)
               { trade.PositionModify(ticket, beSL, tp); continue; }
         }
         // Trail once already in profit zone
         if(sl <= openPrice - beLockDist && sl != 0)
         {
            double newSL = Ask + trailDist;
            if(newSL < sl - trailStep) trade.PositionModify(ticket, newSL, tp);
         }
      }
   }

   // Equity guard runs inside ManageExits so it can force-close if needed
   CheckEquityGuard();
}

//+------------------------------------------------------------------+
//| FRIDAY AUTO-CLOSE — force close all positions on Friday evening  |
//+------------------------------------------------------------------+
void CheckFridayClose()
{
   if(!InpUseFridayClose) return;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) &&
            PositionGetInteger(POSITION_MAGIC) == InpMagic)
            trade.PositionClose(ticket, InpMaxSlippage);
      }
   }
}

//+------------------------------------------------------------------+
//| EQUITY GUARD — force-close if floating equity drops too far      |
//+------------------------------------------------------------------+
void CheckEquityGuard()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_PeakEquity) g_PeakEquity = equity;
   if(g_PeakEquity <= 0)     return;

   // Clear expired halt
   if(g_EquityHaltUntil > 0 && TimeCurrent() >= g_EquityHaltUntil)
      g_EquityHaltUntil = 0;

   if(g_EquityHaltUntil > 0) return;  // Already halted

   double ddPct = (g_PeakEquity - equity) / g_PeakEquity * 100.0;
   if(ddPct >= InpMaxEquityDDPct)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) &&
            PositionGetInteger(POSITION_MAGIC) == InpMagic)
            trade.PositionClose(ticket, InpMaxSlippage);
      }
      g_EquityHaltUntil = TimeCurrent() + 3600;  // 1-hour new-entry halt
      g_PeakEquity      = AccountInfoDouble(ACCOUNT_EQUITY);
      PrintFormat("RegimeAdaptiveEA: Equity Guard fired — %.1f%% DD. Halt 1h.", ddPct);
   }
}

bool IsEquityGuardTriggered()
{
   return (g_EquityHaltUntil > 0 && TimeCurrent() < g_EquityHaltUntil);
}

//+------------------------------------------------------------------+
//| DRAWDOWN HALT — peak-balance and daily-loss circuit breakers     |
//+------------------------------------------------------------------+
bool IsDrawdownHalted()
{
   double   balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   datetime today    = iTime(_Symbol, PERIOD_D1, 0);
   if(today == 0) return false;

   if(balance > g_PeakBalance) g_PeakBalance = balance;

   // Roll day-open balance at the start of each new trading day
   if(g_DayOpenTime == 0 || today > g_DayOpenTime)
   {
      g_DayOpenBalance = balance;
      g_DayOpenTime    = today;
   }

   // Clear expired halt
   if(g_DDHaltUntil > 0 && TimeCurrent() >= g_DDHaltUntil)
      g_DDHaltUntil = 0;
   if(g_DDHaltUntil > 0) return true;

   // Peak drawdown breach
   if(g_PeakBalance > 0)
   {
      double ddPct = (g_PeakBalance - balance) / g_PeakBalance * 100.0;
      if(ddPct >= InpMaxPeakDDPct)
      {
         g_DDHaltUntil = TimeCurrent() + (long)InpDDHaltHours * 3600;
         PrintFormat("RegimeAdaptiveEA: Peak DD halt — %.1f%% below peak. Halt %dh.",
                     ddPct, InpDDHaltHours);
         return true;
      }
   }

   // Daily loss breach
   if(g_DayOpenBalance > 0)
   {
      double dayLoss = (g_DayOpenBalance - balance) / g_DayOpenBalance * 100.0;
      if(dayLoss >= InpMaxDailyLossPct)
      {
         g_DDHaltUntil = today + 86400;  // Block until next calendar day
         PrintFormat("RegimeAdaptiveEA: Daily loss halt — %.1f%%. Halt until EOD.", dayLoss);
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| SESSION + WEEKEND GUARDS                                         |
//+------------------------------------------------------------------+
bool IsSessionTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.hour >= InpSessionStart && dt.hour < InpSessionEnd);
}

bool IsWeekendBlocked()
{
   if(!InpUseFridayClose) return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour) return true;
   if(dt.day_of_week == 6) return true;
   if(dt.day_of_week == 0) return true;
   if(dt.day_of_week == 1 && dt.hour < InpMondayOpenHour)   return true;
   return false;
}

//+------------------------------------------------------------------+
//| DAILY TRADE CAP                                                  |
//+------------------------------------------------------------------+
bool IsDailyLimitReached()
{
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   HistorySelect(todayStart, TimeCurrent());
   int count = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong dk = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(dk, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetInteger(dk, DEAL_ENTRY) == DEAL_ENTRY_OUT) count++;
   }
   return (count >= InpMaxDailyTrades);
}

//+------------------------------------------------------------------+
//| STEP 15: ENGINE SHUTDOWN — check and trigger                     |
//+------------------------------------------------------------------+
bool IsEngineShutdown(ENUM_RA_ENGINE id)
{
   if(!g_Health[id].is_shutdown) return false;

   // STEP 16: Recovery — time-based path
   if(g_Health[id].shutdown_until > 0 && TimeCurrent() >= g_Health[id].shutdown_until)
   {
      RecoverEngine(id, "TIME_EXPIRED");
      return false;
   }

   // STEP 16: Recovery — bar-count path (whichever comes first)
   if(g_Health[id].bars_since_shutdown >= InpRecoveryBars)
   {
      RecoverEngine(id, "BARS_ELAPSED");
      return false;
   }

   return true;
}

void ShutdownEngine(ENUM_RA_ENGINE id, string reason)
{
   g_Health[id].is_shutdown         = true;
   g_Health[id].bars_since_shutdown = 0;
   g_Health[id].shutdown_until      = TimeCurrent() +
                                      (long)InpRecoveryBars * PeriodSeconds(_Period);
   PrintFormat("RegimeAdaptiveEA: Engine %s SHUTDOWN [%s] — recovery in %d bars",
               EngineName(id), reason, InpRecoveryBars);
}

//+------------------------------------------------------------------+
//| STEP 16: ENGINE RECOVERY — explicit, deterministic, gradual      |
//+------------------------------------------------------------------+
void RecoverEngine(ENUM_RA_ENGINE id, string reason)
{
   g_Health[id].is_shutdown         = false;
   g_Health[id].shutdown_until      = 0;
   g_Health[id].bars_since_shutdown = 0;
   g_Health[id].consecutive_losses  = 0;  // Gradual recovery: reset streak counter
   PrintFormat("RegimeAdaptiveEA: Engine %s RECOVERED [%s]", EngineName(id), reason);
}

//+------------------------------------------------------------------+
//| STEPS 15-16: ENGINE HEALTH — record trade result                 |
//+------------------------------------------------------------------+
void UpdateEngineHealth(ENUM_RA_ENGINE id, bool isLoss)
{
   if(isLoss)
   {
      g_Health[id].consecutive_losses++;
      g_Health[id].rolling_losses++;
   }
   else
   {
      g_Health[id].consecutive_losses = 0;  // Win resets the streak
   }
   g_Health[id].rolling_trades++;

   // Step 15: Consecutive-loss shutdown
   if(g_Health[id].consecutive_losses >= InpShutdownLosses)
   {
      ShutdownEngine(id, "CONSEC_LOSSES");
      return;
   }

   // Step 15: Rolling loss-rate shutdown (checked at end of window)
   if(g_Health[id].rolling_trades >= InpRollingWindow)
   {
      double lossRate = (double)g_Health[id].rolling_losses /
                        (double)g_Health[id].rolling_trades;
      if(lossRate >= InpMaxRollingLossRate)
         ShutdownEngine(id, "ROLLING_LOSS_RATE");
      // Reset rolling window after evaluation
      g_Health[id].rolling_trades = 0;
      g_Health[id].rolling_losses = 0;
   }
}

//+------------------------------------------------------------------+
//| BAR COUNTER — new-bar detection drives recovery tick counting    |
//+------------------------------------------------------------------+
void UpdateBarCounter()
{
   datetime barTime = iTime(_Symbol, _Period, 0);
   if(g_LastBarTime == 0) { g_LastBarTime = barTime; return; }
   if(barTime == g_LastBarTime) return;

   g_LastBarTime = barTime;

   // Increment bar counter for all shutdown engines (Step 16)
   for(int i = 0; i < REGIME_EA_ENGINE_COUNT; i++)
      if(g_Health[i].is_shutdown) g_Health[i].bars_since_shutdown++;

   // Scan closed deals on each new bar for engine health updates
   ScanClosedDeals();
}

//+------------------------------------------------------------------+
//| SCAN CLOSED DEALS — detect results, update health + risk state   |
//+------------------------------------------------------------------+
void ScanClosedDeals()
{
   datetime now   = TimeCurrent();
   datetime from  = (g_LastDealScan > 0) ? g_LastDealScan : (now - 86400);

   HistorySelect(from, now);
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong dk = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(dk, DEAL_MAGIC) != InpMagic)        continue;
      if(HistoryDealGetInteger(dk, DEAL_ENTRY) != DEAL_ENTRY_OUT)  continue;
      if((datetime)HistoryDealGetInteger(dk, DEAL_TIME) <= from)   continue;

      double profit = HistoryDealGetDouble(dk, DEAL_PROFIT);
      bool   isLoss = (profit < 0);

      // Determine originating engine from trade comment
      string cmt = HistoryDealGetString(dk, DEAL_COMMENT);
      ENUM_RA_ENGINE engId = ENG_TREND_MOMENTUM;  // Default
      if(StringFind(cmt, "MeanReversion") >= 0) engId = ENG_MEAN_REVERSION;
      else if(StringFind(cmt, "TrendBreakout") >= 0) engId = ENG_TREND_BREAKOUT;

      UpdateEngineHealth(engId, isLoss);

      // Global consecutive-loss scaler (Step 14 / risk engine)
      if(InpUseLossScaler)
      {
         if(isLoss)
            g_ConsecLosses++;
         else if(g_ConsecLosses > 0)
            g_ConsecLosses--;
      }
   }

   g_LastDealScan = now;
}

//+------------------------------------------------------------------+
//| RISK SCALER — Kelly-inspired consecutive-loss size reduction     |
//| Applied inside RiskEngineApprove (Step 14) in normal mode only   |
//+------------------------------------------------------------------+
double GetRiskScaler()
{
   if(!InpUseLossScaler || g_ConsecLosses <= 0) return 1.00;
   if(g_ConsecLosses == 1)                      return 0.75;  // −25% after 1 loss
   if(g_ConsecLosses == 2)                      return 0.50;  // −50% after 2 losses
   return 0.25;                                               // −75% survival mode (3+)
}

//+------------------------------------------------------------------+
//| UTILITY: Reset a candidate to its blank initial state            |
//+------------------------------------------------------------------+
void ResetCandidate(TradeCandidate &c)
{
   c.allowed             = false;
   c.direction           = 0;
   c.engine_id           = ENG_TREND_MOMENTUM;
   c.engine_name         = "";
   c.signal_time         = 0;
   c.signal_origin_price = 0.0;
   c.hard_veto_reason    = "";
   c.strength_0_100      = 0.0;
   c.confidence_0_1      = 0.0;
   c.context_tag         = "";
   c.score_normalized    = 0.0;
   c.retry_deadline      = 0;
   c.retry_count         = 0;
}

//+------------------------------------------------------------------+
//| UTILITY: Human-readable engine name by ID                        |
//+------------------------------------------------------------------+
string EngineName(ENUM_RA_ENGINE id)
{
   if(id == ENG_TREND_MOMENTUM) return "TrendMomentum";
   if(id == ENG_MEAN_REVERSION) return "MeanReversion";
   if(id == ENG_TREND_BREAKOUT) return "TrendBreakout";
   return "Unknown";
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                      SCALP GOLDEA V20.mq5       |
//|                          Copyright 2026, Trading Pro            |
//|   V20.0 — Regime-Adaptive Layer built on V19.0                  |
//|   (Multi-Pair Auto-Config + Regime-Gated Engine Routing)        |
//+------------------------------------------------------------------+
//
// V20.0 ADDS (layered on top of V19.0 — ALL V19 logic intact):
//
//   REGIME ENGINE (ClassifyRegimeV20):
//     Classifies market every tick into one of four exclusive states:
//       RANGE      – ADX weak, BB compressed → mean-reversion dominates
//       TREND      – ADX strong, DI clear separation → directional engines active
//       TRANSITION – ADX in grey zone → cautious mixed mode
//       CHAOS      – extreme ATR spike (news / gap) → all engines silenced
//     Outputs a continuous confidence score (0–1).  If confidence falls
//     below InpV20MinRegimeConf, ALL new entries are blocked (NO TRADE).
//
//   REGIME GATING (OnTick routing):
//     RANGE + TRANSITION: Mean-Reversion engine (V19 BUY/SELL blocks) allowed.
//                         In TRANSITION mode MR is demoted to L1 only (extra caution).
//     TREND:              Mean-Reversion HARD BLOCKED (no exceptions).
//                         Trend-Momentum engine (V20 NEW) becomes active.
//     CHAOS:              All engines blocked; position exits still managed.
//
//   TREND-MOMENTUM ENGINE (RunTrendMomentumEngineV20):
//     Fires in TREND regime only.  Requires:
//       • EMA crossover OR sustained EMA alignment (fast vs slow)
//       • DI+/DI- dominant direction matching EMA bias
//       • H4 macro trend aligned (HTF EMA50 vs EMA200)
//       • ADX rising above the trend threshold
//     Risk tier: L2 base → L3 when DI spread strong → L4 elite when all
//     combine with active tick-momentum confirmation.
//     Trade comment prefix "V20_TM|" identifies Trend-Momentum deals.
//
//   ENGINE HEALTH (V20IsEngineShutdown / V20ScanClosedDeals):
//     Two independent health counters — one per engine:
//       Mean-Reversion (MR): tracks existing V19-style trades
//       Trend-Momentum (TM): tracks V20_TM| tagged trades
//     After InpV20ShutLosses consecutive losses an engine is suspended.
//     It recovers after InpV20RecoveryBars new bars have elapsed.
//
//   BACKWARDS COMPATIBILITY:
//     InpV20UseRegimeFilter = false → V20 regime layer is FULLY DISABLED,
//     EA runs as an exact V19.0 clone.  Zero impact on existing logic.
//
//   ALL V19 FEATURES PRESERVED (unchanged):
//     Challenge mode, L1/L2/L3/L4 scoring, equity guard, consecutive loss
//     scaler, Friday/weekend protection, pending retry, re-entry, drawdown
//     circuit breaker, survival mode, multi-pair auto-config, tick-level
//     multi-scenario engine, partial TP, breakeven, trailing stop.
//+------------------------------------------------------------------+

#property copyright "Copyright 2026, Trading Pro"
#property link      "https://www.mql5.com"
#property version   "20.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| V20 ENUMERATIONS                                                 |
//+------------------------------------------------------------------+

enum ENUM_REGIME_V20
{
   REGIME_V20_RANGE      = 0,  // Low ADX, compressed BB — mean-reversion conditions
   REGIME_V20_TREND      = 1,  // High ADX, clear DI separation — trend-following conditions
   REGIME_V20_TRANSITION = 2,  // ADX between thresholds — mixed / cautious
   REGIME_V20_CHAOS      = 3   // ATR spike / news — all engines silenced
};

enum ENUM_ENGINE_V20
{
   ENG_V20_MEAN_REVERSION  = 0,  // V19 BB/RSI engine — active in RANGE/TRANSITION
   ENG_V20_TREND_MOMENTUM  = 1   // V20 EMA+DI engine — active in TREND only
};

//--- INPUT PARAMETERS (V19 — unchanged)
input group "=== DYNAMIC SIGNAL SCORING (HFT) ==="
input double   InpRiskLevel1     = 2.0;       // Level 1: Daily HFT Scalping
input double   InpRiskLevel2     = 5.0;       // Level 2: Sniper Trade (HTF Aligned)
input double   InpRiskLevel3     = 10.0;      // Level 3: God-Tier Trade (Perfect Confluence)
input double   InpRiskLevel4     = 15.0;      // Level 4: Elite Sniper (~95% win rate setup)

input group "=== SNIPER HTF FILTER (FOR LEVEL 2/3) ==="
input ENUM_TIMEFRAMES InpHTF     = PERIOD_H4; // Higher Timeframe for 100% setup
input int      InpHTF_FastEMA    = 50;        // HTF Fast Trend
input int      InpHTF_SlowEMA    = 200;       // HTF Macro Trend

input group "=== HFT EXECUTION & GOALS ==="
input double   InpStopLossPips   = 80.0;      // Increased SL for Gold Volatility (80 pips)
input double   InpTakeProfitPips = 550.0;     // Extended TP for runners (550 pips)
input double   InpPartialTPPips  = 40.0;      // TP1: Close 50% here to lock profit
input double   InpPipMultiplier  = 10.0;      // Points per Pip (10 for Gold)

input group "=== BREAK-EVEN & TRAILING (RELAXED) ==="
input double   InpBETriggerPips  = 45.0;      // Wait for 45 pips before moving to BE
input double   InpBELockPips     = 10.0;      // Lock 10 pips (covers spread + small gain)
input double   InpTrailDistPips  = 65.0;      // Wider trail to let Gold breathe
input double   InpTrailStepPips  = 20.0;      // Larger steps to avoid micro-stops

input group "=== DISCIPLINE LIMITS (10 TRADES) ==="
input int      InpMaxTradesDay   = 10;        // Strict max 10 trades per day
input int      InpMagic          = 7772028;   // HFT Magic Number

input group "=== FILTERS & SAFETY ==="
input int      InpMaxSpread      = 45;        // More realistic for Gold (45 points)
input int      InpMaxSlippage    = 30;        // Realistic Slippage for Gold HFT
input bool     InpUseVolFilter   = true;      // Dynamic Trend-Expansion Filter
input bool     InpUseADXConfirmation = true;  // Check ADX Slope (Increasing Momentum)

input group "=== TIME BLACKOUTS ==="
input int      InpHourStart      = 1;         // Start HFT
input int      InpHourEnd        = 22;        // Pause before Asian consolidation

input group "=== 500 PIP CHALLENGE MODE ==="
input bool     InpChallengeMode       = true; // Enable $20→$40k Challenge Mode
input double   InpChallengeRisk       = 30.0; // Risk per trade in Challenge (%)
input double   InpChallengeSL         = 80.0; // Stop Loss in Challenge (pips)
input double   InpChallengeTP_Early   = 500.0;// TP when balance < threshold (pips)
input double   InpChallengeTP_Late    = 20.0; // TP when balance >= threshold (pips)
input double   InpChallengeThreshold  = 300.0;// Balance threshold: switch from Early to Late TP ($)

input group "=== PRECISION TIMING (V13) ==="
input double InpADXDelayMin       = 18.0;  // ADX < this: delay entry, not reject
input int    InpPendingExpireBars  = 5;    // Bars before a delayed signal expires
input double InpLargeBodyMult     = 2.0;  // Body > N×ATR: wait for pullback before entry
input bool   InpEnableReentry     = true; // Allow one re-entry attempt after SL hit

input group "=== L2/L3 SURVIVAL MODE (V14) ==="
input int    InpL23WeeklyCap       = 3;    // Max combined L2+L3 trades per week
input int    InpL23DailyCap        = 1;    // Max combined L2+L3 trades per day
input int    InpL3CooldownHours    = 48;   // Min hours between consecutive L3 trades
input int    InpL23LossCooldownH   = 72;   // Hours L2/L3 frozen after any L2/L3 loss
input double InpSniperADXStrong    = 28.0; // ADX must exceed this for any L2/L3 entry
input int    InpSniperADXSpikeBars = 5;    // Look-back bars for fake-breakout ADX spike
input double InpSniperADXSpikeMin  = 16.0; // If ADX was below this N bars ago → suspect spike
input double InpSniperMaxWickRatio = 0.45; // Max wick/range ratio on entry candle (L2/L3 only)

input group "=== V15: DRAWDOWN CIRCUIT BREAKER ==="
input bool   InpUseDDProtection = true;   // Enable global drawdown circuit breaker
input double InpMaxDailyLossPct = 20.0;   // Halt today if daily balance loss exceeds this %
input double InpMaxPeakDDPct    = 30.0;   // Halt N hours if balance drops this % from peak
input int    InpDDHaltHours     = 24;     // Hours to block all new entries after peak DD breach

input group "=== V16: ELITE SNIPER (L4) ==="
input bool   InpEnableL4        = true;   // Enable Level 4 Elite Sniper tier
input double InpL4RSIExtreme    = 22.0;   // RSI below this (BUY) / above 100-this (SELL) for L4
input double InpL4ADXMin        = 40.0;   // ADX must exceed this for L4 (institutional momentum)

input group "=== V18: CORE 1 – EQUITY GUARD ==="
input bool   InpUseEquityGuard  = true;   // Monitor open equity; close all + halt if drops too far
input double InpMaxEquityDDPct  = 25.0;   // Max allowed equity drop from session equity peak (%)
input int    InpEquityHaltHours = 4;      // Hours to halt new entries after equity guard fires

input group "=== V18: CORE 2 – CONSECUTIVE LOSS SCALER ==="
input bool   InpUseLossScaler   = true;   // Reduce risk % after consecutive losses (Kelly-inspired)

input group "=== V18: CORE 3 – FRIDAY/WEEKEND PROTECTION ==="
input bool   InpUseFridayClose  = true;   // Auto-close all positions at Friday closing hour
input int    InpFridayCloseHour = 21;     // Server hour on Friday to close all + block new entries
input int    InpMondayOpenHour  = 1;      // Server hour on Monday to resume trading

input group "=== V19: MULTI-PAIR AUTO-CONFIG ==="
input bool   InpAutoSymbolConfig  = true;  // Auto-detect symbol (Gold/Forex) and set pip/spread/SL/TP params
input string InpAllowedSymbols    = "GOLD#,EURUSD,USDJPY,GBPUSD,AUDUSD,USDCAD,USDCHF,NZDUSD,EURGBP,EURJPY,GBPJPY"; // Comma-separated list of allowed symbols

//--- V20 INPUT PARAMETERS (new — all default to backwards-compatible values)
input group "=== V20: REGIME ENGINE ==="
input bool   InpV20UseRegimeFilter = true;  // Enable V20 regime gating (false = exact V19 behaviour)
input double InpV20MinRegimeConf   = 0.55;  // Min regime confidence to allow any new entry (0–1)
input double InpV20ChaosATRMult    = 3.0;   // ATR > N × avg = CHAOS (all engines silenced)
input double InpV20TrendADXMin     = 25.0;  // ADX above this = TREND regime
input double InpV20RangeADXMax     = 20.0;  // ADX below this = RANGE regime

input group "=== V20: TREND-MOMENTUM ENGINE ==="
input bool   InpV20UseTrendEngine  = true;  // Enable Trend-Momentum engine in TREND regime
input int    InpV20FastEMAPeriod   = 21;    // Fast EMA period (M5 timeframe)
input int    InpV20SlowEMAPeriod   = 50;    // Slow EMA period (M5 timeframe)

input group "=== V20: ENGINE HEALTH ==="
input int    InpV20ShutLosses      = 3;     // Consecutive losses to temporarily shut down an engine
input int    InpV20RecoveryBars    = 50;    // New bars before a shutdown engine is re-enabled

//--- GLOBALS (V19 — unchanged)
CTrade trade;
int handleBB, handleRSI, handleADX, handleATR;
int handleHTF_Fast, handleHTF_Slow;
double stepVolume, minVolume, maxVolume;

// Pending signal state
bool     g_PendingSignal  = false;
int      g_PendingDir     = 0;
double   g_PendingRisk    = 0.0;
datetime g_PendingExpiry  = 0;

// Re-entry state
bool     g_ReentryArmed   = false;
int      g_ReentryDir     = 0;
datetime g_ReentryExpiry  = 0;
int      g_LastPosCount   = 0;

// L2/L3 Survival Mode state
datetime g_L3LastTime          = 0;
datetime g_L23LossCooldownEnd  = 0;

// V15 – Drawdown Circuit Breaker state
double   g_PeakBalance    = 0.0;
datetime g_DDHaltUntil    = 0;
double   g_DayOpenBalance = 0.0;
datetime g_DayOpenTime    = 0;

// V15 – Tick-level momentum tracker
double   g_LastTickBid = 0.0;
int      g_TicksBull   = 0;
int      g_TicksBear   = 0;
int      g_TicksWindow = 0;

// V18 Core 1 – Real-Time Equity Guard
double   g_PeakEquity      = 0.0;
datetime g_EquityHaltUntil = 0;

// V18 Core 2 – Consecutive Loss Risk Scaler
int      g_ConsecLosses = 0;

// V19 – Multi-Pair Auto-Config: effective runtime parameters
double g_PipMult;
double g_SLPips;
double g_TPPips;
double g_PartialTPPips;
double g_BETriggerPips;
double g_BELockPips;
double g_TrailDistPips;
double g_TrailStepPips;
int    g_MaxSpread;
double g_RSIOversold;
double g_RSIOverbought;
double g_RSIStaleOversold;
double g_RSIStaleOverbought;
double g_ADXMedium;
double g_ADXStrong;
double g_L4RSIExtreme;

//--- GLOBALS (V20 — new)
int    handleV20FastEMA;        // M5 fast EMA handle (TrendMomentum engine)
int    handleV20SlowEMA;        // M5 slow EMA handle (TrendMomentum engine)

ENUM_REGIME_V20 g_V20Regime;   // Current classified regime
double          g_V20RegConf;  // Current regime confidence (0–1)
ENUM_REGIME_V20 g_V20LastLoggedRegime;
double          g_V20LastLoggedConf;

// Engine health — mean-reversion
int      g_V20MRLosses   = 0;
bool     g_V20MRShutdown = false;
int      g_V20MRBars     = 0;

// Engine health — trend-momentum
int      g_V20TMLosses   = 0;
bool     g_V20TMShutdown = false;
int      g_V20TMBars     = 0;

datetime g_V20LastBarTime  = 0;
datetime g_V20LastDealScan = 0;

// Tag flag for ExecuteHFTOrder: 0=MR (V19 default), 1=TM (V20 Trend-Momentum)
int      g_V20ActiveEngine = 0;

//+------------------------------------------------------------------+
//| Forward declarations (V20 only — V19 helpers defined inline)     |
//+------------------------------------------------------------------+
void    ClassifyRegimeV20(ENUM_REGIME_V20 &regime, double &confidence);
void    RunTrendMomentumEngineV20(double Ask, double Bid, double spread, double slPoints,
                                   double adx, double adxPrev, double plus, double minus,
                                   bool adxRising, bool htfBullish, bool htfBearish);
bool    V20IsEngineShutdown(ENUM_ENGINE_V20 eng);
void    V20UpdateBarCounter();
void    V20ScanClosedDeals();

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // V19.1 – Symbol allowlist guard
   if(StringLen(InpAllowedSymbols) > 0)
   {
      string symUpper = _Symbol;
      StringToUpper(symUpper);
      string allowedUpper = InpAllowedSymbols;
      StringToUpper(allowedUpper);

      bool found = false;
      string parts[];
      int n = StringSplit(allowedUpper, ',', parts);
      for(int k = 0; k < n; k++)
      {
         StringTrimLeft(parts[k]);
         StringTrimRight(parts[k]);
         if(StringFind(symUpper, parts[k]) >= 0 || StringFind(parts[k], symUpper) >= 0)
         { found = true; break; }
      }
      if(!found)
      {
         PrintFormat("V20 AllowList: %s NOT in allowed list (%s) – EA not started.", _Symbol, InpAllowedSymbols);
         return INIT_FAILED;
      }
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpMaxSlippage);
   trade.SetTypeFilling(SYMBOL_FILLING_IOC);

   stepVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   minVolume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   maxVolume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   // V19 indicator handles
   handleBB       = iBands(_Symbol, _Period, 20, 0, 2.0, PRICE_CLOSE);
   handleRSI      = iRSI(_Symbol, _Period, 7, PRICE_CLOSE);
   handleADX      = iADX(_Symbol, _Period, 14);
   handleATR      = iATR(_Symbol, _Period, 14);
   handleHTF_Fast = iMA(_Symbol, InpHTF, InpHTF_FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleHTF_Slow = iMA(_Symbol, InpHTF, InpHTF_SlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(handleBB == INVALID_HANDLE || handleRSI == INVALID_HANDLE ||
      handleADX == INVALID_HANDLE || handleATR == INVALID_HANDLE ||
      handleHTF_Fast == INVALID_HANDLE || handleHTF_Slow == INVALID_HANDLE)
   { Print("V20: V19 indicator handle failed – EA not started."); return INIT_FAILED; }

   // V20: EMA handles for Trend-Momentum engine
   handleV20FastEMA = iMA(_Symbol, _Period, InpV20FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   handleV20SlowEMA = iMA(_Symbol, _Period, InpV20SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(handleV20FastEMA == INVALID_HANDLE || handleV20SlowEMA == INVALID_HANDLE)
   { Print("V20: EMA handles failed – EA not started."); return INIT_FAILED; }

   // Reset V19 precision timing state
   g_PendingSignal = false; g_PendingDir = 0; g_PendingRisk = 0.0; g_PendingExpiry = 0;
   g_ReentryArmed  = false; g_ReentryDir = 0; g_ReentryExpiry = 0; g_LastPosCount  = 0;

   // Reset L2/L3 survival state
   g_L3LastTime = 0; g_L23LossCooldownEnd = 0;

   // Reset V15 drawdown state
   g_PeakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_DDHaltUntil = 0; g_DayOpenBalance = AccountInfoDouble(ACCOUNT_BALANCE); g_DayOpenTime = 0;

   // Reset V15 tick momentum
   g_LastTickBid = 0.0; g_TicksBull = 0; g_TicksBear = 0; g_TicksWindow = 0;

   // Reset V18 equity guard + loss scaler
   g_PeakEquity = AccountInfoDouble(ACCOUNT_EQUITY); g_EquityHaltUntil = 0; g_ConsecLosses = 0;

   // V19 symbol profile
   InitSymbolProfile();

   // Reset V20 state
   g_V20Regime            = REGIME_V20_RANGE;
   g_V20RegConf           = 0.0;
   g_V20LastLoggedRegime  = REGIME_V20_CHAOS;
   g_V20LastLoggedConf    = 0.0;
   g_V20MRLosses          = 0; g_V20MRShutdown = false; g_V20MRBars = 0;
   g_V20TMLosses          = 0; g_V20TMShutdown = false; g_V20TMBars = 0;
   g_V20LastBarTime       = 0;
   g_V20LastDealScan      = 0;
   g_V20ActiveEngine      = 0;

   PrintFormat("SCALP GOLDEA V20.0 initialized. Symbol=%s TF=%s HTF=%s RegimeFilter=%s",
               _Symbol, EnumToString(_Period), EnumToString(InpHTF),
               InpV20UseRegimeFilter ? "ON" : "OFF");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(handleBB);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleADX);
   IndicatorRelease(handleATR);
   IndicatorRelease(handleHTF_Fast);
   IndicatorRelease(handleHTF_Slow);
   IndicatorRelease(handleV20FastEMA);  // V20
   IndicatorRelease(handleV20SlowEMA); // V20
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdateTickMomentum();   // V15: first – lowest latency tick counters
   CheckEquityGuard();     // V18 Core 1: force-close if floating equity drops too far
   CheckFridayClose();     // V18 Core 3: auto-close on Friday
   ManageHFTExits();
   CheckReentryArm();      // detect stop-outs; arm second-chance re-entry

   // V20: bar counter drives engine recovery — runs every tick, low cost
   V20UpdateBarCounter();

   if(IsGlobalStopped())  return;  // V15: circuit breaker
   if(IsEquityHalted())   return;  // V18 Core 1: equity guard halt
   if(IsWeekendBlocked()) return;  // V18 Core 3: weekend protection
   if(!IsTradingTime())   return;
   if(DailyLimitsReached()) return;
   if(PositionsTotal() > 0) return;

   double Ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double Bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = (Ask - Bid) / _Point;

   // ── V20: REGIME CLASSIFICATION ────────────────────────────────────
   if(InpV20UseRegimeFilter)
   {
      ClassifyRegimeV20(g_V20Regime, g_V20RegConf);

      // Log regime changes for transparency (one line per change)
      if(g_V20Regime != g_V20LastLoggedRegime ||
         MathAbs(g_V20RegConf - g_V20LastLoggedConf) > 0.10)
      {
         string regName = (g_V20Regime == REGIME_V20_RANGE)      ? "RANGE"      :
                          (g_V20Regime == REGIME_V20_TREND)      ? "TREND"      :
                          (g_V20Regime == REGIME_V20_TRANSITION) ? "TRANSITION" : "CHAOS";
         PrintFormat("V20 Regime: %s  Conf=%.2f", regName, g_V20RegConf);
         g_V20LastLoggedRegime = g_V20Regime;
         g_V20LastLoggedConf   = g_V20RegConf;
      }

      // Below confidence threshold → no new entries this tick
      if(g_V20RegConf < InpV20MinRegimeConf) return;

      // CHAOS regime → silence all engines; exits already managed above
      if(g_V20Regime == REGIME_V20_CHAOS) return;
   }

   // ── PENDING SIGNAL RETRY (V19 unchanged) ─────────────────────────
   if(g_PendingSignal)
   {
      if(TimeCurrent() > g_PendingExpiry)
         ClearPending();
      else if(spread <= g_MaxSpread && TryPendingEntry(Ask, Bid))
         return;
   }

   // ── RE-ENTRY (V19 unchanged) ──────────────────────────────────────
   if(InpEnableReentry && g_ReentryArmed)
   {
      if(TimeCurrent() > g_ReentryExpiry)
         g_ReentryArmed = false;
      else if(spread <= g_MaxSpread && TryReentry(Ask, Bid))
         return;
   }

   // ── BASE INDICATORS (V19 unchanged) ──────────────────────────────
   double bbUpper[], bbLower[], rsi[], adxMain[], adxPlus[], adxMinus[];
   ArraySetAsSeries(bbUpper, true); ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(rsi, true);     ArraySetAsSeries(adxMain, true);
   ArraySetAsSeries(adxPlus, true); ArraySetAsSeries(adxMinus, true);

   double htfFast[], htfSlow[];
   ArraySetAsSeries(htfFast, true); ArraySetAsSeries(htfSlow, true);

   if(CopyBuffer(handleBB,       1, 0, 3, bbUpper) < 3) return;
   if(CopyBuffer(handleBB,       2, 0, 3, bbLower) < 3) return;
   if(CopyBuffer(handleRSI,      0, 0, 3, rsi)     < 3) return;
   if(CopyBuffer(handleADX,      0, 0, 3, adxMain) < 3) return;
   if(CopyBuffer(handleADX,      1, 0, 3, adxPlus) < 3) return;
   if(CopyBuffer(handleADX,      2, 0, 3, adxMinus)< 3) return;
   if(CopyBuffer(handleHTF_Fast, 0, 0, 2, htfFast) < 2) return;
   if(CopyBuffer(handleHTF_Slow, 0, 0, 2, htfSlow) < 2) return;

   double adx     = adxMain[1];
   double adxPrev = adxMain[2];
   double plus    = adxPlus[1];
   double minus   = adxMinus[1];

   bool adxRising    = (adx > adxPrev);
   bool htfBullish   = (htfFast[1] > htfSlow[1]);
   bool htfBearish   = (htfFast[1] < htfSlow[1]);

   double close1 = iClose(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol,  _Period, 1);
   double high1  = iHigh(_Symbol,  _Period, 1);
   double low1   = iLow(_Symbol,   _Period, 1);
   double close2 = iClose(_Symbol, _Period, 2);
   double high2  = iHigh(_Symbol,  _Period, 2);
   double low2   = iLow(_Symbol,   _Period, 2);

   bool bullishCandle      = (close1 > open1);
   bool bearishCandle      = (close1 < open1);
   bool strongBuyReversal  = (close1 > close2) && (high1 > high2);
   bool strongSellReversal = (close1 < close2) && (low1  < low2);

   double slPoints = g_SLPips * g_PipMult;

   // ── V20: ENGINE ROUTING ───────────────────────────────────────────
   // Determine which engines are permitted based on regime.
   // When InpV20UseRegimeFilter is false, V20 gating is OFF and MR engine
   // always runs — identical to V19.
   bool mrAllowed = !InpV20UseRegimeFilter ||
                    (g_V20Regime == REGIME_V20_RANGE ||
                     g_V20Regime == REGIME_V20_TRANSITION);

   // V20 hard rule: mean-reversion is BLOCKED during strong TREND (no override)
   if(InpV20UseRegimeFilter && g_V20Regime == REGIME_V20_TREND)
      mrAllowed = false;

   bool mrActive  = mrAllowed && !V20IsEngineShutdown(ENG_V20_MEAN_REVERSION);

   bool tmAllowed = InpV20UseTrendEngine &&
                    (!InpV20UseRegimeFilter || g_V20Regime == REGIME_V20_TREND);
   bool tmActive  = tmAllowed && !V20IsEngineShutdown(ENG_V20_TREND_MOMENTUM);

   // ── MEAN-REVERSION ENGINE (V19 BUY scoring — exact copy) ─────────
   if(mrActive)
   {
      // ── BUY SCORING ENGINE ──────────────────────────────────────────
      if(low1 <= bbLower[1] && rsi[1] < g_RSIOversold && bullishCandle && strongBuyReversal)
      {
         double scoreRisk = InpRiskLevel1;

         if(htfBullish)
         {
            int score = 0;
            if(adx > g_ADXMedium) score++;
            if(adx > g_ADXStrong) score++;
            if(adxRising)         score++;

            if(score == 3)
            {
               if(InpEnableL4 && rsi[1] < g_L4RSIExtreme &&
                  adx > InpL4ADXMin && TickMomentumBias() == 1)
                  scoreRisk = InpRiskLevel4;
               else
                  scoreRisk = InpRiskLevel3;
            }
            else if(score == 2) scoreRisk = InpRiskLevel2;
         }

         // V20 TRANSITION safety: demote MR to L1 only (extra caution in mixed regime)
         if(InpV20UseRegimeFilter && g_V20Regime == REGIME_V20_TRANSITION)
            scoreRisk = InpRiskLevel1;

         if(scoreRisk >= InpRiskLevel2 && !IsL23SniperAllowed(ORDER_TYPE_BUY, scoreRisk))
            scoreRisk = InpRiskLevel1;

         if(spread > g_MaxSpread)                                 { StorePending(1, scoreRisk);  return; }
         if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_BUY)) { StorePending(1, scoreRisk);  return; }
         if(IsLargeCandle())                                       { StorePending(1, scoreRisk);  return; }
         if(adx < InpADXDelayMin)                                  { StorePending(1, scoreRisk);  return; }
         if(!IsEntryLocationOK(ORDER_TYPE_BUY, Ask))               { StorePending(1, scoreRisk);  return; }
         if(!IsSignalAlignedWithTick(ORDER_TYPE_BUY))              { StorePending(1, scoreRisk);  return; }

         g_V20ActiveEngine = 0;  // MR engine tag
         ExecuteHFTOrder(ORDER_TYPE_BUY, Ask, slPoints, scoreRisk);
         ClearPending();
         return;
      }

      // ── SELL SCORING ENGINE ─────────────────────────────────────────
      if(high1 >= bbUpper[1] && rsi[1] > g_RSIOverbought && bearishCandle && strongSellReversal)
      {
         double scoreRisk = InpRiskLevel1;

         if(htfBearish)
         {
            int score = 0;
            if(adx > g_ADXMedium) score++;
            if(adx > g_ADXStrong) score++;
            if(adxRising)         score++;

            if(score == 3)
            {
               if(InpEnableL4 && rsi[1] > (100.0 - g_L4RSIExtreme) &&
                  adx > InpL4ADXMin && TickMomentumBias() == -1)
                  scoreRisk = InpRiskLevel4;
               else
                  scoreRisk = InpRiskLevel3;
            }
            else if(score == 2) scoreRisk = InpRiskLevel2;
         }

         // V20 TRANSITION safety: demote MR to L1 only
         if(InpV20UseRegimeFilter && g_V20Regime == REGIME_V20_TRANSITION)
            scoreRisk = InpRiskLevel1;

         if(scoreRisk >= InpRiskLevel2 && !IsL23SniperAllowed(ORDER_TYPE_SELL, scoreRisk))
            scoreRisk = InpRiskLevel1;

         if(spread > g_MaxSpread)                                  { StorePending(-1, scoreRisk); return; }
         if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_SELL)) { StorePending(-1, scoreRisk); return; }
         if(IsLargeCandle())                                        { StorePending(-1, scoreRisk); return; }
         if(adx < InpADXDelayMin)                                   { StorePending(-1, scoreRisk); return; }
         if(!IsEntryLocationOK(ORDER_TYPE_SELL, Bid))               { StorePending(-1, scoreRisk); return; }
         if(!IsSignalAlignedWithTick(ORDER_TYPE_SELL))              { StorePending(-1, scoreRisk); return; }

         g_V20ActiveEngine = 0;  // MR engine tag
         ExecuteHFTOrder(ORDER_TYPE_SELL, Bid, slPoints, scoreRisk);
         ClearPending();
         return;
      }
   }

   // ── TREND-MOMENTUM ENGINE (V20 NEW — TREND regime only) ──────────
   if(tmActive)
   {
      RunTrendMomentumEngineV20(Ask, Bid, spread, slPoints,
                                 adx, adxPrev, plus, minus, adxRising,
                                 htfBullish, htfBearish);
   }
}

//+------------------------------------------------------------------+
//| V20: REGIME CLASSIFICATION ENGINE                                |
//| Priority order: CHAOS → TREND → RANGE → TRANSITION              |
//| Each regime produces a continuous confidence score (0–1).        |
//| Same inputs always produce the same label (deterministic).       |
//+------------------------------------------------------------------+
void ClassifyRegimeV20(ENUM_REGIME_V20 &regime, double &confidence)
{
   regime     = REGIME_V20_RANGE;
   confidence = 0.0;

   const int N = 10;
   double adxMain[], adxPlus[], adxMinus[], atr[];
   ArraySetAsSeries(adxMain, true); ArraySetAsSeries(adxPlus, true);
   ArraySetAsSeries(adxMinus, true); ArraySetAsSeries(atr, true);

   if(CopyBuffer(handleADX, 0, 0, N, adxMain)  < N) return;
   if(CopyBuffer(handleADX, 1, 0, N, adxPlus)  < N) return;
   if(CopyBuffer(handleADX, 2, 0, N, adxMinus) < N) return;
   if(CopyBuffer(handleATR, 0, 0, N, atr)      < N) return;

   double adx     = adxMain[1];
   double adxPrev = adxMain[2];
   double plus    = adxPlus[1];
   double minus   = adxMinus[1];
   double curATR  = atr[1];

   // Average ATR over look-back (skip bar[0] — still forming)
   double avgATR = 0;
   for(int i = 1; i < N; i++) avgATR += atr[i];
   avgATR /= (N - 1.0);

   // ── Priority 1: CHAOS ─────────────────────────────────────────────
   if(avgATR > 0 && curATR > avgATR * InpV20ChaosATRMult)
   {
      regime     = REGIME_V20_CHAOS;
      confidence = MathMin(1.0, curATR / (avgATR * InpV20ChaosATRMult));
      return;
   }

   // ── Priority 2: TREND ─────────────────────────────────────────────
   if(adx > InpV20TrendADXMin)
   {
      double diDiff = MathAbs(plus - minus);
      double conf   = 0.0;
      conf += MathMin(0.50, (adx - InpV20TrendADXMin) / 20.0 * 0.50);
      conf += MathMin(0.30, diDiff / 20.0 * 0.30);
      conf += (adx > adxPrev) ? 0.20 : 0.0;   // ADX still rising adds conviction
      regime     = REGIME_V20_TREND;
      confidence = MathMin(1.0, conf);
      return;
   }

   // ── Priority 3: RANGE ─────────────────────────────────────────────
   if(adx < InpV20RangeADXMax)
   {
      double conf = 0.0;
      conf += MathMin(0.50, (InpV20RangeADXMax - adx) / 15.0 * 0.50);
      conf += (adx < adxPrev) ? 0.30 : 0.10;
      conf += 0.20;   // baseline range bonus
      regime     = REGIME_V20_RANGE;
      confidence = MathMin(1.0, conf);
      return;
   }

   // ── Priority 4: TRANSITION ────────────────────────────────────────
   double span          = InpV20TrendADXMin - InpV20RangeADXMax;
   double mid           = (InpV20TrendADXMin + InpV20RangeADXMax) / 2.0;
   double distFromCentre= MathAbs(adx - mid);
   double conf          = MathMin(0.75, 0.45 + 0.25 * (distFromCentre / MathMax(0.01, span / 2.0)));
   conf += (adx > adxPrev) ? 0.05 : 0.0;
   regime     = REGIME_V20_TRANSITION;
   confidence = MathMin(0.75, conf);  // capped: TRANSITION is inherently uncertain
}

//+------------------------------------------------------------------+
//| V20: TREND-MOMENTUM ENGINE                                       |
//| Active in TREND regime only.  Uses M5 EMA crossover + DI        |
//| dominance + H4 macro alignment.  Preserves all V19 precision     |
//| gates: spread, volatility, large-candle, tick-momentum.          |
//+------------------------------------------------------------------+
void RunTrendMomentumEngineV20(double Ask, double Bid, double spread, double slPoints,
                                double adx, double adxPrev, double plus, double minus,
                                bool adxRising, bool htfBullish, bool htfBearish)
{
   // Read M5 EMA buffers
   double fastEMA[], slowEMA[];
   ArraySetAsSeries(fastEMA, true); ArraySetAsSeries(slowEMA, true);
   if(CopyBuffer(handleV20FastEMA, 0, 0, 3, fastEMA) < 3) return;
   if(CopyBuffer(handleV20SlowEMA, 0, 0, 3, slowEMA) < 3) return;

   // EMA crossover on closed bar[1] (bar[2]→bar[1] transition)
   bool emaBullCross = (fastEMA[1] > slowEMA[1]) && (fastEMA[2] <= slowEMA[2]);
   bool emaBearCross = (fastEMA[1] < slowEMA[1]) && (fastEMA[2] >= slowEMA[2]);
   // Sustained alignment without a fresh cross
   bool emaBullAlign = (fastEMA[1] > slowEMA[1]) && (plus > minus);
   bool emaBearAlign = (fastEMA[1] < slowEMA[1]) && (minus > plus);

   // ── BUY: EMA bullish + DI+ dominant + H4 bullish + ADX rising ────
   if((emaBullCross || emaBullAlign) && htfBullish && adxRising && plus > minus)
   {
      // Risk tier: L2 base, L3 with strong DI spread, L4 with elite tick confirmation
      double scoreRisk = InpRiskLevel2;   // Trend trades always start at L2 minimum
      if(adx > g_ADXStrong && (plus - minus) > 10.0)
         scoreRisk = InpRiskLevel3;
      if(InpEnableL4 && adx > InpL4ADXMin && TickMomentumBias() == 1)
         scoreRisk = InpRiskLevel4;

      // Survival mode gate (L2/L3 daily/weekly caps still apply)
      if(scoreRisk >= InpRiskLevel2 && !IsL23SniperAllowed(ORDER_TYPE_BUY, scoreRisk))
         scoreRisk = InpRiskLevel2;   // Keep L2 minimum — this is a trend trade, never demote to L1

      // V19 precision gates — same rules, no exceptions for V20
      if(spread > g_MaxSpread)                                 { StorePending(1, scoreRisk);  return; }
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_BUY)) { StorePending(1, scoreRisk);  return; }
      if(IsLargeCandle())                                       { StorePending(1, scoreRisk);  return; }
      if(adx < InpADXDelayMin)                                  { StorePending(1, scoreRisk);  return; }
      if(!IsSignalAlignedWithTick(ORDER_TYPE_BUY))              { StorePending(1, scoreRisk);  return; }

      g_V20ActiveEngine = 1;   // Tag as TM engine for deal scanning
      ExecuteHFTOrder(ORDER_TYPE_BUY, Ask, slPoints, scoreRisk);
      g_V20ActiveEngine = 0;
      ClearPending();
      return;
   }

   // ── SELL: EMA bearish + DI- dominant + H4 bearish + ADX rising ───
   if((emaBearCross || emaBearAlign) && htfBearish && adxRising && minus > plus)
   {
      double scoreRisk = InpRiskLevel2;
      if(adx > g_ADXStrong && (minus - plus) > 10.0)
         scoreRisk = InpRiskLevel3;
      if(InpEnableL4 && adx > InpL4ADXMin && TickMomentumBias() == -1)
         scoreRisk = InpRiskLevel4;

      if(scoreRisk >= InpRiskLevel2 && !IsL23SniperAllowed(ORDER_TYPE_SELL, scoreRisk))
         scoreRisk = InpRiskLevel2;

      if(spread > g_MaxSpread)                                  { StorePending(-1, scoreRisk); return; }
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_SELL)) { StorePending(-1, scoreRisk); return; }
      if(IsLargeCandle())                                        { StorePending(-1, scoreRisk); return; }
      if(adx < InpADXDelayMin)                                   { StorePending(-1, scoreRisk); return; }
      if(!IsSignalAlignedWithTick(ORDER_TYPE_SELL))              { StorePending(-1, scoreRisk); return; }

      g_V20ActiveEngine = 1;   // Tag as TM engine
      ExecuteHFTOrder(ORDER_TYPE_SELL, Bid, slPoints, scoreRisk);
      g_V20ActiveEngine = 0;
      ClearPending();
      return;
   }
}

//+------------------------------------------------------------------+
//| V20: ENGINE HEALTH — SHUTDOWN CHECK + BAR-COUNT RECOVERY         |
//+------------------------------------------------------------------+
bool V20IsEngineShutdown(ENUM_ENGINE_V20 eng)
{
   if(eng == ENG_V20_MEAN_REVERSION)
   {
      if(!g_V20MRShutdown) return false;
      if(g_V20MRBars >= InpV20RecoveryBars)
      {
         g_V20MRShutdown = false;
         g_V20MRLosses   = 0;
         Print("V20: MeanReversion engine RECOVERED (bars elapsed)");
      }
      return g_V20MRShutdown;
   }
   if(eng == ENG_V20_TREND_MOMENTUM)
   {
      if(!g_V20TMShutdown) return false;
      if(g_V20TMBars >= InpV20RecoveryBars)
      {
         g_V20TMShutdown = false;
         g_V20TMLosses   = 0;
         Print("V20: TrendMomentum engine RECOVERED (bars elapsed)");
      }
      return g_V20TMShutdown;
   }
   return false;
}

//+------------------------------------------------------------------+
//| V20: BAR COUNTER — new-bar detection, increments recovery bars   |
//+------------------------------------------------------------------+
void V20UpdateBarCounter()
{
   datetime barTime = iTime(_Symbol, _Period, 0);
   if(g_V20LastBarTime == 0) { g_V20LastBarTime = barTime; return; }
   if(barTime == g_V20LastBarTime) return;

   g_V20LastBarTime = barTime;

   // Increment recovery counters only for engines that are shut down
   if(g_V20MRShutdown) g_V20MRBars++;
   if(g_V20TMShutdown) g_V20TMBars++;

   // Scan closed deals once per bar (lower overhead than every tick)
   V20ScanClosedDeals();
}

//+------------------------------------------------------------------+
//| V20: SCAN CLOSED DEALS — update per-engine health counters       |
//| Identifies the originating engine by the "V20_TM|" comment tag. |
//| Deals without that tag are attributed to the MR engine.         |
//+------------------------------------------------------------------+
void V20ScanClosedDeals()
{
   if(!InpV20UseRegimeFilter) return;   // Health tracking only meaningful when regime is active

   datetime now  = TimeCurrent();
   datetime from = (g_V20LastDealScan > 0) ? g_V20LastDealScan : (now - 86400);

   HistorySelect(from, now);
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong dk = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(dk, DEAL_MAGIC) != InpMagic)        continue;
      if(HistoryDealGetInteger(dk, DEAL_ENTRY) != DEAL_ENTRY_OUT)  continue;
      if((datetime)HistoryDealGetInteger(dk, DEAL_TIME) <= from)   continue;

      double profit  = HistoryDealGetDouble(dk, DEAL_PROFIT);
      bool   isLoss  = (profit < 0);
      string cmt     = HistoryDealGetString(dk, DEAL_COMMENT);
      bool   isTM    = (StringFind(cmt, "V20_TM|") >= 0);

      if(isTM)
      {
         if(isLoss)
         {
            g_V20TMLosses++;
            if(g_V20TMLosses >= InpV20ShutLosses && !g_V20TMShutdown)
            {
               g_V20TMShutdown = true;
               g_V20TMBars     = 0;
               PrintFormat("V20: TrendMomentum SHUTDOWN after %d consecutive losses", g_V20TMLosses);
            }
         }
         else
            g_V20TMLosses = 0;   // Win resets TM streak
      }
      else
      {
         if(isLoss)
         {
            g_V20MRLosses++;
            if(g_V20MRLosses >= InpV20ShutLosses && !g_V20MRShutdown)
            {
               g_V20MRShutdown = true;
               g_V20MRBars     = 0;
               PrintFormat("V20: MeanReversion SHUTDOWN after %d consecutive losses", g_V20MRLosses);
            }
         }
         else
            g_V20MRLosses = 0;   // Win resets MR streak
      }
   }

   g_V20LastDealScan = now;
}

//+------------------------------------------------------------------+
//| EXECUTION: Fire Scalp Payload with Lot Calculation               |
//| FIX 1 – Micro-Account Lot Boost included                         |
//| CHALLENGE – 30% risk, adaptive TP when enabled                   |
//| V20 ADD – "V20_TM|" comment prefix when g_V20ActiveEngine == 1  |
//+------------------------------------------------------------------+
void ExecuteHFTOrder(ENUM_ORDER_TYPE type, double price, double slPoints, double assignedRisk)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double freeMargin = AccountInfoDouble(ACCOUNT_FREEMARGIN);

   double effectiveRisk   = assignedRisk;
   double effectiveSL     = slPoints;
   double effectiveTPPips = g_TPPips;

   if(InpChallengeMode)
   {
      effectiveRisk   = InpChallengeRisk;
      effectiveTPPips = (balance < InpChallengeThreshold)
                        ? InpChallengeTP_Early : InpChallengeTP_Late;
   }
   else
      effectiveRisk *= GetRiskScaler();   // V18 Core 2

   effectiveSL = slPoints;
   if(InpChallengeMode) effectiveSL = InpChallengeSL * g_PipMult;

   double moneyRisk  = balance * (effectiveRisk / 100.0);
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double lossPerLot = (effectiveSL * _Point / tickSize) * tickValue;
   if(lossPerLot <= 0) return;

   double rawLot        = moneyRisk / lossPerLot;
   double calculatedLot = MathFloor(rawLot / stepVolume) * stepVolume;
   if(calculatedLot > maxVolume) calculatedLot = maxVolume;
   if(calculatedLot < minVolume) calculatedLot = minVolume;

   // FIX 1 – Micro-Account Lot Boost
   bool isMicroAccount = (rawLot <= minVolume);
   if(isMicroAccount)
   {
      double boostMult = 1.0;
      if(assignedRisk >= InpRiskLevel4)      boostMult = InpChallengeMode ? 6.0 : 4.0;
      else if(assignedRisk >= InpRiskLevel3) boostMult = InpChallengeMode ? 5.0 : 3.0;
      else if(assignedRisk >= InpRiskLevel2) boostMult = InpChallengeMode ? 3.0 : 2.0;
      calculatedLot = MathFloor((minVolume * boostMult) / stepVolume) * stepVolume;
      if(calculatedLot > maxVolume) calculatedLot = maxVolume;
      if(calculatedLot < minVolume) calculatedLot = minVolume;
   }

   // Margin safety check
   double marginReq = 0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, calculatedLot, price, marginReq))
   {
      if(marginReq > freeMargin * 0.90)
      {
         double reduction = (freeMargin * 0.90) / marginReq;
         calculatedLot = MathFloor((calculatedLot * reduction) / stepVolume) * stepVolume;
      }
   }
   if(calculatedLot < minVolume) return;

   // Build comment label
   string comment;
   if(InpChallengeMode)
   {
      if(assignedRisk >= InpRiskLevel4)      comment = "CHAL_EliteL4";
      else if(assignedRisk >= InpRiskLevel3) comment = "CHAL_L3";
      else if(assignedRisk >= InpRiskLevel2) comment = "CHAL_L2";
      else                                   comment = "CHAL_L1";
   }
   else
   {
      if(assignedRisk >= InpRiskLevel4)      comment = "V16_EliteL4";
      else if(assignedRisk >= InpRiskLevel3) comment = "V10_SniperL3";
      else if(assignedRisk >= InpRiskLevel2) comment = "V10_SniperL2";
      else                                   comment = "V10_ScalpL1";
   }

   // V20: prefix trend-momentum trades so deal scanner can attribute them correctly
   if(g_V20ActiveEngine == 1) comment = "V20_TM|" + comment;

   // V14 – record L3 activation time
   if(assignedRisk >= InpRiskLevel3) g_L3LastTime = TimeCurrent();

   double sl, tp;
   if(type == ORDER_TYPE_BUY)
   {
      sl = price - effectiveSL * _Point;
      tp = price + (effectiveTPPips * g_PipMult * _Point);
      trade.Buy(calculatedLot, _Symbol, price, sl, tp, comment);
   }
   else
   {
      sl = price + effectiveSL * _Point;
      tp = price - (effectiveTPPips * g_PipMult * _Point);
      trade.Sell(calculatedLot, _Symbol, price, sl, tp, comment);
   }
}

//+------------------------------------------------------------------+
//| Staged Exits: Partial TP, Delayed Breakeven, Relaxed Trailing    |
//+------------------------------------------------------------------+
void ManageHFTExits()
{
   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double partialTPDist = g_PartialTPPips * g_PipMult * _Point;
   double beTriggerDist = g_BETriggerPips * g_PipMult * _Point;
   double beLockDist    = g_BELockPips    * g_PipMult * _Point;
   double trailDist     = g_TrailDistPips * g_PipMult * _Point;
   double trailStep     = g_TrailStepPips * g_PipMult * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      double currentSL = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double volume    = PositionGetDouble(POSITION_VOLUME);
      long   posType   = PositionGetInteger(POSITION_TYPE);
      string comment   = PositionGetString(POSITION_COMMENT);

      // Partial close at TP1 (disabled in challenge mode)
      if(!InpChallengeMode && StringFind(comment, "Partial") < 0)
      {
         bool triggerPartial = (posType == POSITION_TYPE_BUY  && Bid >= openPrice + partialTPDist) ||
                               (posType == POSITION_TYPE_SELL && Ask <= openPrice - partialTPDist);
         if(triggerPartial)
         {
            double closeLot = MathFloor((volume / 2.0) / stepVolume) * stepVolume;
            if(closeLot >= minVolume) { trade.PositionClosePartial(ticket, closeLot, "V10_Partial"); continue; }
         }
      }

      // Breakeven and trailing
      if(posType == POSITION_TYPE_BUY)
      {
         if(Bid >= openPrice + beTriggerDist)
         {
            double beSL = openPrice + beLockDist;
            if(currentSL < beSL - (_Point * 10)) { trade.PositionModify(ticket, beSL, tp); continue; }
         }
         if(currentSL >= openPrice + beLockDist)
         {
            double newSL = Bid - trailDist;
            if(newSL > currentSL + trailStep) trade.PositionModify(ticket, newSL, tp);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         if(Ask <= openPrice - beTriggerDist)
         {
            double beSL = openPrice - beLockDist;
            if(currentSL > beSL + (_Point * 10) || currentSL == 0)
               { trade.PositionModify(ticket, beSL, tp); continue; }
         }
         if(currentSL <= openPrice - beLockDist && currentSL != 0)
         {
            double newSL = Ask + trailDist;
            if(newSL < currentSL - trailStep) trade.PositionModify(ticket, newSL, tp);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Volatility Filter: reject spike entries and low-body candles     |
//+------------------------------------------------------------------+
bool IsVolatilitySafe(ENUM_ORDER_TYPE type)
{
   double atrData[];
   ArraySetAsSeries(atrData, true);
   if(CopyBuffer(handleATR, 0, 0, 10, atrData) < 10) return false;

   double avgATR = 0;
   for(int i = 1; i < 10; i++) avgATR += atrData[i];
   avgATR /= 9.0;

   if(atrData[0] > avgATR * 4.0) return false;

   double body = MathAbs(iClose(_Symbol, _Period, 1) - iOpen(_Symbol, _Period, 1));
   if(atrData[0] > avgATR * 2.0)
      if(body < atrData[0] * 0.5) return false;

   return true;
}

//+------------------------------------------------------------------+
//| UTILITIES                                                        |
//+------------------------------------------------------------------+
bool DailyLimitsReached()
{
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   HistorySelect(todayStart, TimeCurrent());
   int tradesToday = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT &&
         HistoryDealGetInteger(ticket, DEAL_MAGIC) == InpMagic)
         tradesToday++;
   }
   return (tradesToday >= InpMaxTradesDay);
}

bool IsTradingTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.hour >= InpHourStart && dt.hour < InpHourEnd);
}

//+------------------------------------------------------------------+
//| PRECISION TIMING – Helper Functions (V13)                        |
//+------------------------------------------------------------------+
bool IsLargeCandle()
{
   double atrData[];
   ArraySetAsSeries(atrData, true);
   if(CopyBuffer(handleATR, 0, 0, 3, atrData) < 3) return false;
   double body1 = MathAbs(iClose(_Symbol, _Period, 1) - iOpen(_Symbol, _Period, 1));
   return (body1 > atrData[1] * InpLargeBodyMult);
}

bool IsEntryLocationOK(ENUM_ORDER_TYPE type, double currentPrice)
{
   double close1 = iClose(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol,  _Period, 1);
   double body   = MathAbs(close1 - open1);
   if(body < _Point * 10) return true;
   double chase = body * 0.30;
   if(type == ORDER_TYPE_BUY  && currentPrice > close1 + chase) return false;
   if(type == ORDER_TYPE_SELL && currentPrice < close1 - chase) return false;
   return true;
}

void StorePending(int dir, double risk)
{
   if(g_PendingSignal && g_PendingDir != dir) ClearPending();
   if(!g_PendingSignal)
   {
      g_PendingSignal = true;
      g_PendingDir    = dir;
      g_PendingRisk   = risk;
      g_PendingExpiry = TimeCurrent() + InpPendingExpireBars * PeriodSeconds(_Period);
   }
   else if(risk > g_PendingRisk)
      g_PendingRisk = risk;
}

void ClearPending()
{
   g_PendingSignal = false; g_PendingDir = 0; g_PendingRisk = 0.0; g_PendingExpiry = 0;
}

bool TryPendingEntry(double Ask, double Bid)
{
   if(!g_PendingSignal) return false;

   double bbUpper[], bbLower[], rsiArr[], adxArr[], atrCheck[];
   ArraySetAsSeries(bbUpper, true); ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(rsiArr, true);  ArraySetAsSeries(adxArr, true);
   ArraySetAsSeries(atrCheck, true);

   if(CopyBuffer(handleBB,  1, 0, 2, bbUpper)  < 2) return false;
   if(CopyBuffer(handleBB,  2, 0, 2, bbLower)  < 2) return false;
   if(CopyBuffer(handleRSI, 0, 0, 2, rsiArr)   < 2) return false;
   if(CopyBuffer(handleADX, 0, 0, 2, adxArr)   < 2) return false;
   if(CopyBuffer(handleATR, 0, 0, 2, atrCheck) < 2) return false;

   if(adxArr[1] < InpADXDelayMin) return false;
   if(IsLargeCandle())            return false;

   ENUM_ORDER_TYPE pendType = (g_PendingDir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!IsSignalAlignedWithTick(pendType)) return false;

   double slPoints = g_SLPips * g_PipMult;

   if(g_PendingDir == 1)
   {
      if(Ask > bbLower[1] + atrCheck[1] * 1.5) return false;
      if(rsiArr[1] > g_RSIStaleOversold)        return false;
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_BUY)) return false;
      if(!IsEntryLocationOK(ORDER_TYPE_BUY, Ask))              return false;
      g_V20ActiveEngine = 0;
      ExecuteHFTOrder(ORDER_TYPE_BUY, Ask, slPoints, g_PendingRisk);
      ClearPending(); return true;
   }
   else if(g_PendingDir == -1)
   {
      if(Bid < bbUpper[1] - atrCheck[1] * 1.5) return false;
      if(rsiArr[1] < g_RSIStaleOverbought)      return false;
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_SELL)) return false;
      if(!IsEntryLocationOK(ORDER_TYPE_SELL, Bid))              return false;
      g_V20ActiveEngine = 0;
      ExecuteHFTOrder(ORDER_TYPE_SELL, Bid, slPoints, g_PendingRisk);
      ClearPending(); return true;
   }
   return false;
}

void CheckReentryArm()
{
   if(!InpEnableReentry) { g_LastPosCount = 0; return; }

   int curCount = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         curCount++;
   }

   if(curCount < g_LastPosCount && !g_ReentryArmed)
   {
      datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
      HistorySelect(todayStart, TimeCurrent());

      ulong lastTicket = 0;
      int   lastReason = -1;
      long  lastType   = -1;

      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         ulong dk = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(dk, DEAL_MAGIC) != InpMagic)       continue;
         if(HistoryDealGetInteger(dk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         lastTicket = dk; lastReason = (int)HistoryDealGetInteger(dk, DEAL_REASON);
         lastType   = HistoryDealGetInteger(dk, DEAL_TYPE); break;
      }

      if(lastTicket > 0 && lastReason == DEAL_REASON_SL)
      {
         g_ReentryDir    = (lastType == DEAL_TYPE_SELL) ? 1 : -1;
         g_ReentryArmed  = true;
         g_ReentryExpiry = TimeCurrent() + 6 * PeriodSeconds(_Period);

         if(InpUseLossScaler && !InpChallengeMode) g_ConsecLosses++;

         long posId = HistoryDealGetInteger(lastTicket, DEAL_POSITION_ID);
         HistorySelect(TimeCurrent() - 7 * 86400, TimeCurrent());
         for(int j = 0; j < HistoryDealsTotal(); j++)
         {
            ulong dj = HistoryDealGetTicket(j);
            if(HistoryDealGetInteger(dj, DEAL_POSITION_ID) != posId)      continue;
            if(HistoryDealGetInteger(dj, DEAL_ENTRY) != DEAL_ENTRY_IN)    continue;
            string cmt = HistoryDealGetString(dj, DEAL_COMMENT);
            if(StringFind(cmt, "SniperL2") >= 0 || StringFind(cmt, "SniperL3") >= 0 ||
               StringFind(cmt, "EliteL4") >= 0  || StringFind(cmt, "CHAL_L2") >= 0   ||
               StringFind(cmt, "CHAL_L3") >= 0  || StringFind(cmt, "CHAL_EliteL4") >= 0)
               g_L23LossCooldownEnd = TimeCurrent() + (long)InpL23LossCooldownH * 3600;
            break;
         }
      }
      else if(lastTicket > 0)
      {
         if(InpUseLossScaler && !InpChallengeMode)
         {
            double dealProfit = HistoryDealGetDouble(lastTicket, DEAL_PROFIT);
            if(dealProfit > 0 && g_ConsecLosses > 0) g_ConsecLosses--;
         }
      }
   }
   g_LastPosCount = curCount;
}

bool TryReentry(double Ask, double Bid)
{
   if(!g_ReentryArmed) return false;

   double bbUpper[], bbLower[], rsiArr[], adxMain[];
   ArraySetAsSeries(bbUpper, true); ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(rsiArr, true);  ArraySetAsSeries(adxMain, true);

   if(CopyBuffer(handleBB,  1, 0, 3, bbUpper) < 3) return false;
   if(CopyBuffer(handleBB,  2, 0, 3, bbLower) < 3) return false;
   if(CopyBuffer(handleRSI, 0, 0, 3, rsiArr)  < 3) return false;
   if(CopyBuffer(handleADX, 0, 0, 3, adxMain) < 3) return false;

   double adx      = adxMain[1];
   bool   adxRising = (adx > adxMain[2]);
   if(adx < 20.0 || !adxRising) return false;

   ENUM_ORDER_TYPE retryType = (g_ReentryDir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!IsSignalAlignedWithTick(retryType)) return false;

   double close1 = iClose(_Symbol, _Period, 1); double open1 = iOpen(_Symbol, _Period, 1);
   double high1  = iHigh(_Symbol, _Period, 1);  double low1  = iLow(_Symbol, _Period, 1);
   double close2 = iClose(_Symbol, _Period, 2);
   double high2  = iHigh(_Symbol, _Period, 2);  double low2  = iLow(_Symbol, _Period, 2);

   bool bullishCandle      = (close1 > open1);
   bool bearishCandle      = (close1 < open1);
   bool strongBuyReversal  = (close1 > close2) && (high1 > high2);
   bool strongSellReversal = (close1 < close2) && (low1  < low2);
   double slPoints = g_SLPips * g_PipMult;

   if(g_ReentryDir == 1 &&
      low1 <= bbLower[1] && rsiArr[1] < g_RSIOversold && bullishCandle && strongBuyReversal)
   {
      if(IsLargeCandle()) return false;
      if(!IsEntryLocationOK(ORDER_TYPE_BUY, Ask)) return false;
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_BUY)) return false;
      g_V20ActiveEngine = 0;
      ExecuteHFTOrder(ORDER_TYPE_BUY, Ask, slPoints, InpRiskLevel1);
      g_ReentryArmed = false; ClearPending(); return true;
   }
   if(g_ReentryDir == -1 &&
      high1 >= bbUpper[1] && rsiArr[1] > g_RSIOverbought && bearishCandle && strongSellReversal)
   {
      if(IsLargeCandle()) return false;
      if(!IsEntryLocationOK(ORDER_TYPE_SELL, Bid)) return false;
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_SELL)) return false;
      g_V20ActiveEngine = 0;
      ExecuteHFTOrder(ORDER_TYPE_SELL, Bid, slPoints, InpRiskLevel1);
      g_ReentryArmed = false; ClearPending(); return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| L2/L3 SURVIVAL MODE – Helper Functions (V14)                     |
//+------------------------------------------------------------------+
bool IsADXSpikeFromLow()
{
   int needed = InpSniperADXSpikeBars + 2;
   double adxHist[];
   ArraySetAsSeries(adxHist, true);
   if(CopyBuffer(handleADX, 0, 0, needed, adxHist) < needed) return false;
   for(int i = 2; i <= InpSniperADXSpikeBars + 1; i++)
      if(adxHist[i] < InpSniperADXSpikeMin) return true;
   return false;
}

bool HasCleanSniperCandle(ENUM_ORDER_TYPE type)
{
   double high1  = iHigh(_Symbol, _Period, 1); double low1  = iLow(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol, _Period, 1); double close1 = iClose(_Symbol, _Period, 1);
   double range  = high1 - low1;
   if(range < _Point * 10) return true;
   double upperWick = high1 - MathMax(open1, close1);
   double lowerWick = MathMin(open1, close1) - low1;
   if(type == ORDER_TYPE_BUY  && upperWick / range > InpSniperMaxWickRatio) return false;
   if(type == ORDER_TYPE_SELL && lowerWick / range > InpSniperMaxWickRatio) return false;
   return true;
}

int CountL23TradesInPeriod(datetime from)
{
   HistorySelect(from, TimeCurrent());
   int count = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong dk = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(dk, DEAL_MAGIC) != InpMagic)      continue;
      if(HistoryDealGetInteger(dk, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      string cmt = HistoryDealGetString(dk, DEAL_COMMENT);
      if(StringFind(cmt, "SniperL2") >= 0 || StringFind(cmt, "SniperL3") >= 0 ||
         StringFind(cmt, "EliteL4") >= 0  || StringFind(cmt, "CHAL_L2") >= 0   ||
         StringFind(cmt, "CHAL_L3") >= 0  || StringFind(cmt, "CHAL_EliteL4") >= 0 ||
         StringFind(cmt, "V20_TM|") >= 0)   // V20: TM trades also count toward L2/L3 caps
         count++;
   }
   return count;
}

bool IsL23SniperAllowed(ENUM_ORDER_TYPE type, double scoreRisk)
{
   if(g_L23LossCooldownEnd > 0 && TimeCurrent() < g_L23LossCooldownEnd) return false;
   if(scoreRisk >= InpRiskLevel3 && g_L3LastTime > 0 &&
      TimeCurrent() < g_L3LastTime + (long)InpL3CooldownHours * 3600) return false;

   MqlDateTime dtNow;
   TimeToStruct(TimeCurrent(), dtNow);
   int daysToMon = (dtNow.day_of_week == 0) ? 6 : (dtNow.day_of_week - 1);
   datetime weekStart = iTime(_Symbol, PERIOD_D1, 0) - (long)daysToMon * 86400;
   if(CountL23TradesInPeriod(weekStart) >= InpL23WeeklyCap) return false;

   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(CountL23TradesInPeriod(todayStart) >= InpL23DailyCap) return false;

   double adxArr[];
   ArraySetAsSeries(adxArr, true);
   if(CopyBuffer(handleADX, 0, 0, 3, adxArr) < 3) return false;
   if(adxArr[1] < InpSniperADXStrong) return false;
   if(adxArr[1] <= adxArr[2])         return false;
   if(IsADXSpikeFromLow())            return false;
   if(!HasCleanSniperCandle(type))    return false;

   return true;
}

//+------------------------------------------------------------------+
//| V15 – Drawdown Circuit Breaker                                   |
//+------------------------------------------------------------------+
bool IsGlobalStopped()
{
   if(!InpUseDDProtection) return false;
   if(InpChallengeMode)    return false;

   double   balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(todayStart == 0) return false;

   if(balance > g_PeakBalance) g_PeakBalance = balance;
   if(g_DayOpenTime == 0 || todayStart > g_DayOpenTime)
      { g_DayOpenBalance = balance; g_DayOpenTime = todayStart; }

   if(g_DDHaltUntil > 0)
   {
      if(TimeCurrent() < g_DDHaltUntil) return true;
      g_DDHaltUntil = 0;
   }

   if(g_PeakBalance > 0.0)
   {
      double ddPct = (g_PeakBalance - balance) / g_PeakBalance * 100.0;
      if(ddPct >= InpMaxPeakDDPct)
      {
         PrintFormat("V15 Peak DD Halt: %.1f%% from $%.2f → freeze %d h", ddPct, g_PeakBalance, InpDDHaltHours);
         g_DDHaltUntil = TimeCurrent() + (long)InpDDHaltHours * 3600;
         return true;
      }
   }

   if(g_DayOpenBalance > 0.0)
   {
      double dayLossPct = (g_DayOpenBalance - balance) / g_DayOpenBalance * 100.0;
      if(dayLossPct >= InpMaxDailyLossPct)
      {
         PrintFormat("V15 Daily Loss Halt: %.1f%% → freeze until EOD", dayLossPct);
         g_DDHaltUntil = todayStart + 86400;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| V15 – Tick-Level Momentum Engine                                 |
//+------------------------------------------------------------------+
void UpdateTickMomentum()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_LastTickBid > 0.0)
   {
      if(bid > g_LastTickBid + _Point)      g_TicksBull++;
      else if(bid < g_LastTickBid - _Point) g_TicksBear++;
      g_TicksWindow++;
      if(g_TicksWindow >= 30) { g_TicksBull = 0; g_TicksBear = 0; g_TicksWindow = 0; }
   }
   g_LastTickBid = bid;
}

int TickMomentumBias()
{
   int total = g_TicksBull + g_TicksBear;
   if(total < 10) return 0;
   double ratio = (double)(g_TicksBull - g_TicksBear) / total;
   if(ratio >  0.25) return  1;
   if(ratio < -0.25) return -1;
   return 0;
}

bool IsCurrentBarAligned(ENUM_ORDER_TYPE type)
{
   double open0 = iOpen(_Symbol, _Period, 0);
   if(open0 == 0.0) return true;
   double atrData[];
   ArraySetAsSeries(atrData, true);
   if(CopyBuffer(handleATR, 0, 0, 2, atrData) < 2) return true;
   double currentPrice = (type == ORDER_TYPE_BUY)
                         ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                         : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double body0 = currentPrice - open0;
   double limit = atrData[1] * 0.25;
   if(type == ORDER_TYPE_BUY  && body0 < -limit) return false;
   if(type == ORDER_TYPE_SELL && body0 >  limit)  return false;
   return true;
}

bool IsSignalAlignedWithTick(ENUM_ORDER_TYPE type)
{
   int  bias       = TickMomentumBias();
   bool tickOK     = !((type == ORDER_TYPE_BUY  && bias == -1) ||
                       (type == ORDER_TYPE_SELL && bias ==  1));
   bool barAligned = IsCurrentBarAligned(type);
   return (tickOK || barAligned);
}

//+------------------------------------------------------------------+
//| V18 CORE 1 – Real-Time Equity Guard                              |
//+------------------------------------------------------------------+
void CheckEquityGuard()
{
   if(!InpUseEquityGuard) return;
   if(InpChallengeMode)   return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_PeakEquity) g_PeakEquity = equity;
   if(g_PeakEquity <= 0.0)   return;

   if(g_EquityHaltUntil > 0 && TimeCurrent() >= g_EquityHaltUntil)
      g_EquityHaltUntil = 0;
   if(g_EquityHaltUntil > 0) return;

   double ddPct = (g_PeakEquity - equity) / g_PeakEquity * 100.0;
   if(ddPct >= InpMaxEquityDDPct)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == InpMagic)
            trade.PositionClose(ticket, InpMaxSlippage);
      }
      g_EquityHaltUntil = TimeCurrent() + (long)InpEquityHaltHours * 3600;
      g_PeakEquity      = AccountInfoDouble(ACCOUNT_EQUITY);
      PrintFormat("V18 Equity Guard: %.1f%% open DD from $%.2f → close all, halt %d h",
                  ddPct, g_PeakEquity, InpEquityHaltHours);
   }
}

bool IsEquityHalted()
{
   if(!InpUseEquityGuard) return false;
   return (g_EquityHaltUntil > 0 && TimeCurrent() < g_EquityHaltUntil);
}

//+------------------------------------------------------------------+
//| V18 CORE 2 – Consecutive Loss Risk Scaler                        |
//+------------------------------------------------------------------+
double GetRiskScaler()
{
   if(!InpUseLossScaler)   return 1.0;
   if(g_ConsecLosses <= 0) return 1.0;
   if(g_ConsecLosses == 1) return 0.75;
   if(g_ConsecLosses == 2) return 0.50;
   return 0.25;
}

//+------------------------------------------------------------------+
//| V18 CORE 3 – Friday Auto-Close + Weekend Gap Protection          |
//+------------------------------------------------------------------+
void CheckFridayClose()
{
   if(!InpUseFridayClose) return;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == InpMagic)
            trade.PositionClose(ticket, InpMaxSlippage);
      }
   }
}

bool IsWeekendBlocked()
{
   if(!InpUseFridayClose) return false;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour) return true;
   if(dt.day_of_week == 6) return true;
   if(dt.day_of_week == 0) return true;
   if(dt.day_of_week == 1 && dt.hour < InpMondayOpenHour) return true;
   return false;
}

//+------------------------------------------------------------------+
//| V19 – Multi-Pair Auto-Config: symbol profile initialiser        |
//+------------------------------------------------------------------+
void InitSymbolProfile()
{
   g_PipMult            = InpPipMultiplier;
   g_SLPips             = InpStopLossPips;
   g_TPPips             = InpTakeProfitPips;
   g_PartialTPPips      = InpPartialTPPips;
   g_BETriggerPips      = InpBETriggerPips;
   g_BELockPips         = InpBELockPips;
   g_TrailDistPips      = InpTrailDistPips;
   g_TrailStepPips      = InpTrailStepPips;
   g_MaxSpread          = InpMaxSpread;
   g_RSIOversold        = 35.0;
   g_RSIOverbought      = 65.0;
   g_RSIStaleOversold   = 42.0;
   g_RSIStaleOverbought = 58.0;
   g_ADXMedium          = 25.0;
   g_ADXStrong          = 35.0;
   g_L4RSIExtreme       = InpL4RSIExtreme;

   if(!InpAutoSymbolConfig)
   { PrintFormat("V20 Auto-Config: DISABLED – using manual inputs (%s)", _Symbol); return; }

   string sym = _Symbol;
   StringToUpper(sym);

   if(StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0)
   {
      PrintFormat("V20 Auto-Config: GOLD profile (%s) RSI<%.0f/>%.0f ADX>%.0f/%.0f SL=%.0f TP=%.0f trail=%.0f maxSpread=%d",
                  _Symbol, g_RSIOversold, g_RSIOverbought, g_ADXMedium, g_ADXStrong,
                  g_SLPips, g_TPPips, g_TrailDistPips, g_MaxSpread);
      return;
   }

   g_PipMult = 10.0;

   if(StringFind(sym, "EURUSD") >= 0)
   {
      g_SLPips=15; g_TPPips=50; g_PartialTPPips=8;
      g_BETriggerPips=10; g_BELockPips=2; g_TrailDistPips=12; g_TrailStepPips=3; g_MaxSpread=15;
      g_RSIOversold=40; g_RSIOverbought=60; g_RSIStaleOversold=47; g_RSIStaleOverbought=53;
      g_ADXMedium=20; g_ADXStrong=28; g_L4RSIExtreme=27;
   }
   else if(StringFind(sym, "USDJPY") >= 0)
   {
      g_SLPips=15; g_TPPips=50; g_PartialTPPips=8;
      g_BETriggerPips=10; g_BELockPips=2; g_TrailDistPips=12; g_TrailStepPips=3; g_MaxSpread=15;
      g_RSIOversold=39; g_RSIOverbought=61; g_RSIStaleOversold=47; g_RSIStaleOverbought=53;
      g_ADXMedium=20; g_ADXStrong=28; g_L4RSIExtreme=27;
   }
   else if(StringFind(sym, "GBPUSD") >= 0)
   {
      g_SLPips=20; g_TPPips=60; g_PartialTPPips=10;
      g_BETriggerPips=12; g_BELockPips=3; g_TrailDistPips=15; g_TrailStepPips=4; g_MaxSpread=20;
      g_RSIOversold=38; g_RSIOverbought=62; g_RSIStaleOversold=46; g_RSIStaleOverbought=54;
      g_ADXMedium=20; g_ADXStrong=28; g_L4RSIExtreme=26;
   }
   else if(StringFind(sym, "AUDUSD") >= 0)
   {
      g_SLPips=15; g_TPPips=50; g_PartialTPPips=8;
      g_BETriggerPips=10; g_BELockPips=2; g_TrailDistPips=12; g_TrailStepPips=3; g_MaxSpread=15;
      g_RSIOversold=40; g_RSIOverbought=60; g_RSIStaleOversold=47; g_RSIStaleOverbought=53;
      g_ADXMedium=20; g_ADXStrong=28; g_L4RSIExtreme=27;
   }
   else if(StringFind(sym, "USDCAD") >= 0)
   {
      g_SLPips=18; g_TPPips=55; g_PartialTPPips=9;
      g_BETriggerPips=11; g_BELockPips=2; g_TrailDistPips=13; g_TrailStepPips=3; g_MaxSpread=20;
      g_RSIOversold=40; g_RSIOverbought=60; g_RSIStaleOversold=47; g_RSIStaleOverbought=53;
      g_ADXMedium=20; g_ADXStrong=28; g_L4RSIExtreme=27;
   }
   else if(StringFind(sym, "USDCHF") >= 0)
   {
      g_SLPips=18; g_TPPips=55; g_PartialTPPips=9;
      g_BETriggerPips=11; g_BELockPips=2; g_TrailDistPips=13; g_TrailStepPips=3; g_MaxSpread=20;
      g_RSIOversold=40; g_RSIOverbought=60; g_RSIStaleOversold=47; g_RSIStaleOverbought=53;
      g_ADXMedium=20; g_ADXStrong=28; g_L4RSIExtreme=27;
   }
   else if(StringFind(sym, "NZDUSD") >= 0)
   {
      g_SLPips=12; g_TPPips=45; g_PartialTPPips=7;
      g_BETriggerPips=8; g_BELockPips=2; g_TrailDistPips=10; g_TrailStepPips=3; g_MaxSpread=20;
      g_RSIOversold=41; g_RSIOverbought=59; g_RSIStaleOversold=48; g_RSIStaleOverbought=52;
      g_ADXMedium=19; g_ADXStrong=27; g_L4RSIExtreme=28;
   }
   else if(StringFind(sym, "EURGBP") >= 0)
   {
      g_SLPips=10; g_TPPips=35; g_PartialTPPips=6;
      g_BETriggerPips=7; g_BELockPips=1; g_TrailDistPips=8; g_TrailStepPips=2; g_MaxSpread=20;
      g_RSIOversold=42; g_RSIOverbought=58; g_RSIStaleOversold=49; g_RSIStaleOverbought=51;
      g_ADXMedium=18; g_ADXStrong=25; g_L4RSIExtreme=30;
   }
   else if(StringFind(sym, "EURJPY") >= 0)
   {
      g_SLPips=20; g_TPPips=65; g_PartialTPPips=10;
      g_BETriggerPips=12; g_BELockPips=3; g_TrailDistPips=15; g_TrailStepPips=4; g_MaxSpread=25;
      g_RSIOversold=38; g_RSIOverbought=62; g_RSIStaleOversold=46; g_RSIStaleOverbought=54;
      g_ADXMedium=22; g_ADXStrong=30; g_L4RSIExtreme=26;
   }
   else if(StringFind(sym, "GBPJPY") >= 0)
   {
      g_SLPips=28; g_TPPips=90; g_PartialTPPips=15;
      g_BETriggerPips=17; g_BELockPips=4; g_TrailDistPips=20; g_TrailStepPips=5; g_MaxSpread=40;
      g_RSIOversold=37; g_RSIOverbought=63; g_RSIStaleOversold=45; g_RSIStaleOverbought=55;
      g_ADXMedium=22; g_ADXStrong=30; g_L4RSIExtreme=25;
   }
   else
   {
      g_SLPips=20; g_TPPips=60; g_PartialTPPips=10;
      g_BETriggerPips=12; g_BELockPips=3; g_TrailDistPips=15; g_TrailStepPips=4; g_MaxSpread=25;
      g_RSIOversold=40; g_RSIOverbought=60; g_RSIStaleOversold=47; g_RSIStaleOverbought=53;
      g_ADXMedium=20; g_ADXStrong=28; g_L4RSIExtreme=27;
      PrintFormat("V20 Auto-Config: UNKNOWN symbol %s – generic Forex profile applied", _Symbol);
   }

   PrintFormat("V20 Auto-Config: %s RSI<%.0f/>%.0f ADX>%.0f/%.0f SL=%.0f TP=%.0f trail=%.0f/%.0f maxSpread=%d",
               _Symbol, g_RSIOversold, g_RSIOverbought, g_ADXMedium, g_ADXStrong,
               g_SLPips, g_TPPips, g_TrailDistPips, g_TrailStepPips, g_MaxSpread);
}
//+------------------------------------------------------------------+

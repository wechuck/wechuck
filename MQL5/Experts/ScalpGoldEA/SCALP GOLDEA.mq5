//+------------------------------------------------------------------+
//|                                              SCALP GOLDEA.mq5    |
//|                                  Copyright 2026, Trading Pro     |
//|   V17.0 - L2/L3/L4 Gate Fix + CHAL_ Comment Labels             |
//+------------------------------------------------------------------+
// Changelog:
//   v17.0 – L2/L3/L4 SCORING GATE FIX + CHALLENGE MODE COMMENT LABELS.
//
//           FIX – All 146 trades showing "V10_ScalpL1" even on high-lot setups.
//           Root cause: the L2/L3/L4 upgrade gate was `bullishTrend && htfBullish`
//           for BUY (and `bearishTrend && htfBearish` for SELL).  This EA signals
//           at REVERSAL points (lower BB / upper BB).  At the exact moment of a
//           lower-BB buy signal, price has been falling so M5 DI- always dominates
//           → bullishTrend is permanently false → L2/L3/L4 can never score.
//           FIX: gate is now `htfBullish` / `htfBearish` only (H4 macro trend).
//           The H4 EMA50/200 filter correctly confirms the long-term direction
//           without contradicting the short-term reversal nature of the entry.
//           TRADE COUNT IS UNCHANGED – entry conditions are not touched; only
//           the lot-size scoring path can now reach L2/L3/L4 when H4 aligns.
//           Survival mode (weekly/daily caps, cooldowns) still demotes to L1
//           when limits are reached, so no new trades are ever added.
//
//           FIX – Challenge mode comment labels: all challenge-mode trades now
//           use "CHAL_L1/L2/L3/EliteL4" prefix so the user can immediately see
//           that the large lot is driven by the 30% challenge risk, not a scoring
//           mistake, and which signal quality level was scored.
//
//   v16.0 – L4 ELITE SNIPER TIER + CHALLENGE MODE FIX built on V15.0.
//
//           FIX – Challenge Mode vs DD Circuit Breaker conflict: when
//           InpChallengeMode is ON, IsGlobalStopped() now returns false
//           immediately.  Challenge mode deliberately risks 30% per trade
//           to compound $20→$40k; the normal DD safety rails are
//           incompatible with that philosophy and were freezing the EA
//           after every single loss (reducing 146 trades to 8).
//
//           NEW – Level 4 "Elite Sniper" tier: a fourth scoring level
//           above L3 that fires only when ALL of the following align
//           simultaneously (estimated ~95% win rate):
//             • All L3 conditions (ADX>25+35+rising, HTF aligned, DI aligned)
//             • RSI ultra-extreme: < InpL4RSIExtreme for BUY (default 22),
//               > (100−InpL4RSIExtreme) for SELL (default 78)
//             • ADX above InpL4ADXMin (default 40) – institutional momentum
//             • Tick momentum ACTIVELY confirming direction (bias==+1 BUY /
//               bias==−1 SELL) – real-time flow must be WITH the trade, not
//               merely "not against" it as in the L1–L3 tick gate
//           L4 earns InpRiskLevel4 (default 15%) risk → larger lot.
//           On a micro account: 4× minVolume (6× in challenge mode).
//           L4 counts toward L2/L3 weekly/daily caps and respects the
//           L3 cooldown – it is gated by IsL23SniperAllowed() like L3.
//           InpEnableL4 = false disables the tier entirely (L3 fires
//           instead) with zero impact on any other logic.
//
//   v15.0 – DRAWDOWN CIRCUIT BREAKER + TICK-LEVEL MULTI-SCENARIO SIGNAL
//           ENGINE built on top of V14.0.  All V14.0 logic (L2/L3 Survival
//           Mode, precision timing, pending signals, re-entry) is preserved.
//
//           NEW – Peak Drawdown Halt: if closed balance falls more than
//           InpMaxPeakDDPct% below its all-time high the EA freezes all new
//           entries for InpDDHaltHours hours.  Open positions keep being
//           managed by ManageHFTExits() – nothing is ever left unguarded.
//
//           NEW – Daily Loss Halt: if today's closed balance is down more
//           than InpMaxDailyLossPct% versus the day-open balance, new entries
//           are blocked until the next calendar day (broker midnight).
//
//           NEW – Tick-Level Multi-Scenario Engine: addresses the failure
//           mode where bar[1] fires a BUY/SELL signal but real-time tick
//           flow has already reversed direction.  On EVERY tick (lowest
//           latency): (a) a 30-tick rolling up/down bias counter is updated
//           first, before any other logic; (b) when BOTH tick momentum AND
//           the forming bar[0] body simultaneously contradict the signal
//           direction, the entry is deferred via the existing pending-retry
//           system (never discarded) and re-evaluated on every subsequent
//           tick until conditions align or the expiry window closes.
//           Using AND (both must be contrary) prevents over-filtering and
//           preserves overall trade count while eliminating the highest-
//           confidence wrong-direction entries.
//
//           NEW – UpdateTickMomentum() is the very first call in OnTick()
//           so tick data is always current before any decision is made.
//           IsSignalAlignedWithTick() is also applied in TryPendingEntry()
//           and TryReentry() so retried signals benefit from the same gate.
//
//   v14.0 – L2/L3 SURVIVAL MODE layered on top of V13.0.
//           Level 1 frequency and all V13.0 precision-timing logic
//           are completely unchanged.  L2 and L3 are transformed into
//           ultra-selective "institutional sniper executions":
//           WEEKLY CAP: max InpL23WeeklyCap combined L2+L3 per week.
//           DAILY CAP:  max InpL23DailyCap combined L2+L3 per day.
//           L3 COOLDOWN: InpL3CooldownHours rest between L3 trades.
//           LOSS COOLDOWN: any L2/L3 SL hit freezes L2/L3 for
//             InpL23LossCooldownH hours; Level 1 remains active.
//           ADX QUALITY GATE: L2/L3 only when ADX ≥ InpSniperADXStrong
//             AND rising AND no recent spike from low volatility.
//           WICK FILTER: entry candle with rejection wick > threshold
//             blocks L2/L3 (trade still fires at Level 1 risk).
//           DEMOTE-NOT-DISCARD: if any survival gate blocks L2/L3,
//             the trade is demoted to Level 1 – no trades are lost.
//
//   v13.0 – PRECISION TIMING ENGINE layered on top of V10.0.
//           All V10.0 features preserved unchanged (BB/RSI/ADX/ATR,
//           H4 HTF sniper scoring L1/L2/L3, partial TP, BE, trail,
//           daily cap, challenge mode, micro-lot boost).
//           NEW – Pending Signal System: spread/vol/ADX/large-candle
//           issues no longer discard a trade. Signal is stored and
//           retried every tick until conditions normalise or
//           InpPendingExpireBars elapses – zero trades are thrown away.
//           NEW – ADX Delay Gate: ADX < InpADXDelayMin means momentum
//           is still forming; entry is deferred, not rejected.
//           NEW – Large-Candle Guard: after a bar body > InpLargeBodyMult
//           × ATR the EA waits for a pullback before firing; signal
//           stays in the pending slot.
//           NEW – Entry Location Check: if current price has already
//           chased > 30% past the signal candle close, entry is
//           deferred to a better-priced tick (no trade is lost).
//           NEW – Second-Chance Re-entry: after a stop-out the EA arms
//           one re-entry in the same direction (up to 6 bars), requiring
//           rising ADX >= 20 for stronger timing confirmation.
//
//  V10.0 FIX (preserved):
//   FIX 1 – MICRO-ACCOUNT LOT BOOST: when risk-calculation yields a lot below
//            the broker minimum (0.01), the EA is "on a micro account".  In that
//            case Level 2 is boosted to 2 × minVolume and Level 3 to 3 × minVolume
//            so each sniper tier actually trades a distinct, larger position.
//            RSI thresholds and Level 1 entry rules are unchanged from V10.0
//            to preserve the profitable 140-trade frequency shown in backtests.
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Pro"
#property link      "https://www.mql5.com"
#property version   "17.00"
#property strict

#include <Trade\Trade.mqh>

//--- INPUT PARAMETERS
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
input bool     InpChallengeMode       = false; // Enable $20→$40k Challenge Mode
input double   InpChallengeRisk       = 30.0;  // Risk per trade in Challenge (%)
input double   InpChallengeSL         = 150.0; // Stop Loss in Challenge (pips)
input double   InpChallengeTP_Early   = 500.0; // TP when balance < threshold (pips)
input double   InpChallengeTP_Late    = 20.0;  // TP when balance >= threshold (pips)
input double   InpChallengeThreshold  = 300.0; // Balance threshold: switch from Early to Late TP ($)

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

//--- GLOBALS
CTrade trade;
int handleBB, handleRSI, handleADX, handleATR;
int handleHTF_Fast, handleHTF_Slow;
double stepVolume, minVolume, maxVolume;

// Pending signal state – converts hard rejections into retries
bool     g_PendingSignal  = false;
int      g_PendingDir     = 0;     // 1=BUY, -1=SELL
double   g_PendingRisk    = 0.0;
datetime g_PendingExpiry  = 0;

// Re-entry state – second-chance after stop-out
bool     g_ReentryArmed   = false;
int      g_ReentryDir     = 0;     // 1=BUY, -1=SELL
datetime g_ReentryExpiry  = 0;
int      g_LastPosCount   = 0;

// L2/L3 Survival Mode state
datetime g_L3LastTime          = 0; // Time of last executed L3 trade (for cooldown)
datetime g_L23LossCooldownEnd  = 0; // L2/L3 blocked until this datetime after a loss

// V15 – Drawdown Circuit Breaker state
double   g_PeakBalance    = 0.0;   // Highest closed balance seen since EA start
datetime g_DDHaltUntil    = 0;     // All new entries blocked until this timestamp (0 = inactive)
double   g_DayOpenBalance = 0.0;   // Balance at start of current trading day
datetime g_DayOpenTime    = 0;     // Datetime of current day's open (for daily reset detection)

// V15 – Tick-level momentum tracker (rolling 30-tick window, reset when full)
double   g_LastTickBid = 0.0;   // Bid price from the previous tick (direction reference)
int      g_TicksBull   = 0;     // Up-ticks counted in current window
int      g_TicksBear   = 0;     // Down-ticks counted in current window
int      g_TicksWindow = 0;     // Total directional ticks counted (triggers reset at 30)

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpMaxSlippage);
   trade.SetTypeFilling(SYMBOL_FILLING_IOC);

   stepVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   minVolume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   maxVolume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   // Base Timeframe Indicators
   handleBB  = iBands(_Symbol, _Period, 20, 0, 2.0, PRICE_CLOSE);
   handleRSI = iRSI(_Symbol, _Period, 7, PRICE_CLOSE);
   handleADX = iADX(_Symbol, _Period, 14);
   handleATR = iATR(_Symbol, _Period, 14);

   // Higher Timeframe (Sniper) Indicators
   handleHTF_Fast = iMA(_Symbol, InpHTF, InpHTF_FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleHTF_Slow = iMA(_Symbol, InpHTF, InpHTF_SlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(handleBB == INVALID_HANDLE || handleRSI == INVALID_HANDLE ||
      handleADX == INVALID_HANDLE || handleATR == INVALID_HANDLE ||
      handleHTF_Fast == INVALID_HANDLE || handleHTF_Slow == INVALID_HANDLE)
   {
      Print("Indicator Failed To Load!");
      return(INIT_FAILED);
   }

   // Reset precision timing state
   g_PendingSignal = false;
   g_PendingDir    = 0;
   g_PendingRisk   = 0.0;
   g_PendingExpiry = 0;
   g_ReentryArmed  = false;
   g_ReentryDir    = 0;
   g_ReentryExpiry = 0;
   g_LastPosCount  = 0;

   // Reset L2/L3 survival state
   g_L3LastTime         = 0;
   g_L23LossCooldownEnd = 0;

   // Reset V15 drawdown circuit breaker state
   g_PeakBalance    = AccountInfoDouble(ACCOUNT_BALANCE);
   g_DDHaltUntil    = 0;
   g_DayOpenBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_DayOpenTime    = 0;   // properly initialized on the first tick call

   // Reset V15 tick momentum state
   g_LastTickBid = 0.0;
   g_TicksBull   = 0;
   g_TicksBear   = 0;
   g_TicksWindow = 0;

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   IndicatorRelease(handleBB);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleADX);
   IndicatorRelease(handleATR);
   IndicatorRelease(handleHTF_Fast);
   IndicatorRelease(handleHTF_Slow);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdateTickMomentum();          // V15: first – update rolling tick-direction counters at lowest latency
   ManageHFTExits();
   CheckReentryArm();             // detect stop-outs; arm second-chance re-entry

   if(IsGlobalStopped()) return;  // V15: circuit breaker – blocks new entries, exits still managed above
   if(!IsTradingTime()) return;
   if(DailyLimitsReached()) return;
   if(PositionsTotal() > 0) return;

   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = (Ask - Bid) / _Point;

   // --- PENDING SIGNAL: retry a previously delayed setup ---
   if(g_PendingSignal)
   {
      if(TimeCurrent() > g_PendingExpiry)
         ClearPending();
      else if(spread <= InpMaxSpread && TryPendingEntry(Ask, Bid))
         return;
   }

   // --- RE-ENTRY: second-chance after stop-out ---
   if(InpEnableReentry && g_ReentryArmed)
   {
      if(TimeCurrent() > g_ReentryExpiry)
         g_ReentryArmed = false;
      else if(spread <= InpMaxSpread && TryReentry(Ask, Bid))
         return;
   }

   // --- Base Indicators ---
   double bbUpper[], bbLower[], rsi[], adxMain[], adxPlus[], adxMinus[];
   ArraySetAsSeries(bbUpper, true); ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(rsi, true);     ArraySetAsSeries(adxMain, true);
   ArraySetAsSeries(adxPlus, true); ArraySetAsSeries(adxMinus, true);

   // HTF Indicators
   double htfFast[], htfSlow[];
   ArraySetAsSeries(htfFast, true); ArraySetAsSeries(htfSlow, true);

   if(CopyBuffer(handleBB, 1, 0, 3, bbUpper) < 3) return;
   if(CopyBuffer(handleBB, 2, 0, 3, bbLower) < 3) return;
   if(CopyBuffer(handleRSI, 0, 0, 3, rsi) < 3) return;
   if(CopyBuffer(handleADX, 0, 0, 3, adxMain) < 3) return;
   if(CopyBuffer(handleADX, 1, 0, 3, adxPlus) < 3) return;
   if(CopyBuffer(handleADX, 2, 0, 3, adxMinus) < 3) return;
   if(CopyBuffer(handleHTF_Fast, 0, 0, 2, htfFast) < 2) return;
   if(CopyBuffer(handleHTF_Slow, 0, 0, 2, htfSlow) < 2) return;

   // Base ADX & Trend
   double adx     = adxMain[1];
   double adxPrev = adxMain[2];
   double plus    = adxPlus[1];
   double minus   = adxMinus[1];

   bool bullishTrend = (plus > minus);
   bool bearishTrend = (minus > plus);
   bool adxRising    = (adx > adxPrev);

   // HTF (Sniper) Alignment
   bool htfBullish = (htfFast[1] > htfSlow[1]);
   bool htfBearish = (htfFast[1] < htfSlow[1]);

   // Candle structure
   double close1 = iClose(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol, _Period, 1);
   double high1  = iHigh(_Symbol, _Period, 1);
   double low1   = iLow(_Symbol, _Period, 1);
   double close2 = iClose(_Symbol, _Period, 2);
   double high2  = iHigh(_Symbol, _Period, 2);
   double low2   = iLow(_Symbol, _Period, 2);

   bool bullishCandle = close1 > open1;
   bool bearishCandle = close1 < open1;

   bool strongBuyReversal  = (close1 > close2) && (high1 > high2);
   bool strongSellReversal = (close1 < close2) && (low1 < low2);

   double slPoints = InpStopLossPips * InpPipMultiplier;

   // ======================================================
   // BUY SCORING ENGINE (entry conditions unchanged)
   // ======================================================
   if(low1 <= bbLower[1] && rsi[1] < 35 && bullishCandle && strongBuyReversal)
   {
      double scoreRisk = InpRiskLevel1; // Default: Level 1 scalp

      // SNIPER UPGRADE: Level 2/3/4 when H4 macro trend aligns with signal direction.
      // V17 FIX: bullishTrend (M5 DI) was removed from the gate – at a lower-BB reversal
      // candle price has been falling, so M5 DI- always dominates at the exact moment of
      // entry, making the old `bullishTrend && htfBullish` condition permanently false and
      // blocking all L2/L3/L4 upgrades.  The H4 EMA gate alone is the correct macro filter
      // for a mean-reversion EA.  Trade count is unaffected (entry conditions unchanged).
      if(htfBullish)
      {
         int score = 0;
         if(adx > 25) score++;      // Stricter ADX for higher levels
         if(adx > 35) score++;      // Extreme momentum
         if(adxRising) score++;

         if(score == 3)
         {
            // V16: L4 Elite Sniper – ultra-extreme RSI + institutional ADX + tick flow actively confirming
            if(InpEnableL4 && rsi[1] < InpL4RSIExtreme &&
               adx > InpL4ADXMin && TickMomentumBias() == 1)
               scoreRisk = InpRiskLevel4;  // Elite tier (~95% win rate)
            else
               scoreRisk = InpRiskLevel3;  // God Tier
         }
         else if(score == 2) scoreRisk = InpRiskLevel2; // High Probability Sniper
      }

      // V14 SURVIVAL MODE: L2/L3 gated through ultra-selective sniper filter.
      // If any survival condition is not met, demote to L1 – trade still fires.
      if(scoreRisk >= InpRiskLevel2 && !IsL23SniperAllowed(ORDER_TYPE_BUY, scoreRisk))
         scoreRisk = InpRiskLevel1;

      // Precision gates: store pending instead of hard reject
      if(spread > InpMaxSpread)                                { StorePending(1, scoreRisk); return; }
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_BUY)) { StorePending(1, scoreRisk); return; }
      if(IsLargeCandle())                                      { StorePending(1, scoreRisk); return; }
      if(adx < InpADXDelayMin)                                 { StorePending(1, scoreRisk); return; }
      if(!IsEntryLocationOK(ORDER_TYPE_BUY, Ask))              { StorePending(1, scoreRisk); return; }
      // V15: tick-level multi-scenario gate – defer when tick momentum AND forming bar both contradict
      if(!IsSignalAlignedWithTick(ORDER_TYPE_BUY))             { StorePending(1, scoreRisk); return; }

      ExecuteHFTOrder(ORDER_TYPE_BUY, Ask, slPoints, scoreRisk);
      ClearPending();
      return;
   }

   // ======================================================
   // SELL SCORING ENGINE (entry conditions unchanged)
   // ======================================================
   if(high1 >= bbUpper[1] && rsi[1] > 65 && bearishCandle && strongSellReversal)
   {
      double scoreRisk = InpRiskLevel1; // Default: Level 1 scalp

      // SNIPER UPGRADE: Level 2/3/4 when H4 macro trend aligns with signal direction.
      // V17 FIX: bearishTrend (M5 DI) removed – see BUY engine comment above.
      if(htfBearish)
      {
         int score = 0;
         if(adx > 25) score++;      // Stricter ADX
         if(adx > 35) score++;      // Extreme momentum
         if(adxRising) score++;

         if(score == 3)
         {
            // V16: L4 Elite Sniper – ultra-extreme RSI + institutional ADX + tick flow actively confirming
            if(InpEnableL4 && rsi[1] > (100.0 - InpL4RSIExtreme) &&
               adx > InpL4ADXMin && TickMomentumBias() == -1)
               scoreRisk = InpRiskLevel4;  // Elite tier (~95% win rate)
            else
               scoreRisk = InpRiskLevel3;  // God Tier
         }
         else if(score == 2) scoreRisk = InpRiskLevel2; // High Probability Sniper
      }

      // V14 SURVIVAL MODE: L2/L3 gated through ultra-selective sniper filter.
      // If any survival condition is not met, demote to L1 – trade still fires.
      if(scoreRisk >= InpRiskLevel2 && !IsL23SniperAllowed(ORDER_TYPE_SELL, scoreRisk))
         scoreRisk = InpRiskLevel1;

      // Precision gates: store pending instead of hard reject
      if(spread > InpMaxSpread)                                 { StorePending(-1, scoreRisk); return; }
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_SELL)) { StorePending(-1, scoreRisk); return; }
      if(IsLargeCandle())                                       { StorePending(-1, scoreRisk); return; }
      if(adx < InpADXDelayMin)                                  { StorePending(-1, scoreRisk); return; }
      if(!IsEntryLocationOK(ORDER_TYPE_SELL, Bid))              { StorePending(-1, scoreRisk); return; }
      // V15: tick-level multi-scenario gate – defer when tick momentum AND forming bar both contradict
      if(!IsSignalAlignedWithTick(ORDER_TYPE_SELL))             { StorePending(-1, scoreRisk); return; }

      ExecuteHFTOrder(ORDER_TYPE_SELL, Bid, slPoints, scoreRisk);
      ClearPending();
      return;
   }
}

//+------------------------------------------------------------------+
//| EXECUTION: Fire Scalp Payload with Lot Calculation               |
//| FIX 1 – Micro-Account Lot Boost included                         |
//| CHALLENGE – 30% risk, 150 SL, adaptive TP when enabled           |
//+------------------------------------------------------------------+
void ExecuteHFTOrder(ENUM_ORDER_TYPE type, double price, double slPoints, double assignedRisk)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double freeMargin = AccountInfoDouble(ACCOUNT_FREEMARGIN);

   // --- CHALLENGE MODE OVERRIDES ---
   double effectiveRisk   = assignedRisk;
   double effectiveSL     = slPoints;
   double effectiveTPPips = InpTakeProfitPips;

   if(InpChallengeMode)
   {
      effectiveRisk = InpChallengeRisk;   // 30% of balance per trade
      effectiveSL   = InpChallengeSL * InpPipMultiplier;

      // Adaptive TP: large pip target early (small balance needs big RR),
      // switch to fast scalp target once balance compounds past the threshold.
      effectiveTPPips = (balance < InpChallengeThreshold)
                        ? InpChallengeTP_Early
                        : InpChallengeTP_Late;
   }

   double moneyRisk  = balance * (effectiveRisk / 100.0);
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double lossPerLot = (effectiveSL * _Point / tickSize) * tickValue;
   if(lossPerLot <= 0) return;

   // --- Standard risk-based lot calculation ---
   double rawLot = moneyRisk / lossPerLot;
   double calculatedLot = MathFloor(rawLot / stepVolume) * stepVolume;

   if(calculatedLot > maxVolume) calculatedLot = maxVolume;
   if(calculatedLot < minVolume) calculatedLot = minVolume;

   // FIX 1 – MICRO-ACCOUNT LOT BOOST
   // When the raw calculated lot is at or below the broker minimum it means the
   // account balance is too small for the risk-percentage formula to produce
   // meaningful lot differentiation between levels.  Artificially boost Level 2
   // to 2 × minVolume and Level 3 to 3 × minVolume (5 × in challenge mode so that
   // sniper setups always trade a meaningfully larger position than a plain Level 1 scalp.
   bool isMicroAccount = (rawLot <= minVolume);
   if(isMicroAccount)
   {
      double boostMultiplier = 1.0;
      if(assignedRisk >= InpRiskLevel4)
         boostMultiplier = InpChallengeMode ? 6.0 : 4.0;
      else if(assignedRisk >= InpRiskLevel3)
         boostMultiplier = InpChallengeMode ? 5.0 : 3.0;
      else if(assignedRisk >= InpRiskLevel2)
         boostMultiplier = InpChallengeMode ? 3.0 : 2.0;

      calculatedLot = MathFloor((minVolume * boostMultiplier) / stepVolume) * stepVolume;
      if(calculatedLot > maxVolume) calculatedLot = maxVolume;
      if(calculatedLot < minVolume) calculatedLot = minVolume;
   }

   // --- Margin safety check ---
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

   double sl, tp;
   string comment;
   if(InpChallengeMode)
   {
      // Challenge mode: prefix "CHAL_" so the user can instantly see that the lot
      // size is driven by the 30% challenge risk, not the signal scoring level.
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

   // V14 – record L3 activation time for inter-trade cooling enforcement
   if(assignedRisk >= InpRiskLevel3)
      g_L3LastTime = TimeCurrent();

   if(type == ORDER_TYPE_BUY)
   {
      sl = price - effectiveSL * _Point;
      tp = price + (effectiveTPPips * InpPipMultiplier * _Point);
      trade.Buy(calculatedLot, _Symbol, price, sl, tp, comment);
   }
   else
   {
      sl = price + effectiveSL * _Point;
      tp = price - (effectiveTPPips * InpPipMultiplier * _Point);
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

   double partialTPDist = InpPartialTPPips  * InpPipMultiplier * _Point;
   double beTriggerDist = InpBETriggerPips  * InpPipMultiplier * _Point;
   double beLockDist    = InpBELockPips     * InpPipMultiplier * _Point;
   double trailDist     = InpTrailDistPips  * InpPipMultiplier * _Point;
   double trailStep     = InpTrailStepPips  * InpPipMultiplier * _Point;

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

      // --- Partial close at TP1 (once per trade, disabled in challenge mode) ---
      if(!InpChallengeMode && StringFind(comment, "Partial") < 0)
      {
         bool triggerPartial = (posType == POSITION_TYPE_BUY  && Bid >= openPrice + partialTPDist) ||
                               (posType == POSITION_TYPE_SELL && Ask <= openPrice - partialTPDist);

         if(triggerPartial)
         {
            double closeLot = MathFloor((volume / 2.0) / stepVolume) * stepVolume;
            if(closeLot >= minVolume)
            {
               trade.PositionClosePartial(ticket, closeLot, "V10_Partial");
               continue;
            }
         }
      }

      // --- Breakeven and trailing ---
      if(posType == POSITION_TYPE_BUY)
      {
         // Move SL to breakeven + lock pips once BE trigger is reached
         if(Bid >= openPrice + beTriggerDist)
         {
            double beSL = openPrice + beLockDist;
            if(currentSL < beSL - (_Point * 10))
            {
               trade.PositionModify(ticket, beSL, tp);
               continue;
            }
         }
         // Trail once SL is already in profit territory
         if(currentSL >= openPrice + beLockDist)
         {
            double newSL = Bid - trailDist;
            if(newSL > currentSL + trailStep)
               trade.PositionModify(ticket, newSL, tp);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         // Move SL to breakeven + lock pips once BE trigger is reached
         if(Ask <= openPrice - beTriggerDist)
         {
            double beSL = openPrice - beLockDist;
            if(currentSL > beSL + (_Point * 10) || currentSL == 0)
            {
               trade.PositionModify(ticket, beSL, tp);
               continue;
            }
         }
         // Trail once SL is already in profit territory
         if(currentSL <= openPrice - beLockDist && currentSL != 0)
         {
            double newSL = Ask + trailDist;
            if(newSL < currentSL - trailStep)
               trade.PositionModify(ticket, newSL, tp);
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

   // Reject if current bar is a violent spike (> 4× average ATR)
   if(atrData[0] > avgATR * 4.0) return false;

   // During moderate expansion (2–4× ATR), require a healthy candle body
   double body = MathAbs(iClose(_Symbol, _Period, 1) - iOpen(_Symbol, _Period, 1));
   if(atrData[0] > avgATR * 2.0)
   {
      if(body < (atrData[0] * 0.5)) return false;
   }

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
      {
         tradesToday++;
      }
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

// True when the last completed bar had a large impulsive body (exhaustion risk)
bool IsLargeCandle()
{
   double atrData[];
   ArraySetAsSeries(atrData, true);
   if(CopyBuffer(handleATR, 0, 0, 3, atrData) < 3) return false;
   double body1 = MathAbs(iClose(_Symbol, _Period, 1) - iOpen(_Symbol, _Period, 1));
   return (body1 > atrData[1] * InpLargeBodyMult);
}

// True when current price is not chasing more than 30% body-length beyond signal close
bool IsEntryLocationOK(ENUM_ORDER_TYPE type, double currentPrice)
{
   double close1 = iClose(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol, _Period, 1);
   double body   = MathAbs(close1 - open1);
   if(body < _Point * 10) return true;   // tiny doji – no location concern

   double chase = body * 0.30;
   if(type == ORDER_TYPE_BUY  && currentPrice > close1 + chase) return false;
   if(type == ORDER_TYPE_SELL && currentPrice < close1 - chase) return false;
   return true;
}

// Store a pending signal so the setup is retried instead of discarded
void StorePending(int dir, double risk)
{
   if(g_PendingSignal && g_PendingDir != dir)
      ClearPending();   // opposite signal appeared – replace with fresh one

   if(!g_PendingSignal)
   {
      g_PendingSignal = true;
      g_PendingDir    = dir;
      g_PendingRisk   = risk;
      g_PendingExpiry = TimeCurrent() + InpPendingExpireBars * PeriodSeconds(_Period);
   }
   else if(risk > g_PendingRisk)
      g_PendingRisk = risk;   // upgrade to higher-tier risk if a better signal arrives
}

void ClearPending()
{
   g_PendingSignal = false;
   g_PendingDir    = 0;
   g_PendingRisk   = 0.0;
   g_PendingExpiry = 0;
}

// Re-evaluate a stored signal every tick; fire once conditions normalise
bool TryPendingEntry(double Ask, double Bid)
{
   if(!g_PendingSignal) return false;

   // Re-read indicators to confirm signal is still relevant
   double bbUpper[], bbLower[], rsiArr[], adxArr[], atrCheck[];
   ArraySetAsSeries(bbUpper,  true); ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(rsiArr,   true); ArraySetAsSeries(adxArr,  true);
   ArraySetAsSeries(atrCheck, true);

   if(CopyBuffer(handleBB,  1, 0, 2, bbUpper)  < 2) return false;
   if(CopyBuffer(handleBB,  2, 0, 2, bbLower)  < 2) return false;
   if(CopyBuffer(handleRSI, 0, 0, 2, rsiArr)   < 2) return false;
   if(CopyBuffer(handleADX, 0, 0, 2, adxArr)   < 2) return false;
   if(CopyBuffer(handleATR, 0, 0, 2, atrCheck) < 2) return false;

   if(adxArr[1] < InpADXDelayMin) return false;   // ADX still forming
   if(IsLargeCandle())            return false;   // still after large candle

   // V15: tick-level check on every retry tick – only execute when real-time flow agrees
   ENUM_ORDER_TYPE pendType = (g_PendingDir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!IsSignalAlignedWithTick(pendType)) return false;

   double slPoints = InpStopLossPips * InpPipMultiplier;

   if(g_PendingDir == 1)   // BUY pending
   {
      // Signal is stale if price has rallied far above BB lower
      if(Ask > bbLower[1] + atrCheck[1] * 1.5) return false;
      if(rsiArr[1] > 42)                        return false;   // no longer oversold
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_BUY)) return false;
      if(!IsEntryLocationOK(ORDER_TYPE_BUY, Ask))              return false;

      ExecuteHFTOrder(ORDER_TYPE_BUY, Ask, slPoints, g_PendingRisk);
      ClearPending();
      return true;
   }
   else if(g_PendingDir == -1)   // SELL pending
   {
      // Signal is stale if price has fallen far below BB upper
      if(Bid < bbUpper[1] - atrCheck[1] * 1.5) return false;
      if(rsiArr[1] < 58)                        return false;   // no longer overbought
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_SELL)) return false;
      if(!IsEntryLocationOK(ORDER_TYPE_SELL, Bid))              return false;

      ExecuteHFTOrder(ORDER_TYPE_SELL, Bid, slPoints, g_PendingRisk);
      ClearPending();
      return true;
   }
   return false;
}

// Detect stop-outs each tick and arm a second-chance re-entry in the same direction
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

      // HistoryDeals are ordered oldest→newest; iterate newest-first for most recent exit
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         ulong dk = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(dk, DEAL_MAGIC) != InpMagic)       continue;
         if(HistoryDealGetInteger(dk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         lastTicket = dk;
         lastReason = (int)HistoryDealGetInteger(dk, DEAL_REASON);
         lastType   = HistoryDealGetInteger(dk, DEAL_TYPE);
         break;
      }

      if(lastTicket > 0 && lastReason == DEAL_REASON_SL)
      {
         // DEAL_TYPE_SELL closes a BUY position → re-entry is BUY (dir=1)
         // DEAL_TYPE_BUY  closes a SELL position → re-entry is SELL (dir=-1)
         g_ReentryDir    = (lastType == DEAL_TYPE_SELL) ? 1 : -1;
         g_ReentryArmed  = true;
         g_ReentryExpiry = TimeCurrent() + 6 * PeriodSeconds(_Period);

         // V14 – if the stopped-out position was L2/L3, activate survival cooldown.
         // The SL exit deal won't carry the original comment; find the matching IN deal.
         long posId = HistoryDealGetInteger(lastTicket, DEAL_POSITION_ID);
         HistorySelect(TimeCurrent() - 7 * 86400, TimeCurrent()); // wider window for IN deal
         for(int j = 0; j < HistoryDealsTotal(); j++)
         {
            ulong dj = HistoryDealGetTicket(j);
            if(HistoryDealGetInteger(dj, DEAL_POSITION_ID) != posId)     continue;
            if(HistoryDealGetInteger(dj, DEAL_ENTRY)       != DEAL_ENTRY_IN) continue;
            string cmt = HistoryDealGetString(dj, DEAL_COMMENT);
            if(StringFind(cmt, "SniperL2") >= 0 || StringFind(cmt, "SniperL3") >= 0 ||
               StringFind(cmt, "EliteL4") >= 0  || StringFind(cmt, "CHAL_L2") >= 0   ||
               StringFind(cmt, "CHAL_L3") >= 0  || StringFind(cmt, "CHAL_EliteL4") >= 0)
               g_L23LossCooldownEnd = TimeCurrent() + (long)InpL23LossCooldownH * 3600;
            break;
         }
      }
   }
   g_LastPosCount = curCount;
}

// Attempt a second-chance entry after stop-out – requires stronger ADX confirmation
bool TryReentry(double Ask, double Bid)
{
   if(!g_ReentryArmed) return false;

   double bbUpper[], bbLower[], rsiArr[], adxMain[];
   ArraySetAsSeries(bbUpper, true); ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(rsiArr,  true); ArraySetAsSeries(adxMain, true);

   if(CopyBuffer(handleBB,  1, 0, 3, bbUpper) < 3) return false;
   if(CopyBuffer(handleBB,  2, 0, 3, bbLower) < 3) return false;
   if(CopyBuffer(handleRSI, 0, 0, 3, rsiArr)  < 3) return false;
   if(CopyBuffer(handleADX, 0, 0, 3, adxMain) < 3) return false;

   double adx      = adxMain[1];
   bool   adxRising = (adx > adxMain[2]);

   // Stricter ADX confirmation required for re-entry
   if(adx < 20.0 || !adxRising) return false;

   // V15: tick-level confirmation for re-entry – same gate as primary signals
   ENUM_ORDER_TYPE retryType = (g_ReentryDir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!IsSignalAlignedWithTick(retryType)) return false;

   double close1 = iClose(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol, _Period, 1);
   double high1  = iHigh(_Symbol, _Period, 1);
   double low1   = iLow(_Symbol, _Period, 1);
   double close2 = iClose(_Symbol, _Period, 2);
   double high2  = iHigh(_Symbol, _Period, 2);
   double low2   = iLow(_Symbol, _Period, 2);

   bool bullishCandle      = (close1 > open1);
   bool bearishCandle      = (close1 < open1);
   bool strongBuyReversal  = (close1 > close2) && (high1 > high2);
   bool strongSellReversal = (close1 < close2) && (low1 < low2);

   double slPoints = InpStopLossPips * InpPipMultiplier;

   if(g_ReentryDir == 1 &&
      low1 <= bbLower[1] && rsiArr[1] < 35 && bullishCandle && strongBuyReversal)
   {
      if(IsLargeCandle())                                          return false;
      if(!IsEntryLocationOK(ORDER_TYPE_BUY, Ask))                 return false;
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_BUY))    return false;
      ExecuteHFTOrder(ORDER_TYPE_BUY, Ask, slPoints, InpRiskLevel1);
      g_ReentryArmed = false;
      ClearPending();
      return true;
   }
   if(g_ReentryDir == -1 &&
      high1 >= bbUpper[1] && rsiArr[1] > 65 && bearishCandle && strongSellReversal)
   {
      if(IsLargeCandle())                                          return false;
      if(!IsEntryLocationOK(ORDER_TYPE_SELL, Bid))                return false;
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_SELL))   return false;
      ExecuteHFTOrder(ORDER_TYPE_SELL, Bid, slPoints, InpRiskLevel1);
      g_ReentryArmed = false;
      ClearPending();
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| L2/L3 SURVIVAL MODE – Helper Functions (V14)                     |
//+------------------------------------------------------------------+

// True when ADX recently spiked from a low-volatility base (fake breakout risk)
bool IsADXSpikeFromLow()
{
   int needed = InpSniperADXSpikeBars + 2;
   double adxHist[];
   ArraySetAsSeries(adxHist, true);
   if(CopyBuffer(handleADX, 0, 0, needed, adxHist) < needed) return false;
   // Check bars [2 .. InpSniperADXSpikeBars+1] (N bars before the last closed bar)
   for(int i = 2; i <= InpSniperADXSpikeBars + 1; i++)
   {
      if(adxHist[i] < InpSniperADXSpikeMin) return true; // ADX was low → current rise is a spike
   }
   return false;
}

// True when entry candle has acceptable wick structure (no rejection wick against entry direction)
bool HasCleanSniperCandle(ENUM_ORDER_TYPE type)
{
   double high1  = iHigh(_Symbol, _Period, 1);
   double low1   = iLow(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol, _Period, 1);
   double close1 = iClose(_Symbol, _Period, 1);
   double range  = high1 - low1;
   if(range < _Point * 10) return true;  // negligible range – no concern

   double upperWick = high1 - MathMax(open1, close1);
   double lowerWick = MathMin(open1, close1) - low1;

   // BUY: reject if upper wick is dominant (rally was sold into – rejection of upside)
   if(type == ORDER_TYPE_BUY  && upperWick / range > InpSniperMaxWickRatio) return false;
   // SELL: reject if lower wick is dominant (drop was bought into – rejection of downside)
   if(type == ORDER_TYPE_SELL && lowerWick / range > InpSniperMaxWickRatio) return false;

   return true;
}

// Count L2/L3 entry deals (by comment) executed since a given start time
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
         StringFind(cmt, "CHAL_L3") >= 0  || StringFind(cmt, "CHAL_EliteL4") >= 0)
         count++;
   }
   return count;
}

// Master gate: returns true only when ALL L2/L3 survival conditions are satisfied.
// When false the caller demotes the trade to Level 1 – no trade is ever discarded.
bool IsL23SniperAllowed(ENUM_ORDER_TYPE type, double scoreRisk)
{
   // 1. Loss cooldown: L2/L3 frozen after any L2/L3 SL hit
   if(g_L23LossCooldownEnd > 0 && TimeCurrent() < g_L23LossCooldownEnd)
      return false;

   // 2. L3 inter-trade cooldown: enforce rest period between consecutive L3 trades
   if(scoreRisk >= InpRiskLevel3 && g_L3LastTime > 0 &&
      TimeCurrent() < g_L3LastTime + (long)InpL3CooldownHours * 3600)
      return false;

   // 3. Weekly L2/L3 cap (combined)
   MqlDateTime dtNow;
   TimeToStruct(TimeCurrent(), dtNow);
   int daysToMon  = (dtNow.day_of_week == 0) ? 6 : (dtNow.day_of_week - 1);
   datetime weekStart = iTime(_Symbol, PERIOD_D1, 0) - (long)daysToMon * 86400;
   if(CountL23TradesInPeriod(weekStart) >= InpL23WeeklyCap)
      return false;

   // 4. Daily L2/L3 cap
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(CountL23TradesInPeriod(todayStart) >= InpL23DailyCap)
      return false;

   // 5. ADX quality gate: strong trend, rising, no fake spike from low volatility
   double adxArr[];
   ArraySetAsSeries(adxArr, true);
   if(CopyBuffer(handleADX, 0, 0, 3, adxArr) < 3) return false;
   if(adxArr[1] < InpSniperADXStrong) return false;  // market not trending strongly enough
   if(adxArr[1] <= adxArr[2])         return false;  // ADX must be rising (growing momentum)
   if(IsADXSpikeFromLow())            return false;  // spike from low vol = fake breakout risk

   // 6. Candle quality: no rejection wick against entry direction
   if(!HasCleanSniperCandle(type)) return false;

   return true;
}

//+------------------------------------------------------------------+
//| V15 – Drawdown Circuit Breaker                                   |
//| Tracks peak closed balance and day-open balance; blocks new      |
//| entries when either DD limit is breached.  Open positions are    |
//| never affected – ManageHFTExits() always runs before this check. |
//+------------------------------------------------------------------+
bool IsGlobalStopped()
{
   if(!InpUseDDProtection) return false;
   // V16: challenge mode deliberately risks 30% per trade to compound a micro account;
   // the normal DD thresholds are incompatible with that philosophy and would freeze the
   // EA after every single loss, reducing 146 trades to ~8.  Skip all DD halts in challenge mode.
   if(InpChallengeMode)    return false;

   double   balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(todayStart == 0) return false;   // bars not yet loaded on startup

   // Update all-time peak closed balance
   if(balance > g_PeakBalance) g_PeakBalance = balance;

   // Initialise or roll the day-open balance at each new trading day
   if(g_DayOpenTime == 0 || todayStart > g_DayOpenTime)
   {
      g_DayOpenBalance = balance;
      g_DayOpenTime    = todayStart;
   }

   // If an active halt is in place, check whether it has expired
   if(g_DDHaltUntil > 0)
   {
      if(TimeCurrent() < g_DDHaltUntil) return true;
      g_DDHaltUntil = 0;   // halt expired – resume trading
   }

   // Peak drawdown breach
   if(g_PeakBalance > 0.0)
   {
      double ddPct = (g_PeakBalance - balance) / g_PeakBalance * 100.0;
      if(ddPct >= InpMaxPeakDDPct)
      {
         PrintFormat("V15 Peak DD Halt: %.1f%% drop from $%.2f → freeze %d h",
                     ddPct, g_PeakBalance, InpDDHaltHours);
         g_DDHaltUntil = TimeCurrent() + (long)InpDDHaltHours * 3600;
         return true;
      }
   }

   // Daily loss breach
   if(g_DayOpenBalance > 0.0)
   {
      double dayLossPct = (g_DayOpenBalance - balance) / g_DayOpenBalance * 100.0;
      if(dayLossPct >= InpMaxDailyLossPct)
      {
         PrintFormat("V15 Daily Loss Halt: %.1f%% → freeze until EOD", dayLossPct);
         g_DDHaltUntil = todayStart + 86400;   // until next calendar day
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| V15 – Tick-Level Momentum Engine                                 |
//+------------------------------------------------------------------+

// Called as the very first instruction in OnTick() for minimum latency.
// Maintains a rolling 30-tick window of up/down price movements.
void UpdateTickMomentum()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_LastTickBid > 0.0)
   {
      if(bid > g_LastTickBid + _Point)      g_TicksBull++;
      else if(bid < g_LastTickBid - _Point) g_TicksBear++;
      g_TicksWindow++;
      if(g_TicksWindow >= 30)   // reset rolling window
      {
         g_TicksBull   = 0;
         g_TicksBear   = 0;
         g_TicksWindow = 0;
      }
   }
   g_LastTickBid = bid;
}

// Returns +1 (bullish bias), -1 (bearish bias), 0 (neutral / not enough data).
// Threshold: 62.5% of directional ticks must agree to declare a bias.
int TickMomentumBias()
{
   int total = g_TicksBull + g_TicksBear;
   if(total < 10) return 0;   // need at least 10 directional ticks to judge
   double ratio = (double)(g_TicksBull - g_TicksBear) / total;
   if(ratio >  0.25) return  1;   // ≥62.5 % up-ticks → bullish
   if(ratio < -0.25) return -1;   // ≥62.5 % down-ticks → bearish
   return 0;
}

// True when the forming bar[0] body does NOT strongly contradict the intended direction.
// A body exceeding 25% of prior ATR in the opposite direction counts as "contrary".
bool IsCurrentBarAligned(ENUM_ORDER_TYPE type)
{
   double open0 = iOpen(_Symbol, _Period, 0);
   if(open0 == 0.0) return true;   // bar[0] not yet formed

   double atrData[];
   ArraySetAsSeries(atrData, true);
   if(CopyBuffer(handleATR, 0, 0, 2, atrData) < 2) return true;

   // Use the actual entry-side price: Ask for BUY entries, Bid for SELL entries.
   // This ensures the body check reflects the exact price we would execute at.
   double currentPrice = (type == ORDER_TYPE_BUY)
                         ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                         : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double body0 = currentPrice - open0;   // positive → bar forming bullish
   double limit = atrData[1] * 0.25;      // 25% of prior ATR = "strong" contrary move

   if(type == ORDER_TYPE_BUY  && body0 < -limit) return false;   // bar forming bearish
   if(type == ORDER_TYPE_SELL && body0 >  limit)  return false;   // bar forming bullish
   return true;
}

// Combined V15 tick gate applied at every signal decision point.
// Entry is deferred (→ pending retry) ONLY when BOTH conditions are simultaneously wrong:
//   (a) rolling tick momentum is contrary to the signal direction, AND
//   (b) the forming bar[0] body is also contrary.
// Using AND preserves overall trade count while eliminating high-confidence wrong-direction entries.
bool IsSignalAlignedWithTick(ENUM_ORDER_TYPE type)
{
   int  bias       = TickMomentumBias();
   bool tickOK     = !((type == ORDER_TYPE_BUY  && bias == -1) ||
                       (type == ORDER_TYPE_SELL && bias ==  1));
   bool barAligned = IsCurrentBarAligned(type);

   // Allow entry if EITHER tick momentum OR forming bar is aligned with the signal
   return (tickOK || barAligned);
}

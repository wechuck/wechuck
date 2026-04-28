//+------------------------------------------------------------------+
//|                                              SCALP GOLDEA.mq5    |
//|                                  Copyright 2026, Trading Pro     |
//|   V15.0 - 3-Level Institutional Risk Architecture                 |
//+------------------------------------------------------------------+
// Changelog:
//   v15.0 – INSTITUTIONAL RISK ARCHITECTURE built on V14.0.
//           Core trading logic, indicators, and V13 precision-timing
//           are completely unchanged.  Three-level risk system:
//
//           L1 SCALP ENGINE (1%): max 8 trades/day.
//             Pause after 2 consecutive L1 losses for 6 hours.
//
//           L2 PRECISION ENGINE (1.5% fixed): max 2/day, 4/week.
//             Win cooldown: 4h. Loss cooldown: 24h.
//             ADX 25–35 rising, HTF aligned, no vol spike, clean wick.
//             No micro-lot boost. No challenge-mode override.
//
//           L3 SNIPER ENGINE (2% max): max 1/day, 2/week.
//             Trade cooldown: 48h. Loss disable: 5 days (120h).
//             ADX 28–40 rising, multi-TF aligned, stable ATR,
//             tightest spread conditions. No micro-lot boost.
//             No challenge-mode override.
//
//           GLOBAL RISK CONTROL:
//             DD ≥  5% → risk ×0.75 (–25%)
//             DD ≥ 10% → risk ×0.50 (–50%)
//             DD ≥ 15% → disable L2/L3 (L1 only)
//             DD ≥ 20% → stop all trading
//
//           DAILY PROTECTION:
//             Stop at –3% daily loss.
//             Pause 12h after 3 consecutive losses (any level).
//
//           WEEKLY CONTROL:
//             Weekly profit > 10% → reduce risk 30% remainder of week.
//             Weekly loss  >  8% → stop trading for 3 days.
//
//           DEMOTE-NOT-DISCARD: L2/L3 gate failure → downgrade to L1.
//
//   v14.0 – L2/L3 SURVIVAL MODE layered on top of V13.0.
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
#property version   "15.00"
#property strict

#include <Trade\Trade.mqh>

//--- INPUT PARAMETERS
input group "=== DYNAMIC SIGNAL SCORING (HFT) ==="
input double   InpRiskLevel1     = 1.0;       // Level 1: Daily HFT Scalping (1% risk)
input double   InpRiskLevel2     = 1.5;       // Level 2: Precision Engine (1.5% fixed)
input double   InpRiskLevel3     = 2.0;       // Level 3: Sniper Engine (2% max)

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

input group "=== DISCIPLINE LIMITS ==="
input int      InpMaxTradesDay   = 8;         // Max total trades per day (L1 driven)
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

input group "=== GLOBAL RISK CONTROL (V15) ==="
input double InpDDRisk1Pct      = 5.0;   // DD ≥ this → risk –25% (×0.75)
input double InpDDRisk2Pct      = 10.0;  // DD ≥ this → risk –50% (×0.50)
input double InpDDDisableL23Pct = 15.0;  // DD ≥ this → disable L2/L3
input double InpDDStopAllPct    = 20.0;  // DD ≥ this → stop all trading

input group "=== DAILY & WEEKLY PROTECTION (V15) ==="
input double InpDailyLossStopPct   = 3.0;  // Stop trading at –N% daily loss
input int    InpConsecLossGlobal   = 3;    // N consecutive losses (any) → 12h pause
input int    InpGlobalCooldownH    = 12;   // Global cooldown hours after consec loss
input double InpWeeklyProfitPct    = 10.0; // Weekly profit > N% → reduce risk 30%
input double InpWeeklyLossStopPct  = 8.0;  // Weekly loss > N% → stop for N days
input int    InpWeeklyStopDays     = 3;    // Days stopped after weekly loss breach

input group "=== L1 SCALP ENGINE (V15) ==="
input int    InpL1ConsecLossCount  = 2;    // Consecutive L1 losses → pause
input int    InpL1CooldownH        = 6;    // L1 pause hours after consec losses

input group "=== L2 PRECISION ENGINE (V15) ==="
input int    InpL2MaxPerDay        = 2;    // L2 max trades per day
input int    InpL2MaxPerWeek       = 4;    // L2 max trades per week
input int    InpL2WinCooldownH     = 4;    // L2 cooldown hours after WIN
input int    InpL2LossCooldownH    = 24;   // L2 cooldown hours after LOSS
input double InpL2ADXMin           = 25.0; // L2 ADX minimum (trending)
input double InpL2ADXMax           = 35.0; // L2 ADX maximum (not overextended)
input double InpL2MaxWickRatio     = 0.45; // L2 max entry-candle wick/range
input int    InpL2ADXSpikeBars     = 5;    // Look-back bars for fake-breakout gate
input double InpL2ADXSpikeMin     = 16.0; // ADX below this N bars ago → spike risk

input group "=== L3 SNIPER ENGINE (V15) ==="
input int    InpL3MaxPerDay        = 1;    // L3 max trades per day
input int    InpL3MaxPerWeek       = 2;    // L3 max trades per week
input int    InpL3TradeCooldownH   = 48;   // L3 rest hours between any L3 trades
input int    InpL3LossDisableH     = 120;  // L3 disable hours after loss (5 days)
input double InpL3ADXMin           = 28.0; // L3 ADX minimum (strong trend)
input double InpL3ADXMax           = 40.0; // L3 ADX maximum (not exhausted)
input double InpL3MaxWickRatio     = 0.35; // L3 stricter wick filter
input int    InpL3MaxSpread        = 25;   // L3 requires tighter spread (points)
input int    InpL3ADXSpikeBars     = 5;    // Look-back bars for fake-breakout gate
input double InpL3ADXSpikeMin     = 16.0; // ADX below this N bars ago → spike risk

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

// V15 – Global risk tracking
double   g_PeakBalance        = 0.0; // highest balance/equity seen (for DD calc)

// V15 – L1 consecutive-loss cooldown
int      g_ConsecLossL1       = 0;   // rolling count of consecutive L1 losses
datetime g_L1CooldownEnd      = 0;   // L1 entry blocked until this time

// V15 – Global consecutive-loss cooldown (any level)
int      g_ConsecLossGlobal   = 0;
datetime g_GlobalCooldownEnd  = 0;

// V15 – L2 win/loss cooldowns
datetime g_L2LastWinTime      = 0;   // time of last L2 winner (4h win cooldown)
datetime g_L2LossCooldownEnd  = 0;   // L2 blocked after loss (24h)

// V15 – L3 trade cooldown + loss disable
datetime g_L3LastTime         = 0;   // time of last L3 trade (48h cooldown)
datetime g_L3LossCooldownEnd  = 0;   // L3 blocked after loss (120h = 5 days)

// V15 – Weekly protection
datetime g_WeeklyStopEnd      = 0;   // EA stopped until this time after 8% weekly loss

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

   // Reset V15 global risk state
   g_PeakBalance       = AccountInfoDouble(ACCOUNT_BALANCE);
   g_ConsecLossL1      = 0;
   g_L1CooldownEnd     = 0;
   g_ConsecLossGlobal  = 0;
   g_GlobalCooldownEnd = 0;
   g_L2LastWinTime     = 0;
   g_L2LossCooldownEnd = 0;
   g_L3LastTime        = 0;
   g_L3LossCooldownEnd = 0;
   g_WeeklyStopEnd     = 0;

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
   // V15 – Update peak from CLOSED balance only (not floating equity).
   // Using equity here would inflate the peak during open winning trades:
   // when those trades close for less than their floating peak, the EA
   // would see a fake >20% DD and permanently stop.  Balance updates only
   // after a trade closes, giving a stable high-water mark.
   double curBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(curBalance > g_PeakBalance) g_PeakBalance = curBalance;

   ManageHFTExits();
   CheckReentryArm();   // detect stop-outs; arm second-chance re-entry

   // V15 – Hard global stop: DD ≥ 20% or weekly stop active
   if(IsGlobalStopped()) return;

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

      // V15 – L1 consecutive-loss cooldown gate
      if(!IsL1TradingAllowed()) { StorePending(1, scoreRisk); return; }

      // SNIPER UPGRADE: Level 2/3 only when 4-Hour trend aligns perfectly
      if(bullishTrend && htfBullish)
      {
         int score = 0;
         if(adx > 25) score++;      // Stricter ADX for higher levels
         if(adx > 35) score++;      // Extreme momentum
         if(adxRising) score++;

         if(score == 3)      scoreRisk = InpRiskLevel3; // God Tier
         else if(score == 2) scoreRisk = InpRiskLevel2; // High Probability Sniper
      }

      // V15 SURVIVAL MODE: L2/L3 gated through institutional sniper filter.
      // If any condition fails, demote to L1 – trade still fires.
      if(scoreRisk >= InpRiskLevel3 && !IsL3SniperAllowed(ORDER_TYPE_BUY, Ask))
         scoreRisk = InpRiskLevel1;
      else if(scoreRisk >= InpRiskLevel2 && scoreRisk < InpRiskLevel3 &&
              !IsL2SniperAllowed(ORDER_TYPE_BUY))
         scoreRisk = InpRiskLevel1;

      // Precision gates: store pending instead of hard reject
      if(spread > InpMaxSpread)                                { StorePending(1, scoreRisk); return; }
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_BUY)) { StorePending(1, scoreRisk); return; }
      if(IsLargeCandle())                                      { StorePending(1, scoreRisk); return; }
      if(adx < InpADXDelayMin)                                 { StorePending(1, scoreRisk); return; }
      if(!IsEntryLocationOK(ORDER_TYPE_BUY, Ask))              { StorePending(1, scoreRisk); return; }

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

      // V15 – L1 consecutive-loss cooldown gate
      if(!IsL1TradingAllowed()) { StorePending(-1, scoreRisk); return; }

      // SNIPER UPGRADE: Level 2/3 only when 4-Hour trend aligns perfectly
      if(bearishTrend && htfBearish)
      {
         int score = 0;
         if(adx > 25) score++;      // Stricter ADX
         if(adx > 35) score++;      // Extreme momentum
         if(adxRising) score++;

         if(score == 3)      scoreRisk = InpRiskLevel3; // God Tier
         else if(score == 2) scoreRisk = InpRiskLevel2; // High Probability Sniper
      }

      // V15 SURVIVAL MODE: L2/L3 gated through institutional sniper filter.
      // If any condition fails, demote to L1 – trade still fires.
      if(scoreRisk >= InpRiskLevel3 && !IsL3SniperAllowed(ORDER_TYPE_SELL, Bid))
         scoreRisk = InpRiskLevel1;
      else if(scoreRisk >= InpRiskLevel2 && scoreRisk < InpRiskLevel3 &&
              !IsL2SniperAllowed(ORDER_TYPE_SELL))
         scoreRisk = InpRiskLevel1;

      // Precision gates: store pending instead of hard reject
      if(spread > InpMaxSpread)                                 { StorePending(-1, scoreRisk); return; }
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_SELL)) { StorePending(-1, scoreRisk); return; }
      if(IsLargeCandle())                                       { StorePending(-1, scoreRisk); return; }
      if(adx < InpADXDelayMin)                                  { StorePending(-1, scoreRisk); return; }
      if(!IsEntryLocationOK(ORDER_TYPE_SELL, Bid))              { StorePending(-1, scoreRisk); return; }

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

   // --- CHALLENGE MODE OVERRIDES (L1 and L2 only; L3 is precision-only) ---
   double effectiveRisk   = assignedRisk;
   double effectiveSL     = slPoints;
   double effectiveTPPips = InpTakeProfitPips;

   bool isL3 = (assignedRisk >= InpRiskLevel3);
   bool isL2 = (!isL3 && assignedRisk >= InpRiskLevel2);

   if(InpChallengeMode && !isL3)
   {
      effectiveRisk = InpChallengeRisk;   // 30% of balance per trade
      effectiveSL   = InpChallengeSL * InpPipMultiplier;

      // Adaptive TP: large pip target early (small balance needs big RR),
      // switch to fast scalp target once balance compounds past the threshold.
      effectiveTPPips = (balance < InpChallengeThreshold)
                        ? InpChallengeTP_Early
                        : InpChallengeTP_Late;
   }

   // V15 – Hard cap L2 at InpRiskLevel2, L3 at InpRiskLevel3 (survival-first)
   if(isL3 && effectiveRisk > InpRiskLevel3) effectiveRisk = InpRiskLevel3;
   if(isL2 && effectiveRisk > InpRiskLevel2) effectiveRisk = InpRiskLevel2;

   // V15 – Apply drawdown-based risk multiplier
   effectiveRisk *= GetRiskMultiplier();

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

   // FIX 1 – MICRO-ACCOUNT LOT BOOST (L1 only)
   // L2/L3 never receive artificial lot boosts – the spec requires precision, not size.
   bool isMicroAccount = (rawLot <= minVolume);
   if(isMicroAccount && !isL2 && !isL3)
   {
      // L1 boost: 1× minVolume (no boost; already at minimum, consistent with L1 risk)
      calculatedLot = minVolume;
   }
   else if(isMicroAccount && !isL2 && !isL3 && InpChallengeMode)
   {
      // Challenge mode L1 boost preserved
      calculatedLot = minVolume;
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
   if(assignedRisk >= InpRiskLevel3)
      comment = "V15_SniperL3";
   else if(assignedRisk >= InpRiskLevel2)
      comment = "V15_SniperL2";
   else
      comment = "V15_ScalpL1";

   // V15 – record L3 activation time for inter-trade cooling enforcement
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
   // V15 – Global 12h cooldown after 3 consecutive losses
   if(g_GlobalCooldownEnd > 0 && TimeCurrent() < g_GlobalCooldownEnd)
      return true;

   // V15 – L1 6h cooldown (checked separately in IsL1TradingAllowed, but
   // here we block if ALL levels are paused)
   // (L1 cooldown only blocks L1 trades, not the EA; handled in scoring engine)

   // V15 – Daily -3% loss protection
   if(GetDailyLossPct() >= InpDailyLossStopPct)
      return true;

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

   if(curCount < g_LastPosCount)
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

      if(lastTicket > 0)
      {
         // Determine if it was a stop-out (SL) → loss; TP/other → win
         bool wasLoss = (lastReason == DEAL_REASON_SL);

         // Find the matching ENTRY deal to get the original comment and level
         long posId = HistoryDealGetInteger(lastTicket, DEAL_POSITION_ID);
         HistorySelect(TimeCurrent() - 7 * 86400, TimeCurrent());
         string entryComment = "";
         for(int j = 0; j < HistoryDealsTotal(); j++)
         {
            ulong dj = HistoryDealGetTicket(j);
            if(HistoryDealGetInteger(dj, DEAL_POSITION_ID) != posId)      continue;
            if(HistoryDealGetInteger(dj, DEAL_ENTRY)       != DEAL_ENTRY_IN) continue;
            entryComment = HistoryDealGetString(dj, DEAL_COMMENT);
            break;
         }

         bool isL3 = (StringFind(entryComment, "SniperL3") >= 0);
         bool isL2 = (StringFind(entryComment, "SniperL2") >= 0);
         bool isL1 = (!isL2 && !isL3);

         if(wasLoss)
         {
            // --- Global consecutive loss counter ---
            g_ConsecLossGlobal++;
            if(g_ConsecLossGlobal >= InpConsecLossGlobal)
            {
               g_GlobalCooldownEnd = TimeCurrent() + (long)InpGlobalCooldownH * 3600;
               g_ConsecLossGlobal  = 0;  // reset after activating cooldown
            }

            // --- L1 consecutive loss counter ---
            if(isL1)
            {
               g_ConsecLossL1++;
               if(g_ConsecLossL1 >= InpL1ConsecLossCount)
               {
                  g_L1CooldownEnd = TimeCurrent() + (long)InpL1CooldownH * 3600;
                  g_ConsecLossL1  = 0;
               }
            }

            // --- L2 loss cooldown ---
            if(isL2)
               g_L2LossCooldownEnd = TimeCurrent() + (long)InpL2LossCooldownH * 3600;

            // --- L3 loss disable (5 days) ---
            if(isL3)
               g_L3LossCooldownEnd = TimeCurrent() + (long)InpL3LossDisableH * 3600;

            // --- Check weekly loss (≥8%) → stop for N days ---
            if(GetWeeklyLossPct() >= InpWeeklyLossStopPct)
               g_WeeklyStopEnd = TimeCurrent() + (long)InpWeeklyStopDays * 86400;
         }
         else
         {
            // --- Win: reset consecutive loss counters ---
            g_ConsecLossGlobal = 0;
            if(isL1) g_ConsecLossL1 = 0;

            // --- L2 win cooldown ---
            if(isL2) g_L2LastWinTime = TimeCurrent();
         }

         // --- Re-entry arm: only on SL stop-outs, only when not already armed ---
         if(wasLoss && !g_ReentryArmed)
         {
            // DEAL_TYPE_SELL closes a BUY position → re-entry is BUY (dir=1)
            // DEAL_TYPE_BUY  closes a SELL position → re-entry is SELL (dir=-1)
            g_ReentryDir    = (lastType == DEAL_TYPE_SELL) ? 1 : -1;
            g_ReentryArmed  = true;
            g_ReentryExpiry = TimeCurrent() + 6 * PeriodSeconds(_Period);
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
//| V15 – GLOBAL RISK HELPERS                                        |
//+------------------------------------------------------------------+

// Current equity drawdown from peak balance (%)
double GetCurrentDDPct()
{
   if(g_PeakBalance <= 0) return 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity >= g_PeakBalance) return 0.0;
   return (g_PeakBalance - equity) / g_PeakBalance * 100.0;
}

// Today's realised P&L as % of today's starting balance (positive = profit)
double GetDailyLossPct()
{
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   HistorySelect(todayStart, TimeCurrent());
   double pnl = 0.0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong dk = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(dk, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetInteger(dk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      pnl += HistoryDealGetDouble(dk, DEAL_PROFIT)
           + HistoryDealGetDouble(dk, DEAL_COMMISSION)
           + HistoryDealGetDouble(dk, DEAL_SWAP);
   }
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0) return 0.0;
   // Return as positive % when losing
   return (pnl < 0) ? (-pnl / balance * 100.0) : 0.0;
}

// This week's realised P&L as % of balance (positive = profit, negative = loss)
double GetWeeklyPnLPct()
{
   MqlDateTime dtNow;
   TimeToStruct(TimeCurrent(), dtNow);
   int daysToMon = (dtNow.day_of_week == 0) ? 6 : (dtNow.day_of_week - 1);
   datetime weekStart = iTime(_Symbol, PERIOD_D1, 0) - (long)daysToMon * 86400;

   HistorySelect(weekStart, TimeCurrent());
   double pnl = 0.0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong dk = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(dk, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetInteger(dk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      pnl += HistoryDealGetDouble(dk, DEAL_PROFIT)
           + HistoryDealGetDouble(dk, DEAL_COMMISSION)
           + HistoryDealGetDouble(dk, DEAL_SWAP);
   }
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0) return 0.0;
   return pnl / balance * 100.0;
}

// Weekly loss as positive % (0 when profitable)
double GetWeeklyLossPct()
{
   double pnlPct = GetWeeklyPnLPct();
   return (pnlPct < 0) ? -pnlPct : 0.0;
}

// Returns the DD-based risk multiplier (1.0 / 0.75 / 0.50)
double GetRiskMultiplier()
{
   double dd = GetCurrentDDPct();
   if(dd >= InpDDRisk2Pct) return 0.50;
   if(dd >= InpDDRisk1Pct) return 0.75;

   // Weekly profit > 10% → reduce risk by 30% for the rest of the week
   if(GetWeeklyPnLPct() >= InpWeeklyProfitPct) return 0.70;

   return 1.0;
}

// True when all trading must halt (DD ≥ 20% or weekly stop active)
bool IsGlobalStopped()
{
   if(GetCurrentDDPct() >= InpDDStopAllPct) return true;
   if(g_WeeklyStopEnd > 0 && TimeCurrent() < g_WeeklyStopEnd) return true;
   return false;
}

// True when L1 is currently paused due to consecutive loss cooldown
bool IsL1TradingAllowed()
{
   if(g_L1CooldownEnd > 0 && TimeCurrent() < g_L1CooldownEnd) return false;
   return true;
}

//+------------------------------------------------------------------+
//| V15 – L2 PRECISION ENGINE GATE                                   |
//+------------------------------------------------------------------+

// True when ADX has recently spiked from low-vol base (fake breakout guard)
// spikeBars and spikeMin are level-specific parameters
bool IsADXSpikeFromLow(int spikeBars, double spikeMin)
{
   int needed = spikeBars + 2;
   double adxHist[];
   ArraySetAsSeries(adxHist, true);
   if(CopyBuffer(handleADX, 0, 0, needed, adxHist) < needed) return false;
   for(int i = 2; i <= spikeBars + 1; i++)
   {
      if(adxHist[i] < spikeMin) return true;
   }
   return false;
}

// True when entry candle has acceptable wick structure for a given max ratio
bool HasCleanEntryCandle(ENUM_ORDER_TYPE type, double maxWickRatio)
{
   double high1  = iHigh(_Symbol, _Period, 1);
   double low1   = iLow(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol, _Period, 1);
   double close1 = iClose(_Symbol, _Period, 1);
   double range  = high1 - low1;
   if(range < _Point * 10) return true;

   double upperWick = high1 - MathMax(open1, close1);
   double lowerWick = MathMin(open1, close1) - low1;

   if(type == ORDER_TYPE_BUY  && upperWick / range > maxWickRatio) return false;
   if(type == ORDER_TYPE_SELL && lowerWick / range > maxWickRatio) return false;
   return true;
}

// Count L2 entry deals since a given time
int CountL2TradesInPeriod(datetime from)
{
   HistorySelect(from, TimeCurrent());
   int count = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong dk = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(dk, DEAL_MAGIC) != InpMagic)      continue;
      if(HistoryDealGetInteger(dk, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      if(StringFind(HistoryDealGetString(dk, DEAL_COMMENT), "SniperL2") >= 0) count++;
   }
   return count;
}

// Count L3 entry deals since a given time
int CountL3TradesInPeriod(datetime from)
{
   HistorySelect(from, TimeCurrent());
   int count = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong dk = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(dk, DEAL_MAGIC) != InpMagic)      continue;
      if(HistoryDealGetInteger(dk, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      if(StringFind(HistoryDealGetString(dk, DEAL_COMMENT), "SniperL3") >= 0) count++;
   }
   return count;
}

// Helper: start of current week (Monday midnight server time)
datetime GetWeekStart()
{
   MqlDateTime dtNow;
   TimeToStruct(TimeCurrent(), dtNow);
   int daysToMon = (dtNow.day_of_week == 0) ? 6 : (dtNow.day_of_week - 1);
   return iTime(_Symbol, PERIOD_D1, 0) - (long)daysToMon * 86400;
}

// Master gate for L2 – Precision Engine
bool IsL2SniperAllowed(ENUM_ORDER_TYPE type)
{
   // 1. DD ≥ 15%: disable L2
   if(GetCurrentDDPct() >= InpDDDisableL23Pct) return false;

   // 2. Loss cooldown (24h)
   if(g_L2LossCooldownEnd > 0 && TimeCurrent() < g_L2LossCooldownEnd) return false;

   // 3. Win cooldown (4h)
   if(g_L2LastWinTime > 0 &&
      TimeCurrent() < g_L2LastWinTime + (long)InpL2WinCooldownH * 3600) return false;

   // 4. Daily cap
   if(CountL2TradesInPeriod(iTime(_Symbol, PERIOD_D1, 0)) >= InpL2MaxPerDay) return false;

   // 5. Weekly cap
   if(CountL2TradesInPeriod(GetWeekStart()) >= InpL2MaxPerWeek) return false;

   // 6. ADX in range [25–35] and rising
   double adxArr[];
   ArraySetAsSeries(adxArr, true);
   if(CopyBuffer(handleADX, 0, 0, 3, adxArr) < 3) return false;
   if(adxArr[1] < InpL2ADXMin)  return false;
   if(adxArr[1] > InpL2ADXMax)  return false;
   if(adxArr[1] <= adxArr[2])   return false;  // must be rising
   if(IsADXSpikeFromLow(InpL2ADXSpikeBars, InpL2ADXSpikeMin)) return false;

   // 7. Clean entry candle (wick filter)
   if(!HasCleanEntryCandle(type, InpL2MaxWickRatio)) return false;

   // 8. Volatility safe (reuse existing filter)
   if(InpUseVolFilter && !IsVolatilitySafe(type)) return false;

   return true;
}

//+------------------------------------------------------------------+
//| V15 – L3 SNIPER ENGINE GATE                                      |
//+------------------------------------------------------------------+

// Check ATR stability: current ATR must be within 1.5× the 10-bar average
bool IsATRStable()
{
   double atrData[];
   ArraySetAsSeries(atrData, true);
   if(CopyBuffer(handleATR, 0, 0, 11, atrData) < 11) return false;
   double avg = 0;
   for(int i = 1; i <= 10; i++) avg += atrData[i];
   avg /= 10.0;
   return (atrData[0] <= avg * 1.5);
}

// Master gate for L3 – Sniper Engine
bool IsL3SniperAllowed(ENUM_ORDER_TYPE type, double currentPrice)
{
   // 1. DD ≥ 15%: disable L3
   if(GetCurrentDDPct() >= InpDDDisableL23Pct) return false;

   // 2. Loss disable (5 days = 120h)
   if(g_L3LossCooldownEnd > 0 && TimeCurrent() < g_L3LossCooldownEnd) return false;

   // 3. Inter-trade cooldown (48h)
   if(g_L3LastTime > 0 &&
      TimeCurrent() < g_L3LastTime + (long)InpL3TradeCooldownH * 3600) return false;

   // 4. Daily cap (1/day)
   if(CountL3TradesInPeriod(iTime(_Symbol, PERIOD_D1, 0)) >= InpL3MaxPerDay) return false;

   // 5. Weekly cap (2/week)
   if(CountL3TradesInPeriod(GetWeekStart()) >= InpL3MaxPerWeek) return false;

   // 6. ADX in range [28–40] and rising
   double adxArr[];
   ArraySetAsSeries(adxArr, true);
   if(CopyBuffer(handleADX, 0, 0, 3, adxArr) < 3) return false;
   if(adxArr[1] < InpL3ADXMin)  return false;
   if(adxArr[1] > InpL3ADXMax)  return false;
   if(adxArr[1] <= adxArr[2])   return false;
   if(IsADXSpikeFromLow(InpL3ADXSpikeBars, InpL3ADXSpikeMin)) return false;

   // 7. Stricter wick filter
   if(!HasCleanEntryCandle(type, InpL3MaxWickRatio)) return false;

   // 8. Stable ATR (no volatile expansion)
   if(!IsATRStable()) return false;

   // 9. Tighter spread requirement
   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = (Ask - Bid) / _Point;
   if(spread > InpL3MaxSpread) return false;

   // 10. No large impulse candle
   if(IsLargeCandle()) return false;

   return true;
}

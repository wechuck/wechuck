//+------------------------------------------------------------------+
//|                                              SCALP GOLDEA.mq5    |
//|                                  Copyright 2026, Trading Pro     |
//|   V13.0 - Precision Timing Engine (built on V10.0)               |
//+------------------------------------------------------------------+
// Changelog:
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
#property version   "13.00"
#property strict

#include <Trade\Trade.mqh>

//--- INPUT PARAMETERS
input group "=== DYNAMIC SIGNAL SCORING (HFT) ==="
input double   InpRiskLevel1     = 2.0;       // Level 1: Daily HFT Scalping
input double   InpRiskLevel2     = 5.0;       // Level 2: Sniper Trade (HTF Aligned)
input double   InpRiskLevel3     = 10.0;      // Level 3: God-Tier Trade (Perfect Confluence)

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
   ManageHFTExits();
   CheckReentryArm();   // detect stop-outs; arm second-chance re-entry

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
      if(assignedRisk >= InpRiskLevel3)
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
   if(assignedRisk >= InpRiskLevel3)
      comment = "V10_SniperL3";
   else if(assignedRisk >= InpRiskLevel2)
      comment = "V10_SniperL2";
   else
      comment = "V10_ScalpL1";

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

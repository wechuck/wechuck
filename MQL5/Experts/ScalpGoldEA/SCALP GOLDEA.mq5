//+------------------------------------------------------------------+
//|                                              SCALP GOLDEA.mq5    |
//|                                  Copyright 2026, Trading Pro     |
//|            V10.0 - Sniper Level 2/3 & HFT Level 1 Integration    |
//+------------------------------------------------------------------+
// Changelog:
//   v10.0 – Sniper Level 2/3 architecture merged with HFT Level 1.
//           HTF (H4) EMA 50/200 alignment gates Level 2 and Level 3 upgrades.
//           ADX slope (increasing momentum) added as confirmation layer.
//           Staged exits: Partial TP at 40 pips, delayed breakeven at 45 pips,
//           wide trailing stop (65 pips / 20-pip steps) to let Gold breathe.
//           Volatility filter (ATR × 4 spike rejection + body-to-ATR ratio).
//           Daily trade cap enforced via deal history scan.
//
//  FIX APPLIED (backtest analysis):
//   FIX 1 – MICRO-ACCOUNT LOT BOOST: when risk-calculation yields a lot below
//            the broker minimum (0.01), the EA is "on a micro account".  In that
//            case Level 2 is boosted to 2 × minVolume and Level 3 to 3 × minVolume
//            so each sniper tier actually trades a distinct, larger position.
//            RSI thresholds and Level 1 entry rules are unchanged from V10.0
//            to preserve the profitable 140-trade frequency shown in backtests.
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Pro"
#property link      "https://www.mql5.com"
#property version   "10.00"
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

input group "=== CHALLENGE PROTECTION (SMOOTH EQUITY CURVE) ==="
input double          InpChallengeDailyDDPct     = 15.0;       // Stop if daily drawdown hits this % – no more entries today
input int             InpChallengeMaxConsecLoss  = 2;          // Pause after N consecutive losses in one day
input double          InpChallengeDailyProfitPct = 50.0;       // Stop after gaining this % in one day – lock the profit
input double          InpChallengeBETrigger      = 25.0;       // Move to breakeven after X pips (faster than normal 45)
input ENUM_TIMEFRAMES InpChallengeHTF            = PERIOD_H1;  // Challenge entry filter TF (H1 = ~15× more signals than H4)
input int             InpChallengeHTF_FastEMA    = 21;         // Challenge HTF fast EMA period
input int             InpChallengeHTF_SlowEMA    = 50;         // Challenge HTF slow EMA period

//--- GLOBALS
CTrade trade;
int handleBB, handleRSI, handleADX, handleATR;
int handleHTF_Fast, handleHTF_Slow;
int handleChalHTF_Fast, handleChalHTF_Slow;   // Challenge-mode H1 EMA filter
double stepVolume, minVolume, maxVolume;

// Challenge mode daily tracking
double   g_DayStartBalance = 0.0;
datetime g_LastDayStart    = 0;

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

   // Initialise daily tracking for challenge protection
   g_DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_LastDayStart    = iTime(_Symbol, PERIOD_D1, 0);

   // Base Timeframe Indicators
   handleBB  = iBands(_Symbol, _Period, 20, 0, 2.0, PRICE_CLOSE);
   handleRSI = iRSI(_Symbol, _Period, 7, PRICE_CLOSE);
   handleADX = iADX(_Symbol, _Period, 14);
   handleATR = iATR(_Symbol, _Period, 14);

   // Higher Timeframe (Sniper) Indicators
   handleHTF_Fast = iMA(_Symbol, InpHTF, InpHTF_FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleHTF_Slow = iMA(_Symbol, InpHTF, InpHTF_SlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   // Challenge mode uses a faster HTF (H1 EMA21/50) so more signals fire
   handleChalHTF_Fast = iMA(_Symbol, InpChallengeHTF, InpChallengeHTF_FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleChalHTF_Slow = iMA(_Symbol, InpChallengeHTF, InpChallengeHTF_SlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(handleBB == INVALID_HANDLE || handleRSI == INVALID_HANDLE ||
      handleADX == INVALID_HANDLE || handleATR == INVALID_HANDLE ||
      handleHTF_Fast == INVALID_HANDLE || handleHTF_Slow == INVALID_HANDLE ||
      handleChalHTF_Fast == INVALID_HANDLE || handleChalHTF_Slow == INVALID_HANDLE)
   {
      Print("Indicator Failed To Load!");
      return(INIT_FAILED);
   }

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
   IndicatorRelease(handleChalHTF_Fast);
   IndicatorRelease(handleChalHTF_Slow);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   ManageHFTExits();

   // Reset daily balance snapshot at the start of each new trading day
   datetime currentDayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(currentDayStart != g_LastDayStart)
   {
      g_DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_LastDayStart    = currentDayStart;
   }

   if(PositionsTotal() > 0) return;
   if(!IsTradingTime()) return;
   if(DailyLimitsReached()) return;

   // Challenge mode equity-curve guards – block new entries if any limit is hit
   if(InpChallengeMode && ChallengeProtectionTriggered()) return;

   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double spread = (Ask - Bid) / _Point;
   if(spread > InpMaxSpread) return;

   // Base Indicators
   double bbUpper[], bbLower[], rsi[], adxMain[], adxPlus[], adxMinus[];
   ArraySetAsSeries(bbUpper, true); ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(rsi, true);     ArraySetAsSeries(adxMain, true);
   ArraySetAsSeries(adxPlus, true); ArraySetAsSeries(adxMinus, true);

   // HTF Indicators (normal sniper mode)
   double htfFast[], htfSlow[];
   ArraySetAsSeries(htfFast, true); ArraySetAsSeries(htfSlow, true);

   // Challenge mode faster HTF (H1 EMA21/50)
   double chalHTFFast[], chalHTFSlow[];
   ArraySetAsSeries(chalHTFFast, true); ArraySetAsSeries(chalHTFSlow, true);

   if(CopyBuffer(handleBB, 1, 0, 3, bbUpper) < 3) return;
   if(CopyBuffer(handleBB, 2, 0, 3, bbLower) < 3) return;
   if(CopyBuffer(handleRSI, 0, 0, 3, rsi) < 3) return;
   if(CopyBuffer(handleADX, 0, 0, 3, adxMain) < 3) return;
   if(CopyBuffer(handleADX, 1, 0, 3, adxPlus) < 3) return;
   if(CopyBuffer(handleADX, 2, 0, 3, adxMinus) < 3) return;
   if(CopyBuffer(handleHTF_Fast, 0, 0, 2, htfFast) < 2) return;
   if(CopyBuffer(handleHTF_Slow, 0, 0, 2, htfSlow) < 2) return;
   if(CopyBuffer(handleChalHTF_Fast, 0, 0, 2, chalHTFFast) < 2) return;
   if(CopyBuffer(handleChalHTF_Slow, 0, 0, 2, chalHTFSlow) < 2) return;

   // Base ADX & Trend
   double adx     = adxMain[1];
   double adxPrev = adxMain[2];
   double plus    = adxPlus[1];
   double minus   = adxMinus[1];

   bool bullishTrend = (plus > minus);
   bool bearishTrend = (minus > plus);
   bool adxRising    = (adx > adxPrev);

   // HTF (Sniper) Alignment – H4 EMA50/200 for normal mode
   bool htfBullish = (htfFast[1] > htfSlow[1]);
   bool htfBearish = (htfFast[1] < htfSlow[1]);

   // Challenge HTF Alignment – H1 EMA21/50 (much more responsive, fires ~15× more)
   bool chalHTFBullish = (chalHTFFast[1] > chalHTFSlow[1]);
   bool chalHTFBearish = (chalHTFFast[1] < chalHTFSlow[1]);

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
   // BUY SCORING ENGINE
   // ======================================================
   if(low1 <= bbLower[1] && rsi[1] < 35 && bullishCandle && strongBuyReversal)
   {
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_BUY)) return;

      // Challenge mode: only take H1-trend-confirmed shots (H1 EMA21 > EMA50)
      // This replaces the old H4 EMA50/200 gate which blocked ~98% of signals
      if(InpChallengeMode && !chalHTFBullish) return;

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

      ExecuteHFTOrder(ORDER_TYPE_BUY, Ask, slPoints, scoreRisk);
      return;
   }

   // ======================================================
   // SELL SCORING ENGINE
   // ======================================================
   if(high1 >= bbUpper[1] && rsi[1] > 65 && bearishCandle && strongSellReversal)
   {
      if(InpUseVolFilter && !IsVolatilitySafe(ORDER_TYPE_SELL)) return;

      // Challenge mode: only take H1-trend-confirmed shots (H1 EMA21 < EMA50)
      // This replaces the old H4 EMA50/200 gate which blocked ~98% of signals
      if(InpChallengeMode && !chalHTFBearish) return;

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

      ExecuteHFTOrder(ORDER_TYPE_SELL, Bid, slPoints, scoreRisk);
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
   double activeBETrigger = InpChallengeMode ? InpChallengeBETrigger : InpBETriggerPips;
   double beTriggerDist = activeBETrigger   * InpPipMultiplier * _Point;
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

//+------------------------------------------------------------------+
//| Challenge Protection: four guards for a smooth upward equity     |
//| curve – daily drawdown brake, consecutive-loss cool-down,        |
//| daily profit lock, and (via ManageHFTExits) faster breakeven.    |
//+------------------------------------------------------------------+
bool ChallengeProtectionTriggered()
{
   if(g_DayStartBalance <= 0) return false;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   // 1. Daily drawdown circuit breaker ──────────────────────────────
   // If today's floating loss drags equity below the day-start
   // balance by more than InpChallengeDailyDDPct, stop for the day.
   double dailyDD = (g_DayStartBalance - equity) / g_DayStartBalance * 100.0;
   if(dailyDD >= InpChallengeDailyDDPct)
   {
      Print("CHALLENGE GUARD: Daily DD ", DoubleToString(dailyDD, 1),
            "% reached. No new entries today.");
      return true;
   }

   // 2. Daily profit target lock ─────────────────────────────────────
   // Once balance has grown by InpChallengeDailyProfitPct today,
   // stop opening new trades to protect that compounded gain.
   double dailyGain = (balance - g_DayStartBalance) / g_DayStartBalance * 100.0;
   if(dailyGain >= InpChallengeDailyProfitPct)
   {
      Print("CHALLENGE GUARD: Daily profit target ", DoubleToString(dailyGain, 1),
            "% hit. Protecting gains.");
      return true;
   }

   // 3. Consecutive-loss cool-down ───────────────────────────────────
   // After InpChallengeMaxConsecLoss losses in a row today,
   // wait until tomorrow before taking another trade.
   if(CountConsecLossesToday() >= InpChallengeMaxConsecLoss)
   {
      Print("CHALLENGE GUARD: ", InpChallengeMaxConsecLoss,
            " consecutive losses. Cooling down until tomorrow.");
      return true;
   }

   return false;
}

// Returns how many consecutive losing trades have closed today
// (scans newest-to-oldest; stops counting the moment a winner is found).
int CountConsecLossesToday()
{
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   HistorySelect(todayStart, TimeCurrent());

   int consec = 0;
   int total  = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic)       continue;

      double pnl = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket, DEAL_SWAP)
                 + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      if(pnl < 0)
         consec++;
      else
         break; // A winning trade resets the streak
   }
   return consec;
}

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

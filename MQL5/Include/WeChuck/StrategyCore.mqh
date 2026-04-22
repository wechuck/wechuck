#ifndef __WECHUCK_STRATEGY_CORE_MQH__
#define __WECHUCK_STRATEGY_CORE_MQH__

//──────────────────────────────────────────────────────────────────────────────
// StrategyCore.mqh
// Shared signal library for the Multi-Timeframe Exhaustion & Range Scalp
// Strategy.  Contains all pure indicator logic; zero UI, zero order code.
//
// Direction integers are compatible with the EA's TradeDirection enum:
//   0 = NONE  |  1 = BUY  |  -1 = SELL
//──────────────────────────────────────────────────────────────────────────────

// Direction constants (match TradeDirection enum in EA Types.mqh)
#define STRAT_DIR_NONE  0
#define STRAT_DIR_BUY   1
#define STRAT_DIR_SELL  (-1)

enum SetupType
{
   SETUP_NONE           = 0,  // No valid signal
   SETUP_RUBBER_BAND    = 1,  // Setup A – high ADX exhaustion reversal
   SETUP_RANGE_SCALP    = 2,  // Setup B – low ADX range bounce (with Stoch cross)
   SETUP_HFT_RANGE_SCALP = 3  // Setup C – HFT box-touch scalp (no Stoch cross required)
};

// ── Parameter bundle ─────────────────────────────────────────────────────────
struct StrategyParams
{
   // ADX
   int    adxPeriod;
   double adxExhaustionLevel;    // Setup A: 1M ADX must be > this (default 40)
   double adxExpandingMin;       // Invalidation gate lower bound (default 25)
   double adxExpandingMax;       // Invalidation gate upper bound (default 35)
   double adxRangingThreshold;   // Setup B: 5M ADX must be < this (default 20)
   double adxExitWeakThreshold;  // Dynamic exit when ADX drops below (default 18)

   // RSI
   int    rsiPeriod;
   double rsiOversold;           // Setup A BUY confirmation level (default 30)
   double rsiOverbought;         // Setup A SELL confirmation level (default 70)

   // Stochastic
   int    stochKPeriod;
   int    stochDPeriod;
   int    stochSlowing;
   double stochOversold;         // Oversold threshold (default 20)
   double stochOverbought;       // Overbought threshold (default 80)

   // 5M Range Box
   int    m5RangeLookback;       // Bars of 5M history to define the box
   double boxTouchTolerancePct;  // Fraction of box size – price must be within
                                 // this fraction of the edge to qualify (0.15 = 15%)

   // Per-setup enable switches
   bool   setupAEnabled;         // Master switch for Setup A (Rubber Band)
   bool   setupBEnabled;         // Master switch for Setup B (Range Scalp)

   // Setup C – HFT Range Scalp
   bool   setupCEnabled;         // Master switch for Setup C
   bool   setupCRequireADX;      // When true, 5M ADX must be < adxRangingThreshold
   double setupCMinBoxSize;      // Minimum box range in price units (pre-converted from pips)

   // ── Box quality filters (Setup B/C) ──────────────────────────────────────
   int    minBoxAgeMinutes;      // Min minutes the box must exist before entry (0 = off)
   int    minBoxTouches;         // Min touches on the relevant wall (0 = off)
   int    maxBoxTouches;         // Max touches – wall is weakening above this (0 = off)

   // ── Wick sweep confirmation (Setup B/C) ──────────────────────────────────
   bool   requireWickSweep;      // Require wick pierce beyond box wall + close-back
   double sweepBufferPrice;      // Max pierce depth in price units beyond the wall

   // ── Dual M5 Stochastic gate ──────────────────────────────────────────────
   bool   requireM5StochConfirm; // M5 Stoch K must also be at extreme simultaneously

   // ── Rejection candle gate (Setup A/C) ────────────────────────────────────
   bool   requireRejectionCandle; // Require pin bar / hammer on the signal bar
   double minWickBodyRatio;       // Min (lower or upper wick) / body ratio (default 2.0)

   // ── ATR expansion filter ─────────────────────────────────────────────────
   bool   requireATRExpansion;    // M5 ATR must be rising vs the prior bar
   int    atrPeriod;              // ATR period (default 14)

   // ── H4 EMA trend alignment (Setup A) ─────────────────────────────────────
   bool   requireH4TrendAlign;    // Only take Setup A in H4 EMA trend direction
   int    h4EmaFast;              // H4 fast EMA period (default 50)
   int    h4EmaSlow;              // H4 slow EMA period (default 200)

   // ── Fibonacci confluence (Setup B/C, optional) ────────────────────────────
   bool   requireFibConfluence;   // Box wall must coincide with an H1 Fibonacci level
   double fibTolerancePct;        // Fib zone tolerance as % of price (default 0.10)

   // ── Expert-grade filters ─────────────────────────────────────────────────
   bool   avoidRoundNumbers;      // Skip entries when price is near a round-number magnet
   double roundNumRadiusPrice;    // Avoidance radius in price units (pre-converted from pips)
   int    minTickVolume;          // Min tick volume on the signal bar (0 = off)
   bool   liquidityVoidFilter;    // Block entry if bar range > 3× M1 ATR (gap / void)
};

// ── Signal output ─────────────────────────────────────────────────────────────
struct StrategySignal
{
   SetupType setupType;
   int       direction;          // STRAT_DIR_BUY / STRAT_DIR_SELL / STRAT_DIR_NONE
   double    adx1M;              // Last closed 1M ADX value
   double    adx1MPrev;          // 1M ADX one bar prior (for hook & expanding detection)
   bool      adxHooking;         // True when 1M ADX just turned down from its peak
   double    adx5M;              // Last closed 5M ADX value
   double    stochK;             // Last closed Stochastic %K
   double    stochKPrev;         // %K one bar prior
   double    stochD;             // Last closed Stochastic %D
   double    rsiCur;             // Last closed RSI
   double    rsiPrev;            // RSI one bar prior
   double    boxHigh;            // 5M range box upper boundary
   double    boxLow;             // 5M range box lower boundary
   double    signalBarHigh;      // 1M bar[1] high – EA uses this for wick-based SL (Setup A)
   double    signalBarLow;       // 1M bar[1] low  – EA uses this for wick-based SL (Setup A)
   string    details;            // Human-readable reason string for logging
   // ── New filter result fields ─────────────────────────────────────────────
   bool      wickSweepConfirmed; // Wick sweep was detected and confirmed
   double    sweepWickLow;       // BUY: bar[1].low of the sweep bar (SL anchor)
   double    sweepWickHigh;      // SELL: bar[1].high of the sweep bar (SL anchor)
   int       boxAgeMinutes;      // Age of the current box in minutes
   int       boxWallTouches;     // Touch count on the relevant wall
   double    m5StochK;           // M5 Stochastic K (for logging)
   int       h4Bias;             // H4 EMA bias: 1=bullish, -1=bearish, 0=neutral
};

// ── Core class ────────────────────────────────────────────────────────────────
class CStrategyCore
{
private:
   //──────────────────────────────────────────────────────────────────────────
   // Internal helper: returns true when the symbol name contains "XAU" or "GOLD".
   //──────────────────────────────────────────────────────────────────────────
   bool IsGoldSymbol(const string symbol)
   {
      return (StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0);
   }

   //──────────────────────────────────────────────────────────────────────────
   // Read ADX from closed bars.
   // outVal  = bar[1] (last closed)
   // outPrev = bar[2] (one bar prior)
   // outHooking = ADX peaked at bar[2] and turned down: bar[2] > bar[3] &&
   //              bar[1] < bar[2]  (hook detected on the last closed bar)
   //──────────────────────────────────────────────────────────────────────────
   bool GetAdxState(const string symbol, const ENUM_TIMEFRAMES tf, const int period,
                    double &outVal, double &outPrev, bool &outHooking)
   {
      outVal = 0.0; outPrev = 0.0; outHooking = false;
      int h = iADX(symbol, tf, period);
      if(h == INVALID_HANDLE) return false;

      double buf[3];
      ArraySetAsSeries(buf, true);
      // buf[0]=bar1, buf[1]=bar2, buf[2]=bar3 (all closed)
      bool ok = (CopyBuffer(h, 0, 1, 3, buf) >= 3);
      IndicatorRelease(h);
      if(!ok) return false;

      outVal     = buf[0];  // last closed bar
      outPrev    = buf[1];  // one bar prior
      // Hook: bar2 was the peak (higher than bar3), bar1 is now declining
      outHooking = (buf[1] > buf[2] && buf[0] < buf[1]);
      return true;
   }

   //──────────────────────────────────────────────────────────────────────────
   // Read Stochastic K and D from the last two closed 1M bars.
   //──────────────────────────────────────────────────────────────────────────
   bool GetStochKD(const string symbol,
                   const int kPeriod, const int dPeriod, const int slowing,
                   double &outK, double &outKPrev,
                   double &outD, double &outDPrev)
   {
      outK = outKPrev = outD = outDPrev = 0.0;
      int h = iStochastic(symbol, PERIOD_M1, kPeriod, dPeriod, slowing,
                          MODE_SMA, STO_LOWHIGH);
      if(h == INVALID_HANDLE) return false;

      double kBuf[3], dBuf[3];
      ArraySetAsSeries(kBuf, true);
      ArraySetAsSeries(dBuf, true);
      bool ok = (CopyBuffer(h, 0, 1, 3, kBuf) >= 3 &&
                 CopyBuffer(h, 1, 1, 3, dBuf) >= 3);
      IndicatorRelease(h);
      if(!ok) return false;

      outK     = kBuf[0];  // bar 1 (last closed)
      outKPrev = kBuf[1];  // bar 2
      outD     = dBuf[0];
      outDPrev = dBuf[1];
      return true;
   }

   //──────────────────────────────────────────────────────────────────────────
   // Read RSI from the last two closed 1M bars.
   //──────────────────────────────────────────────────────────────────────────
   bool GetRsiValues(const string symbol, const int period,
                     double &outCur, double &outPrev)
   {
      outCur = outPrev = 0.0;
      int h = iRSI(symbol, PERIOD_M1, period, PRICE_CLOSE);
      if(h == INVALID_HANDLE) return false;

      double buf[3];
      ArraySetAsSeries(buf, true);
      bool ok = (CopyBuffer(h, 0, 1, 3, buf) >= 3);
      IndicatorRelease(h);
      if(!ok) return false;

      outCur  = buf[0];  // bar 1
      outPrev = buf[1];  // bar 2
      return true;
   }

   //──────────────────────────────────────────────────────────────────────────
   // Build the 5M structural box from the last N closed 5M bars.
   // Box high = highest high, Box low = lowest low.
   //──────────────────────────────────────────────────────────────────────────
   bool GetM5RangeBox(const string symbol, const int lookback,
                      double &outHigh, double &outLow)
   {
      outHigh = outLow = 0.0;
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      if(CopyRates(symbol, PERIOD_M5, 1, lookback, rates) < lookback)
         return false;

      outHigh = rates[0].high;
      outLow  = rates[0].low;
      for(int i = 1; i < lookback; i++)
      {
         if(rates[i].high > outHigh) outHigh = rates[i].high;
         if(rates[i].low  < outLow)  outLow  = rates[i].low;
      }
      return true;
   }

   //──────────────────────────────────────────────────────────────────────────
   // GetBoxMetrics – box age in minutes + touch count on the relevant wall.
   // direction: STRAT_DIR_BUY → count LOW wall touches
   //            STRAT_DIR_SELL → count HIGH wall touches
   //──────────────────────────────────────────────────────────────────────────
   bool GetBoxMetrics(const string symbol, const int lookback,
                      const double boxHigh, const double boxLow,
                      const int direction,
                      int &outAgeMinutes, int &outTouches)
   {
      outAgeMinutes = 0;
      outTouches    = 0;

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(symbol, PERIOD_M5, 1, lookback, rates);
      if(copied < 2) return false;

      double boxRange   = boxHigh - boxLow;
      double tolerance  = (boxRange > 0.0) ? boxRange * 0.05 : (boxHigh * 0.0005);

      // Find the oldest bar that established the current box extreme on the relevant wall
      int oldestIdx = 0;
      for(int i = 0; i < copied; i++)
      {
         if(direction == STRAT_DIR_BUY)
         {
            if(MathAbs(rates[i].low - boxLow) <= tolerance)
               oldestIdx = i;
         }
         else
         {
            if(MathAbs(rates[i].high - boxHigh) <= tolerance)
               oldestIdx = i;
         }
      }

      outAgeMinutes = (int)((TimeCurrent() - rates[oldestIdx].time) / 60);

      // Count touches on the relevant wall
      for(int i = 0; i < copied; i++)
      {
         if(direction == STRAT_DIR_BUY && rates[i].low <= boxLow + tolerance)
            outTouches++;
         else if(direction == STRAT_DIR_SELL && rates[i].high >= boxHigh - tolerance)
            outTouches++;
      }
      return true;
   }

   //──────────────────────────────────────────────────────────────────────────
   // CheckWickSweep – validates wick-pierce-and-close-back on bar[1].
   // BUY : bar[1].low < boxLow (pierced below) AND bar[1].low >= boxLow - sweepBuffer
   //       AND bar[1].close > boxLow (closed back inside).
   // SELL: mirror logic above boxHigh.
   // On confirmation, outSweepLow / outSweepHigh hold the wick extremes for SL.
   //──────────────────────────────────────────────────────────────────────────
   bool CheckWickSweep(const MqlRates &bar1, const int direction,
                       const double boxHigh, const double boxLow,
                       const double sweepBuffer,
                       double &outSweepLow, double &outSweepHigh)
   {
      outSweepLow  = bar1.low;
      outSweepHigh = bar1.high;

      if(direction == STRAT_DIR_BUY)
      {
         return (bar1.low  < boxLow &&
                 bar1.low  >= boxLow - sweepBuffer &&
                 bar1.close > boxLow);
      }
      if(direction == STRAT_DIR_SELL)
      {
         return (bar1.high > boxHigh &&
                 bar1.high <= boxHigh + sweepBuffer &&
                 bar1.close < boxHigh);
      }
      return false;
   }

   //──────────────────────────────────────────────────────────────────────────
   // GetStochKD_TF – reads Stochastic K from the last closed bar on any TF.
   //──────────────────────────────────────────────────────────────────────────
   bool GetStochKD_TF(const string symbol, const ENUM_TIMEFRAMES tf,
                      const int kPeriod, const int dPeriod, const int slowing,
                      double &outK)
   {
      outK = 0.0;
      int h = iStochastic(symbol, tf, kPeriod, dPeriod, slowing, MODE_SMA, STO_LOWHIGH);
      if(h == INVALID_HANDLE) return false;

      double kBuf[1];
      ArraySetAsSeries(kBuf, true);
      bool ok = (CopyBuffer(h, 0, 1, 1, kBuf) >= 1);
      IndicatorRelease(h);
      if(!ok) return false;

      outK = kBuf[0];
      return true;
   }

   //──────────────────────────────────────────────────────────────────────────
   // IsRejectionCandle – pin bar / hammer / shooting star check on bar[1].
   // BUY  (hammer)       : lower wick >= minRatio × body, close in upper 40% of range.
   // SELL (shooting star): upper wick >= minRatio × body, close in lower 40% of range.
   //──────────────────────────────────────────────────────────────────────────
   bool IsRejectionCandle(const MqlRates &bar1, const int direction,
                          const double minWickBodyRatio)
   {
      double range = bar1.high - bar1.low;
      if(range <= 0.0) return false;

      double body = MathAbs(bar1.close - bar1.open);
      if(body <= 0.0) return false;   // Doji – skip

      if(direction == STRAT_DIR_BUY)
      {
         double lowerWick = MathMin(bar1.open, bar1.close) - bar1.low;
         bool   longWick  = (lowerWick >= minWickBodyRatio * body);
         bool   closedUp  = (bar1.close >= bar1.low + range * 0.60);
         return (longWick && closedUp);
      }
      if(direction == STRAT_DIR_SELL)
      {
         double upperWick = bar1.high - MathMax(bar1.open, bar1.close);
         bool   longWick  = (upperWick >= minWickBodyRatio * body);
         bool   closedDn  = (bar1.close <= bar1.low + range * 0.40);
         return (longWick && closedDn);
      }
      return false;
   }

   //──────────────────────────────────────────────────────────────────────────
   // GetATRExpansion – returns true when the M5 ATR is turning up.
   // Compares bar[1] ATR vs bar[2] ATR (both closed bars on M5).
   //──────────────────────────────────────────────────────────────────────────
   bool GetATRExpansion(const string symbol, const int period, bool &outExpanding)
   {
      outExpanding = false;
      int h = iATR(symbol, PERIOD_M5, period);
      if(h == INVALID_HANDLE) return false;

      double buf[2];
      ArraySetAsSeries(buf, true);
      // buf[0] = bar[1] (last closed), buf[1] = bar[2]
      bool ok = (CopyBuffer(h, 0, 1, 2, buf) >= 2);
      IndicatorRelease(h);
      if(!ok) return false;

      outExpanding = (buf[0] > buf[1]);
      return true;
   }

   //──────────────────────────────────────────────────────────────────────────
   // GetH4EMATrend – returns H4 EMA bias.
   // outBias:  1 = fast > slow (bullish), -1 = fast < slow (bearish), 0 = neutral/equal.
   //──────────────────────────────────────────────────────────────────────────
   bool GetH4EMATrend(const string symbol, const int fastPeriod, const int slowPeriod,
                      int &outBias)
   {
      outBias = 0;
      int hFast = iMA(symbol, PERIOD_H4, fastPeriod, 0, MODE_EMA, PRICE_CLOSE);
      int hSlow = iMA(symbol, PERIOD_H4, slowPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE)
      {
         if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
         if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
         return false;
      }

      double fast[1], slow[1];
      ArraySetAsSeries(fast, true);
      ArraySetAsSeries(slow, true);
      bool ok = (CopyBuffer(hFast, 0, 1, 1, fast) >= 1 &&
                 CopyBuffer(hSlow, 0, 1, 1, slow) >= 1);
      IndicatorRelease(hFast);
      IndicatorRelease(hSlow);
      if(!ok) return false;

      if(fast[0] > slow[0])      outBias =  1;
      else if(fast[0] < slow[0]) outBias = -1;
      return true;
   }

   //──────────────────────────────────────────────────────────────────────────
   // CheckFibConfluence – returns true when the wall price coincides with
   // a key Fibonacci retracement of the last 100-bar H1 swing range.
   // Levels checked: 23.6%, 38.2%, 50%, 61.8%, 78.6%.
   //──────────────────────────────────────────────────────────────────────────
   bool CheckFibConfluence(const string symbol, const double wallPrice,
                           const double tolerancePct)
   {
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(symbol, PERIOD_H1, 1, 100, rates);
      if(copied < 10) return false;

      double swingHigh = rates[0].high;
      double swingLow  = rates[0].low;
      for(int i = 1; i < copied; i++)
      {
         if(rates[i].high > swingHigh) swingHigh = rates[i].high;
         if(rates[i].low  < swingLow)  swingLow  = rates[i].low;
      }
      if(swingHigh <= swingLow) return false;

      double swingRange = swingHigh - swingLow;
      double tolerance  = (wallPrice * tolerancePct / 100.0);

      double fibLevels[5];
      fibLevels[0] = 0.236;
      fibLevels[1] = 0.382;
      fibLevels[2] = 0.500;
      fibLevels[3] = 0.618;
      fibLevels[4] = 0.786;

      for(int i = 0; i < 5; i++)
      {
         double fromHigh = swingHigh - swingRange * fibLevels[i];
         double fromLow  = swingLow  + swingRange * fibLevels[i];
         if(MathAbs(wallPrice - fromHigh) <= tolerance) return true;
         if(MathAbs(wallPrice - fromLow)  <= tolerance) return true;
      }
      return false;
   }

   //──────────────────────────────────────────────────────────────────────────
   // IsNearRoundNumber – returns true when price is within radius of a
   // significant round number.
   // Gold : multiples of $50 (2500, 2550, 2600, …)
   // Forex: multiples of 0.005 (50-pip steps like 1.1000, 1.1050, …)
   //──────────────────────────────────────────────────────────────────────────
   bool IsNearRoundNumber(const double price, const double radius,
                          const bool isGold)
   {
      double interval = isGold ? 50.0 : 0.005;
      double remainder = MathMod(price, interval);
      double distToRound = MathMin(remainder, interval - remainder);
      return (distToRound <= radius);
   }

   //──────────────────────────────────────────────────────────────────────────
   // Setup A BUY trigger:
   //   Stochastic K was in the oversold zone on the previous closed bar AND
   //   K has now crossed above D (bullish K/D cross).
   //──────────────────────────────────────────────────────────────────────────
   bool StochCrossedUpFromOversold(const double k,     const double kPrev,
                                   const double d,     const double dPrev,
                                   const double oversold)
   {
      return (kPrev <= oversold &&   // was in oversold on previous bar
              kPrev <= dPrev   &&   // K was below D (confirming oversold pressure)
              k > d);               // K has now crossed above D (bullish cross)
   }

   //──────────────────────────────────────────────────────────────────────────
   // Setup A SELL trigger:
   //   Stochastic K was in the overbought zone on the previous closed bar AND
   //   K has now crossed below D (bearish K/D cross).
   //──────────────────────────────────────────────────────────────────────────
   bool StochCrossedDownFromOverbought(const double k,    const double kPrev,
                                       const double d,    const double dPrev,
                                       const double overbought)
   {
      return (kPrev >= overbought &&  // was in overbought on previous bar
              kPrev >= dPrev     &&  // K was above D (confirming overbought pressure)
              k < d);               // K has now crossed below D (bearish cross)
   }

public:
   //──────────────────────────────────────────────────────────────────────────
   // Evaluate
   // Reads all indicators, applies the three master setups + invalidation rules,
   // then runs post-signal filter gates (Layer 1-3 and expert additions).
   // Returns true on successful evaluation (signal may still be SETUP_NONE).
   //──────────────────────────────────────────────────────────────────────────
   bool Evaluate(const string symbol, const StrategyParams &p,
                 StrategySignal &outSig)
   {
      // Initialise output
      outSig.setupType         = SETUP_NONE;
      outSig.direction         = STRAT_DIR_NONE;
      outSig.adx1M             = 0.0;
      outSig.adx1MPrev         = 0.0;
      outSig.adxHooking        = false;
      outSig.adx5M             = 0.0;
      outSig.stochK            = 0.0;
      outSig.stochKPrev        = 0.0;
      outSig.stochD            = 0.0;
      outSig.rsiCur            = 0.0;
      outSig.rsiPrev           = 0.0;
      outSig.boxHigh           = 0.0;
      outSig.boxLow            = 0.0;
      outSig.signalBarHigh     = 0.0;
      outSig.signalBarLow      = 0.0;
      outSig.details           = "";
      outSig.wickSweepConfirmed = false;
      outSig.sweepWickLow      = 0.0;
      outSig.sweepWickHigh     = 0.0;
      outSig.boxAgeMinutes     = 0;
      outSig.boxWallTouches    = 0;
      outSig.m5StochK          = 0.0;
      outSig.h4Bias            = 0;

      // ── Read all core indicators ──────────────────────────────────────────
      double adx1M, adx1MPrev, adx5M, adx5MPrev;
      bool   adxHooking1M, adxHooking5M;

      if(!GetAdxState(symbol, PERIOD_M1, p.adxPeriod, adx1M, adx1MPrev, adxHooking1M))
         return false;
      if(!GetAdxState(symbol, PERIOD_M5, p.adxPeriod, adx5M, adx5MPrev, adxHooking5M))
         return false;

      double stochK, stochKPrev, stochD, stochDPrev;
      if(!GetStochKD(symbol, p.stochKPeriod, p.stochDPeriod, p.stochSlowing,
                     stochK, stochKPrev, stochD, stochDPrev))
         return false;

      double rsiCur, rsiPrev;
      if(!GetRsiValues(symbol, p.rsiPeriod, rsiCur, rsiPrev))
         return false;

      double boxHigh, boxLow;
      if(!GetM5RangeBox(symbol, p.m5RangeLookback, boxHigh, boxLow))
         return false;

      // Signal bar (bar[1]) OHLCV – read early; reused for SL and filter gates
      MqlRates bar1[1];
      ArraySetAsSeries(bar1, true);
      if(CopyRates(symbol, PERIOD_M1, 1, 1, bar1) == 1)
      {
         outSig.signalBarHigh = bar1[0].high;
         outSig.signalBarLow  = bar1[0].low;
      }

      // Populate output fields so caller / logger can read raw indicator values
      outSig.adx1M      = adx1M;
      outSig.adx1MPrev  = adx1MPrev;
      outSig.adxHooking = adxHooking1M;
      outSig.adx5M      = adx5M;
      outSig.stochK     = stochK;
      outSig.stochKPrev = stochKPrev;
      outSig.stochD     = stochD;
      outSig.rsiCur     = rsiCur;
      outSig.rsiPrev    = rsiPrev;
      outSig.boxHigh    = boxHigh;
      outSig.boxLow     = boxLow;

      // ── Invalidation Gate ─────────────────────────────────────────────────
      // "If 1M/5M ADX is going 25→30→35 aggressively, we wait."
      // Applies to Setups A and B only; Setup C uses Stoch-only entry and
      // is intentionally unrestricted, so the gate is skipped when only C is active.
      bool adxExpanding = (adx1M >= p.adxExpandingMin &&
                           adx1M <= p.adxExpandingMax &&
                           adx1M > adx1MPrev);
      if(adxExpanding && (p.setupAEnabled || p.setupBEnabled))
      {
         outSig.details = StringFormat(
            "INVALIDATED – 1M ADX expanding %.1f -> %.1f (zone %.0f-%.0f)",
            adx1MPrev, adx1M, p.adxExpandingMin, p.adxExpandingMax);
         return true;  // valid evaluation; signal remains SETUP_NONE
      }

      // ── Signal detection (structured without early returns) ───────────────
      bool stochAtExtreme = (stochKPrev <= p.stochOversold ||
                             stochKPrev >= p.stochOverbought);

      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick)) return false;
      double midPrice = (tick.ask + tick.bid) * 0.5;

      // ── SETUP A: "The Rubber Band" ────────────────────────────────────────
      // Context : 1M ADX screaming high (> exhaustion level) AND hooking down.
      // Trigger : Stochastic crosses from extreme + RSI confirms curl-back.
      if(p.setupAEnabled && adx1M > p.adxExhaustionLevel && adxHooking1M && stochAtExtreme)
      {
         // BUY: Stoch crossed UP from oversold + RSI was < 30 and is curling up
         if(StochCrossedUpFromOversold(stochK, stochKPrev, stochD, stochDPrev,
                                       p.stochOversold) &&
            rsiPrev < p.rsiOversold &&
            rsiCur  > rsiPrev)
         {
            outSig.setupType = SETUP_RUBBER_BAND;
            outSig.direction = STRAT_DIR_BUY;
            outSig.details   = StringFormat(
               "SETUP A BUY | adx1M=%.1f(hook) stochK %.1f<-%.1f rsi %.1f<-%.1f",
               adx1M, stochK, stochKPrev, rsiCur, rsiPrev);
         }

         // SELL: Stoch crossed DOWN from overbought + RSI was > 70 and curling down
         if(outSig.setupType == SETUP_NONE &&
            StochCrossedDownFromOverbought(stochK, stochKPrev, stochD, stochDPrev,
                                           p.stochOverbought) &&
            rsiPrev > p.rsiOverbought &&
            rsiCur  < rsiPrev)
         {
            outSig.setupType = SETUP_RUBBER_BAND;
            outSig.direction = STRAT_DIR_SELL;
            outSig.details   = StringFormat(
               "SETUP A SELL | adx1M=%.1f(hook) stochK %.1f<-%.1f rsi %.1f<-%.1f",
               adx1M, stochK, stochKPrev, rsiCur, rsiPrev);
         }
      }

      // ── SETUP B: "The Range Scalp" ────────────────────────────────────────
      // Context : 5M ADX is dead (< ranging threshold) – market is sideways.
      // Trigger : Price touches edge of 5M structural box + Stoch cross from extreme.
      if(outSig.setupType == SETUP_NONE &&
         p.setupBEnabled && adx5M < p.adxRangingThreshold && stochAtExtreme)
      {
         double boxRange = boxHigh - boxLow;
         if(boxRange > 0.0)
         {
            double tolerance = boxRange * p.boxTouchTolerancePct;

            // BUY: price touching / near the BOTTOM of the box
            if(midPrice <= boxLow + tolerance &&
               StochCrossedUpFromOversold(stochK, stochKPrev, stochD, stochDPrev,
                                          p.stochOversold))
            {
               outSig.setupType = SETUP_RANGE_SCALP;
               outSig.direction = STRAT_DIR_BUY;
               outSig.details   = StringFormat(
                  "SETUP B BUY | adx5M=%.1f price=%.5f boxLow=%.5f stochK=%.1f",
                  adx5M, midPrice, boxLow, stochK);
            }

            // SELL: price touching / near the TOP of the box
            if(outSig.setupType == SETUP_NONE &&
               midPrice >= boxHigh - tolerance &&
               StochCrossedDownFromOverbought(stochK, stochKPrev, stochD, stochDPrev,
                                              p.stochOverbought))
            {
               outSig.setupType = SETUP_RANGE_SCALP;
               outSig.direction = STRAT_DIR_SELL;
               outSig.details   = StringFormat(
                  "SETUP B SELL | adx5M=%.1f price=%.5f boxHigh=%.5f stochK=%.1f",
                  adx5M, midPrice, boxHigh, stochK);
            }
         }
      }

      // ── SETUP C: "HFT Range Scalp" – Stochastic + RSI Filtered ──────────
      // Entry requires Stochastic K at an extreme AND RSI confirmation that
      // momentum is reversing (was oversold/overbought and is now curling back).
      //   BUY : K ≤ oversold  AND rsiPrev < rsiOversold  AND rsiCur > rsiPrev
      //   SELL: K ≥ overbought AND rsiPrev > rsiOverbought AND rsiCur < rsiPrev
      if(outSig.setupType == SETUP_NONE && p.setupCEnabled)
      {
         bool cADXok     = (!p.setupCRequireADX || adx5M < p.adxRangingThreshold);
         bool boxSizeOk  = (p.setupCMinBoxSize <= 0.0 ||
                            (boxHigh - boxLow) >= p.setupCMinBoxSize);

         if(cADXok && boxSizeOk)
         {
            if(stochK <= p.stochOversold &&
               rsiPrev < p.rsiOversold   &&
               rsiCur  > rsiPrev)
            {
               outSig.setupType = SETUP_HFT_RANGE_SCALP;
               outSig.direction = STRAT_DIR_BUY;
               outSig.details   = StringFormat(
                  "SETUP C BUY | stochK=%.1f(oversold<=%.0f) rsiPrev=%.1f rsiCur=%.1f"
                  " adx1M=%.1f adx5M=%.1f boxLow=%.5f boxHigh=%.5f",
                  stochK, p.stochOversold, rsiPrev, rsiCur, adx1M, adx5M, boxLow, boxHigh);
            }
            else if(stochK >= p.stochOverbought &&
                    rsiPrev > p.rsiOverbought   &&
                    rsiCur  < rsiPrev)
            {
               outSig.setupType = SETUP_HFT_RANGE_SCALP;
               outSig.direction = STRAT_DIR_SELL;
               outSig.details   = StringFormat(
                  "SETUP C SELL | stochK=%.1f(overbought>=%.0f) rsiPrev=%.1f rsiCur=%.1f"
                  " adx1M=%.1f adx5M=%.1f boxLow=%.5f boxHigh=%.5f",
                  stochK, p.stochOverbought, rsiPrev, rsiCur, adx1M, adx5M, boxLow, boxHigh);
            }
         }
      }

      // ── No setup found ────────────────────────────────────────────────────
      if(outSig.setupType == SETUP_NONE)
      {
         outSig.details = StringFormat(
            "NO SETUP | adx1M=%.1f(hook=%s) adx5M=%.1f stochK=%.1f rsi=%.1f",
            adx1M, adxHooking1M ? "Y" : "N", adx5M, stochK, rsiCur);
         return true;
      }

      // ═══════════════════════════════════════════════════════════════════════
      // POST-SIGNAL FILTER GATES
      // Each gate: if the condition fails, reject the signal and return true.
      // The original details string is preserved in the rejection message.
      // ═══════════════════════════════════════════════════════════════════════

      string origDetails  = outSig.details;
      bool   isBoxSetup   = (outSig.setupType == SETUP_RANGE_SCALP ||
                             outSig.setupType == SETUP_HFT_RANGE_SCALP);
      bool   isGold       = IsGoldSymbol(symbol);
      int    dir          = outSig.direction;

      // ── Gate 1: Box metrics (Setup B/C only) ─────────────────────────────
      if(isBoxSetup && (p.minBoxAgeMinutes > 0 || p.minBoxTouches > 0 || p.maxBoxTouches > 0))
      {
         int ageMin = 0, touches = 0;
         if(GetBoxMetrics(symbol, p.m5RangeLookback, boxHigh, boxLow,
                          dir, ageMin, touches))
         {
            outSig.boxAgeMinutes  = ageMin;
            outSig.boxWallTouches = touches;

            if(p.minBoxAgeMinutes > 0 && ageMin < p.minBoxAgeMinutes)
            {
               outSig.setupType  = SETUP_NONE;
               outSig.direction  = STRAT_DIR_NONE;
               outSig.details    = StringFormat(
                  "FILTERED – box too young (%d min < %d min required) | %s",
                  ageMin, p.minBoxAgeMinutes, origDetails);
               return true;
            }
            if(p.minBoxTouches > 0 && touches < p.minBoxTouches)
            {
               outSig.setupType = SETUP_NONE;
               outSig.direction = STRAT_DIR_NONE;
               outSig.details   = StringFormat(
                  "FILTERED – wall touches too few (%d < %d required) | %s",
                  touches, p.minBoxTouches, origDetails);
               return true;
            }
            if(p.maxBoxTouches > 0 && touches > p.maxBoxTouches)
            {
               outSig.setupType = SETUP_NONE;
               outSig.direction = STRAT_DIR_NONE;
               outSig.details   = StringFormat(
                  "FILTERED – wall over-touched (%d > %d max, wall weakening) | %s",
                  touches, p.maxBoxTouches, origDetails);
               return true;
            }
         }
      }

      // ── Gate 2: Wick sweep confirmation (Setup B/C only) ──────────────────
      if(isBoxSetup && p.requireWickSweep && p.sweepBufferPrice > 0.0)
      {
         if(CopyRates(symbol, PERIOD_M1, 1, 1, bar1) == 1)
         {
            double sweepLow = 0.0, sweepHigh = 0.0;
            bool   swept    = CheckWickSweep(bar1[0], dir, boxHigh, boxLow,
                                             p.sweepBufferPrice, sweepLow, sweepHigh);
            if(!swept)
            {
               outSig.setupType = SETUP_NONE;
               outSig.direction = STRAT_DIR_NONE;
               outSig.details   = StringFormat(
                  "FILTERED – no wick sweep confirmation (sweepBuf=%.5f) | %s",
                  p.sweepBufferPrice, origDetails);
               return true;
            }
            outSig.wickSweepConfirmed = true;
            outSig.sweepWickLow       = sweepLow;
            outSig.sweepWickHigh      = sweepHigh;
         }
      }

      // ── Gate 3: Dual M5 Stochastic gate ──────────────────────────────────
      if(p.requireM5StochConfirm)
      {
         double m5K = 0.0;
         bool   ok  = GetStochKD_TF(symbol, PERIOD_M5,
                                    p.stochKPeriod, p.stochDPeriod, p.stochSlowing,
                                    m5K);
         outSig.m5StochK = m5K;
         bool m5Extreme  = (dir == STRAT_DIR_BUY  && m5K <= p.stochOversold) ||
                           (dir == STRAT_DIR_SELL && m5K >= p.stochOverbought);
         if(ok && !m5Extreme)
         {
            outSig.setupType = SETUP_NONE;
            outSig.direction = STRAT_DIR_NONE;
            outSig.details   = StringFormat(
               "FILTERED – M5 Stoch K=%.1f not at extreme (%.0f/%.0f) | %s",
               m5K, p.stochOversold, p.stochOverbought, origDetails);
            return true;
         }
      }

      // ── Gate 4: Rejection candle (Setup A/C) ─────────────────────────────
      if(p.requireRejectionCandle &&
         (outSig.setupType == SETUP_RUBBER_BAND || outSig.setupType == SETUP_HFT_RANGE_SCALP))
      {
         if(CopyRates(symbol, PERIOD_M1, 1, 1, bar1) == 1)
         {
            if(!IsRejectionCandle(bar1[0], dir, p.minWickBodyRatio))
            {
               outSig.setupType = SETUP_NONE;
               outSig.direction = STRAT_DIR_NONE;
               outSig.details   = StringFormat(
                  "FILTERED – no rejection candle (wickBodyRatio=%.1f) | %s",
                  p.minWickBodyRatio, origDetails);
               return true;
            }
         }
      }

      // ── Gate 5: ATR expansion filter ──────────────────────────────────────
      if(p.requireATRExpansion && p.atrPeriod > 0)
      {
         bool expanding = false;
         bool ok        = GetATRExpansion(symbol, p.atrPeriod, expanding);
         if(ok && !expanding)
         {
            outSig.setupType = SETUP_NONE;
            outSig.direction = STRAT_DIR_NONE;
            outSig.details   = StringFormat(
               "FILTERED – M5 ATR not expanding (still compressing) | %s", origDetails);
            return true;
         }
      }

      // ── Gate 6: H4 EMA trend alignment (Setup A only) ────────────────────
      if(p.requireH4TrendAlign && outSig.setupType == SETUP_RUBBER_BAND &&
         p.h4EmaFast > 0 && p.h4EmaSlow > 0)
      {
         int  h4Bias = 0;
         bool ok     = GetH4EMATrend(symbol, p.h4EmaFast, p.h4EmaSlow, h4Bias);
         outSig.h4Bias = h4Bias;
         bool aligned  = (dir == STRAT_DIR_BUY  && h4Bias ==  1) ||
                         (dir == STRAT_DIR_SELL && h4Bias == -1);
         if(ok && !aligned)
         {
            outSig.setupType = SETUP_NONE;
            outSig.direction = STRAT_DIR_NONE;
            outSig.details   = StringFormat(
               "FILTERED – H4 EMA bias=%d conflicts with dir=%d | %s",
               h4Bias, dir, origDetails);
            return true;
         }
      }

      // ── Gate 7: Fibonacci confluence (Setup B/C, optional) ────────────────
      if(p.requireFibConfluence && isBoxSetup && p.fibTolerancePct > 0.0)
      {
         double wallPrice = (dir == STRAT_DIR_BUY) ? boxLow : boxHigh;
         if(!CheckFibConfluence(symbol, wallPrice, p.fibTolerancePct))
         {
            outSig.setupType = SETUP_NONE;
            outSig.direction = STRAT_DIR_NONE;
            outSig.details   = StringFormat(
               "FILTERED – no H1 Fib confluence at wall %.5f | %s",
               wallPrice, origDetails);
            return true;
         }
      }

      // ── Gate 8: Round-number magnet avoidance ─────────────────────────────
      if(p.avoidRoundNumbers && p.roundNumRadiusPrice > 0.0)
      {
         if(IsNearRoundNumber(midPrice, p.roundNumRadiusPrice, isGold))
         {
            outSig.setupType = SETUP_NONE;
            outSig.direction = STRAT_DIR_NONE;
            outSig.details   = StringFormat(
               "FILTERED – price %.5f near round-number magnet (radius=%.5f) | %s",
               midPrice, p.roundNumRadiusPrice, origDetails);
            return true;
         }
      }

      // ── Gate 9: Tick-volume minimum ───────────────────────────────────────
      if(p.minTickVolume > 0 && outSig.signalBarLow > 0.0)
      {
         if(CopyRates(symbol, PERIOD_M1, 1, 1, bar1) == 1)
         {
            if((long)bar1[0].tick_volume < (long)p.minTickVolume)
            {
               outSig.setupType = SETUP_NONE;
               outSig.direction = STRAT_DIR_NONE;
               outSig.details   = StringFormat(
                  "FILTERED – tick volume %I64d < minimum %d | %s",
                  bar1[0].tick_volume, p.minTickVolume, origDetails);
               return true;
            }
         }
      }

      // ── Gate 10: Liquidity void (bar range > 3× M1 ATR) ──────────────────
      if(p.liquidityVoidFilter && p.atrPeriod > 0 && outSig.signalBarLow > 0.0)
      {
         if(CopyRates(symbol, PERIOD_M1, 1, 1, bar1) == 1)
         {
            int atrH = iATR(symbol, PERIOD_M1, p.atrPeriod);
            if(atrH != INVALID_HANDLE)
            {
               double atrBuf[1];
               ArraySetAsSeries(atrBuf, true);
               if(CopyBuffer(atrH, 0, 1, 1, atrBuf) >= 1)
               {
                  double barRange = bar1[0].high - bar1[0].low;
                  if(atrBuf[0] > 0.0 && barRange > 3.0 * atrBuf[0])
                  {
                     IndicatorRelease(atrH);
                     outSig.setupType = SETUP_NONE;
                     outSig.direction = STRAT_DIR_NONE;
                     outSig.details   = StringFormat(
                        "FILTERED – liquidity void: bar range %.5f > 3x ATR %.5f | %s",
                        barRange, atrBuf[0], origDetails);
                     return true;
                  }
               }
               IndicatorRelease(atrH);
            }
         }
      }

      // ── All gates passed ─────────────────────────────────────────────────
      return true;
   }

   //──────────────────────────────────────────────────────────────────────────
   // ShouldExit
   // Returns true when momentum conditions justify closing a profitable trade.
   //   • 1M ADX dropped below the weak-exit threshold  (trend is dying)
   //   • Opposite Stochastic cross from extreme         (momentum reversed)
   //──────────────────────────────────────────────────────────────────────────
   bool ShouldExit(const string symbol, const int positionDirection,
                   const StrategyParams &p)
   {
      // ADX weak-exit
      double adx1M, adx1MPrev;
      bool   adxHooking;
      if(GetAdxState(symbol, PERIOD_M1, p.adxPeriod, adx1M, adx1MPrev, adxHooking))
      {
         if(adx1M < p.adxExitWeakThreshold)
            return true;
      }

      // Opposite Stochastic cross from extreme
      double k, kPrev, d, dPrev;
      if(GetStochKD(symbol, p.stochKPeriod, p.stochDPeriod, p.stochSlowing,
                    k, kPrev, d, dPrev))
      {
         if(positionDirection == STRAT_DIR_BUY &&
            StochCrossedDownFromOverbought(k, kPrev, d, dPrev, p.stochOverbought))
            return true;

         if(positionDirection == STRAT_DIR_SELL &&
            StochCrossedUpFromOversold(k, kPrev, d, dPrev, p.stochOversold))
            return true;
      }

      return false;
   }
};

#endif // __WECHUCK_STRATEGY_CORE_MQH__

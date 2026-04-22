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

   // Setup C – HFT Range Scalp
   bool   setupCEnabled;         // Master switch for Setup C
   bool   setupCRequireADX;      // When true, 5M ADX must be < adxRangingThreshold
   double setupCMinBoxSize;      // Minimum box range in price units (pre-converted from pips)
};

// ── Signal output ─────────────────────────────────────────────────────────────
struct StrategySignal
{
   SetupType setupType;
   int       direction;       // STRAT_DIR_BUY / STRAT_DIR_SELL / STRAT_DIR_NONE
   double    adx1M;           // Last closed 1M ADX value
   double    adx1MPrev;       // 1M ADX one bar prior (for hook & expanding detection)
   bool      adxHooking;      // True when 1M ADX just turned down from its peak
   double    adx5M;           // Last closed 5M ADX value
   double    stochK;          // Last closed Stochastic %K
   double    stochKPrev;      // %K one bar prior
   double    stochD;          // Last closed Stochastic %D
   double    rsiCur;          // Last closed RSI
   double    rsiPrev;         // RSI one bar prior
   double    boxHigh;         // 5M range box upper boundary
   double    boxLow;          // 5M range box lower boundary
   double    signalBarHigh;   // 1M bar[1] high – EA uses this for wick-based SL (Setup A)
   double    signalBarLow;    // 1M bar[1] low  – EA uses this for wick-based SL (Setup A)
   string    details;         // Human-readable reason string for logging
};

// ── Core class ────────────────────────────────────────────────────────────────
class CStrategyCore
{
private:
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
   // Reads all indicators and applies the two master setups + invalidation rules.
   // Returns true on successful evaluation (signal may still be SETUP_NONE).
   //──────────────────────────────────────────────────────────────────────────
   bool Evaluate(const string symbol, const StrategyParams &p,
                 StrategySignal &outSig)
   {
      // Initialise output
      outSig.setupType    = SETUP_NONE;
      outSig.direction    = STRAT_DIR_NONE;
      outSig.adx1M        = 0.0;
      outSig.adx1MPrev    = 0.0;
      outSig.adxHooking   = false;
      outSig.adx5M        = 0.0;
      outSig.stochK       = 0.0;
      outSig.stochKPrev   = 0.0;
      outSig.stochD       = 0.0;
      outSig.rsiCur       = 0.0;
      outSig.rsiPrev      = 0.0;
      outSig.boxHigh      = 0.0;
      outSig.boxLow       = 0.0;
      outSig.signalBarHigh = 0.0;
      outSig.signalBarLow  = 0.0;
      outSig.details      = "";

      // ── Read all indicators ───────────────────────────────────────────────
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

      // Populate output fields so caller/logger can read raw indicator values
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

      // Signal bar (bar[1]) OHLC – used by the EA to place SL just beyond the sweep wick
      MqlRates bar1[1];
      ArraySetAsSeries(bar1, true);
      if(CopyRates(symbol, PERIOD_M1, 1, 1, bar1) == 1)
      {
         outSig.signalBarHigh = bar1[0].high;
         outSig.signalBarLow  = bar1[0].low;
      }

      // ── Invalidation Gate ─────────────────────────────────────────────────
      // "If 1M/5M ADX is going 25→30→35 aggressively, we wait."
      // Applies to all setups: a strongly expanding trend is not a range.
      bool adxExpanding = (adx1M >= p.adxExpandingMin &&
                           adx1M <= p.adxExpandingMax &&
                           adx1M > adx1MPrev);
      if(adxExpanding)
      {
         outSig.details = StringFormat(
            "INVALIDATED – 1M ADX expanding %.1f -> %.1f (zone %.0f-%.0f)",
            adx1MPrev, adx1M, p.adxExpandingMin, p.adxExpandingMax);
         return true;  // valid evaluation; signal remains SETUP_NONE
      }

      // Stochastic extreme flag – required by Setup A and B but NOT by Setup C.
      bool stochAtExtreme = (stochKPrev <= p.stochOversold ||
                             stochKPrev >= p.stochOverbought);

      // ── SETUP A: "The Rubber Band" ────────────────────────────────────────
      // Context : 1M ADX screaming high (> exhaustion level) AND hooking down.
      // Trigger : Stochastic crosses from extreme + RSI confirms curl-back.
      if(adx1M > p.adxExhaustionLevel && adxHooking1M && stochAtExtreme)
      {
         // BUY: Stoch crossed UP from oversold  +  RSI was < 30 and is curling up
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
            return true;
         }

         // SELL: Stoch crossed DOWN from overbought  +  RSI was > 70 and curling down
         if(StochCrossedDownFromOverbought(stochK, stochKPrev, stochD, stochDPrev,
                                           p.stochOverbought) &&
            rsiPrev > p.rsiOverbought &&
            rsiCur  < rsiPrev)
         {
            outSig.setupType = SETUP_RUBBER_BAND;
            outSig.direction = STRAT_DIR_SELL;
            outSig.details   = StringFormat(
               "SETUP A SELL | adx1M=%.1f(hook) stochK %.1f<-%.1f rsi %.1f<-%.1f",
               adx1M, stochK, stochKPrev, rsiCur, rsiPrev);
            return true;
         }
      }

      // ── SETUP B: "The Range Scalp" ────────────────────────────────────────
      // Context : 5M ADX is dead (< ranging threshold) – market is sideways.
      // Trigger : Price touches edge of 5M structural box + Stoch cross from extreme.
      if(adx5M < p.adxRangingThreshold && stochAtExtreme)
      {
         MqlTick tick;
         if(!SymbolInfoTick(symbol, tick)) return false;
         double midPrice = (tick.ask + tick.bid) * 0.5;

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
               return true;
            }

            // SELL: price touching / near the TOP of the box
            if(midPrice >= boxHigh - tolerance &&
               StochCrossedDownFromOverbought(stochK, stochKPrev, stochD, stochDPrev,
                                              p.stochOverbought))
            {
               outSig.setupType = SETUP_RANGE_SCALP;
               outSig.direction = STRAT_DIR_SELL;
               outSig.details   = StringFormat(
                  "SETUP B SELL | adx5M=%.1f price=%.5f boxHigh=%.5f stochK=%.1f",
                  adx5M, midPrice, boxHigh, stochK);
               return true;
            }
         }
      }

      // ── SETUP C: "HFT Range Scalp" ───────────────────────────────────────
      // Context : Price ranging inside the 5M box; open price confirmed inside box.
      // Trigger : Price touches box edge + Stochastic K at extreme level
      //           (no K/D cross needed – speed matters for HFT).
      //           ADX gate is optional (InpSetupCRequireADX) – off by default so
      //           ADX at 22-25 does not block valid wall-bounce entries.
      // Hierarchy: Only evaluated when neither Setup A nor Setup B fired.
      if(p.setupCEnabled)
      {
         bool adxOkForC = (!p.setupCRequireADX || adx5M < p.adxRangingThreshold);
         if(adxOkForC)
         {
            MqlTick tick;
            if(!SymbolInfoTick(symbol, tick)) return false;
            double midPrice = (tick.ask + tick.bid) * 0.5;

            double boxRange = boxHigh - boxLow;

            // Box size guard: avoids entering tiny ranges where spread eats the move
            if(boxRange >= p.setupCMinBoxSize && boxRange > 0.0)
            {
               // Price must be inside the box at this bar\'s open
               if(midPrice > boxLow && midPrice < boxHigh)
               {
                  double tolerance = boxRange * p.boxTouchTolerancePct;

                  // BUY: price at box low + Stoch K in oversold zone (no cross required)
                  if(midPrice <= boxLow + tolerance && stochK <= p.stochOversold)
                  {
                     outSig.setupType = SETUP_HFT_RANGE_SCALP;
                     outSig.direction = STRAT_DIR_BUY;
                     outSig.details   = StringFormat(
                        "SETUP C BUY | adx5M=%.1f price=%.5f boxLow=%.5f stochK=%.1f(extreme)",
                        adx5M, midPrice, boxLow, stochK);
                     return true;
                  }

                  // SELL: price at box high + Stoch K in overbought zone (no cross required)
                  if(midPrice >= boxHigh - tolerance && stochK >= p.stochOverbought)
                  {
                     outSig.setupType = SETUP_HFT_RANGE_SCALP;
                     outSig.direction = STRAT_DIR_SELL;
                     outSig.details   = StringFormat(
                        "SETUP C SELL | adx5M=%.1f price=%.5f boxHigh=%.5f stochK=%.1f(extreme)",
                        adx5M, midPrice, boxHigh, stochK);
                     return true;
                  }
               }
            }
         }
      }

      outSig.details = StringFormat(
         "NO SETUP | adx1M=%.1f(hook=%s) adx5M=%.1f stochK=%.1f rsi=%.1f",
         adx1M, adxHooking1M ? "Y" : "N", adx5M, stochK, rsiCur);
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

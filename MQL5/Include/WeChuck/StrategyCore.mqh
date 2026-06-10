#ifndef __WECHUCK_STRATEGY_CORE_MQH__
#define __WECHUCK_STRATEGY_CORE_MQH__

//──────────────────────────────────────────────────────────────────────────────
// StrategyCore.mqh – WeChuck Institutional Edge Engine (v4.00)
//
// Six institutional-grade setups.  Zero retail-indicator crossovers.
// All signals derived from price structure, liquidity, and session mechanics.
//
// Setup A – London Liquidity Sweep   : Asian-range stop-hunt reversal
// Setup B – H4 Order Block Retest    : Institutional demand/supply zone retest
// Setup C – Fair Value Gap Fill      : H1 imbalance fill in trend direction
// Setup D – Daily Pivot Bounce       : Classic mathematical S/R with M15 confirmation
// Setup E – MSS Retest (Smart Money) : Market Structure Shift – broken level retest
// Setup F – Weekly Sniper            : Prior week High/Low sweep, 20-pip challenge
//
// Direction constants match TradeDirection enum in Types.mqh
//──────────────────────────────────────────────────────────────────────────────

#define STRAT_DIR_NONE  0
#define STRAT_DIR_BUY   1
#define STRAT_DIR_SELL  (-1)

enum SetupType
{
   SETUP_NONE              = 0,
   SETUP_LONDON_SWEEP      = 1,  // Setup A – London session Asian-range stop-hunt reversal
   SETUP_ORDER_BLOCK       = 2,  // Setup B – H4 unmitigated order block retest
   SETUP_FVG_FILL          = 3,  // Setup C – H1 Fair Value Gap fill in H4 trend direction
   SETUP_PIVOT_BOUNCE      = 4,  // Setup D – Classic daily pivot level bounce
   SETUP_MSS_RETEST        = 5,  // Setup E – H1 Market Structure Shift retest
   SETUP_WEEKLY_PRECISION  = 6   // Setup F – Weekly high/low sniper (20-pip challenge)
};

// ── Parameter bundle ─────────────────────────────────────────────────────────
struct StrategyParams
{
   // Shared: H4 EMA trend filter (all setups)
   int    h4EmaFast;             // Default 50
   int    h4EmaSlow;             // Default 200

   // Shared: Stochastic (only used by Setup F confirmation)
   int    stochKPeriod;
   int    stochDPeriod;
   int    stochSlowing;
   double stochOversold;
   double stochOverbought;

   // ── Setup A: London Liquidity Sweep ──────────────────────────────────────
   bool   setupAEnabled;
   int    asianStartHour;        // Asian session UTC start (default 0)
   int    asianEndHour;          // Asian session UTC end   (default 7)
   int    londonStartHour;       // London window UTC start (default 7)
   int    londonEndHour;         // London window UTC end   (default 10)
   double setupASweepBuf;        // Max sweep depth beyond Asian H/L in price units
   double setupAMinRange;        // Min Asian range size in price units (quality gate)

   // ── Setup B: H4 Order Block Retest ───────────────────────────────────────
   bool   setupBEnabled;
   int    setupBH4Lookback;      // H4 bars back to search for OBs (default 50)
   double setupBImpulseFactor;   // Impulse candle must be >= factor × avg range (default 1.5)
   double setupBRetestPct;       // Price must be within this fraction of OB zone (default 0.30)
   int    setupBMaxAgeHours;     // OB expires after this many hours (default 48)

   // ── Setup C: Fair Value Gap Fill ─────────────────────────────────────────
   bool   setupCEnabled;
   int    setupCH1Lookback;      // H1 bars back to search for FVGs (default 20)
   double setupCMinFVGSize;      // Min FVG size in price units (quality gate)

   // ── Setup D: Daily Pivot Bounce ───────────────────────────────────────────
   bool   setupDEnabled;
   double setupDPivotTolerance;  // Max distance from pivot in price units to qualify

   // ── Setup E: Market Structure Shift Retest ────────────────────────────────
   bool   setupEEnabled;
   int    setupESwingLookback;   // H1 bars to scan for swing high/low (default 30)
   double setupERetestBuffer;    // Retest zone half-width in price units

   // ── Setup F: Weekly Precision Scalp ──────────────────────────────────────
   bool   setupFEnabled;
   double setupFWeeklySweepBuf;  // Max M15 wick beyond weekly level (price units)
   bool   setupFRequireH4Align;  // H4 EMA must not oppose trade direction
   bool   setupFRequireM15Stoch; // M15 Stochastic must cross from extreme
};

// ── Signal output from Evaluate() ────────────────────────────────────────────
struct StrategySignal
{
   SetupType setupType;
   int       direction;      // STRAT_DIR_BUY / SELL / NONE
   string    details;

   // Price levels for SL/TP placement in the EA
   double    suggestedSL;    // Raw SL price (before spread/buffer added by EA)
   double    suggestedTP;    // Raw TP price (0 = EA uses RR-based TP)
   double    keyLevel;       // The primary S/R level that triggered the setup

   // Signal-bar context
   double    signalBarHigh;  // Last closed M15 bar high (for SL anchoring)
   double    signalBarLow;   // Last closed M15 bar low

   // Supplemental state for EA management
   int       h4Bias;         // 1=bull, -1=bear, 0=neutral
   bool      wickSweepConfirmed;
   double    sweepWickLow;   // BUY: extreme of sweep wick below key level
   double    sweepWickHigh;  // SELL: extreme of sweep wick above key level
};

// ─────────────────────────────────────────────────────────────────────────────
class CInstitutionalCore
{
private:

   //──────────────────────────────────────────────────────────────────────────
   // Utility helpers
   //──────────────────────────────────────────────────────────────────────────

   bool IsGoldSymbol(const string symbol)
   {
      string upper = symbol;
      StringToUpper(upper);
      return (StringFind(upper, "XAU") >= 0 || StringFind(upper, "GOLD") >= 0);
   }

   // Returns H4 EMA bias: 1=bullish, -1=bearish, 0=neutral/flat
   bool GetH4EMATrend(const string symbol, const int fastP, const int slowP, int &outBias)
   {
      outBias = 0;
      if(fastP <= 0 || slowP <= 0) return false;
      int hFast = iMA(symbol, PERIOD_H4, fastP, 0, MODE_EMA, PRICE_CLOSE);
      int hSlow  = iMA(symbol, PERIOD_H4, slowP,  0, MODE_EMA, PRICE_CLOSE);
      if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE)
      {
         if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
         if(hSlow  != INVALID_HANDLE) IndicatorRelease(hSlow);
         return false;
      }
      double fast[], slow[];
      ArraySetAsSeries(fast, true);
      ArraySetAsSeries(slow, true);
      bool ok = (CopyBuffer(hFast, 0, 1, 1, fast) >= 1 &&
                 CopyBuffer(hSlow,  0, 1, 1, slow) >= 1);
      IndicatorRelease(hFast);
      IndicatorRelease(hSlow);
      if(!ok) return false;
      outBias = (fast[0] > slow[0]) ? 1 : (fast[0] < slow[0]) ? -1 : 0;
      return true;
   }

   // Returns true if the last closed M15 bar shows a valid rejection candle in dir.
   // Hammer / Pin bar: the directional wick must be >= 40% of the total bar range,
   // and the candle body must close in the reversal direction.
   bool IsM15RejectionCandle(const string symbol, const int dir)
   {
      MqlRates m15[];
      ArraySetAsSeries(m15, true);
      if(CopyRates(symbol, PERIOD_M15, 1, 1, m15) < 1) return false;
      double range = m15[0].high - m15[0].low;
      if(range <= 0.0) return false;
      if(dir == STRAT_DIR_BUY)
      {
         double lowerWick = MathMin(m15[0].open, m15[0].close) - m15[0].low;
         return (lowerWick >= range * 0.40 && m15[0].close >= m15[0].open);
      }
      else
      {
         double upperWick = m15[0].high - MathMax(m15[0].open, m15[0].close);
         return (upperWick >= range * 0.40 && m15[0].close <= m15[0].open);
      }
   }

   //──────────────────────────────────────────────────────────────────────────
   // Setup A helpers – London Liquidity Sweep
   //──────────────────────────────────────────────────────────────────────────

   // Build the Asian session high/low from H1 bars between asianStartHour and
   // asianEndHour (UTC) for the current calendar day.
   // Uses TimeGMT() to avoid broker-timezone dependency.
   bool GetAsianRangeHL(const string symbol,
                        const int asianStartHour, const int asianEndHour,
                        double &asianHigh, double &asianLow)
   {
      asianHigh = 0.0;
      asianLow  = DBL_MAX;

      // Determine GMT midnight of today
      datetime gmtNow = TimeGMT();
      MqlDateTime gmtDT;
      TimeToStruct(gmtNow, gmtDT);
      datetime todayMidnightGMT = gmtNow -
         (datetime)((long)gmtDT.hour * 3600 + gmtDT.min * 60 + gmtDT.sec);

      // GMT offset of broker server (seconds)
      long gmtOffset = (long)(TimeGMT() - TimeCurrent());

      MqlRates h1[];
      ArraySetAsSeries(h1, true);
      int copied = CopyRates(symbol, PERIOD_H1, 0, 24, h1);
      if(copied < 3) return false;

      int asianBarCount = 0;
      for(int i = 0; i < copied; i++)
      {
         // Convert bar's broker time to UTC
         datetime barGMT = h1[i].time + (datetime)gmtOffset;
         MqlDateTime bd;
         TimeToStruct(barGMT, bd);

         // Must be on today's date and within the Asian session window
         if(barGMT >= todayMidnightGMT &&
            bd.hour >= asianStartHour && bd.hour < asianEndHour)
         {
            if(h1[i].high > asianHigh) asianHigh = h1[i].high;
            if(h1[i].low  < asianLow)  asianLow  = h1[i].low;
            asianBarCount++;
         }
      }

      if(asianBarCount < 2 || asianHigh <= asianLow) return false;
      return true;
   }

   // Returns true if the last closed M15 bar swept (wick pierced + closed back) the
   // Asian high (SELL) or Asian low (BUY).
   bool CheckLondonSweep(const string symbol, const int dir,
                         const double asianHigh, const double asianLow,
                         const double sweepBuf, double &outWick)
   {
      outWick = 0.0;
      MqlRates m15[];
      ArraySetAsSeries(m15, true);
      if(CopyRates(symbol, PERIOD_M15, 1, 1, m15) < 1) return false;

      if(dir == STRAT_DIR_BUY)
      {
         // Wick pierced below Asian low, closed back above it
         bool swept = (m15[0].low  <  asianLow          &&
                       m15[0].low  >= asianLow - sweepBuf &&
                       m15[0].close > asianLow);
         if(!swept) return false;
         outWick = m15[0].low;
         return true;
      }
      else
      {
         // Wick pierced above Asian high, closed back below it
         bool swept = (m15[0].high >  asianHigh          &&
                       m15[0].high <= asianHigh + sweepBuf &&
                       m15[0].close < asianHigh);
         if(!swept) return false;
         outWick = m15[0].high;
         return true;
      }
   }

   //──────────────────────────────────────────────────────────────────────────
   // Setup B helpers – H4 Order Block Retest
   //──────────────────────────────────────────────────────────────────────────

   // Finds the most recent unmitigated H4 Order Block in the given direction.
   // OB = the last opposing candle immediately before a strong directional impulse.
   // "Unmitigated" = price has not returned to the OB zone since its creation.
   bool FindH4OrderBlock(const string symbol, const int direction,
                         const int lookback, const double impulseFactor,
                         const int maxAgeHours,
                         double &obHigh, double &obLow, datetime &obTime)
   {
      obHigh = obLow = 0.0;
      obTime = 0;

      MqlRates h4[];
      ArraySetAsSeries(h4, true);
      int copied = CopyRates(symbol, PERIOD_H4, 1, lookback, h4);
      if(copied < 5) return false;

      // Average bar range for impulse detection
      double avgRange = 0.0;
      for(int i = 0; i < copied; i++)
         avgRange += (h4[i].high - h4[i].low);
      avgRange /= copied;
      if(avgRange <= 0.0) return false;

      // Scan from most recent backward (index 0 = most recent closed H4 bar)
      for(int i = 1; i < copied - 2; i++)
      {
         // The bar at index (i-1) is the potential impulse candle (more recent)
         double impulseRange = h4[i-1].high - h4[i-1].low;
         if(impulseRange < avgRange * impulseFactor) continue;

         // Age check
         datetime age = TimeCurrent() - h4[i].time;
         if(age > (datetime)((long)maxAgeHours * 3600)) continue;

         if(direction == STRAT_DIR_BUY)
         {
            // Demand OB: last BEARISH candle before a BULLISH impulse
            bool impulseIsBullish = (h4[i-1].close > h4[i-1].open);
            bool obIsBearish      = (h4[i].close    < h4[i].open);
            if(!impulseIsBullish || !obIsBearish) continue;

            // Unmitigated check: no bar between i-1 and 0 touched the OB zone
            bool mitigated = false;
            for(int j = i - 1; j >= 0; j--)
            {
               if(h4[j].low <= h4[i].open && h4[j].high >= h4[i].close)
               { mitigated = true; break; }
            }
            if(mitigated) continue;

            obHigh = MathMax(h4[i].open, h4[i].close); // body top
            obLow  = MathMin(h4[i].open, h4[i].close); // body bottom
            obTime = h4[i].time;
            return true;
         }
         else
         {
            // Supply OB: last BULLISH candle before a BEARISH impulse
            bool impulseIsBearish = (h4[i-1].close < h4[i-1].open);
            bool obIsBullish      = (h4[i].close    > h4[i].open);
            if(!impulseIsBearish || !obIsBullish) continue;

            bool mitigated = false;
            for(int j = i - 1; j >= 0; j--)
            {
               if(h4[j].low <= h4[i].close && h4[j].high >= h4[i].open)
               { mitigated = true; break; }
            }
            if(mitigated) continue;

            obHigh = MathMax(h4[i].open, h4[i].close);
            obLow  = MathMin(h4[i].open, h4[i].close);
            obTime = h4[i].time;
            return true;
         }
      }
      return false;
   }

   // Returns true if the current mid-price is inside (or within retestPct of) the OB body.
   bool PriceAtOrderBlock(const string symbol, const double obHigh, const double obLow,
                          const double retestPct)
   {
      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick)) return false;
      double mid  = (tick.ask + tick.bid) * 0.5;
      double zone = (obHigh - obLow) * retestPct;
      return (mid >= obLow - zone && mid <= obHigh + zone);
   }

   //──────────────────────────────────────────────────────────────────────────
   // Setup C helpers – Fair Value Gap (FVG) Fill
   //──────────────────────────────────────────────────────────────────────────

   // Scans recent H1 bars for the most recent FVG in the given direction.
   // Bullish FVG: bar[i+1].high < bar[i-1].low (gap going up through bar[i]).
   // Bearish FVG: bar[i+1].low  > bar[i-1].high.
   // Array is SetAsSeries: index 0 = most recent closed bar.
   bool FindH1FVG(const string symbol, const int direction,
                  const int lookback, const double minSize,
                  double &fvgHigh, double &fvgLow)
   {
      fvgHigh = fvgLow = 0.0;

      MqlRates h1[];
      ArraySetAsSeries(h1, true);
      int copied = CopyRates(symbol, PERIOD_H1, 1, lookback + 2, h1);
      if(copied < 3) return false;

      for(int i = 1; i < copied - 1; i++)
      {
         if(direction == STRAT_DIR_BUY)
         {
            // Bullish FVG: gap between h1[i+1].high and h1[i-1].low
            if(h1[i+1].high < h1[i-1].low)
            {
               double gap = h1[i-1].low - h1[i+1].high;
               if(gap >= minSize)
               {
                  fvgLow  = h1[i+1].high;
                  fvgHigh = h1[i-1].low;
                  return true; // return most recent FVG
               }
            }
         }
         else
         {
            // Bearish FVG: gap between h1[i-1].high and h1[i+1].low
            if(h1[i+1].low > h1[i-1].high)
            {
               double gap = h1[i+1].low - h1[i-1].high;
               if(gap >= minSize)
               {
                  fvgHigh = h1[i+1].low;
                  fvgLow  = h1[i-1].high;
                  return true;
               }
            }
         }
      }
      return false;
   }

   // True if current mid-price is inside the FVG zone.
   bool PriceInFVG(const string symbol, const double fvgHigh, const double fvgLow)
   {
      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick)) return false;
      double mid = (tick.ask + tick.bid) * 0.5;
      return (mid >= fvgLow && mid <= fvgHigh);
   }

   //──────────────────────────────────────────────────────────────────────────
   // Setup D helpers – Daily Classic Pivot Bounce
   //──────────────────────────────────────────────────────────────────────────

   // Calculates classic floor trader pivots from the previous completed D1 bar.
   bool GetDailyPivots(const string symbol,
                       double &pp, double &r1, double &r2, double &s1, double &s2)
   {
      pp = r1 = r2 = s1 = s2 = 0.0;
      MqlRates daily[];
      ArraySetAsSeries(daily, true);
      if(CopyRates(symbol, PERIOD_D1, 1, 1, daily) < 1) return false;
      double h = daily[0].high;
      double l = daily[0].low;
      double c = daily[0].close;
      pp = (h + l + c) / 3.0;
      r1 = 2.0 * pp - l;
      r2 = pp + (h - l);
      s1 = 2.0 * pp - h;
      s2 = pp - (h - l);
      return (pp > 0.0);
   }

   // Returns true if current price is within tolerance of pivotLevel AND the
   // last M15 bar shows a rejection candle in dir.
   bool CheckPivotBounce(const string symbol, const int dir,
                         const double pivotLevel, const double tolerance)
   {
      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick)) return false;
      double mid = (tick.ask + tick.bid) * 0.5;
      if(MathAbs(mid - pivotLevel) > tolerance) return false;
      return IsM15RejectionCandle(symbol, dir);
   }

   //──────────────────────────────────────────────────────────────────────────
   // Setup E helpers – Market Structure Shift (MSS) Retest
   //──────────────────────────────────────────────────────────────────────────

   // Finds the most recent H1 swing high (for BUY-MSS) or swing low (for SELL-MSS)
   // that has been broken by a subsequent close.  Returns the broken level (mssLevel)
   // which, once broken, flips: resistance → support (BUY) or support → resistance (SELL).
   bool FindH1MSS(const string symbol, const int direction,
                  const int lookback, double &mssLevel)
   {
      mssLevel = 0.0;
      MqlRates h1[];
      ArraySetAsSeries(h1, true);
      int copied = CopyRates(symbol, PERIOD_H1, 1, lookback, h1);
      if(copied < 10) return false;

      if(direction == STRAT_DIR_BUY)
      {
         // Look for the most recent swing HIGH (local peak) that was broken upward
         for(int i = 3; i < copied - 3; i++)
         {
            bool isSwingHigh = (h1[i].high > h1[i+1].high && h1[i].high > h1[i+2].high &&
                                h1[i].high > h1[i-1].high && h1[i].high > h1[i-2].high);
            if(!isSwingHigh) continue;

            double swingH = h1[i].high;
            // Check if any bar MORE RECENT (lower index) closed above swingH
            for(int j = 0; j < i - 1; j++)
            {
               if(h1[j].close > swingH)
               {
                  mssLevel = swingH; // flip level – now acts as support
                  return true;
               }
            }
            break; // only check the single most recent qualifying swing high
         }
      }
      else
      {
         // Look for the most recent swing LOW that was broken downward
         for(int i = 3; i < copied - 3; i++)
         {
            bool isSwingLow = (h1[i].low < h1[i+1].low && h1[i].low < h1[i+2].low &&
                               h1[i].low < h1[i-1].low && h1[i].low < h1[i-2].low);
            if(!isSwingLow) continue;

            double swingL = h1[i].low;
            for(int j = 0; j < i - 1; j++)
            {
               if(h1[j].close < swingL)
               {
                  mssLevel = swingL; // flip level – now acts as resistance
                  return true;
               }
            }
            break;
         }
      }
      return false;
   }

   // True if current price is retesting the MSS level within the buffer zone.
   bool CheckMSSRetest(const string symbol, const int dir,
                       const double mssLevel, const double buffer)
   {
      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick)) return false;
      double mid = (tick.ask + tick.bid) * 0.5;
      // Price must be approaching the level from the "new" side
      if(dir == STRAT_DIR_BUY)
         return (mid >= mssLevel - buffer && mid <= mssLevel + buffer * 0.5);
      else
         return (mid >= mssLevel - buffer * 0.5 && mid <= mssLevel + buffer);
   }

   //──────────────────────────────────────────────────────────────────────────
   // Setup F helpers – Weekly High/Low Sniper (unchanged from prior session)
   //──────────────────────────────────────────────────────────────────────────

   bool GetWeeklyHighLow(const string symbol,
                         double &priorHigh, double &priorLow,
                         double &curHigh,   double &curLow)
   {
      priorHigh = priorLow = curHigh = curLow = 0.0;
      MqlRates weekly[];
      ArraySetAsSeries(weekly, true);
      if(CopyRates(symbol, PERIOD_W1, 0, 2, weekly) < 2) return false;
      priorHigh = weekly[1].high;
      priorLow  = weekly[1].low;
      curHigh   = weekly[0].high;
      curLow    = weekly[0].low;
      return (priorHigh > priorLow);
   }

   bool CheckM15WeeklySweep(const string symbol, const int direction,
                             const double weeklyLevel, const double sweepBuf,
                             double &outSweepWick)
   {
      outSweepWick = 0.0;
      MqlRates m15[];
      ArraySetAsSeries(m15, true);
      if(CopyRates(symbol, PERIOD_M15, 1, 1, m15) < 1) return false;

      if(direction == STRAT_DIR_BUY)
      {
         if(m15[0].low  <  weeklyLevel             &&
            m15[0].low  >= weeklyLevel - sweepBuf  &&
            m15[0].close >  weeklyLevel)
         { outSweepWick = m15[0].low; return true; }
      }
      else
      {
         if(m15[0].high >  weeklyLevel             &&
            m15[0].high <= weeklyLevel + sweepBuf  &&
            m15[0].close <  weeklyLevel)
         { outSweepWick = m15[0].high; return true; }
      }
      return false;
   }

   int GetM15StochCrossDir(const string symbol,
                            const int kP, const int dP, const int slowing,
                            const double oversold, const double overbought)
   {
      int h = iStochastic(symbol, PERIOD_M15, kP, dP, slowing, MODE_SMA, STO_LOWHIGH);
      if(h == INVALID_HANDLE) return 0;
      double kBuf[], dBuf[];
      ArraySetAsSeries(kBuf, true);
      ArraySetAsSeries(dBuf, true);
      bool ok = (CopyBuffer(h, 0, 1, 2, kBuf) >= 2 &&
                 CopyBuffer(h, 1, 1, 2, dBuf) >= 2);
      IndicatorRelease(h);
      if(!ok) return 0;
      if(kBuf[1] <= oversold  && kBuf[1] <= dBuf[1] && kBuf[0] > dBuf[0]) return  1;
      if(kBuf[1] >= overbought && kBuf[1] >= dBuf[1] && kBuf[0] < dBuf[0]) return -1;
      return 0;
   }

public:

   //──────────────────────────────────────────────────────────────────────────
   // Evaluate – main signal engine
   // Returns true on success (even if no signal found).
   // outSig.setupType == SETUP_NONE means no trade.
   //──────────────────────────────────────────────────────────────────────────
   bool Evaluate(const string symbol, const StrategyParams &p, StrategySignal &outSig)
   {
      // ── Reset output ─────────────────────────────────────────────────────
      outSig.setupType          = SETUP_NONE;
      outSig.direction          = STRAT_DIR_NONE;
      outSig.details            = "";
      outSig.suggestedSL        = 0.0;
      outSig.suggestedTP        = 0.0;
      outSig.keyLevel           = 0.0;
      outSig.signalBarHigh      = 0.0;
      outSig.signalBarLow       = 0.0;
      outSig.h4Bias             = 0;
      outSig.wickSweepConfirmed = false;
      outSig.sweepWickLow       = 0.0;
      outSig.sweepWickHigh      = 0.0;

      // ── H4 EMA bias (shared gate) ─────────────────────────────────────────
      int h4Bias = 0;
      GetH4EMATrend(symbol, p.h4EmaFast, p.h4EmaSlow, h4Bias);
      outSig.h4Bias = h4Bias;

      // ── Capture the last closed M15 bar for SL anchoring ─────────────────
      {
         MqlRates m15b[];
         ArraySetAsSeries(m15b, true);
         if(CopyRates(symbol, PERIOD_M15, 1, 1, m15b) == 1)
         {
            outSig.signalBarHigh = m15b[0].high;
            outSig.signalBarLow  = m15b[0].low;
         }
      }

      // ── Current UTC hour for session gating ──────────────────────────────
      MqlDateTime gmtDT;
      TimeToStruct(TimeGMT(), gmtDT);
      int gmtHour = gmtDT.hour;

      // ═════════════════════════════════════════════════════════════════════
      // SETUP A – London Liquidity Sweep
      // Only fires during the London open window (07:00–10:00 UTC).
      // H4 bias: neutral or aligned (not strongly opposing).
      // ═════════════════════════════════════════════════════════════════════
      if(p.setupAEnabled && outSig.setupType == SETUP_NONE)
      {
         bool inLondonWindow = (gmtHour >= p.londonStartHour && gmtHour < p.londonEndHour);
         if(inLondonWindow)
         {
            double asianHigh = 0.0, asianLow = 0.0;
            if(GetAsianRangeHL(symbol, p.asianStartHour, p.asianEndHour, asianHigh, asianLow))
            {
               if((asianHigh - asianLow) >= p.setupAMinRange)
               {
                  double sweepWick = 0.0;

                  // BUY: sweep of Asian low (stop-hunt below, reversal long)
                  if(h4Bias >= 0 &&
                     CheckLondonSweep(symbol, STRAT_DIR_BUY,
                                      asianHigh, asianLow, p.setupASweepBuf, sweepWick))
                  {
                     outSig.setupType          = SETUP_LONDON_SWEEP;
                     outSig.direction          = STRAT_DIR_BUY;
                     outSig.keyLevel           = asianLow;
                     outSig.wickSweepConfirmed = true;
                     outSig.sweepWickLow       = sweepWick;
                     outSig.suggestedSL        = sweepWick;          // EA adds buffer
                     outSig.suggestedTP        = asianHigh;          // Opposite Asian wall
                     outSig.details            = StringFormat(
                        "SETUP A BUY | Asian=[%.5f,%.5f] wick=%.5f h4=%d",
                        asianLow, asianHigh, sweepWick, h4Bias);
                  }
                  // SELL: sweep of Asian high (stop-hunt above, reversal short)
                  else if(h4Bias <= 0 &&
                          CheckLondonSweep(symbol, STRAT_DIR_SELL,
                                           asianHigh, asianLow, p.setupASweepBuf, sweepWick))
                  {
                     outSig.setupType          = SETUP_LONDON_SWEEP;
                     outSig.direction          = STRAT_DIR_SELL;
                     outSig.keyLevel           = asianHigh;
                     outSig.wickSweepConfirmed = true;
                     outSig.sweepWickHigh      = sweepWick;
                     outSig.suggestedSL        = sweepWick;
                     outSig.suggestedTP        = asianLow;
                     outSig.details            = StringFormat(
                        "SETUP A SELL | Asian=[%.5f,%.5f] wick=%.5f h4=%d",
                        asianLow, asianHigh, sweepWick, h4Bias);
                  }
               }
            }
         }
      }

      // ═════════════════════════════════════════════════════════════════════
      // SETUP B – H4 Order Block Retest
      // Active all sessions.  H4 bias must align.
      // ═════════════════════════════════════════════════════════════════════
      if(p.setupBEnabled && outSig.setupType == SETUP_NONE)
      {
         double obH = 0.0, obL = 0.0;
         datetime obTime = 0;

         // BUY – Demand Order Block
         if(h4Bias >= 0 &&
            FindH4OrderBlock(symbol, STRAT_DIR_BUY,
                             p.setupBH4Lookback, p.setupBImpulseFactor,
                             p.setupBMaxAgeHours, obH, obL, obTime) &&
            PriceAtOrderBlock(symbol, obH, obL, p.setupBRetestPct) &&
            IsM15RejectionCandle(symbol, STRAT_DIR_BUY))
         {
            outSig.setupType   = SETUP_ORDER_BLOCK;
            outSig.direction   = STRAT_DIR_BUY;
            outSig.keyLevel    = obL;
            outSig.suggestedSL = obL - (obH - obL) * 0.20; // just below OB body
            outSig.suggestedTP = 0.0;                        // EA uses RR-based TP
            outSig.details     = StringFormat(
               "SETUP B BUY | OB=[%.5f,%.5f] age=%dh h4=%d",
               obL, obH, (int)((TimeCurrent() - obTime) / 3600), h4Bias);
         }
         // SELL – Supply Order Block
         else if(h4Bias <= 0 &&
                 FindH4OrderBlock(symbol, STRAT_DIR_SELL,
                                  p.setupBH4Lookback, p.setupBImpulseFactor,
                                  p.setupBMaxAgeHours, obH, obL, obTime) &&
                 PriceAtOrderBlock(symbol, obH, obL, p.setupBRetestPct) &&
                 IsM15RejectionCandle(symbol, STRAT_DIR_SELL))
         {
            outSig.setupType   = SETUP_ORDER_BLOCK;
            outSig.direction   = STRAT_DIR_SELL;
            outSig.keyLevel    = obH;
            outSig.suggestedSL = obH + (obH - obL) * 0.20;
            outSig.suggestedTP = 0.0;
            outSig.details     = StringFormat(
               "SETUP B SELL | OB=[%.5f,%.5f] age=%dh h4=%d",
               obL, obH, (int)((TimeCurrent() - obTime) / 3600), h4Bias);
         }
      }

      // ═════════════════════════════════════════════════════════════════════
      // SETUP C – Fair Value Gap Fill (H1 imbalance in H4 trend direction)
      // ═════════════════════════════════════════════════════════════════════
      if(p.setupCEnabled && outSig.setupType == SETUP_NONE)
      {
         double fvgH = 0.0, fvgL = 0.0;

         if(h4Bias >= 0 &&
            FindH1FVG(symbol, STRAT_DIR_BUY,
                      p.setupCH1Lookback, p.setupCMinFVGSize, fvgH, fvgL) &&
            PriceInFVG(symbol, fvgH, fvgL))
         {
            outSig.setupType   = SETUP_FVG_FILL;
            outSig.direction   = STRAT_DIR_BUY;
            outSig.keyLevel    = fvgL;
            outSig.suggestedSL = fvgL - (fvgH - fvgL) * 0.50; // below FVG
            outSig.suggestedTP = 0.0;
            outSig.details     = StringFormat(
               "SETUP C BUY | FVG=[%.5f,%.5f] h4=%d", fvgL, fvgH, h4Bias);
         }
         else if(h4Bias <= 0 &&
                 FindH1FVG(symbol, STRAT_DIR_SELL,
                           p.setupCH1Lookback, p.setupCMinFVGSize, fvgH, fvgL) &&
                 PriceInFVG(symbol, fvgH, fvgL))
         {
            outSig.setupType   = SETUP_FVG_FILL;
            outSig.direction   = STRAT_DIR_SELL;
            outSig.keyLevel    = fvgH;
            outSig.suggestedSL = fvgH + (fvgH - fvgL) * 0.50;
            outSig.suggestedTP = 0.0;
            outSig.details     = StringFormat(
               "SETUP C SELL | FVG=[%.5f,%.5f] h4=%d", fvgL, fvgH, h4Bias);
         }
      }

      // ═════════════════════════════════════════════════════════════════════
      // SETUP D – Daily Classic Pivot Bounce
      // H4 alignment required; active sessions only.
      // ═════════════════════════════════════════════════════════════════════
      if(p.setupDEnabled && outSig.setupType == SETUP_NONE)
      {
         double pp = 0, r1 = 0, r2 = 0, s1 = 0, s2 = 0;
         if(GetDailyPivots(symbol, pp, r1, r2, s1, s2))
         {
            // Level table: {price, direction, TP target}
            double levels[5]    = { s2,  s1,   pp,  r1,  r2 };
            int    dirs[5]      = { STRAT_DIR_BUY, STRAT_DIR_BUY, STRAT_DIR_NONE,
                                    STRAT_DIR_SELL, STRAT_DIR_SELL };
            double tpTargets[5] = { s1,  pp,  0.0,  pp,  r1 };

            for(int i = 0; i < 5; i++)
            {
               int pDir = dirs[i];
               // PP direction depends on H4 bias
               if(i == 2) pDir = (h4Bias > 0) ? STRAT_DIR_BUY :
                                 (h4Bias < 0) ? STRAT_DIR_SELL : STRAT_DIR_NONE;
               if(pDir == STRAT_DIR_NONE) continue;
               // H4 alignment gate for support/resistance pivots
               if(h4Bias > 0 && pDir == STRAT_DIR_SELL) continue;
               if(h4Bias < 0 && pDir == STRAT_DIR_BUY)  continue;

               if(CheckPivotBounce(symbol, pDir, levels[i], p.setupDPivotTolerance))
               {
                  outSig.setupType   = SETUP_PIVOT_BOUNCE;
                  outSig.direction   = pDir;
                  outSig.keyLevel    = levels[i];
                  outSig.suggestedSL = (pDir == STRAT_DIR_BUY)
                                       ? levels[i] - p.setupDPivotTolerance * 3.0
                                       : levels[i] + p.setupDPivotTolerance * 3.0;
                  outSig.suggestedTP = (tpTargets[i] > 0.0) ? tpTargets[i] : 0.0;
                  outSig.details     = StringFormat(
                     "SETUP D %s | pivot=%.5f pp=%.5f r1=%.5f s1=%.5f h4=%d",
                     pDir == STRAT_DIR_BUY ? "BUY" : "SELL",
                     levels[i], pp, r1, s1, h4Bias);
                  break;
               }
            }
         }
      }

      // ═════════════════════════════════════════════════════════════════════
      // SETUP E – Market Structure Shift (MSS) Retest
      // Finds H1 BOS → waits for retest of the broken level with M15 rejection.
      // H4 alignment required.
      // ═════════════════════════════════════════════════════════════════════
      if(p.setupEEnabled && outSig.setupType == SETUP_NONE)
      {
         double mssLevel = 0.0;

         if(h4Bias >= 0 &&
            FindH1MSS(symbol, STRAT_DIR_BUY, p.setupESwingLookback, mssLevel) &&
            CheckMSSRetest(symbol, STRAT_DIR_BUY, mssLevel, p.setupERetestBuffer) &&
            IsM15RejectionCandle(symbol, STRAT_DIR_BUY))
         {
            outSig.setupType   = SETUP_MSS_RETEST;
            outSig.direction   = STRAT_DIR_BUY;
            outSig.keyLevel    = mssLevel;
            outSig.suggestedSL = mssLevel - p.setupERetestBuffer * 2.5;
            outSig.suggestedTP = 0.0;
            outSig.details     = StringFormat(
               "SETUP E BUY | mssLevel=%.5f h4=%d", mssLevel, h4Bias);
         }
         else if(h4Bias <= 0 &&
                 FindH1MSS(symbol, STRAT_DIR_SELL, p.setupESwingLookback, mssLevel) &&
                 CheckMSSRetest(symbol, STRAT_DIR_SELL, mssLevel, p.setupERetestBuffer) &&
                 IsM15RejectionCandle(symbol, STRAT_DIR_SELL))
         {
            outSig.setupType   = SETUP_MSS_RETEST;
            outSig.direction   = STRAT_DIR_SELL;
            outSig.keyLevel    = mssLevel;
            outSig.suggestedSL = mssLevel + p.setupERetestBuffer * 2.5;
            outSig.suggestedTP = 0.0;
            outSig.details     = StringFormat(
               "SETUP E SELL | mssLevel=%.5f h4=%d", mssLevel, h4Bias);
         }
      }

      // ═════════════════════════════════════════════════════════════════════
      // SETUP F – Weekly High/Low Sniper (20-pip challenge)
      // Most selective setup: fires only 2–3 times/week on perfect alignment.
      // ═════════════════════════════════════════════════════════════════════
      if(p.setupFEnabled && outSig.setupType == SETUP_NONE)
      {
         double priorHigh = 0, priorLow = 0, curHigh = 0, curLow = 0;
         if(GetWeeklyHighLow(symbol, priorHigh, priorLow, curHigh, curLow))
         {
            int    fDir        = STRAT_DIR_NONE;
            double wklyLevel   = 0.0;
            double sweepWick   = 0.0;

            double sw = 0.0;
            if(CheckM15WeeklySweep(symbol, STRAT_DIR_BUY,
                                   priorLow, p.setupFWeeklySweepBuf, sw))
            { fDir = STRAT_DIR_BUY; wklyLevel = priorLow; sweepWick = sw; }

            if(fDir == STRAT_DIR_NONE)
            {
               if(CheckM15WeeklySweep(symbol, STRAT_DIR_SELL,
                                      priorHigh, p.setupFWeeklySweepBuf, sw))
               { fDir = STRAT_DIR_SELL; wklyLevel = priorHigh; sweepWick = sw; }
            }

            if(fDir != STRAT_DIR_NONE)
            {
               bool h4Ok = true;
               if(p.setupFRequireH4Align)
                  h4Ok = (fDir == STRAT_DIR_BUY ? h4Bias >= 0 : h4Bias <= 0);

               bool m15Ok = true;
               if(p.setupFRequireM15Stoch)
               {
                  int crossDir = GetM15StochCrossDir(symbol,
                                                     p.stochKPeriod, p.stochDPeriod,
                                                     p.stochSlowing,
                                                     p.stochOversold, p.stochOverbought);
                  m15Ok = (crossDir == fDir);
               }

               if(h4Ok && m15Ok)
               {
                  outSig.setupType          = SETUP_WEEKLY_PRECISION;
                  outSig.direction          = fDir;
                  outSig.keyLevel           = wklyLevel;
                  outSig.wickSweepConfirmed = true;
                  if(fDir == STRAT_DIR_BUY) outSig.sweepWickLow  = sweepWick;
                  else                       outSig.sweepWickHigh = sweepWick;
                  outSig.suggestedSL = sweepWick; // EA adds buffer
                  outSig.suggestedTP = 0.0;        // EA uses fixed pip target
                  outSig.details = StringFormat(
                     "SETUP F %s | wklyLevel=%.5f wick=%.5f h4=%d h4ok=%s m15ok=%s",
                     fDir == STRAT_DIR_BUY ? "BUY" : "SELL",
                     wklyLevel, sweepWick, h4Bias,
                     h4Ok ? "Y" : "N", m15Ok ? "Y" : "N");
               }
            }
         }
      }

      // ── No setup ─────────────────────────────────────────────────────────
      if(outSig.setupType == SETUP_NONE)
         outSig.details = StringFormat("NO SETUP | h4=%d utcHour=%d", h4Bias, gmtHour);

      return true;
   }

   //──────────────────────────────────────────────────────────────────────────
   // ShouldExit – dynamic exit condition
   // Returns true when the H4 EMA flips against the trade direction.
   //──────────────────────────────────────────────────────────────────────────
   bool ShouldExit(const string symbol, const int posDir, const StrategyParams &p)
   {
      int h4Bias = 0;
      if(GetH4EMATrend(symbol, p.h4EmaFast, p.h4EmaSlow, h4Bias))
      {
         if(posDir == STRAT_DIR_BUY  && h4Bias < 0) return true;
         if(posDir == STRAT_DIR_SELL && h4Bias > 0) return true;
      }
      return false;
   }
};

#endif // __WECHUCK_STRATEGY_CORE_MQH__

#ifndef __WECHUCK_ENTRY_SCORING_MQH__
#define __WECHUCK_ENTRY_SCORING_MQH__

#include "Types.mqh"

#define ADX_THRESHOLD_LOW 20.0
#define ADX_THRESHOLD_HIGH 30.0
#define ADX_EXIT_WEAK_THRESHOLD 18.0
#define ZSCORE_ENTRY_WEIGHT 2
#define ZSCORE_NORMALIZATION_EXIT 0.2
#define VOLUME_SPIKE_MULTIPLIER 1.5

class CEntryScoring
{
private:
   bool StochCross(const string symbol, const int direction, const int kPeriod, const int dPeriod, const int slowing, bool &crossed)
   {
      crossed = false;
      int stoch = iStochastic(symbol, PERIOD_M1, kPeriod, dPeriod, slowing, MODE_SMA, STO_LOWHIGH);
      if(stoch == INVALID_HANDLE) return false;

      double k[3], d[3];
      ArraySetAsSeries(k, true);
      ArraySetAsSeries(d, true);
      bool ok = (CopyBuffer(stoch, 0, 1, 3, k) >= 3 && CopyBuffer(stoch, 1, 1, 3, d) >= 3);
      IndicatorRelease(stoch);
      if(!ok) return false;

      if(direction == DIR_BUY)
         crossed = (k[1] <= d[1] && k[0] > d[0]);
      else if(direction == DIR_SELL)
         crossed = (k[1] >= d[1] && k[0] < d[0]);
      return true;
   }

public:
   bool Evaluate(const string symbol,
                 const int direction,
                 const int adxPeriod,
                 const double adxThresholdLow,
                 const double adxThresholdHigh,
                 const int zscorePeriod,
                 const double zscoreThreshold,
                 const int stochK,
                 const int stochD,
                 const int stochSlowing,
                 const int breakoutBars,
                 const int volumeMaPeriod,
                 EntryScoreBreakdown &outScore)
   {
      outScore.adx = 0;
      outScore.zscore = 0;
      outScore.stoch = 0;
      outScore.breakout = 0;
      outScore.volume = 0;
      outScore.total = 0;
      outScore.details = "";

      int adxHandle = iADX(symbol, PERIOD_M1, adxPeriod);
      if(adxHandle != INVALID_HANDLE)
      {
         double adxBuf[2];
         ArraySetAsSeries(adxBuf, true);
         if(CopyBuffer(adxHandle, 0, 1, 2, adxBuf) >= 2)
         {
            double adxVal = adxBuf[0];
            if(adxVal >= adxThresholdHigh)      outScore.adx = 2;
            else if(adxVal >= adxThresholdLow)  outScore.adx = 1;
         }
         IndicatorRelease(adxHandle);
      }

      double closeBuf[];
      ArrayResize(closeBuf, zscorePeriod + 2);
      ArraySetAsSeries(closeBuf, true);
      if(CopyClose(symbol, PERIOD_M1, 1, zscorePeriod + 1, closeBuf) >= zscorePeriod + 1)
      {
         double mean = 0.0;
         for(int i = 1; i <= zscorePeriod; i++) mean += closeBuf[i];
         mean /= zscorePeriod;

         double var = 0.0;
         for(int i = 1; i <= zscorePeriod; i++)
         {
            double d = closeBuf[i] - mean;
            var += d * d;
         }
         double stddev = MathSqrt(var / zscorePeriod);
         if(stddev > 0.0)
         {
            double z = (closeBuf[0] - mean) / stddev;
            if(direction == DIR_BUY && z >= zscoreThreshold) outScore.zscore = ZSCORE_ENTRY_WEIGHT;
            else if(direction == DIR_SELL && z <= -zscoreThreshold) outScore.zscore = ZSCORE_ENTRY_WEIGHT;
         }
      }

      bool stochCrossed = false;
      if(StochCross(symbol, direction, stochK, stochD, stochSlowing, stochCrossed) && stochCrossed)
         outScore.stoch = 1;

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      if(CopyRates(symbol, PERIOD_M1, 1, breakoutBars + 2, rates) >= breakoutBars + 2)
      {
         double hh = rates[2].high;
         double ll = rates[2].low;
         for(int i = 3; i <= breakoutBars + 1; i++)
         {
            if(rates[i].high > hh) hh = rates[i].high;
            if(rates[i].low < ll) ll = rates[i].low;
         }

         if(direction == DIR_BUY && rates[1].close > hh) outScore.breakout = 1;
         else if(direction == DIR_SELL && rates[1].close < ll) outScore.breakout = 1;
      }

      long vol[];
      ArrayResize(vol, volumeMaPeriod + 2);
      ArraySetAsSeries(vol, true);
      if(CopyTickVolume(symbol, PERIOD_M1, 1, volumeMaPeriod + 1, vol) >= volumeMaPeriod + 1)
      {
         double avg = 0.0;
         for(int i = 1; i <= volumeMaPeriod; i++) avg += (double)vol[i];
         avg /= volumeMaPeriod;
         if(avg > 0.0 && (double)vol[0] > VOLUME_SPIKE_MULTIPLIER * avg) outScore.volume = 1;
      }

      outScore.total = outScore.adx + outScore.zscore + outScore.stoch + outScore.breakout + outScore.volume;
      outScore.details = StringFormat("adx=%d,z=%d,stoch=%d,breakout=%d,vol=%d,total=%d",
                                      outScore.adx, outScore.zscore, outScore.stoch, outScore.breakout, outScore.volume, outScore.total);
      return true;
   }

   bool ShouldExitByDynamics(const string symbol, const int positionDirection, const int stochK, const int stochD, const int stochSlowing, const int zscorePeriod, const int adxPeriod, const double adxExitWeakThreshold)
   {
      int opposite = (positionDirection == DIR_BUY ? DIR_SELL : DIR_BUY);
      bool cross = false;
      bool stochExit = StochCross(symbol, opposite, stochK, stochD, stochSlowing, cross) && cross;

      bool adxWeak = false;
      int adxHandle = iADX(symbol, PERIOD_M1, adxPeriod);
      if(adxHandle != INVALID_HANDLE)
      {
         double adxBuf[2];
         ArraySetAsSeries(adxBuf, true);
         if(CopyBuffer(adxHandle, 0, 1, 2, adxBuf) >= 2)
            adxWeak = (adxBuf[0] < adxExitWeakThreshold);
         IndicatorRelease(adxHandle);
      }

      bool zNorm = false;
      double closeBuf[];
      ArrayResize(closeBuf, zscorePeriod + 2);
      ArraySetAsSeries(closeBuf, true);
      if(CopyClose(symbol, PERIOD_M1, 1, zscorePeriod + 1, closeBuf) >= zscorePeriod + 1)
      {
         double mean = 0.0;
         for(int i = 1; i <= zscorePeriod; i++) mean += closeBuf[i];
         mean /= zscorePeriod;

         double var = 0.0;
         for(int i = 1; i <= zscorePeriod; i++)
         {
            double d = closeBuf[i] - mean;
            var += d * d;
         }
         double stddev = MathSqrt(var / zscorePeriod);
         if(stddev > 0.0)
         {
            double z = (closeBuf[0] - mean) / stddev;
            zNorm = (MathAbs(z) < ZSCORE_NORMALIZATION_EXIT);
         }
      }

      return (stochExit || zNorm || adxWeak);
   }
};

#endif

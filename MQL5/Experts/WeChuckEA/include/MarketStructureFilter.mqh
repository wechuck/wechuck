#ifndef __WECHUCK_MARKET_STRUCTURE_FILTER_MQH__
#define __WECHUCK_MARKET_STRUCTURE_FILTER_MQH__

#include "Types.mqh"

class CMarketStructureFilter
{
public:
   bool Evaluate(const string symbol, const int emaFastPeriod, const int emaSlowPeriod, const int structureLookback, BiasResult &outBias)
   {
      outBias.direction = DIR_NONE;
      outBias.emaBull = false;
      outBias.emaBear = false;
      outBias.structureBull = false;
      outBias.structureBear = false;
      outBias.details = "";

      int emaFast = iMA(symbol, PERIOD_M15, emaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
      int emaSlow = iMA(symbol, PERIOD_M15, emaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(emaFast == INVALID_HANDLE || emaSlow == INVALID_HANDLE)
      {
         outBias.details = "EMA handles invalid";
         return false;
      }

      double fastBuf[], slowBuf[];
      ArraySetAsSeries(fastBuf, true);
      ArraySetAsSeries(slowBuf, true);
      if(CopyBuffer(emaFast, 0, 1, 2, fastBuf) < 2 || CopyBuffer(emaSlow, 0, 1, 2, slowBuf) < 2)
      {
         IndicatorRelease(emaFast);
         IndicatorRelease(emaSlow);
         outBias.details = "EMA copy failed";
         return false;
      }

      outBias.emaBull = (fastBuf[0] > slowBuf[0]);
      outBias.emaBear = (fastBuf[0] < slowBuf[0]);

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int needBars = (structureLookback * 2) + 5;
      if(CopyRates(symbol, PERIOD_M15, 1, needBars, rates) < needBars)
      {
         IndicatorRelease(emaFast);
         IndicatorRelease(emaSlow);
         outBias.details = "Insufficient M15 bars";
         return false;
      }

      int recentStart = 1;
      int recentEnd = structureLookback;
      int prevStart = structureLookback + 1;
      int prevEnd = structureLookback * 2;

      if(prevEnd >= ArraySize(rates))
      {
         IndicatorRelease(emaFast);
         IndicatorRelease(emaSlow);
         outBias.details = "Structure window out of bounds";
         return false;
      }

      double recentHigh = rates[recentStart].high;
      double prevHigh = rates[prevStart].high;
      double recentLow = rates[recentStart].low;
      double prevLow = rates[prevStart].low;

      for(int i = recentStart + 1; i <= recentEnd; i++)
      {
         if(rates[i].high > recentHigh) recentHigh = rates[i].high;
         if(rates[i].low < recentLow) recentLow = rates[i].low;
      }

      for(int i = prevStart + 1; i <= prevEnd; i++)
      {
         if(rates[i].high > prevHigh) prevHigh = rates[i].high;
         if(rates[i].low < prevLow) prevLow = rates[i].low;
      }

      outBias.structureBull = (recentHigh > prevHigh && recentLow > prevLow);
      outBias.structureBear = (recentHigh < prevHigh && recentLow < prevLow);

      if(outBias.emaBull && outBias.structureBull)
         outBias.direction = DIR_BUY;
      else if(outBias.emaBear && outBias.structureBear)
         outBias.direction = DIR_SELL;
      else
         outBias.direction = DIR_NONE;

      outBias.details = StringFormat("emaBull=%s emaBear=%s structBull=%s structBear=%s", outBias.emaBull ? "1" : "0", outBias.emaBear ? "1" : "0", outBias.structureBull ? "1" : "0", outBias.structureBear ? "1" : "0");

      IndicatorRelease(emaFast);
      IndicatorRelease(emaSlow);
      return true;
   }
};

#endif

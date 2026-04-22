#ifndef __WECHUCK_ENTRY_SCORING_MQH__
#define __WECHUCK_ENTRY_SCORING_MQH__

//──────────────────────────────────────────────────────────────────────────────
// EntryScoring.mqh
// Thin adapter layer: accepts a pre-built StrategyParams struct and delegates
// all signal logic to CStrategyCore (StrategyCore.mqh).
// Handles the "No Zone, No Trade" guard using ZoneDetector.mqh.
//──────────────────────────────────────────────────────────────────────────────

#include "Types.mqh"
#include <WeChuck/ZoneDetector.mqh>

class CEntryScoring
{
private:
   CStrategyCore  m_core;
   CZoneDetector  m_zones;

   SRZone         m_zonesH1[];
   SRZone         m_zonesM15[];
   int            m_zoneCountH1;
   int            m_zoneCountM15;
   datetime       m_lastZoneScan;

   //──────────────────────────────────────────────────────────────────────────
   // Zone cache: rescanned at most once per hour.
   //──────────────────────────────────────────────────────────────────────────
   void RefreshZones(const string symbol,
                     const int lookback, const int wingBars,
                     const int minTouches, const double tolerancePct)
   {
      datetime now = TimeCurrent();
      if(now - m_lastZoneScan < 3600) return;

      m_zoneCountH1  = m_zones.ScanZones(symbol, PERIOD_H1,  lookback, wingBars,
                                          minTouches, tolerancePct, m_zonesH1);
      m_zoneCountM15 = m_zones.ScanZones(symbol, PERIOD_M15, lookback, wingBars,
                                          minTouches, tolerancePct, m_zonesM15);
      m_lastZoneScan = now;
   }

   bool PriceNearMacroZone(const double price)
   {
      if(m_zones.PriceNearZone(price, m_zonesH1,  m_zoneCountH1))  return true;
      if(m_zones.PriceNearZone(price, m_zonesM15, m_zoneCountM15)) return true;
      return false;
   }

public:
   void Init()
   {
      m_zoneCountH1  = 0;
      m_zoneCountM15 = 0;
      m_lastZoneScan = 0;
   }

   //──────────────────────────────────────────────────────────────────────────
   // Evaluate
   // Accepts a fully-populated StrategyParams struct (all filter fields included).
   // Returns false only on a hard data error.
   // outScore.valid distinguishes "no signal" from "signal confirmed".
   //──────────────────────────────────────────────────────────────────────────
   bool Evaluate(const string symbol,
                 const StrategyParams &p,
                 const bool   requireZone,
                 const int    zoneLookback,
                 const int    zoneWingBars,
                 const int    zoneMinTouches,
                 const double zoneTolerancePct,
                 EntryScoreBreakdown &outScore)
   {
      outScore.valid              = false;
      outScore.setup              = SETUP_NONE;
      outScore.direction          = STRAT_DIR_NONE;
      outScore.adx1M              = 0.0;
      outScore.adx5M              = 0.0;
      outScore.stochK             = 0.0;
      outScore.rsiCur             = 0.0;
      outScore.boxHigh            = 0.0;
      outScore.boxLow             = 0.0;
      outScore.signalBarHigh      = 0.0;
      outScore.signalBarLow       = 0.0;
      outScore.details            = "";
      outScore.wickSweepConfirmed = false;
      outScore.sweepWickLow       = 0.0;
      outScore.sweepWickHigh      = 0.0;
      outScore.boxAgeMinutes      = 0;
      outScore.boxWallTouches     = 0;
      outScore.m5StochK           = 0.0;
      outScore.h4Bias             = 0;

      StrategySignal sig;
      if(!m_core.Evaluate(symbol, p, sig))
         return false;

      outScore.adx1M              = sig.adx1M;
      outScore.adx5M              = sig.adx5M;
      outScore.stochK             = sig.stochK;
      outScore.rsiCur             = sig.rsiCur;
      outScore.boxHigh            = sig.boxHigh;
      outScore.boxLow             = sig.boxLow;
      outScore.signalBarHigh      = sig.signalBarHigh;
      outScore.signalBarLow       = sig.signalBarLow;
      outScore.details            = sig.details;
      outScore.wickSweepConfirmed = sig.wickSweepConfirmed;
      outScore.sweepWickLow       = sig.sweepWickLow;
      outScore.sweepWickHigh      = sig.sweepWickHigh;
      outScore.boxAgeMinutes      = sig.boxAgeMinutes;
      outScore.boxWallTouches     = sig.boxWallTouches;
      outScore.m5StochK           = sig.m5StochK;
      outScore.h4Bias             = sig.h4Bias;

      if(sig.setupType == SETUP_NONE)
         return true;

      // "No Zone, No Trade" – enforced for Setup A (Rubber Band) only.
      // Setup B and C already qualify via box-edge proximity check.
      if(sig.setupType == SETUP_RUBBER_BAND && requireZone)
      {
         RefreshZones(symbol, zoneLookback, zoneWingBars,
                      zoneMinTouches, zoneTolerancePct);

         MqlTick tick;
         if(!SymbolInfoTick(symbol, tick)) return false;
         double price = (tick.ask + tick.bid) * 0.5;

         if(!PriceNearMacroZone(price))
         {
            outScore.details = "INVALIDATED – price not near H1/M15 zone (No Zone, No Trade)";
            return true;
         }
      }

      outScore.valid     = true;
      outScore.setup     = sig.setupType;
      outScore.direction = sig.direction;
      return true;
   }

   //──────────────────────────────────────────────────────────────────────────
   // ShouldExitByDynamics – delegates to CStrategyCore.ShouldExit()
   //──────────────────────────────────────────────────────────────────────────
   bool ShouldExitByDynamics(const string symbol,
                              const int    positionDirection,
                              const StrategyParams &p)
   {
      return m_core.ShouldExit(symbol, positionDirection, p);
   }
};

#endif // __WECHUCK_ENTRY_SCORING_MQH__

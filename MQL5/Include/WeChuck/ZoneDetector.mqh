#ifndef __WECHUCK_ZONE_DETECTOR_MQH__
#define __WECHUCK_ZONE_DETECTOR_MQH__

//──────────────────────────────────────────────────────────────────────────────
// ZoneDetector.mqh
// Finds macro Support & Resistance zones from any timeframe.
// Used by the indicator for visual overlays and by the EA for the
// "No Zone, No Trade" rule.
//
// Zone = a price band around a swing high or swing low that has been
// tested at least InpMinTouches times, giving it structural significance.
//──────────────────────────────────────────────────────────────────────────────

struct SRZone
{
   double          high;       // Upper boundary of the zone band
   double          low;        // Lower boundary of the zone band
   int             strength;   // Number of bar touches (higher = stronger)
   ENUM_TIMEFRAMES timeframe;  // Timeframe the zone was found on
};

class CZoneDetector
{
private:
   //──────────────────────────────────────────────────────────────────────────
   // True when rates[idx] is a swing high:
   //   every bar within wingBars on each side has a lower high.
   //──────────────────────────────────────────────────────────────────────────
   bool IsSwingHigh(const MqlRates &rates[], const int idx, const int wingBars)
   {
      int sz = ArraySize(rates);
      if(idx < wingBars || idx + wingBars >= sz) return false;
      for(int i = 1; i <= wingBars; i++)
      {
         if(rates[idx - i].high >= rates[idx].high) return false;
         if(rates[idx + i].high >= rates[idx].high) return false;
      }
      return true;
   }

   //──────────────────────────────────────────────────────────────────────────
   // True when rates[idx] is a swing low:
   //   every bar within wingBars on each side has a higher low.
   //──────────────────────────────────────────────────────────────────────────
   bool IsSwingLow(const MqlRates &rates[], const int idx, const int wingBars)
   {
      int sz = ArraySize(rates);
      if(idx < wingBars || idx + wingBars >= sz) return false;
      for(int i = 1; i <= wingBars; i++)
      {
         if(rates[idx - i].low <= rates[idx].low) return false;
         if(rates[idx + i].low <= rates[idx].low) return false;
      }
      return true;
   }

   //──────────────────────────────────────────────────────────────────────────
   // Count how many bars in the history came close to or touched 'level'.
   // A touch is when the bar's range overlaps the level ± tolerance.
   //──────────────────────────────────────────────────────────────────────────
   int CountTouches(const MqlRates &rates[], const int totalBars,
                    const double level, const double tolerance)
   {
      int touches = 0;
      for(int i = 0; i < totalBars; i++)
      {
         if(MathAbs(rates[i].high - level) <= tolerance ||
            MathAbs(rates[i].low  - level) <= tolerance ||
            (rates[i].low <= level + tolerance && rates[i].high >= level - tolerance))
            touches++;
      }
      return touches;
   }

public:
   //──────────────────────────────────────────────────────────────────────────
   // ScanZones
   // Scans 'lookback' closed bars on the given timeframe for swing highs/lows.
   // Zones that have been touched at least 'minTouches' times are added to
   // outZones[].  Nearby zones (within 2x tolerance) are merged rather than
   // duplicated.
   //
   // Returns the total number of zones found.
   //──────────────────────────────────────────────────────────────────────────
   int ScanZones(const string symbol, const ENUM_TIMEFRAMES tf,
                 const int lookback, const int wingBars,
                 const int minTouches, const double tolerancePct,
                 SRZone &outZones[])
   {
      ArrayResize(outZones, 0);

      int barsNeeded = lookback + wingBars * 2;
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(symbol, tf, 1, barsNeeded, rates);
      if(copied < lookback + wingBars * 2) return 0;

      // Tolerance: percentage of current price
      double tolerance = rates[0].close * tolerancePct / 100.0;
      double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
      if(tolerance < point * 5) tolerance = point * 5;

      for(int i = wingBars; i < copied - wingBars; i++)
      {
         // ── Check for swing high ─────────────────────────────────────────
         if(IsSwingHigh(rates, i, wingBars))
         {
            double level  = rates[i].high;
            int    touches = CountTouches(rates, copied, level, tolerance);
            if(touches >= minTouches)
               AddOrMergeZone(outZones, level, tolerance, touches, tf);
         }

         // ── Check for swing low ──────────────────────────────────────────
         if(IsSwingLow(rates, i, wingBars))
         {
            double level  = rates[i].low;
            int    touches = CountTouches(rates, copied, level, tolerance);
            if(touches >= minTouches)
               AddOrMergeZone(outZones, level, tolerance, touches, tf);
         }
      }

      return ArraySize(outZones);
   }

   //──────────────────────────────────────────────────────────────────────────
   // PriceNearZone
   // Returns true if 'price' falls inside any zone band in outZones[].
   //──────────────────────────────────────────────────────────────────────────
   bool PriceNearZone(const double price, const SRZone &zones[],
                      const int zoneCount)
   {
      for(int i = 0; i < zoneCount; i++)
      {
         if(price >= zones[i].low && price <= zones[i].high)
            return true;
      }
      return false;
   }

   //──────────────────────────────────────────────────────────────────────────
   // GetNearestZone
   // Finds the nearest zone in the trade direction:
   //   direction  1 (BUY)  → zone whose midpoint is above price (next resistance)
   //   direction -1 (SELL) → zone whose midpoint is below price (next support)
   //
   // Returns true and populates outZone if a matching zone is found.
   //──────────────────────────────────────────────────────────────────────────
   bool GetNearestZone(const double price, const int direction,
                       const SRZone &zones[], const int zoneCount,
                       SRZone &outZone)
   {
      double bestDist = DBL_MAX;
      bool   found    = false;

      for(int i = 0; i < zoneCount; i++)
      {
         double mid  = (zones[i].high + zones[i].low) * 0.5;
         double dist = 0.0;

         if(direction == 1 && mid > price)         // BUY: look above
            dist = mid - price;
         else if(direction == -1 && mid < price)   // SELL: look below
            dist = price - mid;
         else
            continue;

         if(dist < bestDist)
         {
            bestDist = dist;
            outZone  = zones[i];
            found    = true;
         }
      }

      return found;
   }

private:
   //──────────────────────────────────────────────────────────────────────────
   // Helper: add a zone centred on 'level' or merge into an existing one
   // if it is within 2x tolerance of an already-stored zone.
   //──────────────────────────────────────────────────────────────────────────
   void AddOrMergeZone(SRZone &zones[], const double level,
                       const double tolerance, const int touches,
                       const ENUM_TIMEFRAMES tf)
   {
      int sz = ArraySize(zones);

      // Try to merge with an existing nearby zone
      for(int z = 0; z < sz; z++)
      {
         double mid = (zones[z].high + zones[z].low) * 0.5;
         if(MathAbs(mid - level) <= tolerance * 2.0)
         {
            // Keep whichever boundary is wider; keep the higher touch count
            if(level + tolerance > zones[z].high) zones[z].high = level + tolerance;
            if(level - tolerance < zones[z].low)  zones[z].low  = level - tolerance;
            if(touches > zones[z].strength)        zones[z].strength = touches;
            return;
         }
      }

      // No match – add new zone
      ArrayResize(zones, sz + 1);
      zones[sz].high      = level + tolerance;
      zones[sz].low       = level - tolerance;
      zones[sz].strength  = touches;
      zones[sz].timeframe = tf;
   }
};

#endif // __WECHUCK_ZONE_DETECTOR_MQH__

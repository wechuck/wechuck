#property copyright   "WeChuck"
#property version     "1.00"
#property description "WeChuck Zone Scanner – draws H1/M15/5M S&R zones on the chart"
#property script_show_inputs

#include <WeChuck/StrategyCore.mqh>
#include <WeChuck/ZoneDetector.mqh>

//──────────────────────────────────────────────────────────────────────────────
// Inputs
//──────────────────────────────────────────────────────────────────────────────
input group "Zone Detection"
input int    InpZoneLookback      = 200;    // Bars of history to scan
input int    InpZoneWingBars      = 3;      // Confirmation bars on each side of swing
input int    InpZoneMinTouches    = 2;      // Minimum touches for a valid zone
input double InpZoneTolerancePct  = 0.05;  // Zone band as % of price

input group "5M Range Box"
input int    InpM5Lookback        = 50;     // Closed 5M bars that define the box

input group "ADX State Display"
input int    InpAdxPeriod         = 14;

//──────────────────────────────────────────────────────────────────────────────
// Object-name prefix – all drawings created by this script use this prefix
// so they can be selectively deleted and redrawn without touching other objects.
//──────────────────────────────────────────────────────────────────────────────
#define SCAN_PFX "WCSCAN_"

//──────────────────────────────────────────────────────────────────────────────
// Delete all objects previously drawn by this script
//──────────────────────────────────────────────────────────────────────────────
void DeletePreviousObjects()
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, SCAN_PFX) == 0)
         ObjectDelete(0, name);
   }
}

//──────────────────────────────────────────────────────────────────────────────
// Draw a zone rectangle spanning one week into the past from bar 0
//──────────────────────────────────────────────────────────────────────────────
void DrawZoneRect(const string name, const double hi, const double lo,
                  const color clr, const string tooltip)
{
   datetime t1 = iTime(_Symbol, PERIOD_M1, 0);
   datetime t0 = t1 - (datetime)(7 * 86400);

   if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, t0, hi, t1, lo))
      return;
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_FILL,        true);
   ObjectSetInteger(0, name, OBJPROP_BACK,        true);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,       1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);
   ObjectSetString (0, name, OBJPROP_TOOLTIP,     tooltip);
}

//──────────────────────────────────────────────────────────────────────────────
// Read the 1M ADX and return a descriptive state string
//──────────────────────────────────────────────────────────────────────────────
string GetAdxStateStr(double &outAdxVal)
{
   outAdxVal = 0.0;
   int h = iADX(_Symbol, PERIOD_M1, InpAdxPeriod);
   if(h == INVALID_HANDLE) return "N/A";

   double buf[3];
   ArraySetAsSeries(buf, true);
   string state = "N/A";
   if(CopyBuffer(h, 0, 1, 3, buf) >= 3)
   {
      outAdxVal  = buf[0];
      bool rising = (buf[0] > buf[1]);
      if(outAdxVal < 20.0)
         state = "RANGING (<20)";
      else if(outAdxVal <= 35.0 && rising)
         state = "EXPANDING (20-35 rising)";
      else if(outAdxVal > 40.0 && buf[1] > buf[2] && buf[0] < buf[1])
         state = "EXHAUSTED (>40 hooking)";
      else
         state = StringFormat("%.1f", outAdxVal);
   }
   IndicatorRelease(h);
   return state;
}

//──────────────────────────────────────────────────────────────────────────────
// OnStart – main script entry point
//──────────────────────────────────────────────────────────────────────────────
void OnStart()
{
   // Step 1: remove any prior scan objects (idempotent)
   DeletePreviousObjects();
   Print("[WeChuckZoneScanner] Starting zone scan on ", _Symbol, " ...");

   CZoneDetector detector;

   // Step 2: scan H1, M15, M5
   SRZone zonesH1[], zonesM15[], zonesM5[];
   int h1Count  = detector.ScanZones(_Symbol, PERIOD_H1,  InpZoneLookback, InpZoneWingBars,
                                     InpZoneMinTouches, InpZoneTolerancePct, zonesH1);
   int m15Count = detector.ScanZones(_Symbol, PERIOD_M15, InpZoneLookback, InpZoneWingBars,
                                     InpZoneMinTouches, InpZoneTolerancePct, zonesM15);
   int m5Count  = detector.ScanZones(_Symbol, PERIOD_M5,  InpM5Lookback,  InpZoneWingBars,
                                     InpZoneMinTouches, InpZoneTolerancePct, zonesM5);

   // Step 3: draw H1 zones (Yellow – macro structure / Daily-level liquidity)
   for(int i = 0; i < h1Count; i++)
   {
      string name = SCAN_PFX + "H1_" + IntegerToString(i);
      DrawZoneRect(name, zonesH1[i].high, zonesH1[i].low, clrYellow,
                   StringFormat("H1 Zone | strength=%d", zonesH1[i].strength));
   }

   // Step 4: draw M15 zones (Lime Green – intermediate structure)
   for(int i = 0; i < m15Count; i++)
   {
      string name = SCAN_PFX + "M15_" + IntegerToString(i);
      DrawZoneRect(name, zonesM15[i].high, zonesM15[i].low, clrLimeGreen,
                   StringFormat("M15 Zone | strength=%d", zonesM15[i].strength));
   }

   // Step 5: draw 5M zones (White – local order blocks / range box reference)
   for(int i = 0; i < m5Count; i++)
   {
      string name = SCAN_PFX + "M5_" + IntegerToString(i);
      DrawZoneRect(name, zonesM5[i].high, zonesM5[i].low, clrWhite,
                   StringFormat("5M Zone | strength=%d", zonesM5[i].strength));
   }

   // Step 6: nearest support / resistance relative to current price
   MqlTick tick;
   SymbolInfoTick(_Symbol, tick);
   double price = (tick.ask + tick.bid) * 0.5;

   // Merge H1 + M15 into one array for nearest-zone queries
   int    allCount = h1Count + m15Count;
   SRZone allZones[];
   ArrayResize(allZones, allCount);
   for(int i = 0; i < h1Count;  i++) allZones[i]          = zonesH1[i];
   for(int i = 0; i < m15Count; i++) allZones[h1Count + i] = zonesM15[i];

   SRZone nearestSup, nearestRes;
   bool hasSup = detector.GetNearestZone(price, STRAT_DIR_SELL, allZones, allCount, nearestSup);
   bool hasRes = detector.GetNearestZone(price, STRAT_DIR_BUY,  allZones, allCount, nearestRes);

   // Step 7: print summary to Experts log
   double adxVal = 0.0;
   string adxState = GetAdxStateStr(adxVal);

   PrintFormat("[WeChuckZoneScanner] %s | Zones: H1=%d  M15=%d  5M=%d | 1M ADX: %.1f [%s]",
               _Symbol, h1Count, m15Count, m5Count, adxVal, adxState);

   if(hasSup)
      PrintFormat("  Nearest Support    : %.5f – %.5f (strength=%d)",
                  nearestSup.low, nearestSup.high, nearestSup.strength);
   else
      Print("  Nearest Support    : none found");

   if(hasRes)
      PrintFormat("  Nearest Resistance : %.5f – %.5f (strength=%d)",
                  nearestRes.low, nearestRes.high, nearestRes.strength);
   else
      Print("  Nearest Resistance : none found");

   PrintFormat("  Current Price      : %.5f", price);
   PrintFormat("  Price near any zone: %s",
               detector.PriceNearZone(price, allZones, allCount) ? "YES" : "NO");

   ChartRedraw(0);
   Print("[WeChuckZoneScanner] Done. ", allCount + m5Count, " zone objects drawn on chart.");
}

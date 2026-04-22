#property copyright   "WeChuck"
#property version     "1.00"
#property description "Multi-Timeframe Exhaustion & Range Scalp – Signal Indicator"
#property strict

#property indicator_chart_window
#property indicator_plots 0

#include <WeChuck/StrategyCore.mqh>
#include <WeChuck/ZoneDetector.mqh>

//──────────────────────────────────────────────────────────────────────────────
// Inputs
//──────────────────────────────────────────────────────────────────────────────
input group "ADX (Environment Filter)"
input int    InpAdxPeriod         = 14;
input double InpAdxExhaustion     = 40.0;   // Setup A: 1M ADX must exceed this
input double InpAdxExpandingMin   = 25.0;   // Invalidation: expanding zone low
input double InpAdxExpandingMax   = 35.0;   // Invalidation: expanding zone high
input double InpAdxRanging        = 20.0;   // Setup B: 5M ADX must be below this
input double InpAdxExitWeak       = 18.0;   // Dynamic exit threshold

input group "RSI (Pressure Gauge)"
input int    InpRsiPeriod         = 14;
input double InpRsiOversold       = 30.0;
input double InpRsiOverbought     = 70.0;

input group "Stochastic (14,1,3) – The Trigger"
input int    InpStochK            = 14;
input int    InpStochD            = 3;
input int    InpStochSlowing      = 1;
input double InpStochOversold     = 20.0;
input double InpStochOverbought   = 80.0;

input group "5M Range Box"
input int    InpM5Lookback        = 50;     // Closed 5M bars that define the box
input double InpBoxTolerancePct   = 15.0;  // % of box size counted as "near edge"

input group "Zone Detector (S/R Scanner)"
input int    InpZoneLookback      = 200;    // Bars of history to scan
input int    InpZoneWingBars      = 3;      // Bars on each side to confirm swing
input int    InpZoneMinTouches    = 2;      // Minimum touches for a valid zone
input double InpZoneTolerancePct  = 0.05;  // Zone band width as % of price

input group "Signal Panel (Corner Widget)"
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;
input int    InpPanelX            = 12;
input int    InpPanelY            = 22;

//──────────────────────────────────────────────────────────────────────────────
// Object name constants
//──────────────────────────────────────────────────────────────────────────────
#define WC_PFX          "WCS_"   // all objects owned by this indicator
#define PANEL_BG        WC_PFX "PanelBg"
#define ROW_ADX1M       WC_PFX "RowAdx1M"
#define ROW_ADX5M       WC_PFX "RowAdx5M"
#define ROW_STOCH       WC_PFX "RowStoch"
#define ROW_RSI         WC_PFX "RowRsi"
#define ROW_BOX         WC_PFX "RowBox"
#define ROW_SETUP       WC_PFX "RowSetup"
#define ROW_SIG         WC_PFX "RowSig"
#define BOX_HIGH_LINE   WC_PFX "BoxHigh"
#define BOX_LOW_LINE    WC_PFX "BoxLow"
#define PFX_ZONE_H1     WC_PFX "ZH1_"
#define PFX_ZONE_M15    WC_PFX "ZM15_"
#define PFX_ARROW       WC_PFX "Arr_"

//──────────────────────────────────────────────────────────────────────────────
// Globals
//──────────────────────────────────────────────────────────────────────────────
CStrategyCore  g_core;
CZoneDetector  g_zoneDetector;

StrategyParams g_params;
SRZone         g_zonesH1[];
SRZone         g_zonesM15[];
int            g_zoneCountH1  = 0;
int            g_zoneCountM15 = 0;

datetime       g_lastBarTime   = 0;
datetime       g_lastZoneScan  = 0;
int            g_arrowIndex    = 0;

//──────────────────────────────────────────────────────────────────────────────
// Fill the StrategyParams struct from indicator inputs
//──────────────────────────────────────────────────────────────────────────────
void FillParams()
{
   g_params.adxPeriod            = InpAdxPeriod;
   g_params.adxExhaustionLevel   = InpAdxExhaustion;
   g_params.adxExpandingMin      = InpAdxExpandingMin;
   g_params.adxExpandingMax      = InpAdxExpandingMax;
   g_params.adxRangingThreshold  = InpAdxRanging;
   g_params.adxExitWeakThreshold = InpAdxExitWeak;
   g_params.rsiPeriod            = InpRsiPeriod;
   g_params.rsiOversold          = InpRsiOversold;
   g_params.rsiOverbought        = InpRsiOverbought;
   g_params.stochKPeriod         = InpStochK;
   g_params.stochDPeriod         = InpStochD;
   g_params.stochSlowing         = InpStochSlowing;
   g_params.stochOversold        = InpStochOversold;
   g_params.stochOverbought      = InpStochOverbought;
   g_params.m5RangeLookback      = InpM5Lookback;
   g_params.boxTouchTolerancePct = InpBoxTolerancePct / 100.0;
}

//──────────────────────────────────────────────────────────────────────────────
// Delete all objects whose name starts with 'prefix'
//──────────────────────────────────────────────────────────────────────────────
void DeleteByPrefix(const string prefix)
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, prefix) == 0)
         ObjectDelete(0, name);
   }
}

//──────────────────────────────────────────────────────────────────────────────
// Create the Signal Panel background and label rows
//──────────────────────────────────────────────────────────────────────────────
void CreatePanel()
{
   // Background rectangle label
   ObjectCreate(0, PANEL_BG, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_CORNER,    InpPanelCorner);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_YDISTANCE, InpPanelY);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_XSIZE,     250);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_YSIZE,     170);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_BGCOLOR,   C'15,15,25');
   ObjectSetInteger(0, PANEL_BG, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_COLOR,     clrDimGray);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_SELECTABLE, false);

   // Row labels
   string rows[] = { ROW_ADX1M, ROW_ADX5M, ROW_STOCH,
                     ROW_RSI,   ROW_BOX,   ROW_SETUP, ROW_SIG };
   for(int i = 0; i < ArraySize(rows); i++)
   {
      ObjectCreate(0, rows[i], OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, rows[i], OBJPROP_CORNER,    InpPanelCorner);
      ObjectSetInteger(0, rows[i], OBJPROP_XDISTANCE, InpPanelX + 8);
      ObjectSetInteger(0, rows[i], OBJPROP_YDISTANCE, InpPanelY + 10 + i * 22);
      ObjectSetInteger(0, rows[i], OBJPROP_FONTSIZE,  8);
      ObjectSetString (0, rows[i], OBJPROP_FONT,      "Courier New");
      ObjectSetInteger(0, rows[i], OBJPROP_COLOR,     clrSilver);
      ObjectSetString (0, rows[i], OBJPROP_TEXT,      "---");
      ObjectSetInteger(0, rows[i], OBJPROP_SELECTABLE, false);
   }
}

//──────────────────────────────────────────────────────────────────────────────
// Refresh all panel rows from the latest signal
//──────────────────────────────────────────────────────────────────────────────
void UpdatePanel(const StrategySignal &sig)
{
   // ── ADX 1M row ───────────────────────────────────────────────────────────
   string adx1MText;
   color  adx1MColor;
   bool   adxExpanding = (sig.adx1M >= InpAdxExpandingMin &&
                          sig.adx1M <= InpAdxExpandingMax &&
                          sig.adx1M > sig.adx1MPrev);
   if(sig.adx1M < InpAdxRanging)
   {
      adx1MText  = StringFormat("ADX 1M: %.1f  RANGING", sig.adx1M);
      adx1MColor = clrDodgerBlue;
   }
   else if(adxExpanding)
   {
      adx1MText  = StringFormat("ADX 1M: %.1f  EXPANDING !", sig.adx1M);
      adx1MColor = clrOrange;
   }
   else if(sig.adx1M > InpAdxExhaustion && sig.adxHooking)
   {
      adx1MText  = StringFormat("ADX 1M: %.1f  EXHAUSTED <<", sig.adx1M);
      adx1MColor = clrCrimson;
   }
   else
   {
      adx1MText  = StringFormat("ADX 1M: %.1f", sig.adx1M);
      adx1MColor = clrSilver;
   }
   ObjectSetString (0, ROW_ADX1M, OBJPROP_TEXT,  adx1MText);
   ObjectSetInteger(0, ROW_ADX1M, OBJPROP_COLOR, adx1MColor);

   // ── ADX 5M row ───────────────────────────────────────────────────────────
   string adx5MText  = (sig.adx5M < InpAdxRanging)
                       ? StringFormat("ADX 5M: %.1f  RANGING", sig.adx5M)
                       : StringFormat("ADX 5M: %.1f", sig.adx5M);
   color  adx5MColor = (sig.adx5M < InpAdxRanging) ? clrDodgerBlue : clrSilver;
   ObjectSetString (0, ROW_ADX5M, OBJPROP_TEXT,  adx5MText);
   ObjectSetInteger(0, ROW_ADX5M, OBJPROP_COLOR, adx5MColor);

   // ── Stochastic row ────────────────────────────────────────────────────────
   string stochBadge;
   color  stochColor;
   if(sig.stochK < InpStochOversold)
   { stochBadge = "OVERSOLD";   stochColor = clrLime; }
   else if(sig.stochK > InpStochOverbought)
   { stochBadge = "OVERBOUGHT"; stochColor = clrCrimson; }
   else
   { stochBadge = "NEUTRAL";    stochColor = clrSilver; }
   ObjectSetString (0, ROW_STOCH, OBJPROP_TEXT,
                    StringFormat("Stoch K: %.1f  %s", sig.stochK, stochBadge));
   ObjectSetInteger(0, ROW_STOCH, OBJPROP_COLOR, stochColor);

   // ── RSI row ───────────────────────────────────────────────────────────────
   string rsiBadge;
   color  rsiColor;
   if(sig.rsiCur < InpRsiOversold && sig.rsiCur > sig.rsiPrev)
   { rsiBadge = "OVERSOLD ^";   rsiColor = clrLime; }
   else if(sig.rsiCur > InpRsiOverbought && sig.rsiCur < sig.rsiPrev)
   { rsiBadge = "OVERBOUGHT v"; rsiColor = clrCrimson; }
   else
   { rsiBadge = "---";          rsiColor = clrSilver; }
   ObjectSetString (0, ROW_RSI, OBJPROP_TEXT,
                    StringFormat("RSI    : %.1f  %s", sig.rsiCur, rsiBadge));
   ObjectSetInteger(0, ROW_RSI, OBJPROP_COLOR, rsiColor);

   // ── 5M Box row ────────────────────────────────────────────────────────────
   double boxRange   = sig.boxHigh - sig.boxLow;
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipFactor  = (digits == 3 || digits == 5) ? 10.0 : 1.0;
   double boxPips    = (point > 0.0) ? (boxRange / point / pipFactor) : 0.0;
   ObjectSetString (0, ROW_BOX, OBJPROP_TEXT,
                    StringFormat("5M Box : %.5f-%.5f (%.1f pips)",
                                 sig.boxLow, sig.boxHigh, boxPips));
   ObjectSetInteger(0, ROW_BOX, OBJPROP_COLOR, clrSilver);

   // ── Active Setup row ──────────────────────────────────────────────────────
   string setupText;
   color  setupColor;
   switch(sig.setupType)
   {
      case SETUP_RUBBER_BAND:
         setupText  = "SETUP A  [Rubber Band]";
         setupColor = clrDodgerBlue;
         break;
      case SETUP_RANGE_SCALP:
         setupText  = "SETUP B  [Range Scalp]";
         setupColor = clrGold;
         break;
      default:
         setupText  = "NO SETUP";
         setupColor = clrDimGray;
         break;
   }
   ObjectSetString (0, ROW_SETUP, OBJPROP_TEXT,  setupText);
   ObjectSetInteger(0, ROW_SETUP, OBJPROP_COLOR, setupColor);

   // ── Signal row ────────────────────────────────────────────────────────────
   string sigText;
   color  sigColor;
   if(sig.direction == STRAT_DIR_BUY)
   { sigText = "Signal : ^ BUY";  sigColor = clrLime; }
   else if(sig.direction == STRAT_DIR_SELL)
   { sigText = "Signal : v SELL"; sigColor = clrCrimson; }
   else
   { sigText = "Signal : ---";    sigColor = clrDimGray; }
   ObjectSetString (0, ROW_SIG, OBJPROP_TEXT,  sigText);
   ObjectSetInteger(0, ROW_SIG, OBJPROP_COLOR, sigColor);

   ChartRedraw(0);
}

//──────────────────────────────────────────────────────────────────────────────
// Draw / update the two 5M range box horizontal lines
//──────────────────────────────────────────────────────────────────────────────
void DrawRangeBox(const double boxHigh, const double boxLow)
{
   // High line
   if(ObjectFind(0, BOX_HIGH_LINE) < 0)
      ObjectCreate(0, BOX_HIGH_LINE, OBJ_HLINE, 0, 0, boxHigh);
   ObjectSetDouble (0, BOX_HIGH_LINE, OBJPROP_PRICE,  boxHigh);
   ObjectSetInteger(0, BOX_HIGH_LINE, OBJPROP_COLOR,  clrWhite);
   ObjectSetInteger(0, BOX_HIGH_LINE, OBJPROP_STYLE,  STYLE_DASH);
   ObjectSetInteger(0, BOX_HIGH_LINE, OBJPROP_WIDTH,  1);
   ObjectSetString (0, BOX_HIGH_LINE, OBJPROP_TOOLTIP, "5M Box High");
   ObjectSetInteger(0, BOX_HIGH_LINE, OBJPROP_SELECTABLE, false);

   // Low line
   if(ObjectFind(0, BOX_LOW_LINE) < 0)
      ObjectCreate(0, BOX_LOW_LINE, OBJ_HLINE, 0, 0, boxLow);
   ObjectSetDouble (0, BOX_LOW_LINE, OBJPROP_PRICE,  boxLow);
   ObjectSetInteger(0, BOX_LOW_LINE, OBJPROP_COLOR,  clrWhite);
   ObjectSetInteger(0, BOX_LOW_LINE, OBJPROP_STYLE,  STYLE_DASH);
   ObjectSetInteger(0, BOX_LOW_LINE, OBJPROP_WIDTH,  1);
   ObjectSetString (0, BOX_LOW_LINE, OBJPROP_TOOLTIP, "5M Box Low");
   ObjectSetInteger(0, BOX_LOW_LINE, OBJPROP_SELECTABLE, false);
}

//──────────────────────────────────────────────────────────────────────────────
// Draw S/R zone rectangles for H1 (yellow) and M15 (green)
//──────────────────────────────────────────────────────────────────────────────
void DrawZones()
{
   DeleteByPrefix(PFX_ZONE_H1);
   DeleteByPrefix(PFX_ZONE_M15);

   datetime t1 = iTime(_Symbol, PERIOD_M1, 0);
   datetime t0 = t1 - (datetime)(7 * 86400);   // extend 1 week to the left

   // H1 zones – yellow
   for(int i = 0; i < g_zoneCountH1; i++)
   {
      string name = PFX_ZONE_H1 + IntegerToString(i);
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, t0, g_zonesH1[i].high,
                                                    t1, g_zonesH1[i].low))
         continue;
      ObjectSetInteger(0, name, OBJPROP_COLOR,      clrYellow);
      ObjectSetInteger(0, name, OBJPROP_FILL,        true);
      ObjectSetInteger(0, name, OBJPROP_BACK,        true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);
      ObjectSetString (0, name, OBJPROP_TOOLTIP,
                       StringFormat("H1 Zone | touches=%d", g_zonesH1[i].strength));
   }

   // M15 zones – lime green
   for(int i = 0; i < g_zoneCountM15; i++)
   {
      string name = PFX_ZONE_M15 + IntegerToString(i);
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, t0, g_zonesM15[i].high,
                                                    t1, g_zonesM15[i].low))
         continue;
      ObjectSetInteger(0, name, OBJPROP_COLOR,      clrLimeGreen);
      ObjectSetInteger(0, name, OBJPROP_FILL,        true);
      ObjectSetInteger(0, name, OBJPROP_BACK,        true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);
      ObjectSetString (0, name, OBJPROP_TOOLTIP,
                       StringFormat("M15 Zone | touches=%d", g_zonesM15[i].strength));
   }
}

//──────────────────────────────────────────────────────────────────────────────
// Scan S/R zones for both H1 and M15 timeframes
//──────────────────────────────────────────────────────────────────────────────
void ScanZones()
{
   g_zoneCountH1  = g_zoneDetector.ScanZones(_Symbol, PERIOD_H1,
                                              InpZoneLookback, InpZoneWingBars,
                                              InpZoneMinTouches, InpZoneTolerancePct,
                                              g_zonesH1);
   g_zoneCountM15 = g_zoneDetector.ScanZones(_Symbol, PERIOD_M15,
                                              InpZoneLookback, InpZoneWingBars,
                                              InpZoneMinTouches, InpZoneTolerancePct,
                                              g_zonesM15);
}

//──────────────────────────────────────────────────────────────────────────────
// Place a BUY or SELL arrow on the signal bar
// Setup A arrows: blue  |  Setup B arrows: gold
//──────────────────────────────────────────────────────────────────────────────
void DrawArrow(const datetime t, const double price,
               const int direction, const SetupType setup)
{
   string name = PFX_ARROW + IntegerToString(g_arrowIndex++);

   // MT5 Wingdings arrow codes: 233 = up, 234 = down
   int   code  = (direction == STRAT_DIR_BUY) ? 233 : 234;
   color clr   = (setup == SETUP_RUBBER_BAND) ? clrDodgerBlue : clrGold;

   if(!ObjectCreate(0, name, OBJ_ARROW, 0, t, price)) return;
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE,  code);
   ObjectSetInteger(0, name, OBJPROP_COLOR,       clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,       2);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);
   ObjectSetString (0, name, OBJPROP_TOOLTIP,
                    (setup == SETUP_RUBBER_BAND ? "Setup A" : "Setup B") +
                    (direction == STRAT_DIR_BUY ? " BUY" : " SELL"));
}

//──────────────────────────────────────────────────────────────────────────────
// OnInit
//──────────────────────────────────────────────────────────────────────────────
int OnInit()
{
   FillParams();
   CreatePanel();
   ScanZones();
   DrawZones();
   g_lastZoneScan = TimeCurrent();
   return INIT_SUCCEEDED;
}

//──────────────────────────────────────────────────────────────────────────────
// OnDeinit – clean up all owned chart objects
//──────────────────────────────────────────────────────────────────────────────
void OnDeinit(const int reason)
{
   DeleteByPrefix(WC_PFX);
   ChartRedraw(0);
}

//──────────────────────────────────────────────────────────────────────────────
// OnCalculate – runs on every tick; logic executes only on new M1 bar close
//──────────────────────────────────────────────────────────────────────────────
int OnCalculate(const int rates_total,   const int prev_calculated,
                const datetime &time[],  const double &open[],
                const double &high[],    const double &low[],
                const double &close[],   const long &tick_volume[],
                const long &volume[],    const int &spread[])
{
   datetime curBarTime = iTime(_Symbol, PERIOD_M1, 0);
   if(curBarTime == g_lastBarTime) return rates_total;
   g_lastBarTime = curBarTime;

   // Re-scan zones every hour so the overlay stays current
   if(TimeCurrent() - g_lastZoneScan >= 3600)
   {
      ScanZones();
      DrawZones();
      g_lastZoneScan = TimeCurrent();
   }

   // Evaluate strategy signal
   StrategySignal sig;
   if(!g_core.Evaluate(_Symbol, g_params, sig))
      return rates_total;

   // Update 5M range box lines
   DrawRangeBox(sig.boxHigh, sig.boxLow);

   // Refresh the panel widget
   UpdatePanel(sig);

   // Draw signal arrow on the closed bar that generated the signal
   if(sig.setupType != SETUP_NONE && sig.direction != STRAT_DIR_NONE)
   {
      datetime signalBarTime = iTime(_Symbol, PERIOD_M1, 1);
      MqlRates r[1];
      ArraySetAsSeries(r, true);
      if(CopyRates(_Symbol, PERIOD_M1, 1, 1, r) == 1)
      {
         double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         double arrowPrice = (sig.direction == STRAT_DIR_BUY)
                             ? r[0].low  - 5.0 * point
                             : r[0].high + 5.0 * point;
         DrawArrow(signalBarTime, arrowPrice, sig.direction, sig.setupType);
      }
   }

   return rates_total;
}

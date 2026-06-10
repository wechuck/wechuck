#property copyright   "WeChuck"
#property version     "4.00"
#property description "WeChuck Institutional Edge – Signal Indicator (v4.00)"
#property strict

#property indicator_chart_window
#property indicator_plots 0

#include <WeChuck/StrategyCore.mqh>
#include <WeChuck/ZoneDetector.mqh>

//──────────────────────────────────────────────────────────────────────────────
// Inputs
//──────────────────────────────────────────────────────────────────────────────
input group "H4 Trend Filter"
input int    InpH4EmaFast   = 50;
input int    InpH4EmaSlow   = 200;

input group "Stochastic (M15 – Setup F confirmation)"
input int    InpStochK      = 14;
input int    InpStochD      = 3;
input int    InpStochSlowing = 1;
input double InpStochOversold  = 20.0;
input double InpStochOverbought = 80.0;

input group "Setup A – London Sweep"
input bool   InpEnableA          = true;
input int    InpAsianStartHour   = 0;
input int    InpAsianEndHour     = 7;
input int    InpLondonStartHour  = 7;
input int    InpLondonEndHour    = 10;
input double InpSetupASweepPips  = 20.0;
input double InpSetupAMinRgPips  = 15.0;

input group "Setup B – H4 Order Block Retest"
input bool   InpEnableB            = true;
input int    InpH4OBLookback       = 50;
input double InpH4ImpulseFactor    = 1.5;
input double InpH4RetestPct        = 0.30;
input int    InpH4OBMaxAgeHours    = 48;

input group "Setup C – Fair Value Gap Fill"
input bool   InpEnableC       = true;
input int    InpFVGLookback   = 20;
input double InpFVGMinPips    = 5.0;

input group "Setup D – Daily Pivot Bounce"
input bool   InpEnableD          = true;
input double InpPivotTolPips     = 5.0;

input group "Setup E – MSS Retest"
input bool   InpEnableE           = true;
input int    InpSwingLookback     = 30;
input double InpMSSRetestBufPips  = 5.0;

input group "Setup F – Weekly Sniper"
input bool   InpEnableF              = true;
input double InpWeeklySweepBufPips   = 15.0;
input bool   InpFRequireH4Align      = true;
input bool   InpFRequireM15Stoch     = true;

input group "Zone Detector (S/R Scanner)"
input int    InpZoneLookback     = 200;
input int    InpZoneWingBars     = 3;
input int    InpZoneMinTouches   = 2;
input double InpZoneTolerancePct = 0.05;

input group "Signal Panel"
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;
input int    InpPanelX = 12;
input int    InpPanelY = 22;

//──────────────────────────────────────────────────────────────────────────────
// Object name constants
//──────────────────────────────────────────────────────────────────────────────
#define WC_PFX        "WCS_"
#define PANEL_BG      WC_PFX "PanelBg"
#define ROW_H4BIAS    WC_PFX "RowH4Bias"
#define ROW_SETUP     WC_PFX "RowSetup"
#define ROW_DIRECTION WC_PFX "RowDir"
#define ROW_KEYLEVEL  WC_PFX "RowKeyLvl"
#define ROW_SWEEP     WC_PFX "RowSweep"
#define PFX_ZONE_H1   WC_PFX "ZH1_"
#define PFX_ZONE_M15  WC_PFX "ZM15_"
#define PFX_ARROW     WC_PFX "Arr_"

//──────────────────────────────────────────────────────────────────────────────
// Globals
//──────────────────────────────────────────────────────────────────────────────
CInstitutionalCore g_core;
CZoneDetector      g_zoneDetector;

SRZone  g_zonesH1[];
SRZone  g_zonesM15[];
int     g_zoneCountH1  = 0;
int     g_zoneCountM15 = 0;

datetime g_lastBarTime  = 0;
datetime g_lastZoneScan = 0;
datetime g_lastRefresh  = 0;
int      g_arrowIndex   = 0;

//──────────────────────────────────────────────────────────────────────────────
// Build StrategyParams from indicator inputs
//──────────────────────────────────────────────────────────────────────────────
void FillParams(StrategyParams &p)
{
   double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT)
                    * ((SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3 ||
                        SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5) ? 10.0 : 1.0);

   p.h4EmaFast = InpH4EmaFast;
   p.h4EmaSlow = InpH4EmaSlow;

   p.stochKPeriod    = InpStochK;
   p.stochDPeriod    = InpStochD;
   p.stochSlowing    = InpStochSlowing;
   p.stochOversold   = InpStochOversold;
   p.stochOverbought = InpStochOverbought;

   p.setupAEnabled   = InpEnableA;
   p.asianStartHour  = InpAsianStartHour;
   p.asianEndHour    = InpAsianEndHour;
   p.londonStartHour = InpLondonStartHour;
   p.londonEndHour   = InpLondonEndHour;
   p.setupASweepBuf  = InpSetupASweepPips * pipSize;
   p.setupAMinRange  = InpSetupAMinRgPips  * pipSize;

   p.setupBEnabled       = InpEnableB;
   p.setupBH4Lookback    = InpH4OBLookback;
   p.setupBImpulseFactor = InpH4ImpulseFactor;
   p.setupBRetestPct     = InpH4RetestPct;
   p.setupBMaxAgeHours   = InpH4OBMaxAgeHours;

   p.setupCEnabled    = InpEnableC;
   p.setupCH1Lookback = InpFVGLookback;
   p.setupCMinFVGSize = InpFVGMinPips * pipSize;

   p.setupDEnabled        = InpEnableD;
   p.setupDPivotTolerance = InpPivotTolPips * pipSize;

   p.setupEEnabled       = InpEnableE;
   p.setupESwingLookback = InpSwingLookback;
   p.setupERetestBuffer  = InpMSSRetestBufPips * pipSize;

   p.setupFEnabled         = InpEnableF;
   p.setupFWeeklySweepBuf  = InpWeeklySweepBufPips * pipSize;
   p.setupFRequireH4Align  = InpFRequireH4Align;
   p.setupFRequireM15Stoch = InpFRequireM15Stoch;
}

//──────────────────────────────────────────────────────────────────────────────
// Utility helpers
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

string SetupName(const SetupType s)
{
   switch(s)
   {
      case SETUP_LONDON_SWEEP:     return "A  London Sweep";
      case SETUP_ORDER_BLOCK:      return "B  OB Retest";
      case SETUP_FVG_FILL:         return "C  FVG Fill";
      case SETUP_PIVOT_BOUNCE:     return "D  Pivot Bounce";
      case SETUP_MSS_RETEST:       return "E  MSS Retest";
      case SETUP_WEEKLY_PRECISION: return "F  WEEKLY SNIPER";
      default:                     return "---";
   }
}

color SetupColor(const SetupType s)
{
   switch(s)
   {
      case SETUP_LONDON_SWEEP:     return clrDodgerBlue;
      case SETUP_ORDER_BLOCK:      return clrGold;
      case SETUP_FVG_FILL:         return clrOrangeRed;
      case SETUP_PIVOT_BOUNCE:     return clrMediumPurple;
      case SETUP_MSS_RETEST:       return clrDarkOrange;
      case SETUP_WEEKLY_PRECISION: return clrLime;
      default:                     return clrDimGray;
   }
}

//──────────────────────────────────────────────────────────────────────────────
// Panel creation (5 rows)
//──────────────────────────────────────────────────────────────────────────────
void CreatePanel()
{
   // Background
   ObjectCreate(0, PANEL_BG, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_CORNER,       InpPanelCorner);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_XDISTANCE,    InpPanelX);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_YDISTANCE,    InpPanelY);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_XSIZE,        260);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_YSIZE,        120);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_BGCOLOR,      C'10,10,20');
   ObjectSetInteger(0, PANEL_BG, OBJPROP_BORDER_TYPE,  BORDER_FLAT);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_COLOR,        clrDimGray);
   ObjectSetInteger(0, PANEL_BG, OBJPROP_SELECTABLE,   false);

   string rows[] = { ROW_H4BIAS, ROW_SETUP, ROW_DIRECTION, ROW_KEYLEVEL, ROW_SWEEP };
   for(int i = 0; i < ArraySize(rows); i++)
   {
      ObjectCreate(0, rows[i], OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, rows[i], OBJPROP_CORNER,    InpPanelCorner);
      ObjectSetInteger(0, rows[i], OBJPROP_XDISTANCE, InpPanelX + 8);
      ObjectSetInteger(0, rows[i], OBJPROP_YDISTANCE, InpPanelY + 8 + i * 22);
      ObjectSetInteger(0, rows[i], OBJPROP_FONTSIZE,  8);
      ObjectSetString (0, rows[i], OBJPROP_FONT,      "Courier New");
      ObjectSetInteger(0, rows[i], OBJPROP_COLOR,     clrSilver);
      ObjectSetString (0, rows[i], OBJPROP_TEXT,      "---");
      ObjectSetInteger(0, rows[i], OBJPROP_SELECTABLE, false);
   }
}

//──────────────────────────────────────────────────────────────────────────────
// Update panel rows from the latest signal
//──────────────────────────────────────────────────────────────────────────────
void UpdatePanel(const StrategySignal &sig)
{
   // H4 Bias row
   string h4Text;
   color  h4Color;
   if(sig.h4Bias > 0)
   { h4Text = "H4 Bias : BULLISH  EMA50>200"; h4Color = clrLime; }
   else if(sig.h4Bias < 0)
   { h4Text = "H4 Bias : BEARISH  EMA50<200"; h4Color = clrCrimson; }
   else
   { h4Text = "H4 Bias : NEUTRAL"; h4Color = clrSilver; }
   ObjectSetString (0, ROW_H4BIAS, OBJPROP_TEXT,  h4Text);
   ObjectSetInteger(0, ROW_H4BIAS, OBJPROP_COLOR, h4Color);

   // Setup row
   color  setupClr = SetupColor(sig.setupType);
   string setupTxt = "Setup   : " + SetupName(sig.setupType);
   ObjectSetString (0, ROW_SETUP, OBJPROP_TEXT,  setupTxt);
   ObjectSetInteger(0, ROW_SETUP, OBJPROP_COLOR, setupClr);

   // Direction row
   string dirText;
   color  dirColor;
   if(sig.direction == STRAT_DIR_BUY)
   { dirText = "Signal  : ^ BUY";  dirColor = clrLime; }
   else if(sig.direction == STRAT_DIR_SELL)
   { dirText = "Signal  : v SELL"; dirColor = clrCrimson; }
   else
   { dirText = "Signal  : ---";    dirColor = clrDimGray; }
   ObjectSetString (0, ROW_DIRECTION, OBJPROP_TEXT,  dirText);
   ObjectSetInteger(0, ROW_DIRECTION, OBJPROP_COLOR, dirColor);

   // Key Level row
   string klText;
   if(sig.keyLevel > 0.0)
      klText = StringFormat("KeyLvl  : %.5f", sig.keyLevel);
   else
      klText = "KeyLvl  : ---";
   ObjectSetString (0, ROW_KEYLEVEL, OBJPROP_TEXT,  klText);
   ObjectSetInteger(0, ROW_KEYLEVEL, OBJPROP_COLOR, clrSilver);

   // Sweep confirmation row
   string sweepText;
   color  sweepColor;
   if(sig.wickSweepConfirmed)
   {
      double wickLvl = (sig.sweepWickLow > 0.0) ? sig.sweepWickLow : sig.sweepWickHigh;
      sweepText  = StringFormat("SweepWk : %.5f  CONFIRMED", wickLvl);
      sweepColor = clrGold;
   }
   else
   {
      sweepText  = "SweepWk : ---";
      sweepColor = clrDimGray;
   }
   ObjectSetString (0, ROW_SWEEP, OBJPROP_TEXT,  sweepText);
   ObjectSetInteger(0, ROW_SWEEP, OBJPROP_COLOR, sweepColor);

   ChartRedraw(0);
}

//──────────────────────────────────────────────────────────────────────────────
// Zone drawing helpers
//──────────────────────────────────────────────────────────────────────────────
void DrawZones()
{
   DeleteByPrefix(PFX_ZONE_H1);
   DeleteByPrefix(PFX_ZONE_M15);

   datetime now = TimeCurrent();
   datetime t1  = now + (datetime)(4 * 3600);
   datetime t0  = now - (datetime)(7 * 86400);

   for(int i = 0; i < g_zoneCountH1; i++)
   {
      string name = PFX_ZONE_H1 + IntegerToString(i);
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, t0, g_zonesH1[i].high, t1, g_zonesH1[i].low))
         continue;
      ObjectSetInteger(0, name, OBJPROP_COLOR,     clrYellow);
      ObjectSetInteger(0, name, OBJPROP_FILL,       true);
      ObjectSetInteger(0, name, OBJPROP_BACK,       true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetString (0, name, OBJPROP_TOOLTIP,
                       StringFormat("H1 Zone | touches=%d", g_zonesH1[i].strength));
   }

   for(int i = 0; i < g_zoneCountM15; i++)
   {
      string name = PFX_ZONE_M15 + IntegerToString(i);
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, t0, g_zonesM15[i].high, t1, g_zonesM15[i].low))
         continue;
      ObjectSetInteger(0, name, OBJPROP_COLOR,     clrLimeGreen);
      ObjectSetInteger(0, name, OBJPROP_FILL,       true);
      ObjectSetInteger(0, name, OBJPROP_BACK,       true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetString (0, name, OBJPROP_TOOLTIP,
                       StringFormat("M15 Zone | touches=%d", g_zonesM15[i].strength));
   }
}

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
// Draw a signal arrow on the last closed M15 bar
// Colour by setup: A=DodgerBlue, B=Gold, C=OrangeRed, D=MediumPurple, E=DarkOrange, F=Lime
//──────────────────────────────────────────────────────────────────────────────
void DrawArrow(const datetime t, const double price,
               const int direction, const SetupType setup)
{
   string name = PFX_ARROW + IntegerToString(g_arrowIndex++);
   int    code = (direction == STRAT_DIR_BUY) ? 233 : 234; // Wingdings up/down
   color  clr  = SetupColor(setup);

   if(!ObjectCreate(0, name, OBJ_ARROW, 0, t, price)) return;
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE,  code);
   ObjectSetInteger(0, name, OBJPROP_COLOR,       clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,       2);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);
   ObjectSetString (0, name, OBJPROP_TOOLTIP,
                    "Setup " + SetupName(setup) +
                    (direction == STRAT_DIR_BUY ? " BUY" : " SELL"));
}

//──────────────────────────────────────────────────────────────────────────────
// Event handlers
//──────────────────────────────────────────────────────────────────────────────
int OnInit()
{
   CreatePanel();
   ScanZones();
   DrawZones();
   g_lastZoneScan = TimeCurrent();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   DeleteByPrefix(WC_PFX);
   ChartRedraw(0);
}

int OnCalculate(const int rates_total,   const int prev_calculated,
                const datetime &time[],  const double &open[],
                const double &high[],    const double &low[],
                const double &close[],   const long &tick_volume[],
                const long &volume[],    const int &spread[])
{
   // Throttle to one evaluation per second
   datetime nowSec = TimeCurrent();
   if(nowSec == g_lastRefresh) return rates_total;
   g_lastRefresh = nowSec;

   // Re-scan zones every hour
   if(nowSec - g_lastZoneScan >= 3600)
   {
      ScanZones();
      DrawZones();
      g_lastZoneScan = nowSec;
   }

   // Build params and evaluate signal
   StrategyParams p;
   FillParams(p);

   StrategySignal sig;
   if(!g_core.Evaluate(_Symbol, p, sig))
      return rates_total;

   // Always update the panel widget
   UpdatePanel(sig);

   // Draw arrows only on a new M15 bar close
   datetime curBarTime = iTime(_Symbol, PERIOD_M15, 0);
   if(curBarTime != g_lastBarTime)
   {
      g_lastBarTime = curBarTime;

      if(sig.setupType != SETUP_NONE && sig.direction != STRAT_DIR_NONE)
      {
         datetime signalBarTime = iTime(_Symbol, PERIOD_M15, 1);
         MqlRates r[];
         ArraySetAsSeries(r, true);
         if(CopyRates(_Symbol, PERIOD_M15, 1, 1, r) == 1)
         {
            double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
            double arrowPrice = (sig.direction == STRAT_DIR_BUY)
                                ? r[0].low  - 5.0 * point
                                : r[0].high + 5.0 * point;
            DrawArrow(signalBarTime, arrowPrice, sig.direction, sig.setupType);
         }
      }
   }

   return rates_total;
}

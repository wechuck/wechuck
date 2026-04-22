#ifndef __WECHUCK_TYPES_MQH__
#define __WECHUCK_TYPES_MQH__

// Import the shared SetupType enum and direction constants
#include <WeChuck/StrategyCore.mqh>

enum TradeDirection
{
   DIR_NONE = 0,
   DIR_BUY  = 1,
   DIR_SELL = -1
};

// Entry result from the strategy signal evaluation.
// 'valid'     – true when a confirmed Setup A, B, or C signal fired.
// 'setup'     – which setup triggered (SETUP_RUBBER_BAND / SETUP_RANGE_SCALP / SETUP_HFT_RANGE_SCALP).
// 'direction' – STRAT_DIR_BUY or STRAT_DIR_SELL (compatible with TradeDirection).
// 'boxHigh' / 'boxLow' – 5M structural box boundaries (used for Setup B/C TP).
struct EntryScoreBreakdown
{
   bool      valid;
   SetupType setup;
   int       direction;
   double    adx1M;
   double    adx5M;
   double    stochK;
   double    rsiCur;
   double    boxHigh;
   double    boxLow;
   double    signalBarHigh;        // 1M bar[1] high – for wick-based SL placement
   double    signalBarLow;         // 1M bar[1] low  – for wick-based SL placement
   string    details;
   // New fields from post-signal filter gates
   bool      wickSweepConfirmed;   // Wick sweep was confirmed (SL anchor below sweep wick)
   double    sweepWickLow;         // BUY wick-sweep bar[1].low  – use as SL anchor
   double    sweepWickHigh;        // SELL wick-sweep bar[1].high – use as SL anchor
   int       boxAgeMinutes;        // Age of the box in minutes
   int       boxWallTouches;       // Touch count on the relevant wall
   double    m5StochK;             // M5 Stochastic K value (for logging)
   int       h4Bias;               // H4 EMA bias: 1=bull, -1=bear, 0=neutral
};

struct BiasResult
{
   TradeDirection direction;
   bool emaBull;
   bool emaBear;
   bool structureBull;
   bool structureBear;
   string details;
};

#endif

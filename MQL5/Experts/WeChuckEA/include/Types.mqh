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
// 'valid'     – true when a confirmed Setup A or Setup B signal fired.
// 'setup'     – which setup triggered (SETUP_RUBBER_BAND / SETUP_RANGE_SCALP).
// 'direction' – STRAT_DIR_BUY or STRAT_DIR_SELL (compatible with TradeDirection).
// 'boxHigh' / 'boxLow' – 5M structural box boundaries (used for Setup B TP).
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
   double    signalBarHigh;   // 1M bar[1] high – for wick-based SL placement
   double    signalBarLow;    // 1M bar[1] low  – for wick-based SL placement
   string    details;
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

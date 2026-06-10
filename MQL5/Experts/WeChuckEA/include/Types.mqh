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

// Entry result returned by EntryScoring.Evaluate() to the EA.
// 'valid'     – true when a confirmed signal was detected.
// 'setup'     – which setup triggered (A–F).
// 'direction' – STRAT_DIR_BUY or STRAT_DIR_SELL.
// 'suggestedSL' / 'suggestedTP' – raw price levels from the strategy core (EA adds buffers).
// 'keyLevel'  – primary S/R level (used for box-invalidation / management).
struct EntryScoreBreakdown
{
   bool      valid;
   SetupType setup;
   int       direction;
   string    details;

   // SL / TP from strategy core (before EA spread/buffer adjustments)
   double    suggestedSL;
   double    suggestedTP;

   // Signal bar context (last completed M15 bar)
   double    signalBarHigh;
   double    signalBarLow;

   // Key level driving the setup (Asian range edge, OB level, pivot, MSS flip, etc.)
   double    keyLevel;

   // Supplemental context for management and logging
   int       h4Bias;              // H4 EMA bias: 1=bull, -1=bear, 0=neutral
   bool      wickSweepConfirmed;  // Setup A/F: wick-sweep trap confirmed
   double    sweepWickLow;        // BUY: extreme of sweep wick below key level
   double    sweepWickHigh;       // SELL: extreme of sweep wick above key level
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

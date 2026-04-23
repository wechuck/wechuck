#ifndef __WECHUCK_ENTRY_SCORING_MQH__
#define __WECHUCK_ENTRY_SCORING_MQH__

#include "Types.mqh"
#include <WeChuck/StrategyCore.mqh>

//──────────────────────────────────────────────────────────────────────────────
// CEntryScoring
//
// Thin adapter between the institutional signal engine (CInstitutionalCore) and
// the EA's EntryScoreBreakdown struct.  All actual strategy logic lives in
// StrategyCore.mqh – this class only translates the output.
//──────────────────────────────────────────────────────────────────────────────
class CEntryScoring
{
private:
   CInstitutionalCore m_core;

public:

   // Evaluate current market conditions.
   // Returns true if evaluation succeeded (result may still be SETUP_NONE = no trade).
   bool Evaluate(const string     symbol,
                 const StrategyParams &p,
                 EntryScoreBreakdown  &outScore)
   {
      // Reset output
      outScore.valid             = false;
      outScore.setup             = SETUP_NONE;
      outScore.direction         = STRAT_DIR_NONE;
      outScore.details           = "";
      outScore.suggestedSL       = 0.0;
      outScore.suggestedTP       = 0.0;
      outScore.signalBarHigh     = 0.0;
      outScore.signalBarLow      = 0.0;
      outScore.keyLevel          = 0.0;
      outScore.h4Bias            = 0;
      outScore.wickSweepConfirmed = false;
      outScore.sweepWickLow      = 0.0;
      outScore.sweepWickHigh     = 0.0;

      // Run the institutional signal engine
      StrategySignal sig;
      if(!m_core.Evaluate(symbol, p, sig))
         return false;

      // Translate StrategySignal → EntryScoreBreakdown
      outScore.setup             = sig.setupType;
      outScore.direction         = sig.direction;
      outScore.details           = sig.details;
      outScore.suggestedSL       = sig.suggestedSL;
      outScore.suggestedTP       = sig.suggestedTP;
      outScore.signalBarHigh     = sig.signalBarHigh;
      outScore.signalBarLow      = sig.signalBarLow;
      outScore.keyLevel          = sig.keyLevel;
      outScore.h4Bias            = sig.h4Bias;
      outScore.wickSweepConfirmed = sig.wickSweepConfirmed;
      outScore.sweepWickLow      = sig.sweepWickLow;
      outScore.sweepWickHigh     = sig.sweepWickHigh;
      outScore.valid             = (sig.setupType != SETUP_NONE);

      return true;
   }

   // Proxy for dynamic exit condition (H4 EMA flip against trade direction).
   bool ShouldExit(const string symbol, const int posDir, const StrategyParams &p)
   {
      return m_core.ShouldExit(symbol, posDir, p);
   }
};

#endif // __WECHUCK_ENTRY_SCORING_MQH__

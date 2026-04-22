#ifndef __WECHUCK_DIAGNOSTICS_LOGGER_MQH__
#define __WECHUCK_DIAGNOSTICS_LOGGER_MQH__

class CDiagnosticsLogger
{
private:
   bool m_enabled;
   long m_setupACount;   // Setup A "Rubber Band" signals that passed all filters
   long m_setupBCount;   // Setup B "Range Scalp" signals that passed all filters
   long m_setupCCount;   // Setup C "HFT Range Scalp" signals that passed all filters
   long m_rejectedCount; // Evaluations that produced no valid signal

public:
   void Init(const bool enabled)
   {
      m_enabled      = enabled;
      m_setupACount  = 0;
      m_setupBCount  = 0;
      m_setupCCount  = 0;
      m_rejectedCount = 0;
   }

   void Log(const string msg)
   {
      if(!m_enabled) return;
      Print("[WECHUCK] ", msg);
   }

   void LogScore(const string symbol, const int setup, const int direction,
                 const double adx1M, const double adx5M,
                 const double stochK, const double rsiCur,
                 const string details)
   {
      if(!m_enabled) return;
      PrintFormat("[WECHUCK][SIGNAL] %s setup=%d dir=%d adx1M=%.1f adx5M=%.1f "
                  "stochK=%.1f rsi=%.1f | %s",
                  symbol, setup, direction, adx1M, adx5M, stochK, rsiCur, details);
   }

   void LogDecision(const string symbol, const bool accepted, const string reason)
   {
      if(!m_enabled) return;
      PrintFormat("[WECHUCK][DECISION] %s accepted=%s reason=%s",
                  symbol, accepted ? "true" : "false", reason);
   }

   void LogExecution(const string symbol, const string action, const long retcode,
                     const int spreadPoints, const double slippagePoints,
                     const long latencyMs)
   {
      if(!m_enabled) return;
      PrintFormat("[WECHUCK][EXEC] %s action=%s retcode=%ld spreadPts=%d "
                  "slippagePts=%.1f latencyMs=%ld",
                  symbol, action, retcode, spreadPoints, slippagePoints, latencyMs);
   }

   // Call once per bar after a valid signal is detected (before entry filter).
   void TrackContribution(const bool isSetupA, const bool isSetupB, const bool isSetupC)
   {
      if(isSetupA) m_setupACount++;
      if(isSetupB) m_setupBCount++;
      if(isSetupC) m_setupCCount++;
      if(!isSetupA && !isSetupB && !isSetupC) m_rejectedCount++;
   }

   void DumpStats()
   {
      if(!m_enabled) return;
      PrintFormat("[WECHUCK][STATS] SetupA(RubberBand)=%ld  SetupB(RangeScalp)=%ld  "
                  "SetupC(HFTRangeScalp)=%ld  Rejected=%ld",
                  m_setupACount, m_setupBCount, m_setupCCount, m_rejectedCount);
   }
};

#endif

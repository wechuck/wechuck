#ifndef __WECHUCK_DIAGNOSTICS_LOGGER_MQH__
#define __WECHUCK_DIAGNOSTICS_LOGGER_MQH__

class CDiagnosticsLogger
{
private:
   bool m_enabled;
   long m_setupACount;   // Setup A – London Liquidity Sweep
   long m_setupBCount;   // Setup B – H4 Order Block Retest
   long m_setupCCount;   // Setup C – Fair Value Gap Fill
   long m_setupDCount;   // Setup D – Daily Pivot Bounce
   long m_setupECount;   // Setup E – Market Structure Shift Retest
   long m_setupFCount;   // Setup F – Weekly High/Low Sniper (20-pip challenge)
   long m_rejectedCount; // Evaluations that produced no valid signal

public:
   void Init(const bool enabled)
   {
      m_enabled       = enabled;
      m_setupACount   = 0;
      m_setupBCount   = 0;
      m_setupCCount   = 0;
      m_setupDCount   = 0;
      m_setupECount   = 0;
      m_setupFCount   = 0;
      m_rejectedCount = 0;
   }

   void Log(const string msg)
   {
      if(!m_enabled) return;
      Print("[WECHUCK] ", msg);
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

   // Called once per detected signal (before final entry gates).
   void TrackContribution(const bool isA, const bool isB, const bool isC,
                          const bool isD, const bool isE, const bool isF)
   {
      if(isA) m_setupACount++;
      if(isB) m_setupBCount++;
      if(isC) m_setupCCount++;
      if(isD) m_setupDCount++;
      if(isE) m_setupECount++;
      if(isF) m_setupFCount++;
      if(!isA && !isB && !isC && !isD && !isE && !isF) m_rejectedCount++;
   }

   void DumpStats()
   {
      if(!m_enabled) return;
      PrintFormat(
         "[WECHUCK][STATS] "
         "A(LondonSweep)=%ld  B(OBRetest)=%ld  C(FVGFill)=%ld  "
         "D(PivotBounce)=%ld  E(MSSRetest)=%ld  F(WeeklySniper)=%ld  "
         "Rejected=%ld",
         m_setupACount, m_setupBCount, m_setupCCount,
         m_setupDCount, m_setupECount, m_setupFCount, m_rejectedCount);
   }
};

#endif

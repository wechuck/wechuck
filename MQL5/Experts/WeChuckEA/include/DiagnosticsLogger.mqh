#ifndef __WECHUCK_DIAGNOSTICS_LOGGER_MQH__
#define __WECHUCK_DIAGNOSTICS_LOGGER_MQH__

class CDiagnosticsLogger
{
private:
   bool m_enabled;
   long m_adxCount;
   long m_zscoreCount;
   long m_stochCount;
   long m_breakoutCount;
   long m_volumeCount;

public:
   void Init(const bool enabled)
   {
      m_enabled = enabled;
      m_adxCount = 0;
      m_zscoreCount = 0;
      m_stochCount = 0;
      m_breakoutCount = 0;
      m_volumeCount = 0;
   }

   void Log(const string msg)
   {
      if(!m_enabled) return;
      Print("[WECHUCK] ", msg);
   }

   void LogScore(const string symbol, const int direction, const int total, const string details)
   {
      if(!m_enabled) return;
      PrintFormat("[WECHUCK][SCORE] %s dir=%d total=%d details=%s", symbol, direction, total, details);
   }

   void LogDecision(const string symbol, const bool accepted, const string reason)
   {
      if(!m_enabled) return;
      PrintFormat("[WECHUCK][DECISION] %s accepted=%s reason=%s", symbol, accepted ? "true" : "false", reason);
   }

   void LogExecution(const string symbol, const string action, const long retcode, const int spreadPoints, const double slippagePoints, const long latencyMs)
   {
      if(!m_enabled) return;
      PrintFormat("[WECHUCK][EXEC] %s action=%s retcode=%ld spreadPts=%d slippagePts=%.1f latencyMs=%ld", symbol, action, retcode, spreadPoints, slippagePoints, latencyMs);
   }

   void TrackContribution(const bool adx, const bool zscore, const bool stoch, const bool breakout, const bool volume)
   {
      if(adx) m_adxCount++;
      if(zscore) m_zscoreCount++;
      if(stoch) m_stochCount++;
      if(breakout) m_breakoutCount++;
      if(volume) m_volumeCount++;
   }

   void DumpStats()
   {
      if(!m_enabled) return;
      PrintFormat("[WECHUCK][STATS] adx=%ld zscore=%ld stoch=%ld breakout=%ld volume=%ld", m_adxCount, m_zscoreCount, m_stochCount, m_breakoutCount, m_volumeCount);
   }
};

#endif

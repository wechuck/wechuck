#ifndef __WECHUCK_RISK_MANAGER_MQH__
#define __WECHUCK_RISK_MANAGER_MQH__

#define LOSS_STREAK_LOOKBACK_DAYS 5
#define MIN_DAY_START_BALANCE 0.01
#define ROLLING_WIN_BUFFER_MAX 50

class CRiskManager
{
private:
   datetime m_lastEntryTime;

   // ── Rolling win rate (circular buffer) ─────────────────────────────────
   int  m_winBuffer[ROLLING_WIN_BUFFER_MAX];  // 1 = win, 0 = loss
   int  m_winBufHead;
   int  m_winBufCount;
   int  m_rollingWindowSize;

   // ── Drawdown-adaptive lot scaling ───────────────────────────────────────
   double m_sessionPeakEquity;     // Highest equity since last daily reset
   bool   m_ddScaleActive;         // True when lot scaling is currently halved

   // ── Daily reset tracking ─────────────────────────────────────────────────
   datetime m_lastDailyReset;

public:
   void Init()
   {
      m_lastEntryTime      = 0;
      m_winBufHead         = 0;
      m_winBufCount        = 0;
      m_rollingWindowSize  = 20;
      m_sessionPeakEquity  = 0.0;
      m_ddScaleActive      = false;
      m_lastDailyReset     = 0;
      for(int i = 0; i < ROLLING_WIN_BUFFER_MAX; i++) m_winBuffer[i] = 0;
   }

   void RegisterEntry(const datetime nowTime)
   {
      m_lastEntryTime = nowTime;
   }

   //──────────────────────────────────────────────────────────────────────────
   // SetRollingWindowSize – configures how many recent trades to track (max 50).
   //──────────────────────────────────────────────────────────────────────────
   void SetRollingWindowSize(const int n)
   {
      m_rollingWindowSize = MathMax(1, MathMin(n, ROLLING_WIN_BUFFER_MAX));
   }

   //──────────────────────────────────────────────────────────────────────────
   // RecordTradeOutcome – push a win (true) or loss (false) into the circular buffer.
   // Call this when a position closes.
   //──────────────────────────────────────────────────────────────────────────
   void RecordTradeOutcome(const bool win)
   {
      m_winBuffer[m_winBufHead] = win ? 1 : 0;
      m_winBufHead = (m_winBufHead + 1) % m_rollingWindowSize;
      if(m_winBufCount < m_rollingWindowSize) m_winBufCount++;
   }

   //──────────────────────────────────────────────────────────────────────────
   // RollingWinRatePct – returns win rate over the last N recorded trades (0–100).
   // Returns 100.0 when no trades have been recorded yet (no restriction).
   //──────────────────────────────────────────────────────────────────────────
   double RollingWinRatePct() const
   {
      if(m_winBufCount == 0) return 100.0;
      int wins = 0;
      for(int i = 0; i < m_winBufCount; i++) wins += m_winBuffer[i];
      return (wins * 100.0) / m_winBufCount;
   }

   //──────────────────────────────────────────────────────────────────────────
   // UpdateSessionPeak – call each tick to keep peak equity current.
   //──────────────────────────────────────────────────────────────────────────
   void UpdateSessionPeak(const double equity)
   {
      if(equity > m_sessionPeakEquity)
         m_sessionPeakEquity = equity;
   }

   //──────────────────────────────────────────────────────────────────────────
   // GetLotFactor – returns the drawdown-adaptive lot multiplier.
   // ddScalePct    : drawdown % from session peak that triggers halving (e.g. 5.0)
   // ddLotFactor   : lot multiplier when scaling is active (e.g. 0.5)
   // Once activated the factor stays halved until a winning trade is recorded,
   // which resets m_ddScaleActive to false.
   //──────────────────────────────────────────────────────────────────────────
   double GetLotFactor(const double equity,
                       const double ddScalePct,
                       const double ddLotFactor)
   {
      if(ddScalePct <= 0.0 || m_sessionPeakEquity <= 0.0) return 1.0;

      double drawdownPct = (m_sessionPeakEquity - equity) / m_sessionPeakEquity * 100.0;

      if(drawdownPct >= ddScalePct)
         m_ddScaleActive = true;

      // Re-enable full lots only after the last recorded trade was a win
      if(m_ddScaleActive && m_winBufCount > 0 &&
         m_winBuffer[(m_winBufHead - 1 + m_rollingWindowSize) % m_rollingWindowSize] == 1)
         m_ddScaleActive = false;

      return m_ddScaleActive ? ddLotFactor : 1.0;
   }

   //──────────────────────────────────────────────────────────────────────────
   // CheckDailyReset – call once per new M1 bar.
   // Resets session peak and rolling buffer at 00:00 UTC each day.
   //──────────────────────────────────────────────────────────────────────────
   void CheckDailyReset(const datetime now)
   {
      MqlDateTime dt;
      TimeToStruct(now, dt);

      MqlDateTime resetDT;
      resetDT.year  = dt.year;
      resetDT.mon   = dt.mon;
      resetDT.day   = dt.day;
      resetDT.hour  = 0;
      resetDT.min   = 0;
      resetDT.sec   = 0;
      datetime todayStart = StructToTime(resetDT);

      if(todayStart > m_lastDailyReset)
      {
         m_lastDailyReset    = todayStart;
         m_sessionPeakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         m_winBufHead        = 0;
         m_winBufCount       = 0;
         m_ddScaleActive     = false;
         Print("[RiskManager] Daily reset at ", TimeToString(todayStart, TIME_DATE | TIME_MINUTES));
      }
   }

   int CountOpenPositionsAll()
   {
      return (int)PositionsTotal();
   }

   double ClosedPnlToday(const string symbol = "")
   {
      datetime nowTime = TimeCurrent();
      MqlDateTime t;
      TimeToStruct(nowTime, t);
      t.hour = 0;
      t.min = 0;
      t.sec = 0;
      datetime dayStart = StructToTime(t);

      if(!HistorySelect(dayStart, nowTime)) return 0.0;

      double pnl = 0.0;
      int totalDeals = (int)HistoryDealsTotal();
      for(int i = 0; i < totalDeals; i++)
      {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0) continue;
         long entryType = HistoryDealGetInteger(deal, DEAL_ENTRY);
         if(entryType != DEAL_ENTRY_OUT) continue;

         string dealSymbol = HistoryDealGetString(deal, DEAL_SYMBOL);
         if(symbol != "" && dealSymbol != symbol) continue;

         pnl += HistoryDealGetDouble(deal, DEAL_PROFIT);
         pnl += HistoryDealGetDouble(deal, DEAL_SWAP);
         pnl += HistoryDealGetDouble(deal, DEAL_COMMISSION);
      }
      return pnl;
   }

   int TradesInLastHour(const string symbol)
   {
      datetime nowTime = TimeCurrent();
      datetime fromTime = nowTime - 3600;
      if(!HistorySelect(fromTime, nowTime)) return 0;

      int count = 0;
      int totalDeals = (int)HistoryDealsTotal();
      for(int i = 0; i < totalDeals; i++)
      {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0) continue;
         if(HistoryDealGetString(deal, DEAL_SYMBOL) != symbol) continue;
         long entryType = HistoryDealGetInteger(deal, DEAL_ENTRY);
         if(entryType == DEAL_ENTRY_IN) count++;
      }
      return count;
   }

   bool HasConsecutiveLossPause(const string symbol, const int lossLimit, const int pauseMinutes, string &reason)
   {
      reason = "";
      datetime nowTime = TimeCurrent();
      datetime fromTime = nowTime - 86400 * LOSS_STREAK_LOOKBACK_DAYS;
      if(!HistorySelect(fromTime, nowTime)) return false;

      int totalDeals = (int)HistoryDealsTotal();
      int losses = 0;
      datetime lastLossTime = 0;

      for(int i = totalDeals - 1; i >= 0; i--)
      {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0) continue;
         if(HistoryDealGetString(deal, DEAL_SYMBOL) != symbol) continue;
         if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

         double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_COMMISSION);
         if(pnl < 0.0)
         {
            losses++;
            if(lastLossTime == 0) lastLossTime = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
            if(losses >= lossLimit)
            {
               datetime resume = lastLossTime + (pauseMinutes * 60);
               if(nowTime < resume)
               {
                  reason = StringFormat("Consecutive-loss pause active until %s", TimeToString(resume, TIME_DATE | TIME_MINUTES));
                  return true;
               }
               return false;
            }
         }
         else
         {
            break;
         }
      }
      return false;
   }

   bool CanTradeNow(const string symbol,
                    const int cooldownSeconds,
                    const int maxTradesPerHour,
                    const int globalMaxPositions,
                    const int consecutiveLossLimit,
                    const int pauseMinutes,
                    const double dailyLossCapPct,
                    const bool useProfitStop,
                    const double dailyProfitStopPct,
                    string &reason)
   {
      reason = "";
      datetime nowTime = TimeCurrent();

      if((nowTime - m_lastEntryTime) < cooldownSeconds)
      {
         reason = "Cooldown between entries active";
         return false;
      }

      if(CountOpenPositionsAll() >= globalMaxPositions)
      {
         reason = "Global open-position cap reached";
         return false;
      }

      int tradeCountHour = TradesInLastHour(symbol);
      if(tradeCountHour >= maxTradesPerHour)
      {
         reason = "Per-symbol per-hour trade cap reached";
         return false;
      }

      if(HasConsecutiveLossPause(symbol, consecutiveLossLimit, pauseMinutes, reason))
         return false;

      double dayPnl = ClosedPnlToday("");
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double dayStartBalance = (balance - dayPnl);
      if(dayStartBalance < MIN_DAY_START_BALANCE)
      {
         reason = "Invalid day-start balance for daily guard calculation";
         return false;
      }
      double dayPct = (dayPnl / dayStartBalance) * 100.0;

      if(dayPct <= -MathAbs(dailyLossCapPct))
      {
         reason = "Daily loss cap reached";
         return false;
      }

      if(useProfitStop && dayPct >= MathAbs(dailyProfitStopPct))
      {
         reason = "Daily profit stop reached";
         return false;
      }

      return true;
   }
};

#endif

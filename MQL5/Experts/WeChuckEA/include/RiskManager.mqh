#ifndef __WECHUCK_RISK_MANAGER_MQH__
#define __WECHUCK_RISK_MANAGER_MQH__

class CRiskManager
{
private:
   datetime m_lastEntryTime;

public:
   void Init()
   {
      m_lastEntryTime = 0;
   }

   void RegisterEntry(const datetime nowTime)
   {
      m_lastEntryTime = nowTime;
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
      datetime fromTime = nowTime - 86400 * 5;
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
      if(dayStartBalance <= 0.0) dayStartBalance = balance;
      double dayPct = (dayStartBalance > 0.0 ? (dayPnl / dayStartBalance) * 100.0 : 0.0);

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

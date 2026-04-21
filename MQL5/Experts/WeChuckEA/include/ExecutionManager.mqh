#ifndef __WECHUCK_EXECUTION_MANAGER_MQH__
#define __WECHUCK_EXECUTION_MANAGER_MQH__

#include <Trade/Trade.mqh>
#include "Types.mqh"
#include "DiagnosticsLogger.mqh"

class CExecutionManager
{
private:
   CTrade m_trade;

public:
   void Init(const long magic)
   {
      m_trade.SetExpertMagicNumber(magic);
   }

   bool ValidateStops(const string symbol, const int direction, const double price, double &sl, double &tp)
   {
      int stopsLevel = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      int freezeLevel = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      int minDistance = (int)MathMax(stopsLevel, freezeLevel);
      double minDistancePrice = minDistance * point;

      if(direction == DIR_BUY)
      {
         if((price - sl) < minDistancePrice) sl = price - minDistancePrice;
         if((tp - price) < minDistancePrice) tp = price + minDistancePrice;
      }
      else if(direction == DIR_SELL)
      {
         if((sl - price) < minDistancePrice) sl = price + minDistancePrice;
         if((price - tp) < minDistancePrice) tp = price - minDistancePrice;
      }
      return true;
   }

   bool Open(const string symbol,
             const int direction,
             const double volume,
             const int maxDeviationPoints,
             const int retries,
             double sl,
             double tp,
             CDiagnosticsLogger &logger)
   {
      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick)) return false;

      double price = (direction == DIR_BUY) ? tick.ask : tick.bid;
      ValidateStops(symbol, direction, price, sl, tp);
      m_trade.SetDeviationInPoints(maxDeviationPoints);

      for(int i = 0; i < retries; i++)
      {
         ulong start = GetTickCount();
         bool ok = false;
         if(direction == DIR_BUY)
            ok = m_trade.Buy(volume, symbol, 0.0, sl, tp, "WeChuck buy");
         else if(direction == DIR_SELL)
            ok = m_trade.Sell(volume, symbol, 0.0, sl, tp, "WeChuck sell");

         long retcode = m_trade.ResultRetcode();
         long latency = (long)(GetTickCount() - start);
         double fill = m_trade.ResultPrice();
         double slippagePoints = (fill > 0.0 ? MathAbs(fill - price) / SymbolInfoDouble(symbol, SYMBOL_POINT) : 0.0);
         int spreadPts = (int)((tick.ask - tick.bid) / SymbolInfoDouble(symbol, SYMBOL_POINT));
         logger.LogExecution(symbol, "open", retcode, spreadPts, slippagePoints, latency);

         if(ok) return true;
         Sleep(100 + (i * 150));
         SymbolInfoTick(symbol, tick);
      }
      return false;
   }

   bool CloseSymbolPosition(const string symbol, CDiagnosticsLogger &logger)
   {
      MqlTick tick;
      SymbolInfoTick(symbol, tick);
      bool ok = m_trade.PositionClose(symbol);
      logger.LogExecution(symbol, "close", m_trade.ResultRetcode(), (int)((tick.ask - tick.bid) / SymbolInfoDouble(symbol, SYMBOL_POINT)), 0.0, 0);
      return ok;
   }

   bool ModifyPosition(const string symbol, const double sl, const double tp)
   {
      return m_trade.PositionModify(symbol, sl, tp);
   }
};

#endif

#ifndef __WECHUCK_PARTIAL_CLOSE_MQH__
#define __WECHUCK_PARTIAL_CLOSE_MQH__

//──────────────────────────────────────────────────────────────────────────────
// PartialCloseManager.mqh
// 3-Target partial-close system per open position.
//
// T1 at InpT1RR × SL distance → close InpT1ClosePct% of position → move SL to BE
// T2 at InpT2RR × SL distance → close another InpT2ClosePct% of position
// T3 → trailing stop (handled by existing ManageOpenPosition) on remainder
//
// State is tracked in a lightweight struct keyed by position ticket.
// Call Manage() once per ManageOpenPosition() tick AFTER the min-hold check.
//──────────────────────────────────────────────────────────────────────────────

#include <Trade/Trade.mqh>

struct PartialCloseState
{
   ulong    ticket;
   bool     t1Done;
   bool     t2Done;
   bool     breakevenApplied;
};

class CPartialCloseManager
{
private:
   CTrade              m_trade;
   PartialCloseState   m_state;
   bool                m_active;          // true when tracking a position

   //──────────────────────────────────────────────────────────────────────────
   // Attempt a partial close of pct% of the current lot.
   // Returns true when the close order was sent successfully.
   //──────────────────────────────────────────────────────────────────────────
   bool DoPartialClose(const string symbol, const double pct)
   {
      if(!PositionSelect(symbol)) return false;

      double lots     = PositionGetDouble(POSITION_VOLUME);
      double closeLot = NormalizeDouble(lots * (pct / 100.0), 2);

      double minVol  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double stepVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      if(stepVol > 0.0)
         closeLot = MathFloor(closeLot / stepVol) * stepVol;

      closeLot = MathMax(closeLot, (minVol > 0.0 ? minVol : 0.01));

      // Cannot close more than we have (guard against floating-point edge)
      if(closeLot >= lots)
         return false;

      closeLot = NormalizeDouble(closeLot, 2);
      return m_trade.PositionClosePartial(symbol, closeLot);
   }

   //──────────────────────────────────────────────────────────────────────────
   // Move SL to break-even (entry price + 1 pip buffer in trade direction).
   //──────────────────────────────────────────────────────────────────────────
   void ApplyBreakeven(const string symbol)
   {
      if(!PositionSelect(symbol)) return;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long   posType   = PositionGetInteger(POSITION_TYPE);

      int    digits    = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
      double onePip    = ((digits == 3 || digits == 5) ? 10.0 : 1.0) * point;
      double bePip     = onePip;  // 1-pip cushion to avoid immediate stop-out

      double newSL;
      if(posType == POSITION_TYPE_BUY)
      {
         newSL = openPrice + bePip;
         if(currentSL >= newSL) return;  // already at or better than BE
      }
      else
      {
         newSL = openPrice - bePip;
         if(currentSL > 0.0 && currentSL <= newSL) return;
      }

      m_trade.PositionModify(symbol, newSL, currentTP);
      Print("[PartialClose] Breakeven applied on ", symbol, " | newSL=", newSL);
   }

public:
   //──────────────────────────────────────────────────────────────────────────
   // Init – call from OnInit or when a new position is opened.
   //──────────────────────────────────────────────────────────────────────────
   void Init(const long magicNumber)
   {
      m_trade.SetExpertMagicNumber(magicNumber);
      m_active = false;
      m_state.ticket           = 0;
      m_state.t1Done           = false;
      m_state.t2Done           = false;
      m_state.breakevenApplied = false;
   }

   //──────────────────────────────────────────────────────────────────────────
   // OnNewPosition – call immediately after a successful position open.
   //──────────────────────────────────────────────────────────────────────────
   void OnNewPosition(const ulong ticket)
   {
      m_state.ticket           = ticket;
      m_state.t1Done           = false;
      m_state.t2Done           = false;
      m_state.breakevenApplied = false;
      m_active                 = true;
   }

   //──────────────────────────────────────────────────────────────────────────
   // OnPositionClosed – call when position closes to reset state.
   //──────────────────────────────────────────────────────────────────────────
   void OnPositionClosed()
   {
      m_active = false;
      m_state.ticket = 0;
   }

   //──────────────────────────────────────────────────────────────────────────
   // Manage – runs each tick AFTER the min-hold gate.
   // Parameters:
   //   symbol       – trading symbol
   //   t1RR         – R:R at which T1 fires (e.g. 1.0)
   //   t2RR         – R:R at which T2 fires (e.g. 2.0)
   //   t1ClosePct   – % of position to close at T1 (e.g. 33)
   //   t2ClosePct   – % of position to close at T2 (e.g. 33)
   //   usePartial   – master switch; if false the method is a no-op
   //──────────────────────────────────────────────────────────────────────────
   void Manage(const string symbol,
               const double t1RR,      const double t2RR,
               const double t1ClosePct, const double t2ClosePct,
               const bool   usePartial)
   {
      if(!usePartial || !m_active) return;
      if(!PositionSelect(symbol)) { m_active = false; return; }

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double entrySL   = PositionGetDouble(POSITION_SL);
      long   posType   = PositionGetInteger(POSITION_TYPE);

      double slDist = MathAbs(openPrice - entrySL);
      if(slDist <= 0.0) return;  // SL not set; cannot compute R:R

      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick)) return;

      double currentBid = tick.bid;
      double currentAsk = tick.ask;
      double profitMove;

      if(posType == POSITION_TYPE_BUY)
         profitMove = currentBid - openPrice;
      else
         profitMove = openPrice - currentAsk;

      // ── T1 trigger ────────────────────────────────────────────────────────
      if(!m_state.t1Done && profitMove >= slDist * t1RR)
      {
         if(DoPartialClose(symbol, t1ClosePct))
         {
            Print("[PartialClose] T1 close (", t1ClosePct, "%) on ", symbol,
                  " at R:R=", DoubleToString(profitMove / slDist, 2));
            m_state.t1Done = true;
         }

         // Move SL to breakeven on T1 hit (regardless of partial close success)
         if(!m_state.breakevenApplied)
         {
            ApplyBreakeven(symbol);
            m_state.breakevenApplied = true;
         }
      }

      // ── T2 trigger ────────────────────────────────────────────────────────
      if(m_state.t1Done && !m_state.t2Done && profitMove >= slDist * t2RR)
      {
         if(DoPartialClose(symbol, t2ClosePct))
         {
            Print("[PartialClose] T2 close (", t2ClosePct, "%) on ", symbol,
                  " at R:R=", DoubleToString(profitMove / slDist, 2));
            m_state.t2Done = true;
         }
      }
   }
};

#endif // __WECHUCK_PARTIAL_CLOSE_MQH__

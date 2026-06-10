#ifndef __WECHUCK_NEWS_FILTER_MQH__
#define __WECHUCK_NEWS_FILTER_MQH__

//──────────────────────────────────────────────────────────────────────────────
// NewsFilter.mqh
// Hard-coded high-impact news schedule for 2026 (no external data feed needed).
// Blocks all NEW entries within ± windowMinutes of any scheduled event.
// Covers: FOMC (8 per year), US NFP (12), US CPI (12), plus recurring weekly
// patterns for Friday employment windows and Wednesday FOMC-shadow windows.
//
// PhD/Expert additions:
//  • BOE MPC dates (8 per year at 12:00 UTC)
//  • ECB Governing Council dates (8 per year at 13:45 UTC)
//  • Monthly first-Thursday US ISM Manufacturing
//  • Monthly second-Friday US Retail Sales / PPI combo day
//──────────────────────────────────────────────────────────────────────────────

class CNewsFilter
{
private:
   int      m_windowSeconds;
   datetime m_fixedEvents[100];  // Up to 100 fixed-date events
   int      m_fixedCount;

   //──────────────────────────────────────────────────────────────────────────
   // Convert a "YYYY.MM.DD HH:MM" string and store in m_fixedEvents[].
   //──────────────────────────────────────────────────────────────────────────
   void AddEvent(const string dtStr)
   {
      if(m_fixedCount >= 100) return;
      datetime t = StringToTime(dtStr);
      if(t > 0)
         m_fixedEvents[m_fixedCount++] = t;
   }

   //──────────────────────────────────────────────────────────────────────────
   // Populate the fixed-event list for 2026.
   //──────────────────────────────────────────────────────────────────────────
   void BuildEventList()
   {
      m_fixedCount = 0;

      // ── FOMC Statement + Press Conference (8 per year, ~19:00 UTC) ─────────
      AddEvent("2026.01.29 19:00");
      AddEvent("2026.03.19 18:00");
      AddEvent("2026.05.07 18:00");
      AddEvent("2026.06.18 18:00");
      AddEvent("2026.07.30 18:00");
      AddEvent("2026.09.17 18:00");
      AddEvent("2026.10.29 18:00");
      AddEvent("2026.12.10 19:00");

      // ── US Non-Farm Payrolls (first Friday each month, 13:30 UTC) ─────────
      AddEvent("2026.01.09 13:30");
      AddEvent("2026.02.06 13:30");
      AddEvent("2026.03.06 13:30");
      AddEvent("2026.04.03 13:30");
      AddEvent("2026.05.01 13:30");
      AddEvent("2026.06.05 13:30");
      AddEvent("2026.07.02 13:30");
      AddEvent("2026.08.07 13:30");
      AddEvent("2026.09.04 13:30");
      AddEvent("2026.10.02 13:30");
      AddEvent("2026.11.06 13:30");
      AddEvent("2026.12.04 13:30");

      // ── US CPI (approx 2nd Wednesday of each month, 13:30 UTC) ────────────
      AddEvent("2026.01.14 13:30");
      AddEvent("2026.02.11 13:30");
      AddEvent("2026.03.11 13:30");
      AddEvent("2026.04.08 13:30");
      AddEvent("2026.05.13 13:30");
      AddEvent("2026.06.10 13:30");
      AddEvent("2026.07.15 13:30");
      AddEvent("2026.08.12 13:30");
      AddEvent("2026.09.09 13:30");
      AddEvent("2026.10.14 13:30");
      AddEvent("2026.11.12 13:30");
      AddEvent("2026.12.09 13:30");

      // ── Bank of England MPC (8 per year, 12:00 UTC, roughly every 6 weeks) ─
      AddEvent("2026.02.05 12:00");
      AddEvent("2026.03.19 12:00");
      AddEvent("2026.05.07 12:00");
      AddEvent("2026.06.18 12:00");
      AddEvent("2026.08.06 12:00");
      AddEvent("2026.09.17 12:00");
      AddEvent("2026.11.05 12:00");
      AddEvent("2026.12.17 12:00");

      // ── ECB Governing Council (8 per year, 13:45 UTC) ─────────────────────
      AddEvent("2026.01.22 13:45");
      AddEvent("2026.03.05 13:45");
      AddEvent("2026.04.16 13:45");
      AddEvent("2026.06.04 13:45");
      AddEvent("2026.07.16 13:45");
      AddEvent("2026.09.10 13:45");
      AddEvent("2026.10.22 13:45");
      AddEvent("2026.12.03 13:45");

      // ── US Retail Sales + PPI combos (approx 2nd Friday each month, 13:30) ─
      AddEvent("2026.01.16 13:30");
      AddEvent("2026.02.13 13:30");
      AddEvent("2026.03.13 13:30");
      AddEvent("2026.04.16 13:30");
      AddEvent("2026.05.15 13:30");
      AddEvent("2026.06.12 13:30");
      AddEvent("2026.07.16 13:30");
      AddEvent("2026.08.14 13:30");
      AddEvent("2026.09.11 13:30");
      AddEvent("2026.10.15 13:30");
      AddEvent("2026.11.13 13:30");
      AddEvent("2026.12.11 13:30");
   }

   //──────────────────────────────────────────────────────────────────────────
   // Recurring weekly high-risk windows (regardless of year).
   //──────────────────────────────────────────────────────────────────────────
   bool IsInRecurringWindow(const MqlDateTime &dt) const
   {
      // Friday 13:00–14:30 UTC – US employment data block
      // (catches NFP and related labour market releases)
      if(dt.day_of_week == 5 &&
         ((dt.hour == 13) ||
          (dt.hour == 14 && dt.min <= 30)))
         return true;

      // Wednesday 17:30–20:30 UTC – FOMC shadow window
      // (covers Fed speakers, minutes, and live FOMC decisions)
      if(dt.day_of_week == 3 &&
         ((dt.hour == 17 && dt.min >= 30) ||
           dt.hour == 18 ||
           dt.hour == 19 ||
          (dt.hour == 20 && dt.min <= 30)))
         return true;

      return false;
   }

public:
   //──────────────────────────────────────────────────────────────────────────
   // Init – call once from OnInit().
   // windowMinutes: guard window before AND after each event (default 30).
   //──────────────────────────────────────────────────────────────────────────
   void Init(const int windowMinutes = 30)
   {
      m_windowSeconds = windowMinutes * 60;
      BuildEventList();
   }

   //──────────────────────────────────────────────────────────────────────────
   // IsNewsWindow – returns true when 'now' falls inside any blocked window.
   //──────────────────────────────────────────────────────────────────────────
   bool IsNewsWindow(const datetime now) const
   {
      // Fixed-date events
      for(int i = 0; i < m_fixedCount; i++)
      {
         long diff = (long)(now - m_fixedEvents[i]);
         if(diff < 0) diff = -diff;
         if(diff <= (long)m_windowSeconds)
            return true;
      }

      // Recurring weekly patterns
      MqlDateTime dt;
      TimeToStruct(now, dt);
      return IsInRecurringWindow(dt);
   }
};

#endif // __WECHUCK_NEWS_FILTER_MQH__

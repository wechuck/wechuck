#ifndef __WECHUCK_TYPES_MQH__
#define __WECHUCK_TYPES_MQH__

enum TradeDirection
{
   DIR_NONE = 0,
   DIR_BUY  = 1,
   DIR_SELL = -1
};

struct EntryScoreBreakdown
{
   int adx;
   int zscore;
   int stoch;
   int breakout;
   int volume;
   int total;
   string details;
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

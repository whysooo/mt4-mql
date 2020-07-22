/**
 * XMT-Scalper
 *
 * Based on the MillionDollarPips EA. Not much remains from the original, except the core idea of the strategy (tick scalping
 * based on a reversal from a channel breakout).
 */
#include <stddefines.mqh>
int   __INIT_FLAGS__[];
int __DEINIT_FLAGS__[];

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern string  Configuration              = "==== Configuration ====";
extern bool    ReverseTrade               = false; // ReverseTrade: If true, then trade in opposite direction
extern int     Magic                      = -1; // Magic: If set to a number less than 0 it will calculate MagicNumber automatically
extern string  OrderCmt                   = "XMT-Scalper 2.522"; // OrderCmt. Trade comments that appears in the Trade and Account History tab
extern bool    ECN_Mode                   = false; // ECN_Mode: true for brokers that don't accept SL and TP to be sent at the same time as the order
extern bool    Debug                      = false; // Debug: Print huge log files with info, only for debugging purposes
extern bool    Verbose                    = false; // Verbose: Additional log information printed in the Expert tab
extern string  TradingSettings            = "==== Trade settings ====";
extern int     TimeFrame                  = PERIOD_M1; // TimeFrame: Trading timeframe must matrch the timeframe of the chart
extern double  MaxSpread                  = 30.0; // MaxSprea: Max allowed spread in points (1 / 10 pip)
extern int     MaxExecution               = 0; // MaxExecution: Max allowed average execution time in ms (0 means no restrictions)
extern int     MaxExecutionMinutes        = 5; // MaxExecutionMinutes: How often in minutes should fake orders be sent to measure execution speed
extern double  StopLoss                   = 60; // StopLoss: SL from as many points. Default 60 (= 6 pips)
extern double  TakeProfit                 = 100; // TakeProfit: TP from as many points. Default 100 (= 10 pip)
extern double  AddPriceGap                = 0; // AddPriceGap: Additional price gap in points added to SL and TP in order to avoid Error 130
extern double  TrailingStart              = 20; // TrailingStart: Start trailing profit from as so many points.
extern double  Commission                 = 0; // Commission: Some broker accounts charge commission in USD per 1.0 lot. Commission in dollar per lot
extern int     Slippage                   = 3; // Slippage: Maximum allowed Slippage of price in points
extern double  MinimumUseStopLevel        = 0; // MinimumUseStopLevel: Stoplevel to use will be max value of either this value or broker stoplevel
extern string  VolatilitySettings         = "==== Volatility Settings ====";
extern bool    UseDynamicVolatilityLimit  = true; // UseDynamicVolatilityLimit: Calculated based on INT (spread * VolatilityMultiplier)
extern double  VolatilityMultiplier       = 125; // VolatilityMultiplier: A multiplier that only is used if UseDynamicVolatilityLimit is set to true
extern double  VolatilityLimit            = 180; // VolatilityLimit: A fix value that only is used if UseDynamicVolatilityLimit is set to false
extern bool    UseVolatilityPercentage    = true; // UseVolatilityPercentage: If true, then price must break out more than a specific percentage
extern double  VolatilityPercentageLimit  = 0; // VolatilityPercentageLimit: Percentage of how much iHigh-iLow difference must differ from VolatilityLimit.
extern string  UseIndicatorSet            = "=== Indicators: 1 = Moving Average, 2 = BollingerBand, 3 = Envelopes";
extern int     UseIndicatorSwitch         = 1; // UseIndicatorSwitch: Choose of indicator for price channel.
extern int     Indicatorperiod            = 3; // Indicatorperiod: Period in bars for indicator
extern double  BBDeviation                = 2.0; // BBDeviation: Deviation for the iBands indicator only
extern double  EnvelopesDeviation         = 0.07; // EnvelopesDeviation: Deviation for the iEnvelopes indicator only
extern int     OrderExpireSeconds         = 3600; // OrderExpireSeconds: Orders are deleted after so many seconds
extern string  Money_Management           = "==== Money Management ====";
extern bool    MoneyManagement            = true; // MoneyManagement: If true then calculate lotsize automaticallay based on Risk, if false then use ManualLotsize below
extern double  MinLots                    = 0.01; // MinLots: Minimum lot-size to trade with
extern double  MaxLots                    = 100.0; // MaxLots : Maximum allowed lot-size to trade with
extern double  Risk                       = 2.0; // Risk: Risk setting in percentage, For 10.000 in Equity 10% Risk and 60 StopLoss lotsize = 16.66
extern double  ManualLotsize              = 0.1; // ManualLotsize: Fix lot size to trade with if MoneyManagement above is set to false
extern double  MinMarginLevel             = 100; // MinMarginLevel: Lowest allowed Margin level for new positions to be opened
extern string  Screen_Shooter             = "==== Screen Shooter ====";
extern bool    TakeShots                  = false; // TakeShots: Save screen shots for each opened order
extern int     DelayTicks                 = 1; // DelayTicks: Delay so many ticks after new bar
extern int     ShotsPerBar                = 1; // ShotsPerBar: How many screen shots per bar
extern string  DisplayGraphics            = "=== Display Graphics ==="; // Colors for sub_Display at upper left
extern int     Heading_Size               = 13;  // Heading_Size: Font size for headline
extern int     Text_Size                  = 12;  // Text_Size: Font size for texts
extern color   Color_Heading              = Lime;   // Color for text lines
extern color   Color_Section1             = Yellow; // Color for text lines
extern color   Color_Section2             = Aqua;   // Color for text lines
extern color   Color_Section3             = Orange; // Color for text lines
extern color   Color_Section4             = Magenta;// Color for text lines

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#include <core/expert.mqh>
#include <stdfunctions.mqh>
#include <rsfLibs.mqh>

//--------------------------- Globals --------------------------------------------------------------

string EA_version = "XMT-Scalper v2.522";

datetime StartTime;        // Initial time
datetime LastTime;         // For measuring tics

int GlobalError = 0;       // To keep track on number of added errors
int TickCounter = 0;       // Counting tics
int UpTo30Counter = 0;     // For calculating average spread
int Execution = -1;        // For Execution speed, -1 means no speed
int Avg_execution = 0;     // Average Execution speed
int Execution_samples = 0; // For calculating average Execution speed
int Err_unchangedvalues;   // Error count for unchanged values (modify to the same values)
int Err_busyserver;        // Error count for busy server
int Err_lostconnection;    // Error count for lost connection
int Err_toomanyrequest;    // Error count for too many requests
int Err_invalidprice;      // Error count for invalid price
int Err_invalidstops;      // Error count for invalid SL and/or TP
int Err_invalidtradevolume;// Error count for invalid lot size
int Err_pricechange;       // Error count for change of price
int Err_brokerbuzy;        // Error count for broker is buzy
int Err_requotes;          // Error count for requotes
int Err_toomanyrequests;   // Error count for too many requests
int Err_trademodifydenied; // Error count for modify orders is denied
int Err_tradecontextbuzy;  // error count for trade context is buzy
int SkippedTicks = 0;      // Used for simulation of latency during backtests, how many tics that should be skipped
int Ticks_samples = 0;     // Used for simulation of latency during backtests, number of tick samples
int Tot_closed_pos;        // Number of closed positions for this EA
int Tot_Orders;            // Number of open orders disregarding of magic and pairs
int Tot_open_pos;          // Number of open positions for this EA

double LotBase;            // Amount of money in base currency for 1 lot
double Tot_open_profit;    // A summary of the current open profit/loss for this EA
double Tot_open_lots;      // A summary of the current open lots for this EA
double Tot_open_swap;      // A summary of the current charged swaps of the open positions for this EA
double Tot_open_commission;// A summary of the currebt charged commission of the open positions for this EA
double G_equity;           // Current equity for this EA
double Changedmargin;      // Free margin for this account
double Tot_closed_lots;    // A summary of the current closed lots for this EA
double Tot_closed_profit;  // A summary of the current closed profit/loss for this EA
double Tot_closed_swap;    // A summary of the current closed swaps for this EA
double Tot_closed_comm;    // A summary of the current closed commission for this EA
double G_balance = 0;      // Balance for this EA
double Array_spread[30];   // Store spreads for the last 30 tics
double LotSize;            // Lotsize
double highest;            // LotSize indicator value
double lowest;             // Lowest indicator value
double StopLevel;          // Broker StopLevel
double LotStep;            // Broker LotStep
double MarginForOneLot;    // Margin required for 1 lot
double Avg_tickspermin;    // Used for simulation of latency during backtests
double MarginFree;         // Free margin in percentage


/**
 * Initialization
 *
 * @return int - error status
 */
int onInit() {
   // If we don't run a backtest
   if (!IsTesting()) {
      // Check if timeframe of chart matches timeframe of external setting
      if (Period() != TimeFrame) {
         // The setting of timefram,e does not match the chart tiomeframe, so alert of this and exit
         return(catch("onInit(1)  The EA has been set to run on timeframe "+ TimeframeDescription(TimeFrame) +" but it has been attached to a chart with timeframe "+ TimeframeDescription(Period()) +".", ERR_RUNTIME_ERROR));
      }
   }

   // If we have any objects on the screen then clear the screen
   sub_DeleteDisplay();   // clear the chart

   // Reset time for Execution control
   StartTime = TimeLocal();

   // Reset error variable
   GlobalError = -1;

   // Calculate StopLevel as max of either STOPLEVEL or FREEZELEVEL
   StopLevel = MathMax ( MarketInfo ( Symbol(), MODE_FREEZELEVEL ), MarketInfo ( Symbol(), MODE_STOPLEVEL ) );
   // Then calculate the StopLevel as max of either this StopLevel or MinimumUseStopLevel
   StopLevel = MathMax ( MinimumUseStopLevel, StopLevel );

   // Calculate LotStep
   LotStep = MarketInfo ( Symbol(), MODE_LOTSTEP );

   // Check to confirm that indicator switch is valid choices, if not force to 1 (Moving Average)
   if ( UseIndicatorSwitch < 1 || UseIndicatorSwitch > 4 )
      UseIndicatorSwitch = 1;

   // If indicator switch is set to 4, using iATR, tben UseVolatilityPercentage cannot be used, so force it to false
   if ( UseIndicatorSwitch == 4 )
      UseVolatilityPercentage = false;

   // Adjust SL and TP to broker StopLevel if they are less than this StopLevel
   StopLoss = MathMax ( StopLoss, StopLevel );
   TakeProfit = MathMax ( TakeProfit, StopLevel );

   // Re-calculate variables
   VolatilityPercentageLimit = VolatilityPercentageLimit / 100 + 1;
   VolatilityMultiplier = VolatilityMultiplier / 10;
   ArrayInitialize ( Array_spread, 0 );
   VolatilityLimit = VolatilityLimit * Point;
   Commission = sub_normalizebrokerdigits ( Commission * Point );
   TrailingStart = TrailingStart * Point;
   StopLevel = StopLevel * Point;
   AddPriceGap = AddPriceGap * Point;

   // If we have set MaxLot and/or MinLots to more/less than what the broker allows, then adjust accordingly
   if ( MinLots < MarketInfo ( Symbol(), MODE_MINLOT ) )
      MinLots = MarketInfo ( Symbol(), MODE_MINLOT );
   if ( MaxLots > MarketInfo ( Symbol(), MODE_MAXLOT ) )
      MaxLots = MarketInfo ( Symbol(), MODE_MAXLOT );
   if ( MaxLots < MinLots )
      MaxLots = MinLots;

   // Fetch the margin required for 1 lot
   MarginForOneLot = MarketInfo ( Symbol(), MODE_MARGINREQUIRED );

   // Fetch the amount of money in base currency for 1 lot
   LotBase = MarketInfo ( Symbol(), MODE_LOTSIZE );

   // Also make sure that if the risk-percentage is too low or too high, that it's adjusted accordingly
   sub_recalculatewrongrisk();

   // Calculate intitial LotSize
   LotSize = sub_calculatelotsize();

   // If magic number is set to a value less than 0, then calculate MagicNumber automatically
   if ( Magic < 0 )
     Magic = sub_magicnumber();

   // If Execution speed should be measured, then adjust maxexecution from minutes to seconds
   if ( MaxExecution > 0 )
      MaxExecutionMinutes = MaxExecution * 60;

   // Check through all closed and open orders to get stats
   UpdateClosedOrderStats();
   sub_CheckThroughAllOpenOrders();

   // Show info in graphics
   sub_ShowGraphInfo();

   return(catch("onInit(2)"));
}


/**
 * Deinitialization
 *
 * @return int - error status
 */
int onDeinit() {
   string text = "";

   // Print summarize of broker errors
   sub_printsumofbrokererrors();

   // Delete all objects on the screen
   sub_DeleteDisplay();

   // Check through all closed orders
   UpdateClosedOrderStats();

   // If we're running as backtest, then print some result
   if (IsTesting()) {
      Print ( "Total closed lots = ", DoubleToStr ( Tot_closed_lots, 2 ) );
      Print ( "Total closed swap = ", DoubleToStr ( Tot_closed_swap, 2 ) );
      Print ( "Total closed commission = ", DoubleToStr ( Tot_closed_comm, 2 ) );

      // If we run backtests and simulate latency, then print result
      if ( MaxExecution > 0 )
      {
         text = text + "During backtesting " + SkippedTicks + " number of ticks was ";
         text = text + "skipped to simulate latency of up to " + MaxExecution + " ms";
         sub_printandcomment ( text );
      }
   }

   // Print short message when EA has been deinitialized
   Print ( EA_version, " has been deinitialized!" );

   // Print the uninitialization reason code
   Print ( "OnDeinit _Uninitalization reason code = ", UninitializeReason());
   //--- The second way to get the uninitialization reason code
   Print ( "OnDeinit _UninitReason = ", sub_UninitReasonText(UninitializeReason()) );

   return(catch("onDeinit(1)"));
}


/**
 * Main function
 *
 * @return int - error status
 */
int onTick() {
   // We must wait til we have enough of bar data before we call trading routine
   if ( iBars ( Symbol(), TimeFrame ) > Indicatorperiod )
   {
      // Call the actual main subroutine
      sub_trade();

      // Check through all closed and open orders to get stats to show on screen
      UpdateClosedOrderStats();
      sub_CheckThroughAllOpenOrders();
      sub_ShowGraphInfo();
   }
   // We have not yet enough of bar data, so print message
   else
      Print ( "Please wait until enough of bar data has been gathered!" );

   return(catch("onTick(1)"));
}


//================================ Subroutines (aka functions) starts here =========================================
// Notation:
// All actual and formal parameters in subs have their names starting with par_
// All local variables in subs have their names written in lower case


/**
 * Main trading subroutine
 */
void sub_trade() {
   string textstring;
   string pair;
   string indy;

   datetime orderexpiretime;

   bool select = false;
   bool wasordermodified = false;
   bool ordersenderror = false;
   bool isbidgreaterthanima = false;
   bool isbidgreaterthanibands = false;
   bool isbidgreaterthanenvelopes = false;
   bool isbidgreaterthanindy = false;

   int orderticket;
   int loopcount2;
   int loopcount1;
   int pricedirection;
   int counter1;
   int counter2;
   int askpart;
   int bidpart;

   double ask;
   double bid;
   double askplusdistance;
   double bidminusdistance;
   double volatilitypercentage = 0;
   double orderprice;
   double orderstoploss;
   double ordertakeprofit;
   double ihigh;
   double ilow;
   double imalow = 0;
   double imahigh = 0;
   double imadiff;
   double ibandsupper = 0;
   double ibandslower = 0;
   double ibandsdiff;
   double envelopesupper = 0;
   double envelopeslower = 0;
   double envelopesdiff;
   double volatility;
   double spread;
   double avgspread;
   double realavgspread;
   double fakeprice;
   double sumofspreads;
   double askpluscommission;
   double bidminuscommission;
   double skipticks;
   double am = 0.000000001;  // Set variable to a very small number
   double marginlevel;
   double tmpexecution;

   // Get the Free Margin
   MarginFree = AccountFreeMargin();

   // Calculate Margin level
   if ( AccountMargin() != 0 )
      am = AccountMargin();
   marginlevel = AccountEquity() / am * 100;

   // Free Margin is less than the value of MinMarginLevel, so no trading is allowed
   if ( marginlevel < MinMarginLevel )
   {
      Print ( "Warning! Free Margin " + DoubleToStr ( marginlevel, 2 ) + " is lower than MinMarginLevel!" );
      Alert ( "Warning! Free Margin " + DoubleToStr ( marginlevel, 2 ) + " is lower than MinMarginLevel!" );
      return;
   }

   // Previous time was less than current time, initiate tick counter
   if ( LastTime < Time[0] )
   {
      // For simulation of latency during backtests, consider only 10 samples at most.
      if ( Ticks_samples < 10 )
         Ticks_samples ++;
      Avg_tickspermin = Avg_tickspermin + ( TickCounter - Avg_tickspermin ) / Ticks_samples;
      // Set previopus time to current time and reset tick counter
      LastTime = Time[0];
      TickCounter = 0;
   }
   // Previous time was NOT less than current time, so increase tick counter with 1
   else
      TickCounter ++;

   // If backtesting and MaxExecution is set let's skip a proportional number of ticks them in order to
   // reproduce the effect of latency on this EA
   if ( IsTesting() && MaxExecution != 0 && Execution != -1 )
   {
      skipticks = MathRound ( Avg_tickspermin * MaxExecution / ( 60 * 1000 ) );
      if ( SkippedTicks >= skipticks )
      {
         Execution = -1;
         SkippedTicks = 0;
      }
      else
      {
         SkippedTicks ++;
      }
   }

   // Get Ask and Bid for the currency
   ask = MarketInfo ( Symbol(), MODE_ASK );
   bid = MarketInfo ( Symbol(), MODE_BID );

   // Calculate the channel of Volatility based on the difference of iHigh and iLow during current bar
   ihigh = iHigh ( Symbol(), TimeFrame, 0 );
   ilow = iLow ( Symbol(), TimeFrame, 0 );
   volatility = ihigh - ilow;

   // Reset printout string
   indy = "";

   // Calculate a channel on Moving Averages, and check if the price is outside of this channel.
   if ( UseIndicatorSwitch == 1 || UseIndicatorSwitch == 4 )
   {
      imalow = iMA ( Symbol(), TimeFrame, Indicatorperiod, 0, MODE_LWMA, PRICE_LOW, 0 );
      imahigh = iMA ( Symbol(), TimeFrame, Indicatorperiod, 0, MODE_LWMA, PRICE_HIGH, 0 );
      imadiff = imahigh - imalow;
      isbidgreaterthanima = bid >= imalow + imadiff / 2.0;
      indy = "iMA_low: " + sub_dbl2strbrokerdigits ( imalow ) + ", iMA_high: " + sub_dbl2strbrokerdigits ( imahigh ) + ", iMA_diff: " + sub_dbl2strbrokerdigits ( imadiff );
   }

   // Calculate a channel on BollingerBands, and check if the price is outside of this channel
   if ( UseIndicatorSwitch == 2 )
   {
      ibandsupper = iBands ( Symbol(), TimeFrame, Indicatorperiod, BBDeviation, 0, PRICE_OPEN, MODE_UPPER, 0 );
      ibandslower = iBands ( Symbol(), TimeFrame, Indicatorperiod, BBDeviation, 0, PRICE_OPEN, MODE_LOWER, 0 );
      ibandsdiff = ibandsupper - ibandslower;
      isbidgreaterthanibands = bid >= ibandslower + ibandsdiff / 2.0;
      indy = "iBands_upper: " + sub_dbl2strbrokerdigits ( ibandsupper ) + ", iBands_lower: " + sub_dbl2strbrokerdigits ( ibandslower ) + ", iBands_diff: " + sub_dbl2strbrokerdigits ( ibandsdiff );
   }

   // Calculate a channel on Envelopes, and check if the price is outside of this channel
   if ( UseIndicatorSwitch == 3 )
   {
      envelopesupper = iEnvelopes ( Symbol(), TimeFrame, Indicatorperiod, MODE_LWMA, 0, PRICE_OPEN, EnvelopesDeviation, MODE_UPPER, 0 );
      envelopeslower = iEnvelopes ( Symbol(), TimeFrame, Indicatorperiod, MODE_LWMA, 0, PRICE_OPEN, EnvelopesDeviation, MODE_LOWER, 0 );
      envelopesdiff = envelopesupper - envelopeslower;
      isbidgreaterthanenvelopes = bid >= envelopeslower + envelopesdiff / 2.0;
      indy = "iEnvelopes_upper: " + sub_dbl2strbrokerdigits ( envelopesupper ) + ", iEnvelopes_lower: " + sub_dbl2strbrokerdigits ( envelopeslower ) + ", iEnvelopes_diff: " + sub_dbl2strbrokerdigits ( envelopesdiff) ;
   }

   // Reset breakout variable as false
   isbidgreaterthanindy = false;

   // Reset pricedirection for no indication of trading direction
   pricedirection = 0;

   // If we're using iMA as indicator, then set variables from it
   if (UseIndicatorSwitch==1 && isbidgreaterthanima) {
      isbidgreaterthanindy = true;
      highest = imahigh;
      lowest = imalow;
   }

   // If we're using iBands as indicator, then set variables from it
   else if (UseIndicatorSwitch==2 && isbidgreaterthanibands) {
      isbidgreaterthanindy = true;
      highest = ibandsupper;
      lowest = ibandslower;
   }

   // If we're using iEnvelopes as indicator, then set variables from it
   else if (UseIndicatorSwitch==3 && isbidgreaterthanenvelopes) {
      isbidgreaterthanindy = true;
      highest = envelopesupper;
      lowest = envelopeslower;
   }

   // Calculate spread
   spread = ask - bid;

   // Calculate lot size
   LotSize = sub_calculatelotsize();

   // calculatwe orderexpiretime, but only if it is set to a value
   if ( OrderExpireSeconds != 0 )
      orderexpiretime = TimeCurrent() + OrderExpireSeconds;
   else
      orderexpiretime = 0;

   // Calculate average true spread, which is the average of the spread for the last 30 tics
   ArrayCopy ( Array_spread, Array_spread, 0, 1, 29 );
   Array_spread[29] = spread;
   if ( UpTo30Counter < 30 )
      UpTo30Counter ++;
   sumofspreads = 0;
   loopcount2 = 29;
   for ( loopcount1 = 0; loopcount1 < UpTo30Counter; loopcount1 ++ )
   {
      sumofspreads += Array_spread[loopcount2];
      loopcount2 --;
   }

   // Calculate an average of spreads based on the spread from the last 30 tics
   avgspread = sumofspreads / UpTo30Counter;

   // Calculate price and spread considering commission
   askpluscommission = sub_normalizebrokerdigits ( ask + Commission );
   bidminuscommission = sub_normalizebrokerdigits ( bid - Commission );
   realavgspread = avgspread + Commission;

   // Recalculate the VolatilityLimit if it's set to dynamic. It's based on the average of spreads multiplied with the VolatilityMulitplier constant
   if (UseDynamicVolatilityLimit)
      VolatilityLimit = realavgspread * VolatilityMultiplier;

   // If the variables below have values it means that we have enough of data from broker server.
   if ( volatility && VolatilityLimit && lowest && highest && UseIndicatorSwitch != 4 )
   {
      // We have a price breakout, as the Volatility is outside of the VolatilityLimit, so we can now open a trade
      if ( volatility > VolatilityLimit )
      {
         // Calculate how much it differs
         volatilitypercentage = volatility / VolatilityLimit;

         // In case of UseVolatilityPercentage then also check if it differ enough of percentage
         if (!UseVolatilityPercentage || (UseVolatilityPercentage && volatilitypercentage > VolatilityPercentageLimit)) {
            if ( bid < lowest )
            {
               if (!ReverseTrade)
                  pricedirection = -1; // BUY or BUYSTOP
               else // ReverseTrade
                  pricedirection = 1; // SELL or SELLSTOP
            }
            else if (bid > highest) {
               if (!ReverseTrade)
                  pricedirection = 1;  // SELL or SELLSTOP
               else // ReverseTrade
                  pricedirection = -1; // BUY or BUYSTOP
            }
         }
      }
      // The Volatility is less than the VolatilityLimit so we set the volatilitypercentage to zero
      else
         volatilitypercentage = 0;
   }

   // Check for out of money
   if ( AccountEquity() <= 0.0 )
   {
      Print ( "ERROR -- Account Equity is " + DoubleToStr ( MathRound ( AccountEquity() ), 0 ) );
      return;
   }

   // Reset Execution time
   Execution = -1;

   // Reset counters
   counter1 = 0;
   counter2 = 0;

   // Loop through all open orders (if any) to either modify them or delete them
   for ( loopcount2 = 0; loopcount2 < OrdersTotal(); loopcount2 ++ )
   {
      // Select an order from the open orders
      select = OrderSelect ( loopcount2, SELECT_BY_POS, MODE_TRADES );
      // We've found an that matches the magic number and is open
      if ( OrderMagicNumber() == Magic && OrderCloseTime() == 0 )
      {
         // If the order doesn't match the currency pair from the chart then check next open order
         if ( OrderSymbol() != Symbol() )
         {
            // Increase counter
            counter2 ++;
            continue;
         }
         // Select order by type of order
         switch ( OrderType() )
         {
         // We've found a matching BUY-order
         case OP_BUY:
            // Start endless loop
            while (true) {
               // Update prices from the broker
               RefreshRates();
               // Set SL and TP
               orderstoploss = OrderStopLoss();
               ordertakeprofit = OrderTakeProfit();
               // Ok to modify the order if its TP is less than the price+commission+StopLevel AND price+StopLevel-TP greater than trailingStart
               if ( ordertakeprofit < sub_normalizebrokerdigits ( askpluscommission + TakeProfit * Point + AddPriceGap ) && askpluscommission + TakeProfit * Point + AddPriceGap - ordertakeprofit > TrailingStart )
               {
                  // Set SL and TP
                  orderstoploss = sub_normalizebrokerdigits ( bid - StopLoss * Point - AddPriceGap );
                  ordertakeprofit = sub_normalizebrokerdigits ( askpluscommission + TakeProfit * Point + AddPriceGap );
                  // Send an OrderModify command with adjusted SL and TP
                  if ( orderstoploss != OrderStopLoss() && ordertakeprofit != OrderTakeProfit() )
                  {
                     // Start Execution timer
                     Execution = GetTickCount();
                     // Try to modify order
                     wasordermodified = OrderModify ( OrderTicket(), 0, orderstoploss, ordertakeprofit, orderexpiretime, Lime );
                  }
                  // Order was modified with new SL and TP
                  if (wasordermodified) {
                     // Calculate Execution speed
                     Execution = GetTickCount() - Execution;
                     // If we have choosen to take snapshots and we're not backtesting, then do so
                     if ( TakeShots && !IsTesting() )
                        sub_takesnapshot();
                     // Break out from while-loop since the order now has been modified
                     break;
                  }
                  // Order was not modified
                  else
                  {
                     // Reset Execution counter
                     Execution = -1;
                     // Add to errors
                     sub_errormessages();
                     // Print if debug or verbose
                     if ( Debug || Verbose )
                        Print ( "Order could not be modified because of ", ErrorDescription ( GetLastError() ) );
                     // Order has not been modified and it has no StopLoss
                     if ( orderstoploss == 0 )
                     // Try to modify order with a safe hard SL that is 3 pip from current price
                        wasordermodified = OrderModify ( OrderTicket(), 0, NormalizeDouble ( Bid - 30, Digits ), 0, 0, Red );
                  }
               }
               // Break out from while-loop since the order now has been modified
               break;
            }
            // count 1 more up
            counter1 ++;
            // Break out from switch
            break;

         // We've found a matching SELL-order
         case OP_SELL:
            // Start endless loop
            while (true) {
               // Update broker prices
               RefreshRates();
               // Set SL and TP
               orderstoploss = OrderStopLoss();
               ordertakeprofit = OrderTakeProfit();
               // Ok to modify the order if its TP is greater than price-commission-StopLevel AND TP-price-commission+StopLevel is greater than trailingstart
               if ( ordertakeprofit > sub_normalizebrokerdigits ( bidminuscommission - TakeProfit * Point - AddPriceGap ) && ordertakeprofit - bidminuscommission + TakeProfit * Point - AddPriceGap > TrailingStart )
               {
                  // set SL and TP
                  orderstoploss = sub_normalizebrokerdigits ( ask + StopLoss * Point + AddPriceGap );
                  ordertakeprofit = sub_normalizebrokerdigits ( bidminuscommission - TakeProfit * Point - AddPriceGap );
                  // Send an OrderModify command with adjusted SL and TP
                  if ( orderstoploss != OrderStopLoss() && ordertakeprofit != OrderTakeProfit() )
                  {
                     // Start Execution timer
                     Execution = GetTickCount();
                     wasordermodified = OrderModify ( OrderTicket(), 0, orderstoploss, ordertakeprofit, orderexpiretime, Orange );
                  }
                  // Order was modiified with new SL and TP
                  if (wasordermodified) {
                     // Calculate Execution speed
                     Execution = GetTickCount() - Execution;
                     // If we have choosen to take snapshots and we're not backtesting, then do so
                     if ( TakeShots && !IsTesting() )
                        sub_takesnapshot();
                     // Break out from while-loop since the order now has been modified
                     break;
                  }
                  // Order was not modified
                  else
                  {
                     // Reset Execution counter
                     Execution = -1;
                     // Add to errors
                     sub_errormessages();
                     // Print if debug or verbose
                     if ( Debug || Verbose )
                        Print ( "Order could not be modified because of ", ErrorDescription ( GetLastError() ) );
                     // Lets wait 1 second before we try to modify the order again
                     Sleep ( 1000 );
                     // Order has not been modified and it has no StopLoss
                     if ( orderstoploss == 0 )
                     // Try to modify order with a safe hard SL that is 3 pip from current price
                        wasordermodified = OrderModify ( OrderTicket(), 0, NormalizeDouble ( Ask + 30, Digits), 0, 0, Red );
                  }
               }
               // Break out from while-loop since the order now has been modified
               break;
            }
            // count 1 more up
            counter1 ++;
            // Break out from switch
            break;

         // We've found a matching BUYSTOP-order
         case OP_BUYSTOP:
            // Price must NOT be larger than indicator in order to modify the order, otherwise the order will be deleted
            if (!isbidgreaterthanindy) {
               // Calculate how much Price, SL and TP should be modified
               orderprice = sub_normalizebrokerdigits ( ask + StopLevel + AddPriceGap );
               orderstoploss = sub_normalizebrokerdigits ( orderprice - spread - StopLoss * Point - AddPriceGap );
               ordertakeprofit = sub_normalizebrokerdigits ( orderprice + Commission + TakeProfit * Point + AddPriceGap );
               // Start endless loop
               while (true) {
                  // Ok to modify the order if price+StopLevel is less than orderprice AND orderprice-price-StopLevel is greater than trailingstart
                  if ( orderprice < OrderOpenPrice() && OrderOpenPrice() - orderprice > TrailingStart )
                  {

                     // Send an OrderModify command with adjusted Price, SL and TP
                     if ( orderstoploss != OrderStopLoss() && ordertakeprofit != OrderTakeProfit() )
                     {
                        RefreshRates();
                        // Start Execution timer
                        Execution = GetTickCount();
                        wasordermodified = OrderModify ( OrderTicket(), orderprice, orderstoploss, ordertakeprofit, 0, Lime );
                     }
                     // Order was modified
                     if (wasordermodified) {
                        // Calculate Execution speed
                        Execution = GetTickCount() - Execution;
                        // Print if debug or verbose
                        if ( Debug || Verbose )
                           Print ( "Order executed in " + Execution + " ms" );
                     }
                     // Order was not modified
                     else
                     {
                        // Reset Execution counter
                        Execution = -1;
                        // Add to errors
                        sub_errormessages();
                     }
                  }
                  // Break out from endless loop
                  break;
               }
               // Increase counter
               counter1 ++;
            }
            // Price was larger than the indicator
            else
               // Delete the order
               select = OrderDelete ( OrderTicket() );
            // Break out from switch
            break;

         // We've found a matching SELLSTOP-order
         case OP_SELLSTOP:
            // Price must be larger than the indicator in order to modify the order, otherwise the order will be deleted
            if (isbidgreaterthanindy) {
               // Calculate how much Price, SL and TP should be modified
               orderprice = sub_normalizebrokerdigits ( bid - StopLevel - AddPriceGap );
               orderstoploss = sub_normalizebrokerdigits ( orderprice + spread + StopLoss * Point + AddPriceGap );
               ordertakeprofit = sub_normalizebrokerdigits ( orderprice - Commission - TakeProfit * Point - AddPriceGap );
               // Endless loop
               while (true) {
                  // Ok to modify order if price-StopLevel is greater than orderprice AND price-StopLevel-orderprice is greater than trailingstart
                  if ( orderprice > OrderOpenPrice() && orderprice - OrderOpenPrice() > TrailingStart)
                  {
                     // Send an OrderModify command with adjusted Price, SL and TP
                     if ( orderstoploss != OrderStopLoss() && ordertakeprofit != OrderTakeProfit() )
                     {
                        RefreshRates();
                        // Start Execution counter
                        Execution = GetTickCount();
                        wasordermodified = OrderModify ( OrderTicket(), orderprice, orderstoploss, ordertakeprofit, 0, Orange );
                     }
                     // Order was modified
                     if (wasordermodified) {
                        // Calculate Execution speed
                        Execution = GetTickCount() - Execution;
                        // Print if debug or verbose
                        if ( Debug || Verbose )
                           Print ( "Order executed in " + Execution + " ms" );
                     }
                     // Order was not modified
                     else
                     {
                        // Reset Execution counter
                        Execution = -1;
                        // Add to errors
                        sub_errormessages();
                     }
                  }
                  // Break out from endless loop
                  break;
               }
               // count 1 more up
               counter1 ++;
            }
            // Price was NOT larger than the indicator, so delete the order
            else
               select = OrderDelete ( OrderTicket() );
         } // end of switch
      }  // end if OrderMagicNumber
   } // end for loopcount2 - end of loop through open orders

   // Calculate and keep track on global error number
   if ( GlobalError >= 0 || GlobalError == -2 )
   {
      bidpart = NormalizeDouble ( bid / Point, 0 );
      askpart = NormalizeDouble ( ask / Point, 0 );
      if ( bidpart % 10 != 0 || askpart % 10 != 0 )
         GlobalError = -1;
      else
      {
         if ( GlobalError >= 0 && GlobalError < 10 )
            GlobalError ++;
         else
            GlobalError = -2;
      }
   }

   // Reset error-variable
   ordersenderror = false;

   // Before executing new orders, lets check the average Execution time.
   if ( pricedirection != 0 && MaxExecution > 0 && Avg_execution > MaxExecution )
   {
      pricedirection = 0; // Ignore the order opening triger
      if ( Debug || Verbose )
         Print ( "Server is too Slow. Average Execution: " + Avg_execution );
   }

   // Set default price adjustment
   askplusdistance = ask + StopLevel;
   bidminusdistance = bid - StopLevel;

   // If we have no open orders AND a price breakout AND average spread is less or equal to max allowed spread AND we have no errors THEN proceed
   if ( counter1 == 0 && pricedirection != 0 && sub_normalizebrokerdigits ( realavgspread) <= sub_normalizebrokerdigits ( MaxSpread * Point ) && GlobalError == -1 )
   {
      // If we have a price breakout downwards (Bearish) then send a BUYSTOP order
      if ( pricedirection == -1 || pricedirection == 2 ) // Send a BUYSTOP
      {
         // Calculate a new price to use
         orderprice = ask + StopLevel;
         // SL and TP is not sent with order, but added afterwords in a OrderModify command
         if (ECN_Mode) {
            // Set prices for OrderModify of BUYSTOP order
            orderprice = askplusdistance;
            orderstoploss =  0;
            ordertakeprofit = 0;
            // Start Execution counter
            Execution = GetTickCount();
            // Send a BUYSTOP order without SL and TP
            orderticket = OrderSend ( Symbol(), OP_BUYSTOP, LotSize, orderprice, Slippage, orderstoploss, ordertakeprofit, OrderCmt, Magic, 0, Lime );
            // OrderSend was executed successfully
            if ( orderticket > 0 )
            {
               // Calculate Execution speed
               Execution = GetTickCount() - Execution;
               if ( Debug || Verbose )
                  Print ( "Order executed in " + Execution + " ms" );
               // If we have choosen to take snapshots and we're not backtesting, then do so
               if ( TakeShots && !IsTesting() )
                  sub_takesnapshot();
            }  // end if ordersend
            // OrderSend was NOT executed
            else
            {
               ordersenderror = true;
               Execution = -1;
               // Add to errors
               sub_errormessages();
            }
            // OrderSend was executed successfully, so now modify it with SL and TP
            if ( OrderSelect ( orderticket, SELECT_BY_TICKET ) )
            {
               RefreshRates();
               // Set prices for OrderModify of BUYSTOP order
               orderprice = OrderOpenPrice();
               orderstoploss =  sub_normalizebrokerdigits ( orderprice - spread - StopLoss * Point - AddPriceGap );
               ordertakeprofit = sub_normalizebrokerdigits ( orderprice + TakeProfit * Point + AddPriceGap );
               // Start Execution timer
               Execution = GetTickCount();
               // Send a modify order for BUYSTOP order with new SL and TP
               wasordermodified = OrderModify ( OrderTicket(), orderprice, orderstoploss, ordertakeprofit, orderexpiretime, Lime );
               // OrderModify was executed successfully
               if (wasordermodified) {
                  // Calculate Execution speed
                  Execution = GetTickCount() - Execution;
                  if ( Debug || Verbose )
                     Print ( "Order executed in " + Execution + " ms" );
                  // If we have choosen to take snapshots and we're not backtesting, then do so
                  if ( TakeShots && !IsTesting() )
                     sub_takesnapshot();
               } // end successful ordermodiify
               // Order was NOT modified
               else
               {
                  ordersenderror = true;
                  Execution = -1;
                  // Add to errors
                  sub_errormessages();
               } // end if-else
            }  // end if ordermodify
         } // end if ECN_Mode

         // No ECN-mode, SL and TP can be sent directly
         else
         {
            RefreshRates();
            // Set prices for BUYSTOP order
            orderprice = askplusdistance;//ask+StopLevel
            orderstoploss =  sub_normalizebrokerdigits ( orderprice - spread - StopLoss * Point - AddPriceGap );
            ordertakeprofit = sub_normalizebrokerdigits ( orderprice + TakeProfit * Point + AddPriceGap );
            // Start Execution counter
            Execution = GetTickCount();
            // Send a BUYSTOP order with SL and TP
            orderticket = OrderSend ( Symbol(), OP_BUYSTOP, LotSize, orderprice, Slippage, orderstoploss, ordertakeprofit, OrderCmt, Magic, orderexpiretime, Lime );
            if ( orderticket > 0 ) // OrderSend was executed suxxessfully
            {
               // Calculate Execution speed
               Execution = GetTickCount() - Execution;
               if ( Debug || Verbose )
                  Print ( "Order executed in " + Execution + " ms" );
               // If we have choosen to take snapshots and we're not backtesting, then do so
               if ( TakeShots && !IsTesting() )
                  sub_takesnapshot();
            } // end successful ordersend
            // Order was NOT sent
            else
            {
               ordersenderror = true;
               // Reset Execution timer
               Execution = -1;
               // Add to errors
               sub_errormessages();
            } // end if-else
         } // end no ECN-mode
      } // end if pricedirection == -1 or 2

      // If we have a price breakout upwards (Bullish) then send a SELLSTOP order
      if ( pricedirection == 1 || pricedirection == 2 )
      {
         // Set prices for SELLSTOP order with zero SL and TP
         orderprice = bidminusdistance;
         orderstoploss = 0;
         ordertakeprofit = 0;
         // SL and TP cannot be sent with order, but must be sent afterwords in a modify command
         if (ECN_Mode)
         {
            // Start Execution timer
            Execution = GetTickCount();
            // Send a SELLSTOP order without SL and TP
            orderticket = OrderSend ( Symbol(), OP_SELLSTOP, LotSize, orderprice, Slippage, orderstoploss, ordertakeprofit, OrderCmt, Magic, 0, Orange );
            // OrderSend was executed successfully
            if ( orderticket > 0 )
            {
               // Calculate Execution speed
               Execution = GetTickCount() - Execution;
               if ( Debug || Verbose )
                  Print ( "Order executed in " + Execution + " ms" );
               // If we have choosen to take snapshots and we're not backtesting, then do so
               if ( TakeShots && !IsTesting() )
                  sub_takesnapshot();
            }  // end if ordersend
            // OrderSend was NOT executed
            else
            {
               ordersenderror = true;
               Execution = -1;
               // Add to errors
               sub_errormessages();
            }
            // If the SELLSTOP order was executed successfully, then select that order
            if ( OrderSelect(orderticket, SELECT_BY_TICKET ) )
            {
               RefreshRates();
               // Set prices for SELLSTOP order with modified SL and TP
               orderprice = OrderOpenPrice();
               orderstoploss = sub_normalizebrokerdigits ( orderprice + spread + StopLoss * Point + AddPriceGap );
               ordertakeprofit = sub_normalizebrokerdigits ( orderprice - TakeProfit * Point - AddPriceGap );
               // Start Execution timer
               Execution = GetTickCount();
               // Send a modify order with adjusted SL and TP
               wasordermodified = OrderModify ( OrderTicket(), OrderOpenPrice(), orderstoploss, ordertakeprofit, orderexpiretime, Orange );
            }
            // OrderModify was executed successfully
            if (wasordermodified) {
               // Calculate Execution speed
               Execution = GetTickCount() - Execution;
               // Print debug info
               if ( Debug || Verbose )
                  Print ( "Order executed in " + Execution + " ms" );
               // If we have choosen to take snapshots and we're not backtesting, then do so
               if ( TakeShots && !IsTesting() )
                  sub_takesnapshot();
            } // end if ordermodify was executed successfully
            // Order was NOT executed
            else
            {
               ordersenderror = true;
               // Reset Execution timer
               Execution = -1;
               // Add to errors
               sub_errormessages();
            }
         }
         else // No ECN-mode, SL and TP can be sent directly
         {
            RefreshRates();
            // Set prices for SELLSTOP order with SL and TP
            orderprice = bidminusdistance;
            orderstoploss = sub_normalizebrokerdigits ( orderprice + spread + StopLoss * Point + AddPriceGap );
            ordertakeprofit = sub_normalizebrokerdigits ( orderprice - TakeProfit * Point - AddPriceGap );
            // Start Execution timer
            Execution = GetTickCount();
            // Send a SELLSTOP order with SL and TP
            orderticket = OrderSend ( Symbol(), OP_SELLSTOP, LotSize, orderprice, Slippage, orderstoploss, ordertakeprofit, OrderCmt, Magic, orderexpiretime, Orange );
            // If OrderSend was executed successfully
            if ( orderticket > 0 )
            {
               // Calculate exection speed for that order
               Execution = GetTickCount() - Execution;
               // Print debug info
               if ( Debug || Verbose )
                  Print ( "Order executed in " + Execution + " ms" );
               if ( TakeShots && !IsTesting() )
                  sub_takesnapshot();
            } // end successful ordersend
            // OrderSend was NOT executed successfully
            else
            {
               ordersenderror = true;
               // Nullify Execution timer
               Execution = 0;
               // Add to errors
               sub_errormessages();
            } // end if-else
         } // end no ECN-mode
      } // end pricedirection == 0 or 2
   } // end if execute new orders

   // If we have no samples, every MaxExecutionMinutes a new OrderModify Execution test is done
   if ( MaxExecution && Execution == -1 && ( TimeLocal() - StartTime ) % MaxExecutionMinutes == 0 )
   {
      // When backtesting, simulate random Execution time based on the setting
      if ( IsTesting() && MaxExecution )
      {
         MathSrand ( TimeLocal( ));
         Execution = MathRand() / ( 32767 / MaxExecution );
      }
      else
      {
         // Unless backtesting, lets send a fake order to check the OrderModify Execution time,
         if (!IsTesting()) {
            // To be sure that the fake order never is executed, st the price to twice the current price
            fakeprice = ask * 2.0;
            // Send a BUYSTOP order
            orderticket = OrderSend ( Symbol(), OP_BUYSTOP, LotSize, fakeprice, Slippage, 0, 0, OrderCmt, Magic, 0, Lime );
            Execution = GetTickCount();
            // Send a modify command where we adjust the price with +1 pip
            wasordermodified = OrderModify ( orderticket, fakeprice + 10 * Point, 0, 0, 0, Lime );
            // Calculate Execution speed
            Execution = GetTickCount() - Execution;
            // Delete the order
            select = OrderDelete(orderticket);
         }
      }
   }

   // Do we have a valid Execution sample? Update the average Execution time.
   if ( Execution >= 0 )
   {
      // Consider only 10 samples at most.
      if ( Execution_samples < 10 )
         Execution_samples ++;
      // Calculate average Execution speed
      Avg_execution = Avg_execution + ( Execution - Avg_execution ) / Execution_samples;
   }

   // Check initialization
   if ( GlobalError >= 0 )
      Print ( "Robot is initializing..." );
   else
   {
      // Error
      if ( GlobalError == -2 )
         Print ( "ERROR -- Instrument " + Symbol() + " prices should have " + Digits + " fraction digits on broker account" );
      // No errors, ready to print
      else
      {
         textstring = TimeToStr ( TimeCurrent() ) + " Tick: " + sub_adjust00instring ( TickCounter );
         // Only show / print this if Debug OR Verbose are set to true
         if ( Debug || Verbose )
         {
            // In case Execution is -1 (not yet calculate dvalue, set it to 0 for printing
            tmpexecution = Execution;
            if ( Execution == -1 )
               tmpexecution = 0;
            // Prepare text string for printing
            textstring = textstring + "\n*** DEBUG MODE *** \nCurrency pair: " + Symbol() + ", Volatility: " + sub_dbl2strbrokerdigits ( volatility )
            + ", VolatilityLimit: " + sub_dbl2strbrokerdigits ( VolatilityLimit ) + ", VolatilityPercentage: " + sub_dbl2strbrokerdigits ( volatilitypercentage );
            textstring = textstring + "\nPriceDirection: " + StringSubstr ( "BUY NULLSELLBOTH", 4 * pricedirection + 4, 4 ) +  ", Expire: "
            + TimeToStr ( orderexpiretime, TIME_MINUTES ) + ", Open orders: " + counter1;
            textstring = textstring + "\nBid: " + sub_dbl2strbrokerdigits ( bid ) + ", Ask: " + sub_dbl2strbrokerdigits ( ask ) + ", " + indy;
            textstring = textstring + "\nAvgSpread: " + sub_dbl2strbrokerdigits ( avgspread ) + ", RealAvgSpread: " + sub_dbl2strbrokerdigits ( realavgspread )
            + ", Commission: " + sub_dbl2strbrokerdigits ( Commission ) + ", Lots: " + DoubleToStr ( LotSize, 2 ) + ", Execution: " + tmpexecution + " ms";
            if ( sub_normalizebrokerdigits ( realavgspread ) > sub_normalizebrokerdigits ( MaxSpread * Point ) )
            {
               textstring = textstring + "\n" + "The current spread (" + sub_dbl2strbrokerdigits ( realavgspread )
               +") is higher than what has been set as MaxSpread (" + sub_dbl2strbrokerdigits ( MaxSpread * Point ) + ") so no trading is allowed right now on this currency pair!";
            }
            if ( MaxExecution > 0 && Avg_execution > MaxExecution )
            {
               textstring = textstring + "\n" + "The current Avg Execution (" + Avg_execution +") is higher than what has been set as MaxExecution ("
               + MaxExecution+ " ms), so no trading is allowed right now on this currency pair!";
            }
            Print ( textstring );
            // Only print this if we have a any orders  OR have a price breakout OR Verbode mode is set to true
            if ( counter1 != 0 || pricedirection != 0 )
               sub_printformattedstring ( textstring );
         }
      } // end if-else
   } // end check initialization

   // Check for stray market orders without SL
   sub_Check4StrayTrades();
}


/**
 * Check for stray trades
 */
void sub_Check4StrayTrades() {
   // Initiate some local variables
   int loop;
   int totals;
   bool modified = true;
   bool selected;
   double ordersl;
   double newsl;

   // New SL to use for modifying stray market orders is max of either current SL or 10 points
   newsl = MathMax ( StopLoss, 10 );
   // Get number of open orders
   totals = OrdersTotal();

   // Loop through all open orders from first to last
   for ( loop = 0; loop < totals; loop ++ )
   {
      // Select on order
      if ( OrderSelect ( loop, SELECT_BY_POS, MODE_TRADES ) )
      {
         // Check if it matches the MagicNumber and chart symbol
         if ( OrderMagicNumber() == Magic && OrderSymbol() == Symbol() )    // If the orders are for this EA
         {
            ordersl = OrderStopLoss();
            // Continue as long as the SL for the order is 0.0
            while ( ordersl == 0.0 )
            {
               // We have found a Buy-order
               if ( OrderType() == OP_BUY )
               {
                  // Set new SL 10 points away from current price
                  newsl = Bid - newsl * Point;
                  modified = OrderModify ( OrderTicket(), OrderOpenPrice(), NormalizeDouble ( newsl, Digits ), OrderTakeProfit(), 0, Blue );
               }
               // We have found a Sell-order
               else if ( OrderType() == OP_SELL )
               {
                  // Set new SL 10 points away from current price
                  newsl = Ask + newsl * Point;
                  modified = OrderModify ( OrderTicket(), OrderOpenPrice(), NormalizeDouble ( newsl, Digits ), OrderTakeProfit(), 0, Blue );
               }
               // If the order without previous SL was modified wit a new SL
               if (modified) {
                  // Select that modified order, set while condition variable to that true value and exit while-loop
                  selected = OrderSelect ( modified, SELECT_BY_TICKET, MODE_TRADES );
                  ordersl = OrderStopLoss();
                  break;
               }
               // If the order could not be modified
               else // if (!modified)
               {
                  // Wait 1/10 second and then fetch new prices
                  Sleep ( 100 );
                  RefreshRates();
                  // Print debug info
                  if ( Debug || Verbose )
                     Print ( "Error trying to modify stray order with a SL!" );
                  // Add to errors
                  sub_errormessages();
               }
            }
         }
      }
   }
}


/**
 * Convert a decimal number to a text string
 */
string sub_dbl2strbrokerdigits ( double par_a ) {
   return ( DoubleToStr ( par_a, Digits ) );
}


/**
 * Adjust numbers with as many decimals as the broker uses
 */
double sub_normalizebrokerdigits ( double par_a ) {
   return ( NormalizeDouble ( par_a, Digits ) );
}


/**
 * Adjust textstring with zeros at the end
 */
string sub_adjust00instring ( int par_a ) {
   if ( par_a < 10 )
      return ( "00" + par_a );
   if ( par_a < 100 )
      return ( "0" + par_a );
   return ( "" + par_a );
}


/**
 * Print out formatted textstring
 */
void sub_printformattedstring ( string par_a ) {
   // Initiate some local variables
   int difference;
   int a = -1;

   // Loop through the text string from left to right to find a newline
   while ( a < StringLen ( par_a ) )
   {
      difference = a + 1;
      a = StringFind ( par_a, "\n", difference );
      if ( a == -1 )
      {
         Print ( StringSubstr ( par_a, difference ) );
         return;
      }
      // Print out the formatted text string, line for line
      Print ( StringSubstr ( par_a, difference, a - difference ) );
   }
}


/**
 * Calculate lot multiplicator for Account Currency. Assumes that account currency is any of the 8 majors.
 * If the account currency is of any other currency, then calculate the multiplicator as follows:
 * If base-currency is USD then use the BID-price for the currency pair USDXXX; or if the
 * counter currency is USD the use 1 / BID-price for the currency pair XXXUSD,
 * where XXX is the abbreviation for the account currency. The calculated lot-size should
 * then be multiplied with this multiplicator.
 */
double sub_multiplicator() {
   // Initiate some local variables
   double marketbid = 0;
   double multiplicator = 1.0;
   int length;
   string appendix = "";

   // If the account currency is USD
   if ( AccountCurrency() == "USD" )
      return ( multiplicator );
   length = StringLen ( Symbol() );
   if ( length != 6 )
      appendix = StringSubstr ( Symbol(), 6, length - 6 );

   // If the account currency is EUR
   if ( AccountCurrency() == "EUR" )
   {
      marketbid = MarketInfo ( "EURUSD" + appendix, MODE_BID );
      if ( marketbid != 0 )
         multiplicator = 1.0 / marketbid;
      else
      {
         Print ( "WARNING! Unable to fetch the market Bid price for " + AccountCurrency() + ", will use the static value 1.0 instead!" );
         multiplicator = 1.0;
      }
   }

   // If the account currency is GBP
   if ( AccountCurrency() == "GBP" )
   {
      marketbid = MarketInfo ( "GBPUSD" + appendix, MODE_BID );
      if ( marketbid != 0 )
         multiplicator = 1.0 / marketbid;
      else
      {
         Print ( "WARNING! Unable to fetch the market Bid price for " + AccountCurrency() + ", will use the static value 1.5 instead!" );
         multiplicator = 1.5;
      }
   }

   // If the account currenmmcy is AUD
   if ( AccountCurrency() == "AUD" )
   {
      marketbid = MarketInfo ( "AUDUSD" + appendix, MODE_BID );
      if ( marketbid != 0 )
         multiplicator = 1.0 / marketbid;
      else
      {
         Print ( "WARNING! Unable to fetch the market Bid price for " + AccountCurrency() + ", will use the static value 0.7 instead!" );
         multiplicator = 0.7;
      }
   }

   // If the account currency is NZD
   if ( AccountCurrency() == "NZD" )
   {
      marketbid = MarketInfo ( "NZDUSD" + appendix, MODE_BID );
      if ( marketbid != 0 )
         multiplicator = 1.0 / marketbid;
      else
      {
         Print ( "WARNING! Unable to fetch the market Bid price for " + AccountCurrency() + ", will use the static value 0.65 instead!" );
         multiplicator = 0.65;
      }
   }

   // If the account currency is CHF
   if ( AccountCurrency() == "CHF" )
   {
      marketbid = MarketInfo ( "USDCHF" + appendix, MODE_BID );
      if ( marketbid != 0 )
         multiplicator = 1.0 / marketbid;
      else
      {
         Print ( "WARNING! Unable to fetch the market Bid price for " + AccountCurrency() + ", will use the static value 1.0 instead!" );
         multiplicator = 1.0;
      }
   }

   // If the account currenmmcy is JPY
   if ( AccountCurrency() == "JPY" )
   {
      marketbid = MarketInfo ( "USDJPY" + appendix, MODE_BID );
      if ( marketbid != 0 )
         multiplicator = 1.0 / marketbid;
      else
      {
         Print ( "WARNING! Unable to fetch the market Bid price for " + AccountCurrency() + ", will use the static value 120 instead!" );
         multiplicator = 120;
      }
   }

   // If the account currenmcy is CAD
   if ( AccountCurrency() == "CAD" )
   {
      marketbid = MarketInfo ( "USDCAD" + appendix, MODE_BID );
      if ( marketbid != 0 )
         multiplicator = 1.0 / marketbid;
      else
      {
         Print ( "WARNING! Unable to fetch the market Bid price for " + AccountCurrency() + ", will use the static value 1.3 instead!" );
         multiplicator = 1.3;
      }
   }

   // If account currency is neither of EUR, GBP, AUD, NZD, CHF, JPY or CAD we assumes that it is USD
   if ( multiplicator == 0 )
      multiplicator = 1.0;

   // Return the calculated multiplicator value for the account currency
   return ( multiplicator );
}


/**
 * Magic Number - calculated from a sum of account number + ASCII-codes from currency pair
 */
int sub_magicnumber () {
   // Initiate some local variables
   string a;
   string b;
   int c;
   int d;
   int i;
   string par = "EURUSDJPYCHFCADAUDNZDGBP";
   string sym = Symbol();

   a = StringSubstr ( sym, 0, 3 );
   b = StringSubstr ( sym, 3, 3 );
   c = StringFind ( par, a, 0 );
   d = StringFind ( par, b, 0 );
   i = 999999999 - AccountNumber() - c - d;
   if (Debug)
      Print ( "MagicNumber: ", i );
   return ( i );
}


/**
 * Main routine for making a screenshoot / printscreen
 */
void sub_takesnapshot() {
   // Initiate some local variables
   static datetime lastbar;
   static int doshot = -1;
   static int oldphase = 3000000;
   int shotinterval;
   int phase;

   // If more than 0 screen shot should be taken per bar
   if ( ShotsPerBar > 0 )
      shotinterval = MathRound ( ( 60 * Period() ) / ShotsPerBar );
   // Only one screen shot should be taken
   else
      shotinterval = 60 * Period();
   phase = MathFloor ( ( CurTime() - Time[0] ) / shotinterval );

   // Check to see that one bar has passed by
   if ( Time[0] != lastbar )
   {
      lastbar = Time[0];
      doshot = DelayTicks;
   }
   // No new bar has passed by, so check if enough of time has passed by within this bar
   else if ( phase > oldphase )
      sub_makescreenshot ( "i" );

   // Reset varioable
   oldphase = phase;

   // If no screen shot has been taken then do it now
   if ( doshot == 0 )
      sub_makescreenshot ( "" );
   // A screen shot has already been taken, so decrease counter
   if ( doshot >= 0 )
      doshot -= 1;
}


/**
 * Make a screenshoot / printscreen
 */
void sub_makescreenshot ( string par_sx = "" ) {
   // Initate a local variables
   static int no = 0;
   string fn;

   // Increase counter
   no ++;
   // Prepare textstring as filename to be saved
   fn = "SnapShot" + Symbol() + Period() + "\\" + Year() + "-" + sub_maketimestring ( Month(), 2 )
   + "-" + sub_maketimestring ( Day(), 2 ) + " " + sub_maketimestring ( Hour(), 2 ) + "_" + sub_maketimestring ( Minute(), 2 )
   + "_" + sub_maketimestring ( Seconds( ), 2 ) + " " + no + par_sx + ".gif";

   // Make a scrren shot, and i there is an error when a screen shot should have been taken then print out error message
   if ( !ScreenShot ( fn, 640, 480 ) )
      Print ( "ScreenShot error: ", ErrorDescription ( GetLastError() ) );
}


/**
 * Add leading zeros that the resulting string has 'digits' length.
 */
string sub_maketimestring ( int par_number, int par_digits ) {
   // Initiate a local variable
   string result;

   result = DoubleToStr ( par_number, 0 );
   while ( StringLen ( result ) < par_digits )
      result = "0" + result;

   return ( result );
}


/**
 * Calculate LotSize based on Equity, Risk (in %) and StopLoss in points
 */
double sub_calculatelotsize() {
   // initiate some localö variables
   string textstring;
   double availablemoney;
   double lotsize;
   double maxlot;
   double minlot;
   int lotdigit = 0;

   // Adjust lot decimals to broker lotstep
   if ( LotStep ==  1)
      lotdigit = 0;
   if ( LotStep == 0.1 )
      lotdigit = 1;
   if ( LotStep == 0.01 )
      lotdigit = 2;

   // Get available money as Equity
   availablemoney = AccountEquity();

   // Maximum allowed Lot by the broker according to Equity. And we don't use 100% but 98%
   maxlot = MathMin ( MathFloor ( availablemoney * 0.98 / MarginForOneLot / LotStep ) * LotStep, MaxLots );
   // Minimum allowed Lot by the broker
   minlot = MinLots;

   // Lot according to Risk. Don't use 100% but 98% (= 102) to avoid
   lotsize = MathMin(MathFloor ( Risk / 102 * availablemoney / ( StopLoss + AddPriceGap ) / LotStep ) * LotStep, MaxLots );
   lotsize = lotsize * sub_multiplicator();
   lotsize = NormalizeDouble ( lotsize, lotdigit );

   // Empty textstring
   textstring = "";

   // Use manual fix LotSize, but if necessary adjust to within limits
   if (!MoneyManagement) {
      // Set LotSize to manual LotSize
      lotsize = ManualLotsize;

      // Check if ManualLotsize is greater than allowed LotSize
      if ( ManualLotsize > maxlot )
      {
         lotsize = maxlot;
         textstring = "Note: Manual LotSize is too high. It has been recalculated to maximum allowed " + DoubleToStr ( maxlot, 2 );
         Print ( textstring );
         ManualLotsize = maxlot;
      }
      // ManualLotSize is NOT greater than allowed LotSize
      else if ( ManualLotsize < minlot )
         lotsize = minlot;
   }

   return ( lotsize );
}


/**
 * Re-calculate a new Risk if the current one is too low or too high
 */
void sub_recalculatewrongrisk() {
   // Initiate some local variables
   string textstring;
   double availablemoney;
   double maxlot;
   double minlot;
   double maxrisk;
   double minrisk;

   // Get available amount of money as Equity
   availablemoney = AccountEquity();
   // Maximum allowed Lot by the broker according to Equity
   maxlot = MathFloor ( availablemoney / MarginForOneLot / LotStep ) * LotStep;
   // Maximum allowed Risk by the broker according to maximul allowed Lot and Equity
   maxrisk = MathFloor ( maxlot * ( StopLevel + StopLoss ) / availablemoney * 100 / 0.1 ) * 0.1;
   // Minimum allowed Lot by the broker
   minlot = MinLots;
   // Minimum allowed Risk by the broker according to minlots_broker
   minrisk = MathRound ( minlot * StopLoss / availablemoney * 100 / 0.1 ) * 0.1;
   // Empty textstring
   textstring = "";

   // If we use money management
   if (MoneyManagement) {
      // If Risk% is greater than the maximum risklevel the broker accept, then adjust Risk accordingly and print out changes
      if ( Risk > maxrisk )
      {
         textstring = textstring + "Note: Risk has manually been set to " + DoubleToStr ( Risk, 1 ) + " but cannot be higher than " + DoubleToStr ( maxrisk, 1 ) + " according to ";
         textstring = textstring + "the broker, StopLoss and Equity. It has now been adjusted accordingly to " + DoubleToStr ( maxrisk, 1 ) + "%";
         Risk = maxrisk;
         sub_printandcomment ( textstring );
      }
      // If Risk% is less than the minimum risklevel the broker accept, then adjust Risk accordingly and print out changes
      if (Risk < minrisk)
      {
         textstring = textstring + "Note: Risk has manually been set to " + DoubleToStr ( Risk, 1 ) + " but cannot be lower than " + DoubleToStr ( minrisk, 1 ) + " according to ";
         textstring = textstring + "the broker, StopLoss, AddPriceGap and Equity. It has now been adjusted accordingly to " + DoubleToStr ( minrisk, 1 ) + "%";
         Risk = minrisk;
         sub_printandcomment ( textstring );
      }
   }
   // If we don't use MoneyManagement, then use fixed manual LotSize
   else // !MoneyManagement
   {
      // Check and if necessary adjust manual LotSize to external limits
      if ( ManualLotsize < MinLots )
      {
         textstring = "Manual LotSize " + DoubleToStr ( ManualLotsize, 2 ) + " cannot be less than " + DoubleToStr ( MinLots, 2 ) + ". It has now been adjusted to " + DoubleToStr ( MinLots, 2);
         ManualLotsize = MinLots;
         sub_printandcomment ( textstring );
      }
      if ( ManualLotsize > MaxLots )
      {
         textstring = "Manual LotSize " + DoubleToStr ( ManualLotsize, 2 ) + " cannot be greater than " + DoubleToStr ( MaxLots, 2 ) + ". It has now been adjusted to " + DoubleToStr ( MinLots, 2 );
         ManualLotsize = MaxLots;
         sub_printandcomment ( textstring );
      }
      // Check to see that manual LotSize does not exceeds maximum allowed LotSize
      if ( ManualLotsize > maxlot )
      {
         textstring = "Manual LotSize " + DoubleToStr ( ManualLotsize, 2 ) + " cannot be greater than maximum allowed LotSize. It has now been adjusted to " + DoubleToStr ( maxlot, 2 );
         ManualLotsize = maxlot;
         sub_printandcomment ( textstring );
      }
   }
}


/**
 * Print and show comment of text
 */
void sub_printandcomment(string par_text) {
   Print(par_text);
}


/**
 * Summarize error messages that comes from the broker server
 */
void sub_errormessages() {
   // Initiate a local variable
   int error = GetLastError();

   // Depending on the value if the variable error, one case should match and the counter for that errtor should be increased with 1
   switch ( error )
   {
      // Unchanged values
      case 1: // ERR_SERVER_BUSY:
      {
         Err_unchangedvalues ++;
         break;
      }
      // Trade server is busy
      case 4: // ERR_SERVER_BUSY:
      {
         Err_busyserver ++;
         break;
      }
      case 6: // ERR_NO_CONNECTION:
      {
         Err_lostconnection ++;
         break;
      }
      case 8: // ERR_TOO_FREQUENT_REQUESTS:
      {
         Err_toomanyrequest ++;
         break;
      }
      case 129: // ERR_INVALID_PRICE:
      {
         Err_invalidprice ++;
         break;
      }
      case 130: // ERR_INVALID_STOPS:
      {
         Err_invalidstops ++;
         break;
      }
      case 131: // ERR_INVALID_TRADE_VOLUME:
      {
         Err_invalidtradevolume ++;
         break;
      }
      case 135: // ERR_PRICE_CHANGED:
      {
         Err_pricechange ++;
         break;
      }
      case 137: // ERR_BROKER_BUSY:
      {
         Err_brokerbuzy ++;
         break;
      }
      case 138: // ERR_REQUOTE:
      {
         Err_requotes ++;
         break;
      }
      case 141: // ERR_TOO_MANY_REQUESTS:
      {
         Err_toomanyrequests ++;
         break;
      }
      case 145: // ERR_TRADE_MODIFY_DENIED:
      {
         Err_trademodifydenied ++;
         break;
      }
      case 146: // ERR_TRADE_CONTEXT_BUSY:
      {
         Err_tradecontextbuzy ++;
         break;
      }
   }
}


/**
 * Print out and comment summarized messages from the broker
 */
void sub_printsumofbrokererrors() {
   // Prepare some lopcal variables
   string txt;
   int totalerrors;

   // Prepare a text strring
   txt = "Number of times the brokers server reported that ";

   // Sum up total errors
   totalerrors = Err_unchangedvalues + Err_busyserver + Err_lostconnection + Err_toomanyrequest + Err_invalidprice
   + Err_invalidstops + Err_invalidtradevolume + Err_pricechange + Err_brokerbuzy + Err_requotes + Err_toomanyrequests
   + Err_trademodifydenied + Err_tradecontextbuzy;

   // Call print subroutine with text depending on found errors
   if ( Err_unchangedvalues > 0 )
      sub_printandcomment ( txt + "SL and TP was modified to existing values: " + DoubleToStr ( Err_unchangedvalues, 0 ) );
   if ( Err_busyserver > 0 )
      sub_printandcomment ( txt + "it is buzy: " + DoubleToStr ( Err_busyserver, 0 ) );
   if ( Err_lostconnection > 0 )
      sub_printandcomment ( txt + "the connection is lost: " + DoubleToStr ( Err_lostconnection, 0 ) );
   if ( Err_toomanyrequest > 0 )
      sub_printandcomment ( txt + "there was too many requests: " + DoubleToStr ( Err_toomanyrequest, 0 ) );
   if ( Err_invalidprice > 0 )
      sub_printandcomment ( txt + "the price was invalid: " + DoubleToStr ( Err_invalidprice, 0 ) );
   if ( Err_invalidstops > 0 )
      sub_printandcomment ( txt + "invalid SL and/or TP: " + DoubleToStr ( Err_invalidstops, 0 ) );
   if ( Err_invalidtradevolume > 0 )
      sub_printandcomment ( txt + "invalid lot size: " + DoubleToStr ( Err_invalidtradevolume, 0 ) );
   if ( Err_pricechange > 0 )
      sub_printandcomment(txt + "the price has changed: " + DoubleToStr ( Err_pricechange, 0 ) );
   if ( Err_brokerbuzy > 0 )
      sub_printandcomment(txt + "the broker is buzy: " + DoubleToStr ( Err_brokerbuzy, 0 ) ) ;
   if ( Err_requotes > 0 )
      sub_printandcomment ( txt + "requotes " + DoubleToStr ( Err_requotes, 0 ) );
   if ( Err_toomanyrequests > 0 )
      sub_printandcomment ( txt + "too many requests " + DoubleToStr ( Err_toomanyrequests, 0 ) );
   if ( Err_trademodifydenied > 0 )
      sub_printandcomment ( txt + "modifying orders is denied " + DoubleToStr ( Err_trademodifydenied, 0 ) );
   if ( Err_tradecontextbuzy > 0)
      sub_printandcomment ( txt + "trade context is buzy: " + DoubleToStr ( Err_tradecontextbuzy, 0 ) );
   if ( totalerrors == 0 )
      sub_printandcomment ( "There was no error reported from the broker server!" );
}


/**
 * Check through all open orders
 */
void sub_CheckThroughAllOpenOrders() {
   // Initiate some local variables
   int pos;
   double tmp_order_lots;
   double tmp_order_price;

   // Get total number of open orders
   Tot_Orders = OrdersTotal();

   // Reset counters
   Tot_open_pos = 0;
   Tot_open_profit = 0;
   Tot_open_lots = 0;
   Tot_open_swap = 0;
   Tot_open_commission = 0;
   G_equity = 0;
   Changedmargin = 0;

   // Loop through all open orders from first to last
   for ( pos = 0; pos < Tot_Orders; pos ++ )
   {
      // Select on order
      if ( OrderSelect ( pos, SELECT_BY_POS, MODE_TRADES ) )
      {

         // Check if it matches the MagicNumber
         if ( OrderMagicNumber() == Magic && OrderSymbol() == Symbol() )    // If the orders are for this EA
         {
            // Calculate sum of open orders, open profit, swap and commission
            Tot_open_pos ++;
            tmp_order_lots = OrderLots();
            Tot_open_lots += tmp_order_lots;
            tmp_order_price = OrderOpenPrice();
            Tot_open_profit += OrderProfit();
            Tot_open_swap += OrderSwap();
            Tot_open_commission += OrderCommission();
            Changedmargin += tmp_order_lots * tmp_order_price;
         }
      }
   }
   // Calculate Balance and Equity for this EA and not for the entire account
   G_equity = G_balance + Tot_open_profit + Tot_open_swap + Tot_open_commission;

}


/**
 * Check through all closed orders
 */
void UpdateClosedOrderStats() {
   int openTotal = OrdersHistoryTotal();

   Tot_closed_pos    = 0;
   Tot_closed_lots   = 0;
   Tot_closed_profit = 0;
   Tot_closed_swap   = 0;
   Tot_closed_comm   = 0;
   G_balance         = 0;

   // Loop through all closed orders
   for (int pos=0; pos < openTotal; pos++) {
      // Select an order
      if (OrderSelect(pos, SELECT_BY_POS, MODE_HISTORY)) {                 // Loop through the order history
         // If the MagicNumber matches
         if (OrderMagicNumber()==Magic && OrderSymbol()==Symbol()) {       // If the orders are for this EA
            Tot_closed_lots   += OrderLots();
            Tot_closed_profit += OrderProfit();
            Tot_closed_swap   += OrderSwap();
            Tot_closed_comm   += OrderCommission();
            Tot_closed_pos++;
         }
      }
   }
   G_balance = Tot_closed_profit + Tot_closed_swap + Tot_closed_comm;
}


/**
 * Printout graphics on the chart
 */
void sub_ShowGraphInfo() {
   string line1;
   string line2;
   string line3;
   string line4;
   string line5;
// string line6;
   string line7;
// string line8;
   string line9;
   string line10;
   int textspacing = 10;
   int linespace;

   // Prepare for sub_Display
   line1 = EA_version;
   line2 = "Open: " + DoubleToStr ( Tot_open_pos, 0 ) + " positions, " + DoubleToStr ( Tot_open_lots, 2 ) + " lots with value: " + DoubleToStr ( Tot_open_profit, 2 );
   line3 = "Closed: " + DoubleToStr ( Tot_closed_pos, 0 ) + " positions, " + DoubleToStr ( Tot_closed_lots, 2 ) + " lots with value: " + DoubleToStr ( Tot_closed_profit, 2 );
   line4 = "EA Balance: " + DoubleToStr ( G_balance, 2 ) + ", Swap: " + DoubleToStr ( Tot_open_swap, 2 ) + ", Commission: " + DoubleToStr ( Tot_open_commission, 2 );
   line5 = "EA Equity: " + DoubleToStr ( G_equity, 2 ) + ", Swap: " + DoubleToStr ( Tot_closed_swap, 2 ) + ", Commission: "  + DoubleToStr ( Tot_closed_comm, 2 );
// line6
   line7 = "                               ";
// line8 = "";
   line9 = "Free margin: " + DoubleToStr ( MarginFree, 2 ) + ", Min allowed Margin level: " + DoubleToStr ( MinMarginLevel, 2 ) + "%";
   line10 = "Margin value: " + DoubleToStr ( Changedmargin, 2 );

   // sub_Display graphic information on the chart
   linespace = textspacing;
   sub_Display ( "line1", line1, Heading_Size, 3, linespace, Color_Heading, 0 );
   linespace = textspacing * 2 + Text_Size * 1 + 3 * 1;
   // linespace = textspacing * 2 + Text_Size * 2 + 3 * 2;  // Next line should look like this
   sub_Display ( "line2", line2, Text_Size, 3, linespace, Color_Section1, 0 );
   linespace = textspacing * 2 + Text_Size * 2 + 3 * 2 + 20;
   sub_Display ( "line3", line3, Text_Size, 3, linespace, Color_Section2, 0 );
   linespace = textspacing * 2 + Text_Size * 3 + 3 * 3 + 40;
   sub_Display ( "line4", line4, Text_Size, 3, linespace, Color_Section3, 0 );
   linespace = textspacing * 2 + Text_Size * 4 + 3 * 4 + 40;
   sub_Display ( "line5", line5, Text_Size, 3, linespace, Color_Section3, 0 );
// linespace = textspacing * 2 + Text_Size * 5 + 3 * 5 + 60;
// sub_Display ( "line6", line6, Text_Size, 3, linespace, Color_Section4, 0 );
   linespace = textspacing * 2 + Text_Size * 5 + 3 * 5 + 40;
   sub_Display ( "line7", line7, Text_Size, 3, linespace, Color_Section4, 0 );
// linespace = textspacing * 2 + Text_Size * 7 + 3 * 7 + 60;
// sub_Display ( "line8", line8, Text_Size, 3, linespace, Color_Section4, 0 );
   linespace = textspacing * 2 + Text_Size * 6 + 3 * 6 + 40;
   sub_Display ( "line9", line9, Text_Size, 3, linespace, Color_Section4, 0 );
   linespace = textspacing * 2 + Text_Size * 7 + 3 * 7 + 40;
   sub_Display ( "line10", line10, Text_Size, 3, linespace, Color_Section4, 0 );
}


/**
 * Subroutine for displaying graphics on the chart
 */
void sub_Display ( string obj_name, string object_text, int object_text_fontsize, int object_x_distance, int object_y_distance, color object_textcolor, int object_corner_value ) {
   ObjectCreate ( obj_name, OBJ_LABEL, 0, 0, 0, 0, 0 );
   ObjectSet ( obj_name, OBJPROP_CORNER, object_corner_value );
   ObjectSet ( obj_name, OBJPROP_XDISTANCE, object_x_distance );
   ObjectSet ( obj_name, OBJPROP_YDISTANCE, object_y_distance );
   ObjectSetText ( obj_name, object_text, object_text_fontsize, "Tahoma", object_textcolor );
}


/**
 * Delete all graphics on the chart
 */
void sub_DeleteDisplay() {
   ObjectsDeleteAll();
}


/**
 * Get text for Uninit Reason
 */
string sub_UninitReasonText( int reasonCode ) {
   string text = "";

   switch ( reasonCode )
   {
      case REASON_ACCOUNT:
         text = "Account was changed";
         break;
      case REASON_CHARTCHANGE:
         text = "Symbol or timeframe was changed";
         break;
      case REASON_CHARTCLOSE:
         text = "Chart was closed";
         break;
      case REASON_PARAMETERS:
         text = "Input-parameter was changed";
         break;
      case REASON_RECOMPILE:
         text = "Program " + WindowExpertName() + " was recompiled";
         break;
      case REASON_REMOVE:
         text = "Program " + WindowExpertName() + " was removed from chart";
         break;
      case REASON_TEMPLATE:
         text = "New template was applied to chart";
         break;
      default:
         text = "Another reason";
   }
   return ( text );
}

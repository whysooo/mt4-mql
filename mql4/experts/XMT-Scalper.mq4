/**
 * XMT-Scalper revisited
 *
 *
 * This EA is originally based on the famous "MillionDollarPips EA". A member of the "www.worldwide-invest.org" forum known
 * as Capella transformed it to "XMT-Scalper". In his own words: "Nothing remains from the original except the core idea of
 * the strategy: scalping based on a reversal from a channel breakout." Today various versions circulate in the internet
 * going by different names (MDP-Plus, XMT, Assar). None is suitable for real trading. Main reasons are a high price feed
 * sensitivity (especially the number of received ticks) and the unaccounted effects of slippage/commission. Moreover test
 * behavior differs from online behavior to such a large degree that testing is meaningless in general.
 *
 * This version is a complete rewrite.
 *
 * Sources:
 *  @link  https://github.com/rosasurfer/mt4-mql/blob/a1b22d0/mql4/experts/mdp#             [MillionDollarPips v2 decompiled]
 *  @link  https://github.com/rosasurfer/mt4-mql/blob/36f494e/mql4/experts/mdp#                    [MDP-Plus v2.2 by Capella]
 *  @link  https://github.com/rosasurfer/mt4-mql/blob/41237e0/mql4/experts/mdp#               [XMT-Scalper v2.522 by Capella]
 *
 *
 * Changes:
 *  - removed MQL5 syntax and fixed compiler issues
 *  - added rosasurfer framework and the framework's test reporting
 *  - added monitoring of PositionOpen and PositionClose events
 *  - rewrote displayed trade statistics
 *  - moved Print() output to the framework logger
 *  - removed obsolete functions and variables
 *  - removed obsolete order expiration, NDD and screenshot functionality
 *  - removed obsolete sending of fake orders and measuring of execution times
 *  - removed configuration of the min. margin level
 *  - renamed and reordered input parameters, removed obsolete or needless ones
 *  - fixed ERR_INVALID_STOP when opening pending orders or positions
 *  - fixed logical program flow issues
 */
#include <stddefines.mqh>
int   __InitFlags[] = {INIT_TIMEZONE, INIT_BUFFERED_LOG};
int __DeinitFlags[];

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern string ___a_____________________ = "=== Entry indicator: 1=MovingAverage, 2=BollingerBands, 3=Envelopes";
extern int    EntryIndicator            = 1;          // entry signal indicator for price channel calculation
extern int    Indicatorperiod           = 3;          // period in bars for indicator
extern double BBDeviation               = 2;          // deviation for the iBands indicator
extern double EnvelopesDeviation        = 0.07;       // deviation for the iEnvelopes indicator

extern string ___b_____________________ = "==== MinBarSize settings ====";
extern bool   UseDynamicVolatilityLimit = true;       // calculated based on (int)(spread * VolatilityMultiplier)
extern double VolatilityMultiplier      = 125;        // a multiplier that is used if UseDynamicVolatilityLimit is TRUE
extern double VolatilityLimit           = 180;        // a fix value that is used if UseDynamicVolatilityLimit is FALSE
extern double VolatilityPercentageLimit = 0;          // percentage of how much iHigh-iLow difference must differ from VolatilityLimit

extern string ___c_____________________ = "==== Trade settings ====";
extern int    TimeFrame                 = PERIOD_M1;  // trading timeframe must match the timeframe of the chart
extern double StopLoss                  = 60;         // SL from as many points. Default 60 (= 6 pips)
extern double TakeProfit                = 100;        // TP from as many points. Default 100 (= 10 pip)
extern double TrailingStart             = 20;         // start trailing profit from as so many points.
extern int    StopDistance.Points       = 0;          // entry order stop distance in points
extern int    Slippage.Points           = 3;          // acceptable market order slippage in points
extern double Commission                = 0;          // commission per lot
extern double MaxSpread                 = 30;         // max allowed spread in points
extern int    Magic                     = -1;         // if negative the MagicNumber is generated
extern bool   ReverseTrades             = false;      // if TRUE, then trade in opposite direction

extern string ___d_____________________ = "==== MoneyManagement ====";
extern bool   MoneyManagement           = true;       // if TRUE lotsize is calculated based on "Risk", if FALSE use "ManualLotsize"
extern double Risk                      = 2;          // risk setting in percentage, for equity=10'000, risk=10% and stoploss=60: lotsize = 16.66
extern double MinLots                   = 0.01;       // minimum lotsize to use
extern double MaxLots                   = 100;        // maximum lotsize to use
extern double ManualLotsize             = 0.1;        // fix lotsize to use if "MoneyManagement" is FALSE

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#include <core/expert.mqh>
#include <stdfunctions.mqh>
#include <rsfLibs.mqh>
#include <functions/JoinStrings.mqh>
#include <structs/rsf/OrderExecution.mqh>

int    openPositions;            // number of open positions
double openLots;                 // total open lotsize
double openSwap;                 // total open swap
double openCommission;           // total open commissions
double openPl;                   // total open gross profit
double openPlNet;                // total open net profit

int    closedPositions;          // number of closed positions
double closedLots;               // total closed lotsize
double closedSwap;               // total closed swap
double closedCommission;         // total closed commission
double closedPl;                 // total closed gross profit
double closedPlNet;              // total closed net profit

double totalPl;                  // totalPl = openPlNet + closedPlNet

double stopDistance;             // entry order stop distance
string orderComment = "XMT-rsf";

// --- old ------------------------------------------------------------
int    UpTo30Counter = 0;        // for calculating average spread
double Array_spread[30];         // store spreads for the last 30 ticks
double LotSize;                  // lotsize
double highest;                  // lotSize indicator value
double lowest;                   // lowest indicator value



/**
 * Initialization
 *
 * @return int - error status
 */
int onInit() {
   if (!IsTesting() && Period()!=TimeFrame) {
      return(catch("onInit(1)  The EA has been set to run on timeframe: "+ TimeFrame +" but it has been attached to a chart with timeframe: "+ Period(), ERR_RUNTIME_ERROR));
   }

   // Check to confirm that indicator switch is valid choices, if not force to 1 (Moving Average)
   if (EntryIndicator < 1 || EntryIndicator > 3)
      EntryIndicator = 1;

   stopDistance = MathMax(stopDistance, StopDistance.Points);
   stopDistance = MathMax(stopDistance, MarketInfo(Symbol(), MODE_STOPLEVEL));
   stopDistance = MathMax(stopDistance, MarketInfo(Symbol(), MODE_FREEZELEVEL));

   // ensure SL and TP aren't smaller than the broker's stop distance
   StopLoss   = MathMax(StopLoss, stopDistance);
   TakeProfit = MathMax(TakeProfit, stopDistance);

   // Re-calculate variables
   VolatilityPercentageLimit = VolatilityPercentageLimit / 100 + 1;
   VolatilityMultiplier = VolatilityMultiplier / 10;
   ArrayInitialize ( Array_spread, 0 );
   VolatilityLimit = VolatilityLimit * Point;
   Commission = NormalizeDouble(Commission * Point, Digits);
   TrailingStart = TrailingStart * Point;
   stopDistance  = stopDistance * Point;

   // If we have set MaxLot and/or MinLots to more/less than what the broker allows, then adjust accordingly
   if (MinLots < MarketInfo(Symbol(), MODE_MINLOT)) MinLots = MarketInfo(Symbol(), MODE_MINLOT);
   if (MaxLots > MarketInfo(Symbol(), MODE_MAXLOT)) MaxLots = MarketInfo(Symbol(), MODE_MAXLOT);
   if (MaxLots < MinLots) MaxLots = MinLots;

   // Also make sure that if the risk-percentage is too low or too high, that it's adjusted accordingly
   RecalculateRisk();

   // Calculate intitial LotSize
   LotSize = CalculateLotsize();

   // If magic number is set to a value less than 0, then calculate MagicNumber automatically
   if ( Magic < 0 )
     Magic = CreateMagicNumber();

   // Check through all closed and open orders to get stats
   CheckClosedOrders();
   CheckOpenOrders();

   ShowGraphInfo();

   return(catch("onInit(2)"));
}


/**
 * Main function
 *
 * @return int - error status
 */
int onTick() {
   if (iBars(Symbol(), TimeFrame) <= Indicatorperiod) {
      Print("Please wait until enough of bar data has been gathered!");
   }
   else {
      UpdateOrderStatus();          // pewa: detect and track open/closed positions

      Trade();                      // Call the actual main subroutine
      CheckClosedOrders();          // Check all closed and open orders to get stats
      CheckOpenOrders();
      ShowGraphInfo();
   }
   return(catch("onTick(1)"));
}


// pewa: order management
int      tickets      [];
int      pendingTypes [];
double   pendingPrices[];
int      types        [];
datetime closeTimes   [];


/**
 * pewa: Detect and track open/closed positions.
 *
 * @return bool - success status
 */
bool UpdateOrderStatus() {
   int orders = ArraySize(tickets);

   // update ticket status
   for (int i=0; i < orders; i++) {
      if (closeTimes[i] > 0) continue;                            // skip tickets already known as closed
      if (!SelectTicket(tickets[i], "UpdateOrderStatus(1)")) return(false);

      bool wasPending  = (types[i] == OP_UNDEFINED);
      bool isPending   = (OrderType() > OP_SELL);
      bool wasPosition = !wasPending;
      bool isOpen      = !OrderCloseTime();
      bool isClosed    = !isOpen;

      if (wasPending) {
         if (!isPending) {                                        // the pending order was filled
            types[i] = OrderType();
            onPositionOpen(i);
            wasPosition = true;                                   // mark as known open position
         }
         else if (isClosed) {                                     // the pending order was cancelled
            onOrderDelete(i);
            i--; orders--;
            continue;
         }
      }

      if (wasPosition) {
         if (!isOpen) {                                           // the open position was closed
            onPositionClose(i);
            i--; orders--;
            continue;
         }
      }
   }
   return(!catch("UpdateOrderStatus(2)"));
}


/**
 * pewa: Handle PositionOpen events.
 *
 * @param  int i - ticket index of the opened position
 *
 * @return bool - success status
 */
bool onPositionOpen(int i) {
   if (IsLogInfo()) {
      // #1 Stop Sell 0.1 GBPUSD at 1.5457'2[ "comment"] was filled[ at 1.5457'2] (market: Bid/Ask[, 0.3 pip [positive ]slippage])

      SelectTicket(tickets[i], "onPositionOpen(1)", /*push=*/true);
      int    pendingType  = pendingTypes [i];
      double pendingPrice = pendingPrices[i];

      string sType         = OperationTypeDescription(pendingType);
      string sPendingPrice = NumberToStr(pendingPrice, PriceFormat);
      string sComment      = ""; if (StringLen(OrderComment()) > 0) sComment = " "+ DoubleQuoteStr(OrderComment());
      string message       = "#"+ OrderTicket() +" "+ sType +" "+ NumberToStr(OrderLots(), ".+") +" "+ Symbol() +" at "+ sPendingPrice + sComment +" was filled";

      string sSlippage = "";
      if (NE(OrderOpenPrice(), pendingPrice, Digits)) {
         double slippage = NormalizeDouble((pendingPrice-OrderOpenPrice())/Pip, 1); if (OrderType() == OP_SELL) slippage = -slippage;
            if (slippage > 0) sSlippage = ", "+ DoubleToStr(slippage, Digits & 1) +" pip positive slippage";
            else              sSlippage = ", "+ DoubleToStr(-slippage, Digits & 1) +" pip slippage";
         message = message +" at "+ NumberToStr(OrderOpenPrice(), PriceFormat);
      }
      OrderPop("onPositionOpen(2)");
      logInfo("onPositionOpen(3)  "+ message +" (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) + sSlippage +")");
   }

   if (IsTesting() && __ExecutionContext[EC.extReporting]) {
      SelectTicket(tickets[i], "onPositionOpen(4)", /*push=*/true);
      Test_onPositionOpen(__ExecutionContext, OrderTicket(), OrderType(), OrderLots(), OrderSymbol(), OrderOpenTime(), OrderOpenPrice(), OrderStopLoss(), OrderTakeProfit(), OrderCommission(), OrderMagicNumber(), OrderComment());
      OrderPop("onPositionOpen(5)");
   }
   return(!catch("onPositionOpen(6)"));
}


/**
 * pewa: Handle PositionClose events.
 *
 * @param  int i - ticket index of the closed position
 *
 * @return bool - success status
 */
bool onPositionClose(int i) {
   if (IsLogInfo()) {
      // #1 Sell 0.1 GBPUSD at 1.5457'2[ "comment"] was closed at 1.5457'2 (market: Bid/Ask[, so: 47.7%/169.20/354.40])

      SelectTicket(tickets[i], "onPositionClose(1)", /*push=*/true);
      string sType       = OperationTypeDescription(OrderType());
      string sOpenPrice  = NumberToStr(OrderOpenPrice(), PriceFormat);
      string sClosePrice = NumberToStr(OrderClosePrice(), PriceFormat);
      string sComment    = ""; if (StringLen(OrderComment()) > 0) sComment = " "+ DoubleQuoteStr(OrderComment());
      string message     = "#"+ OrderTicket() +" "+ sType +" "+ NumberToStr(OrderLots(), ".+") +" "+ Symbol() +" at "+ sOpenPrice + sComment +" was closed at "+ sClosePrice;
      OrderPop("onPositionClose(2)");
      logInfo("onPositionClose(3)  "+ message +" (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")");
   }

   if (IsTesting() && __ExecutionContext[EC.extReporting]) {
      SelectTicket(tickets[i], "onPositionClose(4)", /*push=*/true);
      Test_onPositionClose(__ExecutionContext, OrderTicket(), OrderCloseTime(), OrderClosePrice(), OrderSwap(), OrderProfit());
      OrderPop("onPositionClose(5)");
   }
   return(Orders.RemoveTicket(tickets[i]));
}


/**
 * pewa: Handle OrderDelete events.
 *
 * @param  int i - ticket index of the deleted order
 *
 * @return bool - success status
 */
bool onOrderDelete(int i) {
   if (IsLogInfo()) {
      // #1 Stop Sell 0.1 GBPUSD at 1.5457'2[ "comment"] was deleted

      SelectTicket(tickets[i], "onOrderDelete(1)", /*push=*/true);
      int    pendingType  = pendingTypes [i];
      double pendingPrice = pendingPrices[i];

      string sType         = OperationTypeDescription(pendingType);
      string sPendingPrice = NumberToStr(pendingPrice, PriceFormat);
      string sComment      = ""; if (StringLen(OrderComment()) > 0) sComment = " "+ DoubleQuoteStr(OrderComment());
      string message       = "#"+ OrderTicket() +" "+ sType +" "+ NumberToStr(OrderLots(), ".+") +" "+ Symbol() +" at "+ sPendingPrice + sComment +" was deleted";
      OrderPop("onOrderDelete(2)");

      logInfo("onOrderDelete(3)  "+ message);
   }
   return(Orders.RemoveTicket(tickets[i]));
}


/**
 * pewa: Add a new order record.
 *
 * @param  int      ticket
 * @param  int      pendingType
 * @param  double   pendingPrice
 * @param  int      type
 * @param  datetime closeTime
 *
 * @return bool - success status
 */
bool Orders.AddTicket(int ticket, int pendingType, double pendingPrice, int type, datetime closeTime) {
   int pos = SearchIntArray(tickets, ticket);
   if (pos >= 0) return(!catch("Orders.AddTicket(1)  invalid parameter ticket: "+ ticket +" (already exists)", ERR_INVALID_PARAMETER));

   ArrayPushInt   (tickets,       ticket      );
   ArrayPushInt   (pendingTypes,  pendingType );
   ArrayPushDouble(pendingPrices, pendingPrice);
   ArrayPushInt   (types,         type        );
   ArrayPushInt   (closeTimes,    closeTime   );

   return(!catch("Orders.AddTicket()"));
}


/**
 * pewa: Update the order record of the specified ticket.
 *
 * @param  int      ticket
 * @param  int      pendingType
 * @param  double   pendingPrice
 * @param  int      type
 * @param  datetime closeTime
 *
 * @return bool - success status
 */
bool Orders.UpdateTicket(int ticket, int pendingType, double pendingPrice, int type, datetime closeTime) {
   int pos = SearchIntArray(tickets, ticket);
   if (pos < 0) return(!catch("Orders.UpdateTicket(1)  invalid parameter ticket: "+ ticket +" (order not found)", ERR_INVALID_PARAMETER));

   pendingTypes [pos] = pendingType;
   pendingPrices[pos] = pendingPrice;
   types        [pos] = type;
   closeTimes   [pos] = closeTime;

   return(!catch("Orders.UpdateTicket(2)"));
}


/**
 * pewa: Remove the order record with the specified ticket.
 *
 * @param  int ticket
 *
 * @return bool - success status
 */
bool Orders.RemoveTicket(int ticket) {
   int pos = SearchIntArray(tickets, ticket);
   if (pos < 0) return(!catch("Orders.RemoveTicket(1)  invalid parameter ticket: "+ ticket +" (order not found)", ERR_INVALID_PARAMETER));

   ArraySpliceInts   (tickets,       pos, 1);
   ArraySpliceInts   (pendingTypes,  pos, 1);
   ArraySpliceDoubles(pendingPrices, pos, 1);
   ArraySpliceInts   (types,         pos, 1);
   ArraySpliceInts   (closeTimes,    pos, 1);

   return(!catch("Orders.RemoveTicket(2)"));
}


/**
 * Main trading subroutine
 */
void Trade() {
   string pair;

   bool wasordermodified = false;
   bool isbidgreaterthanima = false;
   bool isbidgreaterthanibands = false;
   bool isbidgreaterthanenvelopes = false;
   bool isbidgreaterthanindy = false;

   int loopcount2;
   int loopcount1;
   int pricedirection;

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
   int oe[];

   // Calculate Margin level
   if (AccountMargin() != 0)
      am = AccountMargin();
   if (!am) return(catch("Trade(1)  am = 0", ERR_ZERO_DIVIDE));
   marginlevel = AccountEquity() / am * 100; // margin level in %

   if (marginlevel < 100) {
      Alert("Warning! Free Margin "+ DoubleToStr(marginlevel, 2) +" is lower than MinMarginLevel!");
      return(catch("Trade(2)"));
   }

   // Calculate the channel of Volatility based on the difference of iHigh and iLow during current bar
   ihigh = iHigh ( Symbol(), TimeFrame, 0 );
   ilow = iLow ( Symbol(), TimeFrame, 0 );
   volatility = ihigh - ilow;

   // Reset printout string
   string indy = "";

   // Calculate a channel on Moving Averages, and check if the price is outside of this channel.
   if (EntryIndicator == 1) {
      imalow = iMA ( Symbol(), TimeFrame, Indicatorperiod, 0, MODE_LWMA, PRICE_LOW, 0 );
      imahigh = iMA ( Symbol(), TimeFrame, Indicatorperiod, 0, MODE_LWMA, PRICE_HIGH, 0 );
      imadiff = imahigh - imalow;
      isbidgreaterthanima = Bid >= imalow + imadiff / 2.0;
      indy = "iMA_low: " + DoubleToStr(imalow, Digits) + ", iMA_high: " + DoubleToStr(imahigh, Digits) + ", iMA_diff: " + DoubleToStr(imadiff, Digits);
   }

   // Calculate a channel on BollingerBands, and check if the price is outside of this channel
   if (EntryIndicator == 2) {
      ibandsupper = iBands ( Symbol(), TimeFrame, Indicatorperiod, BBDeviation, 0, PRICE_OPEN, MODE_UPPER, 0 );
      ibandslower = iBands ( Symbol(), TimeFrame, Indicatorperiod, BBDeviation, 0, PRICE_OPEN, MODE_LOWER, 0 );
      ibandsdiff = ibandsupper - ibandslower;
      isbidgreaterthanibands = Bid >= ibandslower + ibandsdiff / 2.0;
      indy = "iBands_upper: " + DoubleToStr(ibandsupper, Digits) + ", iBands_lower: " + DoubleToStr(ibandslower, Digits) + ", iBands_diff: " + DoubleToStr(ibandsdiff, Digits);
   }

   // Calculate a channel on Envelopes, and check if the price is outside of this channel
   if (EntryIndicator == 3) {
      envelopesupper = iEnvelopes ( Symbol(), TimeFrame, Indicatorperiod, MODE_LWMA, 0, PRICE_OPEN, EnvelopesDeviation, MODE_UPPER, 0 );
      envelopeslower = iEnvelopes ( Symbol(), TimeFrame, Indicatorperiod, MODE_LWMA, 0, PRICE_OPEN, EnvelopesDeviation, MODE_LOWER, 0 );
      envelopesdiff = envelopesupper - envelopeslower;
      isbidgreaterthanenvelopes = Bid >= envelopeslower + envelopesdiff / 2.0;
      indy = "iEnvelopes_upper: " + DoubleToStr(envelopesupper, Digits) + ", iEnvelopes_lower: " + DoubleToStr(envelopeslower, Digits) + ", iEnvelopes_diff: " + DoubleToStr(envelopesdiff, Digits) ;
   }

   // Reset breakout variable as FALSE
   isbidgreaterthanindy = false;

   // Reset pricedirection for no indication of trading direction
   pricedirection = 0;

   // If we're using iMA as indicator, then set variables from it
   if (EntryIndicator==1 && isbidgreaterthanima) {
      isbidgreaterthanindy = true;
      highest = imahigh;
      lowest = imalow;
   }

   // If we're using iBands as indicator, then set variables from it
   else if (EntryIndicator==2 && isbidgreaterthanibands) {
      isbidgreaterthanindy = true;
      highest = ibandsupper;
      lowest = ibandslower;
   }

   // If we're using iEnvelopes as indicator, then set variables from it
   else if (EntryIndicator==3 && isbidgreaterthanenvelopes) {
      isbidgreaterthanindy = true;
      highest = envelopesupper;
      lowest = envelopeslower;
   }

   // Calculate spread
   spread = Ask - Bid;

   // Calculate lot size
   LotSize = CalculateLotsize();

   // calculate average spread of the last 30 ticks
   ArrayCopy(Array_spread, Array_spread, 0, 1, 29);
   Array_spread[29] = spread;
   if (UpTo30Counter < 30) UpTo30Counter++;
   sumofspreads = 0;
   loopcount2 = 29;
   for (loopcount1=0; loopcount1 < UpTo30Counter; loopcount1++) {
      sumofspreads += Array_spread[loopcount2];
      loopcount2 --;
   }
   if (!UpTo30Counter) return(catch("Trade(3)  UpTo30Counter = 0", ERR_ZERO_DIVIDE));
   avgspread = sumofspreads / UpTo30Counter;

   // Calculate price and spread considering commission
   askpluscommission  = NormalizeDouble(Ask + Commission, Digits);
   bidminuscommission = NormalizeDouble(Bid - Commission, Digits);
   realavgspread      = avgspread + Commission;

   // Recalculate the VolatilityLimit if it's set to dynamic. It's based on the average of spreads multiplied with the VolatilityMulitplier constant
   if (UseDynamicVolatilityLimit)
      VolatilityLimit = realavgspread * VolatilityMultiplier;

   // If the variables below have values it means that we have enough of data from broker server.
   if (volatility && VolatilityLimit && lowest && highest) {
      // We have a price breakout, as the Volatility is outside of the VolatilityLimit, so we can now open a trade
      if (volatility > VolatilityLimit) {
         // Calculate how much it differs
         if (!VolatilityLimit) return(catch("Trade(4)  VolatilityLimit = 0", ERR_ZERO_DIVIDE));
         volatilitypercentage = volatility / VolatilityLimit;

         // check if it differ enough from the specified limit
         if (volatilitypercentage > VolatilityPercentageLimit) {
            if (Bid < lowest) {
               pricedirection = ifInt(ReverseTrades, 1, -1);   // -1=Long, 1=Short
            }
            else if (Bid > highest) {
               pricedirection = ifInt(ReverseTrades, -1, 1);   // -1=Long, 1=Short
            }
         }
      }
      else {
         // The Volatility is less than the VolatilityLimit so we set the volatilitypercentage to zero
         volatilitypercentage = 0;
      }
   }

   // Check for out of money
   if (AccountEquity() <= 0) {
      Alert("ERROR: AccountEquity = "+ DoubleToStr(AccountEquity(), 2));
      return(catch("Trade(5)"));
   }

   bool isOpenOrder = false;

   // Loop through all open orders to either modify or to delete them
   for (int i=0; i < OrdersTotal(); i++) {
      OrderSelect(i, SELECT_BY_POS, MODE_TRADES);

      if (OrderMagicNumber()==Magic && OrderSymbol()==Symbol()) {
         isOpenOrder = true;
         RefreshRates();

         switch (OrderType()) {
            case OP_BUY:
               // Modify the order if its TP is less than the price+commission+StopLevel AND the TrailingStart condition is satisfied
               ordertakeprofit = OrderTakeProfit();

               if (ordertakeprofit < NormalizeDouble(askpluscommission + TakeProfit*Point, Digits) && askpluscommission + TakeProfit*Point - ordertakeprofit > TrailingStart) {
                  orderstoploss   = NormalizeDouble(Bid - StopLoss*Point, Digits);
                  ordertakeprofit = NormalizeDouble(askpluscommission + TakeProfit*Point, Digits);

                  if (NE(orderstoploss, OrderStopLoss()) || NE(ordertakeprofit, OrderTakeProfit())) {
                     if (!OrderModifyEx(OrderTicket(), NULL, orderstoploss, ordertakeprofit, NULL, Lime, NULL, oe)) return(catch("Trade(6)"));
                  }
               }
               break;

            case OP_SELL:
               // Modify the order if its TP is greater than price-commission-StopLevel AND the TrailingStart condition is satisfied
               ordertakeprofit = OrderTakeProfit();

               if (ordertakeprofit > NormalizeDouble(bidminuscommission - TakeProfit*Point, Digits) && ordertakeprofit - bidminuscommission + TakeProfit*Point > TrailingStart) {
                  orderstoploss   = NormalizeDouble(Ask + StopLoss*Point, Digits);
                  ordertakeprofit = NormalizeDouble(bidminuscommission - TakeProfit*Point, Digits);

                  if (NE(orderstoploss, OrderStopLoss()) || NE(ordertakeprofit, OrderTakeProfit())) {
                     if (!OrderModifyEx(OrderTicket(), NULL, orderstoploss, ordertakeprofit, NULL, Orange, NULL, oe)) return(catch("Trade(7)"));
                  }
               }
               break;

            case OP_BUYSTOP:
               // Price must NOT be larger than indicator in order to modify the order, otherwise the order will be deleted
               if (!isbidgreaterthanindy) {
                  // Calculate how much Price, SL and TP should be modified
                  orderprice      = NormalizeDouble(Ask + stopDistance, Digits);
                  orderstoploss   = NormalizeDouble(orderprice - spread - StopLoss * Point, Digits);
                  ordertakeprofit = NormalizeDouble(orderprice + Commission + TakeProfit * Point, Digits);
                  // Start endless loop
                  while (true) {
                     // Ok to modify the order if price+StopLevel is less than orderprice AND orderprice-price-StopLevel is greater than trailingstart
                     if ( orderprice < OrderOpenPrice() && OrderOpenPrice() - orderprice > TrailingStart )
                     {

                        // Send an OrderModify command with adjusted Price, SL and TP
                        if (orderstoploss!=OrderStopLoss() && ordertakeprofit!=OrderTakeProfit()) {
                           if (!OrderModifyEx(OrderTicket(), orderprice, orderstoploss, ordertakeprofit, NULL, Lime, NULL, oe)) return(catch("Trade(8)"));
                           wasordermodified = true;
                        }
                        if (wasordermodified) {
                           Orders.UpdateTicket(OrderTicket(), OrderType(), orderprice, OP_UNDEFINED, OrderCloseTime());
                        }
                     }
                     break;
                  }
               }
               else {
                  if (!OrderDeleteEx(OrderTicket(), CLR_NONE, NULL, oe)) return(catch("Trade(9)"));
                  Orders.RemoveTicket(OrderTicket());
                  isOpenOrder = false;
               }
               break;

         case OP_SELLSTOP:
            // Price must be larger than the indicator in order to modify the order, otherwise the order will be deleted
            if (isbidgreaterthanindy) {
               // Calculate how much Price, SL and TP should be modified
               orderprice      = NormalizeDouble(Bid - stopDistance, Digits);
               orderstoploss   = NormalizeDouble(orderprice + spread + StopLoss * Point, Digits);
               ordertakeprofit = NormalizeDouble(orderprice - Commission - TakeProfit * Point, Digits);
               // Endless loop
               while (true) {
                  // Ok to modify order if price-StopLevel is greater than orderprice AND price-StopLevel-orderprice is greater than trailingstart
                  if ( orderprice > OrderOpenPrice() && orderprice - OrderOpenPrice() > TrailingStart)
                  {
                     // Send an OrderModify command with adjusted Price, SL and TP
                     if (orderstoploss!=OrderStopLoss() && ordertakeprofit!=OrderTakeProfit()) {
                        if (!OrderModifyEx(OrderTicket(), orderprice, orderstoploss, ordertakeprofit, NULL, Orange, NULL, oe)) return(catch("Trade(10)"));
                        wasordermodified = true;
                     }
                     if (wasordermodified) {
                        Orders.UpdateTicket(OrderTicket(), OrderType(), orderprice, OP_UNDEFINED, OrderCloseTime());
                     }
                  }
                  break;
               }
            }
            else {
               if (!OrderDeleteEx(OrderTicket(), CLR_NONE, NULL, oe)) return(catch("Trade(11)"));
               Orders.RemoveTicket(OrderTicket());
               isOpenOrder = false;
            }
            break;
         }
      }
   }

   // Open a new order if we have no open orders AND a price breakout AND average spread is less or equal to max allowed spread
   if (!isOpenOrder && pricedirection && NormalizeDouble(realavgspread, Digits) <= NormalizeDouble(MaxSpread * Point, Digits)) {
      if (pricedirection==-1 || pricedirection==2 ) {
         orderprice      = Ask + stopDistance;
         orderstoploss   = NormalizeDouble(orderprice - spread - StopLoss*Point, Digits);
         ordertakeprofit = NormalizeDouble(orderprice + TakeProfit*Point, Digits);

         if (GT(stopDistance, 0) || IsTesting()) {
            if (!OrderSendEx(Symbol(), OP_BUYSTOP, LotSize, orderprice, NULL, orderstoploss, ordertakeprofit, orderComment, Magic, NULL, Lime, NULL, oe)) return(catch("Trade(12)"));
            Orders.AddTicket(oe.Ticket(oe), OP_BUYSTOP, oe.OpenPrice(oe), OP_UNDEFINED, NULL);
         }
         else {
            if (!OrderSendEx(Symbol(), OP_BUY, LotSize, NULL, Slippage.Points, orderstoploss, ordertakeprofit, orderComment, Magic, NULL, Lime, NULL, oe)) return(catch("Trade(13)"));
            Orders.AddTicket(oe.Ticket(oe), OP_UNDEFINED, NULL, OP_BUY, NULL);
         }
      }
      if (pricedirection==1 || pricedirection==2) {
         orderprice      = Bid - stopDistance;
         orderstoploss   = NormalizeDouble(orderprice + spread + StopLoss*Point, Digits);
         ordertakeprofit = NormalizeDouble(orderprice - TakeProfit*Point, Digits);

         if (GT(stopDistance, 0) || IsTesting()) {
            if (!OrderSendEx(Symbol(), OP_SELLSTOP, LotSize, orderprice, NULL, orderstoploss, ordertakeprofit, orderComment, Magic, NULL, Orange, NULL, oe)) return(catch("Trade(14)"));
            Orders.AddTicket(oe.Ticket(oe), OP_SELLSTOP, oe.OpenPrice(oe), OP_UNDEFINED, NULL);
         }
         else {
            if (!OrderSendEx(Symbol(), OP_SELL, LotSize, NULL, Slippage.Points, orderstoploss, ordertakeprofit, orderComment, Magic, NULL, Orange, NULL, oe)) return(catch("Trade(15)"));
            Orders.AddTicket(oe.Ticket(oe), OP_UNDEFINED, NULL, OP_SELL, NULL);
         }
      }
   }

   // show debug messages on screen
   if (IsChart()) {
      string text = "Volatility: "+ DoubleToStr(volatility, Digits) +"   VolatilityLimit: "+ DoubleToStr(VolatilityLimit, Digits) +"   VolatilityPercentage: "+ DoubleToStr(volatilitypercentage, Digits)           + NL
                   +"PriceDirection: "+ StringSubstr("BUY NULLSELLBOTH", 4 * pricedirection + 4, 4) +"   Open orders: "+ isOpenOrder                                                                                + NL
                   + indy                                                                                                                                                                                           + NL
                   +"AvgSpread: "+ DoubleToStr(avgspread, Digits) +"   RealAvgSpread: "+ DoubleToStr(realavgspread, Digits) +"   Commission: "+ DoubleToStr(Commission, 2) +"   LotSize: "+ DoubleToStr(LotSize, 2) + NL;

      if (NormalizeDouble(realavgspread, Digits) > NormalizeDouble(MaxSpread * Point, Digits)) {
         text = text +"The current avg spread ("+ DoubleToStr(realavgspread, Digits) +") is higher than the configured MaxSpread ("+ DoubleToStr(MaxSpread * Point, Digits) +") => trading disabled";
      }
      Comment(NL, text);
   }

   return(catch("Trade(16)"));
}


/**
 * Calculate lot multiplicator for AccountCurrency. Assumes that account currency is one of the 8 majors.
 * The calculated lotsize should be multiplied with this multiplicator.
 *
 * @return double - multiplier value or NULL in case of errors
 */
double GetLotsizeMultiplier() {
   double rate = 0;
   string suffix = StrRight(Symbol(), -6);

   if      (AccountCurrency() == "USD") rate = 1;
   else if (AccountCurrency() == "EUR") rate = MarketInfo("EURUSD"+ suffix, MODE_BID);
   else if (AccountCurrency() == "GBP") rate = MarketInfo("GBPUSD"+ suffix, MODE_BID);
   else if (AccountCurrency() == "AUD") rate = MarketInfo("AUDUSD"+ suffix, MODE_BID);
   else if (AccountCurrency() == "NZD") rate = MarketInfo("NZDUSD"+ suffix, MODE_BID);
   else if (AccountCurrency() == "CHF") rate = MarketInfo("USDCHF"+ suffix, MODE_BID);
   else if (AccountCurrency() == "JPY") rate = MarketInfo("USDJPY"+ suffix, MODE_BID);
   else if (AccountCurrency() == "CAD") rate = MarketInfo("USDCAD"+ suffix, MODE_BID);

   if (!rate) return(!catch("GetLotsizeMultiplier(1)  Unable to fetch market price for account currency "+ DoubleQuoteStr(AccountCurrency()), ERR_INVALID_MARKET_DATA));
   return(1/rate);
}


/**
 * Magic Number - calculated from a sum of account number + ASCII-codes from currency pair
 *
 * @return int
 */
int CreateMagicNumber() {
   string values = "EURUSDJPYCHFCADAUDNZDGBP";
   string base   = StrLeft(Symbol(), 3);
   string quote  = StringSubstr(Symbol(), 3, 3);

   int basePos  = StringFind(values, base, 0);
   int quotePos = StringFind(values, quote, 0);

   int result = INT_MAX - AccountNumber() - basePos - quotePos;

   if (IsLogDebug()) logDebug("MagicNumber: "+ result);
   return(result);
}


/**
 * Calculate LotSize based on Equity, Risk (in %) and StopLoss in points
 */
double CalculateLotsize() {
   double lotStep      = MarketInfo(Symbol(), MODE_LOTSTEP);
   double marginPerLot = MarketInfo(Symbol(), MODE_MARGINREQUIRED);
   double minlot = MinLots;
   if (!marginPerLot) return(!catch("CalculateLotsize(1)  marginPerLot = 0", ERR_ZERO_DIVIDE));
   if (!lotStep)      return(!catch("CalculateLotsize(2)  lotStep = 0", ERR_ZERO_DIVIDE));
   double maxlot = MathMin(MathFloor(AccountEquity() * 0.98/marginPerLot/lotStep) * lotStep, MaxLots);

   int lotdigit = 0;
   if (lotStep == 1)    lotdigit = 0;
   if (lotStep == 0.1)  lotdigit = 1;
   if (lotStep == 0.01) lotdigit = 2;

   // Lot according to Risk. Don't use 100% but 98% (= 102) to avoid
   if (EQ(StopLoss, 0)) return(!catch("CalculateLotsize(3)  StopLoss = 0", ERR_ZERO_DIVIDE));
   if (!lotStep)        return(!catch("CalculateLotsize(4)  lotStep = 0", ERR_ZERO_DIVIDE));
   double lotsize = MathMin(MathFloor(Risk/102 * AccountEquity() / StopLoss / lotStep) * lotStep, MaxLots);
   lotsize *= GetLotsizeMultiplier();
   lotsize  = NormalizeDouble(lotsize, lotdigit);

   // Use manual fix LotSize, but if necessary adjust to within limits
   if (!MoneyManagement) {
      lotsize = ManualLotsize;

      if (ManualLotsize > maxlot) {
         Alert("Note: Manual LotSize is too high. It has been recalculated to maximum allowed "+ DoubleToStr(maxlot, 2));
         lotsize = maxlot;
         ManualLotsize = maxlot;
      }
      else if (ManualLotsize < minlot) {
         lotsize = minlot;
      }
   }
   return(lotsize);
}


/**
 * Recalculate a new "Risk" value if the current one is too low or too high.
 */
void RecalculateRisk() {
   string textstring = "";
   double maxlot;
   double minlot;
   double maxrisk;
   double minrisk;

   double availablemoney = AccountEquity();

   double marginPerLot = MarketInfo(Symbol(), MODE_MARGINREQUIRED);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   if (!marginPerLot) return(!catch("RecalculateRisk(1)  marginPerLot = 0", ERR_ZERO_DIVIDE));
   if (!lotStep)      return(!catch("RecalculateRisk(2)  lotStep = 0", ERR_ZERO_DIVIDE));
   maxlot = MathFloor(availablemoney/marginPerLot/lotStep) * lotStep;

   // Maximum allowed Risk by the broker according to maximul allowed Lot and Equity
   if (!availablemoney) return(!catch("RecalculateRisk(3)  availablemoney = 0", ERR_ZERO_DIVIDE));
   maxrisk = MathFloor(maxlot * (stopDistance + StopLoss) / availablemoney * 100 / 0.1) * 0.1;
   // Minimum allowed Lot by the broker
   minlot = MinLots;
   // Minimum allowed Risk by the broker according to minlots_broker
   minrisk = MathRound(minlot * StopLoss / availablemoney * 100 / 0.1) * 0.1;

   // If we use money management
   if (MoneyManagement) {
      // If Risk% is greater than the maximum risklevel the broker accept, then adjust Risk accordingly and print out changes
      if ( Risk > maxrisk ) {
         textstring = textstring + "Note: Risk has manually been set to " + DoubleToStr ( Risk, 1 ) + " but cannot be higher than " + DoubleToStr ( maxrisk, 1 ) + " according to ";
         textstring = textstring + "the broker, StopLoss and Equity. It has now been adjusted accordingly to " + DoubleToStr ( maxrisk, 1 ) + "%";
         Alert(textstring);
         Risk = maxrisk;
      }
      // If Risk% is less than the minimum risklevel the broker accept, then adjust Risk accordingly and print out changes
      if (Risk < minrisk) {
         textstring = textstring + "Note: Risk has manually been set to " + DoubleToStr ( Risk, 1 ) + " but cannot be lower than " + DoubleToStr ( minrisk, 1 ) + " according to ";
         textstring = textstring + "the broker, StopLoss, AddPriceGap and Equity. It has now been adjusted accordingly to " + DoubleToStr ( minrisk, 1 ) + "%";
         Alert(textstring);
         Risk = minrisk;
      }
   }
   // If we don't use MoneyManagement, then use fixed manual LotSize
   else {
      // Check and if necessary adjust manual LotSize to external limits
      if ( ManualLotsize < MinLots ) {
         textstring = "Manual LotSize " + DoubleToStr ( ManualLotsize, 2 ) + " cannot be less than " + DoubleToStr ( MinLots, 2 ) + ". It has now been adjusted to " + DoubleToStr ( MinLots, 2);
         ManualLotsize = MinLots;
         Alert(textstring);
      }
      if ( ManualLotsize > MaxLots ) {
         textstring = "Manual LotSize " + DoubleToStr ( ManualLotsize, 2 ) + " cannot be greater than " + DoubleToStr ( MaxLots, 2 ) + ". It has now been adjusted to " + DoubleToStr ( MinLots, 2 );
         ManualLotsize = MaxLots;
         Alert(textstring);
      }
      // Check to see that manual LotSize does not exceeds maximum allowed LotSize
      if ( ManualLotsize > maxlot ) {
         textstring = "Manual LotSize " + DoubleToStr ( ManualLotsize, 2 ) + " cannot be greater than maximum allowed LotSize. It has now been adjusted to " + DoubleToStr ( maxlot, 2 );
         ManualLotsize = maxlot;
         Alert(textstring);
      }
   }
}


/**
 * Check through all open orders
 */
void CheckOpenOrders() {
   openPositions  = 0;
   openLots       = 0;
   openSwap       = 0;
   openCommission = 0;
   openPl         = 0;

   int orders = OrdersTotal();
   for (int pos=0; pos < orders; pos++) {
      if (OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) {
         if (OrderMagicNumber()==Magic && OrderSymbol()==Symbol()) {
            openPositions++;
            openLots       += OrderLots();
            openSwap       += OrderSwap();
            openCommission += OrderCommission();
            openPl         += OrderProfit();
         }
      }
   }
   openPlNet = openSwap + openCommission + openPl;
   totalPl   = openPlNet + closedPlNet;
}


/**
 * Check through all closed orders
 */
void CheckClosedOrders() {
   closedPositions  = 0;
   closedLots       = 0;
   closedSwap       = 0;
   closedCommission = 0;
   closedPl         = 0;

   int orders = OrdersHistoryTotal();
   for (int pos=0; pos < orders; pos++) {
      if (OrderSelect(pos, SELECT_BY_POS, MODE_HISTORY)) {
         if (OrderMagicNumber()==Magic && OrderSymbol()==Symbol()) {
            closedPositions++;
            closedLots       += OrderLots();
            closedSwap       += OrderSwap();
            closedCommission += OrderCommission();
            closedPl         += OrderProfit();
         }
      }
   }
   closedPlNet = closedSwap + closedCommission + closedPl;
   totalPl     = openPlNet + closedPlNet;
}


/**
 * Printout graphics on the chart
 */
void ShowGraphInfo() {
   if (!IsChart()) return;

   string line1 = "Open:   "+ openPositions   +" positions, "+ NumberToStr(openLots, ".+")   +" lots, PL(net): "+ DoubleToStr(openPlNet, 2);
   string line2 = "Closed: "+ closedPositions +" positions, "+ NumberToStr(closedLots, ".+") +" lots, PL(net): "+ DoubleToStr(closedPlNet, 2) +", Swap: "+ DoubleToStr(closedSwap, 2) +", Commission: "+ DoubleToStr(closedCommission, 2);
   string line3 = "Total PL: "+ DoubleToStr(totalPl, 2);

   int xPos = 3;
   int yPos = 100;

   Display("line1", line1, xPos, yPos); yPos += 20;
   Display("line2", line2, xPos, yPos); yPos += 20;
   Display("line3", line3, xPos, yPos); yPos += 20;

   return(catch("ShowGraphInfo(1)"));
}


/**
 * Subroutine for displaying graphics on the chart
 */
void Display(string label, string text, int xPos, int yPos) {
   label = WindowExpertName() +"."+ label;

   if (ObjectFind(label) != 0) {
      ObjectCreate(label, OBJ_LABEL, 0, 0, 0);
   }
   ObjectSet(label, OBJPROP_CORNER,    CORNER_TOP_LEFT);
   ObjectSet(label, OBJPROP_XDISTANCE, xPos);
   ObjectSet(label, OBJPROP_YDISTANCE, yPos);
   ObjectSetText(label, text, 10, "Tahoma", Blue);
}

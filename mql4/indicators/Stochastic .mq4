/**
 * Stochastic Oscillator
 *
 *
 * The Stochastic oscillator shows the relative position of current price compared to the price range of the lookback period,
 * normalized to a value from 0 to 100. The fast Stochastic is smoothed once, the slow Stochastic is smoothed twice.
 *
 * Indicator buffers for iCustom():
 *  � Stochastic.MODE_MAIN:   indicator main line (%K or slowed %K)
 *  � Stochastic.MODE_SIGNAL: indicator signal line (%D)
 *  � Stochastic.MODE_TREND:  direction and age of the last signal
 *    - signal direction:     positive values denote a long signal (+1...+n), negative values a short signal (-1...-n)
 *    - signal age:           the absolute value is the age of the signal in bars since its occurrence
 */
#include <stddefines.mqh>
int   __InitFlags[];
int __DeinitFlags[];

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern int    MainLine.Periods      = 14;                // %K line                                                        // EURJPY: 15
extern int    SlowedMain.MA.Periods = 3;                 // slowed %K line (MA)                                            //         1
extern int    SignalLine.MA.Periods = 3;                 // %D line (MA of resulting %K)                                   //         1
extern color  MainLine.Color        = DodgerBlue;
extern color  SignalLine.Color      = Red;
extern int    MaxBars               = 10000;             // max. number of values to calculate (-1: all available)
extern string __________________________;

extern int    SignalLevel.Long      = 70;                // signal level to cross upwards to trigger a long signal         //         73
extern int    SignalLevel.Short     = 30;                // signal level to cross downwards to trigger a short signal      //         27
extern color  SignalColor.Long      = Blue;
extern color  SignalColor.Short     = Magenta;
extern int    SignalBars            = 1000;              // max. number of bars to mark signals for

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#include <core/indicator.mqh>
#include <stdfunctions.mqh>
#include <rsfLibs.mqh>

#define MODE_MAIN             Stochastic.MODE_MAIN       // 0 indicator buffer ids
#define MODE_SIGNAL           Stochastic.MODE_SIGNAL     // 1
#define MODE_TREND            Stochastic.MODE_TREND      // 2

#define PRICERANGE_HIGHLOW    0                          // use all bar prices for range calculation
#define PRICERANGE_CLOSE      1                          // use close prices for range calculation

#property indicator_separate_window
#property indicator_buffers   3                          // buffers visible in input dialog

#property indicator_color1    CLR_NONE
#property indicator_color2    CLR_NONE
#property indicator_color3    CLR_NONE

#property indicator_minimum   0
#property indicator_maximum   100

double main  [];                                         // (slowed) %K line: visible
double signal[];                                         // %D line:          visible
double trend [];                                         // trend direction:  invisible, displayed in "Data" window

int stochPeriods;
int ma1Periods;
int ma2Periods;

int signalLevelLong;
int signalLevelShort;

int maxValues;
int maxSignalBars;


/**
 * Initialization
 *
 * @return int - error status
 */
int onInit() {
   // validate inputs
   if (MainLine.Periods < 2)                             return(catch("onInit(1)  Invalid input parameter MainLine.Periods: "+ MainLine.Periods +" (min. 2)", ERR_INVALID_INPUT_PARAMETER));
   if (SlowedMain.MA.Periods < 0)                        return(catch("onInit(2)  Invalid input parameter SlowedMain.MA.Periods: "+ SlowedMain.MA.Periods, ERR_INVALID_INPUT_PARAMETER));
   if (SignalLine.MA.Periods < 0)                        return(catch("onInit(3)  Invalid input parameter SignalLine.MA.Periods: "+ SignalLine.MA.Periods, ERR_INVALID_INPUT_PARAMETER));
   stochPeriods = MainLine.Periods;
   ma1Periods   = ifInt(!SlowedMain.MA.Periods, 1, SlowedMain.MA.Periods);
   ma2Periods   = ifInt(!SignalLine.MA.Periods, 1, SignalLine.MA.Periods);
   // signal levels
   if (SignalLevel.Long  < 0 || SignalLevel.Long  > 100) return(catch("onInit(4)  Invalid input parameter SignalLevel.Long: "+ SignalLevel.Long +" (from 0..100)", ERR_INVALID_INPUT_PARAMETER));
   if (SignalLevel.Short < 0 || SignalLevel.Short > 100) return(catch("onInit(5)  Invalid input parameter SignalLevel.Short: "+ SignalLevel.Short +" (from 0..100)", ERR_INVALID_INPUT_PARAMETER));
   signalLevelLong  = SignalLevel.Long;
   signalLevelShort = SignalLevel.Short;
   // MaxBars
   if (MaxBars < -1)                                     return(catch("onInit(6)  Invalid input parameter MaxBars: "+ MaxBars, ERR_INVALID_INPUT_PARAMETER));
   maxValues = ifInt(MaxBars==-1, INT_MAX, MaxBars);
   // SignalBars
   if (SignalBars < 0)                                   return(catch("onInit(7)  Invalid input parameter SignalBars: "+ SignalBars, ERR_INVALID_INPUT_PARAMETER));
   maxSignalBars = SignalBars;
   // colors: after deserialization the terminal might turn CLR_NONE (0xFFFFFFFF) into Black (0xFF000000)
   if (MainLine.Color    == 0xFF000000) MainLine.Color    = CLR_NONE;
   if (SignalLine.Color  == 0xFF000000) SignalLine.Color  = CLR_NONE;
   if (SignalColor.Long  == 0xFF000000) SignalColor.Long  = CLR_NONE;
   if (SignalColor.Short == 0xFF000000) SignalColor.Short = CLR_NONE;

   // buffer management
   SetIndexBuffer(MODE_MAIN,   main);                    // (slowed) %K line: visible
   SetIndexBuffer(MODE_SIGNAL, signal);                  // %D line:          visible
   SetIndexBuffer(MODE_TREND,  trend);                   // trend direction:  invisible, displayed in "Data" window

   // names, labels and display options
   string sName=ifString(ma1Periods > 1, "SlowStochastic", "FastStochastic"), sMa1Periods="", sMa2Periods="";
   if (ma1Periods > 1) sMa1Periods = "-"+ ma1Periods;
   if (ma2Periods > 1) sMa2Periods = ", "+ ma2Periods;
   string indicatorName  = sName +"("+ stochPeriods + sMa1Periods + sMa2Periods +")";

   IndicatorShortName(indicatorName +"  ");              // chart subwindow and context menu
   SetIndexLabel(MODE_MAIN,   "StochMain");   if (MainLine.Color  ==CLR_NONE) SetIndexLabel(MODE_MAIN,   NULL);
   SetIndexLabel(MODE_SIGNAL, "StochSignal"); if (SignalLine.Color==CLR_NONE) SetIndexLabel(MODE_SIGNAL, NULL);
   SetIndexLabel(MODE_TREND,  "StochTrend");

   SetIndexEmptyValue(MODE_TREND, 0);
   IndicatorDigits(2);
   SetIndicatorOptions();

   return(catch("onInit(8)"));
}


/**
 * Main function
 *
 * @return int - error status
 */
int onTick() {
   // on the first tick after terminal start buffers may not yet be initialized (spurious issue)
   if (!ArraySize(main)) return(logInfo("onTick(1)  size(main) = 0", SetLastError(ERS_TERMINAL_NOT_YET_READY)));

   // reset all buffers and delete garbage behind Max.Bars before doing a full recalculation
   if (!UnchangedBars) {
      ArrayInitialize(main,   EMPTY_VALUE);
      ArrayInitialize(signal, EMPTY_VALUE);
      ArrayInitialize(trend,  0);
      SetIndicatorOptions();
   }

   // synchronize buffers with a shifted offline chart
   if (ShiftedBars > 0) {
      ShiftIndicatorBuffer(main,   Bars, ShiftedBars, EMPTY_VALUE);
      ShiftIndicatorBuffer(signal, Bars, ShiftedBars, EMPTY_VALUE);
      ShiftIndicatorBuffer(trend,  Bars, ShiftedBars, 0);
   }

   // calculate start bar
   // +------------------------------------------------------+----------------------------------------------------+
   // | Top down                                             | Bottom up                                          |
   // +------------------------------------------------------+----------------------------------------------------+
   // | RequestedBars   = 10000                              | ResultingBars   = startBar(MA2) + 1                |
   // | startBar(MA2)   = RequestedBars - 1                  | startBar(MA2)   = startBar(MA1)   - ma2Periods + 1 |
   // | startBar(MA1)   = startBar(MA2)   + ma2Periods   - 1 | startBar(MA1)   = startBar(Stoch) - ma1Periods + 1 |
   // | startBar(Stoch) = startBar(MA1)   + ma1Periods   - 1 | startBar(Stoch) = oldestBar - stochPeriods + 1     |
   // | firstBar        = startBar(Stoch) + stochPeriods - 1 | oldestBar       = AvailableBars - 1                |
   // | RequiredBars    = firstBar + 1                       | AvailableBars   = Bars                             |
   // +------------------------------------------------------+----------------------------------------------------+
   // |                 --->                                                ---^                                  |
   // +-----------------------------------------------------------------------------------------------------------+
   int requestedBars = Min(ChangedBars, maxValues);
   int resultingBars = Bars - stochPeriods - ma1Periods - ma2Periods + 3;  // max. resulting bars

   int bars          = Min(requestedBars, resultingBars);                  // actual number of bars to be updated
   int ma2StartBar   = bars - 1;
   int ma1StartBar   = ma2StartBar + ma2Periods - 1;
   int stochStartBar = ma1StartBar + ma1Periods - 1;

   // recalculate changed bars
   for (int bar=stochStartBar; bar >= 0; bar--) {
      main  [bar] = iStochastic(NULL, NULL, stochPeriods, ma2Periods, ma1Periods, MODE_SMA, PRICERANGE_HIGHLOW, MODE_MAIN, bar);
      signal[bar] = iStochastic(NULL, NULL, stochPeriods, ma2Periods, ma1Periods, MODE_SMA, PRICERANGE_HIGHLOW, MODE_SIGNAL, bar);
      trend [bar] = CalculateTrend(bar);

      if (bar < maxSignalBars) UpdateSignalMarker(bar);
   }
   return(catch("onTick(2)"));
}


/**
 * Update the signal marker for the specified bar.
 *
 * @param  int bar - bar offset
 *
 * @return bool - success status
 */
bool UpdateSignalMarker(int bar) {
   static string prefix = ""; if (!StringLen(prefix)) {
      prefix = StringConcatenate(StrTrim(ProgramName()), "[", __ExecutionContext[EC.pid], "].signal.");
   }
   string label = StringConcatenate(prefix, TimeToStr(Time[bar], TIME_DATE|TIME_MINUTES));

   if (trend[bar] == 1) {                                      // set marker long
      if (!ObjectFind(label) == 0)
         ObjectCreate(label, OBJ_ARROW, 0, NULL, NULL);
      ObjectSet(label, OBJPROP_ARROWCODE, SYMBOL_ORDEROPEN);
      ObjectSet(label, OBJPROP_COLOR,     SignalColor.Long);
      ObjectSet(label, OBJPROP_TIME1,     Time[bar]);
      ObjectSet(label, OBJPROP_PRICE1,    Close[bar]);
      //ObjectSetText(label, comment);
   }
   else if (trend[bar] == -1) {                                // set marker short
      if (!ObjectFind(label) == 0)
         ObjectCreate(label, OBJ_ARROW, 0, NULL, NULL);
      ObjectSet(label, OBJPROP_ARROWCODE, SYMBOL_ORDEROPEN);
      ObjectSet(label, OBJPROP_COLOR,     SignalColor.Short);
      ObjectSet(label, OBJPROP_TIME1,     Time[bar]);
      ObjectSet(label, OBJPROP_PRICE1,    Close[bar]);
      //ObjectSetText(label, comment);
   }
   else if (ObjectFind(label) == 0) {                          // unset an existing marker
      ObjectDelete(label);
   }

   return(!catch("UpdateSignalMarker(1)"));
}


/**
 * Calculate the trend for the specified bar.
 *
 * @param  int bar - bar offset
 *
 * @return int
 */
int CalculateTrend(int bar) {
   int    prevTrend = trend[bar+1], newTrend = 0;
   double curValue  = signal[bar];
   double prevValue = signal[bar+1];

   if (prevTrend > 0) {
      // existing long trend
      if (curValue <= signalLevelShort) newTrend = -1;                              // trend change short
      else                              newTrend = prevTrend + Sign(prevTrend);     // trend continuation
   }
   else if (prevTrend < 0) {
      // existing short trend
      if (curValue >= signalLevelLong) newTrend = 1;                                // trend change long
      else                             newTrend = prevTrend + Sign(prevTrend);      // trend continuation
   }
   else {
      // no trend yet
      if (curValue >= signalLevelLong) {
         for (int i=bar+1; i < Bars; i++) {
            if (signal[i] == EMPTY_VALUE) break;
            if (signal[i] <= signalLevelShort) {                                    // look for a previous cross downward
               newTrend = 1;                                                        // found: first trend long
               break;
            }
         }
      }
      else if (curValue <= signalLevelShort) {
         for (i=bar+1; i < Bars; i++) {
            if (signal[i] == EMPTY_VALUE) break;
            if (signal[i] >= signalLevelLong) {                                     // look for a previous cross upward
               newTrend = -1;                                                       // found: first trend short
               break;
            }
         }
      }
   }
   return(newTrend);
}


/**
 * Workaround for various terminal bugs when setting indicator options. Usually options are set in init(). However after
 * recompilation options must be set in start() to not be ignored.
 */
void SetIndicatorOptions() {
   int signalType = ifInt(SignalLine.Color==CLR_NONE, DRAW_NONE, DRAW_LINE);

   SetIndexStyle(MODE_MAIN,   DRAW_LINE,  EMPTY, EMPTY, MainLine.Color);
   SetIndexStyle(MODE_SIGNAL, signalType, EMPTY, EMPTY, SignalLine.Color);
   SetIndexStyle(MODE_TREND,  DRAW_NONE,  EMPTY, EMPTY, CLR_NONE);

   SetLevelValue(0, signalLevelLong);
   SetLevelValue(1, signalLevelShort);
}


/**
 * Return a string representation of the input parameters (for logging purposes).
 *
 * @return string
 */
string InputsToStr() {
   return(StringConcatenate("MainLine.Periods=",      MainLine.Periods,              ";"+ NL,
                            "SlowedMain.MA.Periods=", SlowedMain.MA.Periods,         ";"+ NL,
                            "SignalLine.MA.Periods=", SignalLine.MA.Periods,         ";"+ NL,
                            "MainLine.Color=",        ColorToStr(MainLine.Color),    ";"+ NL,
                            "SignalLine.Color=",      ColorToStr(SignalLine.Color),  ";"+ NL,
                            "MaxBars=",               MaxBars,                       ";"+ NL,
                            "SignalLevel.Long=",      SignalLevel.Long,              ";"+ NL,
                            "SignalLevel.Short=",     SignalLevel.Short,             ";"+ NL,
                            "SignalColor.Long=",      ColorToStr(SignalColor.Long),  ";"+ NL,
                            "SignalColor.Short=",     ColorToStr(SignalColor.Short), ";"+ NL,
                            "SignalBars=",            SignalBars,                    ";")
   );
}

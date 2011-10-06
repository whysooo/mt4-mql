/**
 * FXTradePro Semi-Martingale EA
 *
 * @see FXTradePro Strategy:     http://www.forexfactory.com/showthread.php?t=43221
 *      FXTradePro Journal:      http://www.forexfactory.com/showthread.php?t=82544
 *      FXTradePro Swing Trades: http://www.forexfactory.com/showthread.php?t=87564
 *
 *      PowerSM EA:              http://www.forexfactory.com/showthread.php?t=75394
 *      PowerSM Journal:         http://www.forexfactory.com/showthread.php?t=159789
 *
 * ---------------------------------------------------------------------------------
 *
 *  Probleme:
 *  ---------
 *  - Verh�ltnis Spread/StopLoss: hohe Spreads machen den Einsatz teilweise unm�glich
 *  - Verh�ltnis Tagesvolatilit�t/Spread: teilweise wurde innerhalb von 10 Sekunden der n�chste Level getriggert
 *  - gleiche Volatilit�t bedeutet gleicher StopLoss, unabh�ngig vom variablen Spread
 *
 *
 *  Voraussetzungen f�r Produktivbetrieb:
 *  -------------------------------------
 *  - Breakeven berechnen und anzeigen
 *  - parallele Verwaltung mehrerer Instanzen erm�glichen (st�ndige sich �berschneidende Instanzen)
 *  - Sequenzl�nge ver�nderbar machen (sequenceLength aus MagicNumber entfernen)
 *  - f�r alle Signalberechnungen statt Bid/Ask MedianPrice verwenden (die tats�chlich erzielten Entry-Preise sind sekund�r)
 *  - Hedges m�ssen sofort aufgel�st werden (MT4-Equity- und -Marginberechnung mit offenen Hedges ist fehlerhaft)
 *  - ggf. mu� statt nach STATUS_DISABLED nach STATUS_MONITORING gewechselt werden
 *  - Sicherheitsabfrage, wenn nach �nderung von TakeProfit sofort FinishSequence() getriggert wird
 *  - Sicherheitsabfrage, wenn nach �nderung der Konfiguration sofort Trade getriggert wird
 *  - bei STATUS_DISABLED mu� ein REASON_RECOMPILE sich den alten Status merken
 *  - Heartbeat-Order einrichten
 *  - Heartbeat-Order mu� signalisieren, wenn die Konfiguration sich ge�ndert hat => erneuter Download vom Server
 *  - OrderMultiClose.Flatten() mu� pr�fen, ob das Hedge-Volumen mit MarketInfo(MODE_MINLOT) kollidiert
 *  - Visualisierung der gesamten Sequenz
 *  - Visualisierung des Entry.Limits implementieren
 *
 *
 *  TODO:
 *  -----
 *  - mehrere EA's schalten sich gegenseitig ab, wenn sie ohne Lock SwitchExperts(true) aufrufen
 *  - Input-Parameter m�ssen �nderbar sein, ohne den EA anzuhalten
 *  - NumberToStr() reparieren: positives Vorzeichen, 1000-Trennzeichen
 *  - EA mu� automatisch in beliebige Templates hineingeladen werden k�nnen
 *  - die Konfiguration einer gefundenen Sequenz mu� automatisch in den Input-Dialog geladen werden
 *  - UpdateProfitLoss(): Commission-Berechnung an OrderCloseBy() anpassen
 *  - bei fehlender Konfiguration m�ssen die Daten aus der laufenden Instanz weitm�glichst ausgelesen werden
 *  - Symbolwechsel (REASON_CHARTCHANGE) und Accountwechsel (REASON_ACCOUNT) abfangen
 *  - gesamte Sequenz vorher auf [TradeserverLimits] pr�fen
 *  - einzelne Tradefunktionen vorher auf [TradeserverLimits] pr�fen lassen
 *  - Spread�nderungen bei Limit-Checks ber�cksichtigen
 *  - StopLoss -> Breakeven und TakeProfit -> Breakeven implementieren
 *  - SMS-Benachrichtigungen implementieren
 *  - Equity-Chart der laufenden Sequenz implementieren
 *  - ShowStatus() �bersichtlicher gestalten (Textlabel statt Comment())
 */
#include <stdlib.mqh>
#include <win32api.mqh>


#define STATUS_UNDEFINED                 0
#define STATUS_WAITING                   1
#define STATUS_PROGRESSING               2
#define STATUS_FINISHED                  3
#define STATUS_DISABLED                  4

#define ENTRYTYPE_UNDEFINED              0
#define ENTRYTYPE_LIMIT                  1
#define ENTRYTYPE_BANDS                  2
#define ENTRYTYPE_ENVELOPES              3

#define ENTRYDIRECTION_UNDEFINED        -1
#define ENTRYDIRECTION_LONG        OP_LONG            // 0
#define ENTRYDIRECTION_SHORT      OP_SHORT            // 1
#define ENTRYDIRECTION_LONGSHORT         2


int EA.uniqueId = 101;                                // eindeutige ID der Strategie (10 Bits: Bereich 0-1023)


//////////////////////////////////////////////////////////////// Externe Parameter ////////////////////////////////////////////////////////////////

extern string _1____________________________ = "==== Entry Options ===================";
extern string Entry.Condition                = "BollingerBands(35xM15, EMA, 2.0)";        // {LimitValue} | [Bollinger]Bands(35xM5,EMA,2.0) | Env[elopes](75xM15,ALMA,2.0)
extern string Entry.Direction                = "";                                        // long | short

extern string _2____________________________ = "==== TP and SL Settings ==============";
extern int    TakeProfit                     = 50;
extern int    StopLoss                       = 12;

extern string _3____________________________ = "==== Lotsizes =======================";
extern double Lotsize.Level.1                = 0.1;
extern double Lotsize.Level.2                = 0.2;
extern double Lotsize.Level.3                = 0.3;
extern double Lotsize.Level.4                = 0.4;
extern double Lotsize.Level.5                = 0.5;
extern double Lotsize.Level.6                = 0.6;
extern double Lotsize.Level.7                = 0.7;

extern string _4____________________________ = "==== Sequence to Manage =============";
extern string Sequence.ID                    = "";

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


string   intern.Entry.Condition;                      // Die Input-Parameter werden bei REASON_CHARTCHANGE mit den Originalwerten �berschrieben, sie
string   intern.Entry.Direction;                      // werden in intern.* zwischengespeichert und nach REASON_CHARTCHANGE daraus restauriert.
int      intern.TakeProfit;
int      intern.StopLoss;
double   intern.Lotsize.Level.1;
double   intern.Lotsize.Level.2;
double   intern.Lotsize.Level.3;
double   intern.Lotsize.Level.4;
double   intern.Lotsize.Level.5;
double   intern.Lotsize.Level.6;
double   intern.Lotsize.Level.7;
string   intern.Sequence.ID;
bool     intern;                                      // Statusflag: TRUE = zwischengespeicherte Werte vorhanden


double   Pip;
int      PipDigits;
int      PipPoints;
double   TickSize;
string   PriceFormat;

int      status            = STATUS_UNDEFINED;
bool     firstTick         = true;

int      Entry.type        = ENTRYTYPE_UNDEFINED;
int      Entry.iDirection  = ENTRYDIRECTION_UNDEFINED;
int      Entry.MA.periods,   Entry.MA.periods.orig;
int      Entry.MA.timeframe, Entry.MA.timeframe.orig;
int      Entry.MA.method;
double   Entry.MA.deviation;
double   Entry.limit;
double   Entry.lastBid;

int      sequenceId;
int      sequenceLength;
int      progressionLevel;

int      levels.ticket    [];                         // Ticket des Levels
int      levels.type      [];                         // Trade-Direction
double   levels.lots      [], effectiveLots;          // konfigurierte Lotsize der einzelnen Level und aktuelle effektive Gesamtlotsize
double   levels.openLots  [];                         // aktuelle Order-Lotsize (inklusive evt. Hedges)
double   levels.openPrice [], last.closePrice;
datetime levels.openTime  [];
datetime levels.closeTime [];                         // Unterscheidung zwischen offenen und geschlossenen Positionen

double   levels.swap      [], levels.openSwap      [], levels.closedSwap      [], all.swaps;
double   levels.commission[], levels.openCommission[], levels.closedCommission[], all.commissions;
double   levels.profit    [], levels.openProfit    [], levels.closedProfit    [], all.profits;

double   levels.maxProfit  [];                        // maximal m�glicher P/L der Level, wird nur in ShowStatus() verwendet
double   levels.maxDrawdown[];
double   levels.breakeven  [];

bool     levels.lots.changed = true;


/**
 * Initialisierung
 *
 * @return int - Fehlerstatus
 */
int init() {
   init = true; init_error = NO_ERROR; __SCRIPT__ = WindowExpertName();
   stdlib_init(__SCRIPT__);

   PipDigits   = Digits & (~1);
   PipPoints   = MathPow(10, Digits-PipDigits) +0.1;                 // (int) double
   Pip         = 1/MathPow(10, PipDigits);
   TickSize    = MarketInfo(Symbol(), MODE_TICKSIZE);
   PriceFormat = "."+ PipDigits + ifString(Digits==PipDigits, "", "'");

   int error = GetLastError();
   if (error!=NO_ERROR || TickSize < 0.000009) {
      error = catch("init(1)   TickSize = "+ NumberToStr(TickSize, ".+"), ifInt(error==NO_ERROR, ERR_INVALID_MARKETINFO, error));
      ShowStatus();
      return(error);
   }


   // (1) Zuerst sequenceId, dann Konfiguration, dann Sequenz restaurieren: wir unterscheiden 4 grunds�tzliche init()-Szenarien
   //
   // (1.1) Neustart des EA   (keine internen Daten, externe Referenz evt. vorhanden)
   // (1.2) Recompilation     (keine internen Daten, externe Referenz immer vorhanden)
   // (1.3) Parameter�nderung (alle internen Daten vorhanden, externe Referenz unn�tig)
   // (1.4) Timeframe-Wechsel (alle internen Daten vorhanden, externe Referenz unn�tig)

   // (1) sind keine internen Daten vorhanden, gelten Szenario 1.1 oder 1.2
   if (sequenceId == 0) {

      // (1.1) Neustart ---------------------------------------------------------------------------------------------------------------------------------------
      if (UninitializeReason() != REASON_RECOMPILE) {
         if (IsSpecificSequenceId()) {                               // Zuerst eine ausdr�cklich angegebene Sequenz-ID auswerten,...
            if (ValidateSpecificSequenceId())
               if (RestoreConfiguration())
                  if (ValidateConfiguration())
                     ReadSequence(sequenceId);
         }
         else if (RestoreHiddenSequenceId()) {                       // ...dann eine versteckt gespeicherte Sequenz-ID restaurieren,...
            if (RestoreConfiguration())
               if (ValidateConfiguration())
                  ReadSequence(sequenceId);
         }
         else if (FindRunningSequence()) {                           // ...dann ID aus laufender Sequenz restaurieren...
            if (RestoreConfiguration())
               if (ValidateConfiguration())
                  ReadSequence(sequenceId);
         }
         else if (ValidateConfiguration()) {                         // ...und zum Schlu� eine neue Sequenz anlegen.
            sequenceId = CreateSequenceId();
            if (Entry.type!=ENTRYTYPE_LIMIT || NE(Entry.limit, 0))   // Bei ENTRYTYPE_LIMIT und Entry.Limit=0 erfolgt sofortiger Einstieg, in diesem Fall
               SaveConfiguration();                                  // wird die Konfiguration erst nach Sicherheitsabfrage in StartSequence() gespeichert.
            ResizeArrays(sequenceLength);
            UpdateMaxProfitLoss();
            VisualizeSequence();
         }
      }

      // (1.2) Recompilation ----------------------------------------------------------------------------------------------------------------------------------
      else if (RestoreHiddenSequenceId()) {                          // externe Referenz immer vorhanden: restaurieren und validieren
         if (RestoreConfiguration())
            if (ValidateConfiguration())
               ReadSequence(sequenceId);
      }
      else catch("init(2)   no hidden sequence id found after REASON_RECOMPILE", ERR_RUNTIME_ERROR);
   }

   // (1.3) Parameter�nderung ---------------------------------------------------------------------------------------------------------------------------------
   else if (UninitializeReason() == REASON_PARAMETERS) {             // Alle internen Daten sind vorhanden.
      if (ValidateConfiguration()) {
         SaveConfiguration();

         // TODO: die manuelle Sequence.ID kann ge�ndert worden sein

         UpdateBreakeven();                                          // nur zwingend n�tig, wenn die Lotsizes ge�ndert wurden
         UpdateMaxProfitLoss();                                      // nur zwingend n�tig, wenn die Limits oder die Lotsizes ge�ndert wurden
         VisualizeSequence();
      }
   }

   // (1.4) Timeframe- oder Symbolwechsel ---------------------------------------------------------------------------------------------------------------------
   else if (UninitializeReason() == REASON_CHARTCHANGE) {
      Entry.Condition = intern.Entry.Condition;                      // Alle internen Daten sind vorhanden, es werden nur die nicht-statischen
      Entry.Direction = intern.Entry.Direction;                      // Inputvariablen restauriert.
      TakeProfit      = intern.TakeProfit;
      StopLoss        = intern.StopLoss;
      Lotsize.Level.1 = intern.Lotsize.Level.1;
      Lotsize.Level.2 = intern.Lotsize.Level.2;
      Lotsize.Level.3 = intern.Lotsize.Level.3;
      Lotsize.Level.4 = intern.Lotsize.Level.4;
      Lotsize.Level.5 = intern.Lotsize.Level.5;
      Lotsize.Level.6 = intern.Lotsize.Level.6;
      Lotsize.Level.7 = intern.Lotsize.Level.7;
      Sequence.ID     = intern.Sequence.ID;
   }

   // ---------------------------------------------------------------------------------------------------------------------------------------------------------
   else catch("init(3)   unknown init() scenario", ERR_RUNTIME_ERROR);


   // (6) aktuellen Status bestimmen
   if (init_error != NO_ERROR)     status = STATUS_DISABLED;
   if (status != STATUS_DISABLED) {
      if (progressionLevel > 0) {
         if (NE(effectiveLots, 0)) status = STATUS_PROGRESSING;
         else                      status = STATUS_FINISHED;
      }
   }


   // (7) Status anzeigen
   ShowStatus();
   if (init_error != NO_ERROR)
      return(init_error);


   // (8) ggf. EA's aktivieren
   int reasons1[] = { REASON_REMOVE, REASON_CHARTCLOSE, REASON_APPEXIT };
   if (!IsExpertEnabled()) /*&&*/ if (IntInArray(UninitializeReason(), reasons1))
      SwitchExperts(true);                                        // TODO: Bug, wenn mehrere EA's den EA-Modus gleichzeitig einschalten


   // (9) nach Reload nicht auf den n�chsten Tick warten (nur bei REASON_CHARTCHANGE oder REASON_ACCOUNT)
   int reasons2[] = { REASON_REMOVE, REASON_CHARTCLOSE, REASON_APPEXIT, REASON_PARAMETERS, REASON_RECOMPILE };
   if (IntInArray(UninitializeReason(), reasons2))
      SendTick(false);

   return(catch("init(4)"));
}


/**
 * Deinitialisierung
 *
 * @return int - Fehlerstatus
 */
int deinit() {
   // vor Recompile aktuellen Status extern speichern
   if (UninitializeReason() == REASON_RECOMPILE) {
      PersistIdForRecompile();
   }
   else {
      // Input-Parameter sind nicht statisch: f�r's n�chste init() intern speichern
      intern.Entry.Condition = Entry.Condition;
      intern.Entry.Direction = Entry.Direction;
      intern.TakeProfit      = TakeProfit;
      intern.StopLoss        = StopLoss;
      intern.Lotsize.Level.1 = Lotsize.Level.1;
      intern.Lotsize.Level.2 = Lotsize.Level.2;
      intern.Lotsize.Level.3 = Lotsize.Level.3;
      intern.Lotsize.Level.4 = Lotsize.Level.4;
      intern.Lotsize.Level.5 = Lotsize.Level.5;
      intern.Lotsize.Level.6 = Lotsize.Level.6;
      intern.Lotsize.Level.7 = Lotsize.Level.7;
      intern.Sequence.ID     = Sequence.ID;
      intern                 = true;                                    // Flag zur sp�teren Erkennung in init() setzen
   }
   return(catch("deinit()"));
}


/**
 * Main-Funktion
 *
 * @return int - Fehlerstatus
 */
int start() {
   Tick++;
   init = false;
   if (init_error != NO_ERROR) return(init_error);
   if (last_error != NO_ERROR) return(last_error);
   // --------------------------------------------

   if (status==STATUS_FINISHED || status==STATUS_DISABLED)
      return(last_error);


   if (UpdateProfitLoss()) {
      if (progressionLevel == 0) {
         if (!IsEntrySignal())                  status = STATUS_WAITING;
         else                                   StartSequence();              // kein Limit definiert oder Limit erreicht
      }
      else if (IsStopLossReached()) {
         if (progressionLevel < sequenceLength) IncreaseProgression();
         else                                   FinishSequence();
      }
      else if (IsProfitTargetReached())         FinishSequence();
   }
   ShowStatus();

   firstTick = false;

   return(catch("start()"));
}


/**
 * Ob die aktuell selektierte Order zu dieser Strategie geh�rt. Wird eine Sequenz-ID angegeben, wird zus�tzlich �berpr�ft,
 * ob die Order zur angegebenen Sequenz geh�rt.
 *
 * @param  int sequenceId - ID einer Sequenz (default: NULL)
 *
 * @return bool
 */
bool IsMyOrder(int sequenceId = NULL) {
   if (OrderSymbol() == Symbol()) {
      if (OrderMagicNumber() >> 22 == EA.uniqueId) {
         if (sequenceId == NULL)
            return(true);
         return(sequenceId == OrderMagicNumber() >> 8 & 0x3FFF);     // 14 Bits (Bits 9-22) => sequenceId
      }
   }
   return(false);
}


/**
 * Generiert eine neue Sequenz-ID.
 *
 * @return int - Sequenz-ID im Bereich 1000-16383 (14 bit)
 */
int CreateSequenceId() {
   MathSrand(GetTickCount());

   int id;
   while (id < 2000) {                                               // Das abschlie�ende Shiften halbiert den Wert und wir wollen mindestens eine 4-stellige ID haben.
      id = MathRand();
   }
   return(id >> 1);
}


/**
 * Generiert aus den internen Daten einen Wert f�r OrderMagicNumber().
 *
 * @return int - MagicNumber oder -1, falls ein Fehler auftrat
 */
int CreateMagicNumber() {
   if (sequenceId < 1000) {
      catch("CreateMagicNumber()   illegal sequenceId = "+ sequenceId, ERR_RUNTIME_ERROR);
      return(-1);
   }

   int ea       = EA.uniqueId & 0x3FF << 22;                         // 10 bit (Bits gr��er 10 l�schen und auf 32 Bit erweitern) | in MagicNumber: Bits 23-32
   int sequence = sequenceId & 0x3FFF << 8;                          // 14 bit (Bits gr��er 14 l�schen und auf 22 Bit erweitern  | in MagicNumber: Bits  9-22
   int length   = sequenceLength & 0xF << 4;                         //  4 bit (Bits gr��er 4 l�schen und auf 8 bit erweitern)   | in MagicNumber: Bits  5-8
   int level    = progressionLevel & 0xF;                            //  4 bit (Bits gr��er 4 l�schen)                           | in MagicNumber: Bits  1-4

   return(ea + sequence + length + level);
}


#include <bollingerbandCrossing.mqh>


/**
 * Signalgeber f�r StartSequence(). Wurde ein Limit von 0 angegeben, gibt die Funktion TRUE zur�ck und die neue Sequenz wird mit dem
 * n�chsten Tick gestartet.
 *
 * @return bool - ob die konfigurierte Entry.Condition erf�llt ist
 */
bool IsEntrySignal() {
   double event[3];
   int    crossing;


   switch (Entry.type) {
      // ---------------------------------------------------------------------------------------------------------------------------------
      case ENTRYTYPE_LIMIT:
         if (EQ(Entry.limit, 0))                                        // kein Limit definiert
            return(true);

         // Das Limit ist erreicht, wenn der Bid-Preis es seit dem letzten Tick ber�hrt oder gekreuzt hat.
         if (EQ(Bid, Entry.limit) || EQ(Entry.lastBid, Entry.limit)) {  // Bid liegt oder lag beim letzten Tick exakt auf dem Limit
            //debug(StringConcatenate("IsEntrySignal()   Bid=", NumberToStr(Bid, PriceFormat), " liegt genau auf dem Entry.limit=", NumberToStr(Entry.limit, PriceFormat)));
            Entry.lastBid = Entry.limit;                                // Tritt w�hrend der weiteren Verarbeitung des Ticks ein behandelbarer Fehler auf, wird durch
            return(true);                                               // Entry.LastPrice = Entry.Limit das Limit, einmal getriggert, nachfolgend immer wieder getriggert.
         }

         static bool lastBid.init = false;

         if (EQ(Entry.lastBid, 0)) {                                    // Entry.lastBid mu� initialisiert sein => ersten Aufruf �berspringen und Status merken,
            lastBid.init = true;                                        // um firstTick bei erstem tats�chlichen Test gegen Entry.lastBid auf TRUE zur�ckzusetzen
         }
         else {
            if (LT(Entry.lastBid, Entry.limit)) {
               if (GT(Bid, Entry.limit)) {                              // Bid hat Limit von unten nach oben gekreuzt
                  //debug(StringConcatenate("IsEntrySignal()   Tick hat Entry.limit=", NumberToStr(Entry.limit, PriceFormat), " von unten (lastBid=", NumberToStr(Entry.lastBid, PriceFormat), ") nach oben (Bid=", NumberToStr(Bid, PriceFormat), ") gekreuzt"));
                  Entry.lastBid = Entry.limit;
                  return(true);
               }
            }
            else if (LT(Bid, Entry.limit)) {                            // Bid hat Limit von oben nach unten gekreuzt
               //debug(StringConcatenate("IsEntrySignal()   Tick hat Entry.limit=", NumberToStr(Entry.limit, PriceFormat), " von oben (lastBid=", NumberToStr(Entry.lastBid, PriceFormat), ") nach unten (Bid=", NumberToStr(Bid, PriceFormat), ") gekreuzt"));
               Entry.lastBid = Entry.limit;
               return(true);
            }
            if (lastBid.init) {
               lastBid.init = false;
               firstTick    = true;                                     // firstTick nach erstem tats�chlichen Test gegen Entry.lastBid auf TRUE zur�ckzusetzen
            }
         }
         Entry.lastBid = Bid;
         return(false);

      // ---------------------------------------------------------------------------------------------------------------------------------
      case ENTRYTYPE_BANDS:                                             // EventListener aufrufen und ggf. Event signalisieren
         if (EventListener.BandsCrossing(Entry.MA.periods, Entry.MA.timeframe, Entry.MA.method, Entry.MA.deviation, event, DeepSkyBlue)) {
            crossing         = event[CROSSING_TYPE] +0.1;               // (int) double
            Entry.limit      = ifDouble(crossing==CROSSING_LOW, event[CROSSING_LOW_VALUE], event[CROSSING_HIGH_VALUE]);
            Entry.iDirection = ifInt(crossing==CROSSING_LOW, OP_SELL, OP_BUY);
            //debug(StringConcatenate("IsEntrySignal()   new ", ifString(crossing==CROSSING_LOW, "low", "high"), " bands crossing at ", TimeToStr(TimeCurrent(), TIME_DATE|TIME_MINUTES|TIME_SECONDS), ifString(crossing==CROSSING_LOW, "  <= ", "  => "), NumberToStr(Entry.limit, PriceFormat)));
            return(true);
         }
         else {
            crossing = event[CROSSING_TYPE] +0.1;                       // (int) double
            if (crossing == CROSSING_UNKNOWN) {
               Entry.limit      = 0.0;
               Entry.iDirection = ENTRYDIRECTION_UNDEFINED;
            }
            else {
               Entry.limit      = ifDouble(crossing==CROSSING_LOW, event[CROSSING_HIGH_VALUE], event[CROSSING_LOW_VALUE]);
               Entry.iDirection = ifInt(crossing==CROSSING_LOW, OP_BUY, OP_SELL);
            }
         }
         return(false);

      // ---------------------------------------------------------------------------------------------------------------------------------
      case ENTRYTYPE_ENVELOPES:                                         // EventListener aufrufen und ggf. Event signalisieren
         if (EventListener.EnvelopesCrossing(Entry.MA.periods, Entry.MA.timeframe, Entry.MA.method, Entry.MA.deviation, event, DeepSkyBlue)) {
            crossing         = event[CROSSING_TYPE] +0.1;               // (int) double
            Entry.limit      = ifDouble(crossing==CROSSING_LOW, event[CROSSING_LOW_VALUE], event[CROSSING_HIGH_VALUE]);
            Entry.iDirection = ifInt(crossing==CROSSING_LOW, OP_SELL, OP_BUY);
            //debug(StringConcatenate("IsEntrySignal()   new ", ifString(crossing==CROSSING_LOW, "low", "high"), " envelopes crossing at ", TimeToStr(TimeCurrent(), TIME_DATE|TIME_MINUTES|TIME_SECONDS), ifString(crossing==CROSSING_LOW, "  <= ", "  => "), NumberToStr(Entry.limit, PriceFormat)));
            return(true);
         }
         else {
            crossing = event[CROSSING_TYPE] +0.1;                       // (int) double
            if (crossing == CROSSING_UNKNOWN) {
               Entry.limit      = 0.0;
               Entry.iDirection = ENTRYDIRECTION_UNDEFINED;
            }
            else {
               Entry.limit      = ifDouble(crossing==CROSSING_LOW, event[CROSSING_HIGH_VALUE], event[CROSSING_LOW_VALUE]);
               Entry.iDirection = ifInt(crossing==CROSSING_LOW, OP_BUY, OP_SELL);
            }
         }
         return(false);

      // ---------------------------------------------------------------------------------------------------------------------------------
      default:
         return(catch("IsEntrySignal()   illegal Entry.type = "+ Entry.type, ERR_RUNTIME_ERROR)==NO_ERROR);
   }
   return(false);
}


/**
 * Ob der konfigurierte StopLoss erreicht oder �berschritten wurde.
 *
 * @return bool
 */
bool IsStopLossReached() {
   int    last           = progressionLevel-1;
   int    last.type      = levels.type     [last];
   double last.openPrice = levels.openPrice[last];

   double last.price, last.loss;

   static string last.directions[] = {"long", "short"};
   static string last.priceNames[] = {"Bid" , "Ask"  };

   if (last.type == OP_BUY) {
      last.price = Bid;
      last.loss  = last.openPrice-Bid;
   }
   else {
      last.price = Ask;
      last.loss  = Ask-last.openPrice;
   }

   if (GT(last.loss, StopLoss*Pip)) {
      //debug(StringConcatenate("IsStopLossReached()   Stoploss f�r ", last.directions[last.type], " position erreicht: ", DoubleToStr(last.loss/Pip, Digits-PipDigits), " pip (openPrice=", NumberToStr(last.openPrice, PriceFormat), ", ", last.priceNames[last.type], "=", NumberToStr(last.price, PriceFormat), ")"));
      return(true);
   }
   return(false);
}


/**
 * Ob der konfigurierte TakeProfit-Level erreicht oder �berschritten wurde.
 *
 * @return bool
 */
bool IsProfitTargetReached() {
   int    last           = progressionLevel-1;
   int    last.type      = levels.type     [last];
   double last.openPrice = levels.openPrice[last];

   double last.price, last.profit;

   static string last.directions[] = { "long", "short" };
   static string last.priceNames[] = { "Bid" , "Ask"   };

   if (last.type == OP_BUY) {
      last.price  = Bid;
      last.profit = Bid-last.openPrice;
   }
   else {
      last.price  = Ask;
      last.profit = last.openPrice-Ask;
   }

   if (GE(last.profit, TakeProfit*Pip)) {
      //debug(StringConcatenate("IsProfitTargetReached()   Profit target f�r ", last.directions[last.type], " position erreicht: ", DoubleToStr(last.profit/Pip, Digits-PipDigits), " pip (openPrice=", NumberToStr(last.openPrice, PriceFormat), ", ", last.priceNames[last.type], "=", NumberToStr(last.price, PriceFormat), ")"));
      return(true);
   }
   return(false);
}


/**
 * Sucht die erste laufende Sequenz und restauriert die interne Variable sequenceId.
 *
 * @return bool - ob eine Sequenz-ID gefunden und restauriert wurde
 */
bool FindRunningSequence() {
   // offene Positionen einlesen
   for (int i=OrdersTotal()-1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))               // FALSE: w�hrend des Auslesens wird in einem anderen Thread eine offene Order entfernt
         continue;

      if (IsMyOrder()) {
         sequenceId = OrderMagicNumber() >> 8 & 0x3FFF;              // 14 Bits (Bits 9-22) => sequenceId
         catch("FindRunningSequence(1)");
         return(true);
      }
   }

   catch("FindRunningSequence(2)");
   return(false);
}


/**
 * Liest die angegebene Sequenz komplett neu ein.
 *
 * @param  int id - einzulesende Sequenz
 *
 * @return bool - Erfolgsstatus
 */
bool ReadSequence(int id) {
   if (id < 1000)
      return(catch("ReadSequence(1)   illegal parameter id = "+ id, ERR_INVALID_FUNCTION_PARAMVALUE)==NO_ERROR);

   int    orig.Entry.iDirection = Entry.iDirection;
   double orig.Entry.lastBid    = Entry.lastBid;
   int    orig.status           = status;

   ResetAll();
   sequenceId = id;

   bool openPositions = false;


   // (1) offene Positionen einlesen
   for (int i=OrdersTotal()-1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))               // FALSE: w�hrend des Auslesens wird in einem anderen Thread eine offene Order entfernt
         continue;

      if (IsMyOrder(sequenceId)) {
         openPositions = true;
         if (sequenceLength == 0) {
            sequenceLength = OrderMagicNumber() >> 4 & 0xF;          //  4 Bits (Bits 5-8 ) => sequenceLength
            ResizeArrays(sequenceLength);
         }
         if (OrderType() > OP_SELL)                                  // Nicht-Trades �berspringen
            continue;

         int level = OrderMagicNumber() & 0xF;                       //  4 Bits (Bits 1-4)  => progressionLevel
         if (level > sequenceLength) return(catch("ReadSequence(2)   illegal sequence state, progression level "+ level +" of ticket #"+ OrderTicket() +" exceeds the value of sequenceLength = "+ sequenceLength, ERR_RUNTIME_ERROR)==NO_ERROR);

         if (level > progressionLevel)
            progressionLevel = level;
         level--;

         levels.ticket        [level] = OrderTicket();
         levels.type          [level] = OrderType();
         levels.openLots      [level] = OrderLots();
         levels.openPrice     [level] = OrderOpenPrice();
         levels.openTime      [level] = OrderOpenTime();

         levels.openSwap      [level] = OrderSwap();
         levels.openCommission[level] = OrderCommission();
         levels.openProfit    [level] = OrderProfit();

         if (OrderType() == OP_BUY) effectiveLots += OrderLots();    // effektive Lotsize berechnen
         else                       effectiveLots -= OrderLots();
      }
   }


   // (2) geschlossene Positionen einlesen
   last.closePrice = 0;
   bool retry = true;

   while (retry) {                                                   // Endlosschleife, bis ausreichend History-Daten verf�gbar sind
      int n, closedTickets=OrdersHistoryTotal();
      int      hist.tickets     []; ArrayResize(hist.tickets     , closedTickets);
      int      hist.types       []; ArrayResize(hist.types       , closedTickets);
      double   hist.lots        []; ArrayResize(hist.lots        , closedTickets);
      double   hist.openPrices  []; ArrayResize(hist.openPrices  , closedTickets);
      datetime hist.openTimes   []; ArrayResize(hist.openTimes   , closedTickets);
      double   hist.closePrices []; ArrayResize(hist.closePrices , closedTickets);
      datetime hist.closeTimes  []; ArrayResize(hist.closeTimes  , closedTickets);
      double   hist.swaps       []; ArrayResize(hist.swaps       , closedTickets);
      double   hist.commissions []; ArrayResize(hist.commissions , closedTickets);
      double   hist.profits     []; ArrayResize(hist.profits     , closedTickets);
      int      hist.magicNumbers[]; ArrayResize(hist.magicNumbers, closedTickets);
      string   hist.comments    []; ArrayResize(hist.comments    , closedTickets);

      for (i=0, n=0; i < closedTickets; i++) {
         if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))           // FALSE: w�hrend des Auslesens wird der Anzeigezeitraum der History verk�rzt
            break;
         if (OrderType() > OP_SELL || OrderSymbol()!=Symbol())       // Nicht-Trades und fremde Tickets �berspringen
            continue;

         // (2.1) Sequenz- und manuelle Trades zwischenspeichern
         hist.tickets     [n] = OrderTicket();
         hist.types       [n] = OrderType();
         hist.lots        [n] = OrderLots();
         hist.openPrices  [n] = OrderOpenPrice();
         hist.openTimes   [n] = OrderOpenTime();
         hist.closePrices [n] = OrderClosePrice();
         hist.closeTimes  [n] = OrderCloseTime();
         hist.swaps       [n] = OrderSwap();
         hist.commissions [n] = OrderCommission();
         hist.profits     [n] = OrderProfit();                       // MagicNumber unterscheidet manuelle von autom. Trades
         hist.magicNumbers[n] = ifInt(IsMyOrder(sequenceId), OrderMagicNumber(), 0);
         hist.comments    [n] = OrderComment();

         if (hist.magicNumbers[n] > 0 && sequenceLength==0) {        // if (IsMyOrder(sequenceId)) ...
            sequenceLength = OrderMagicNumber() >> 4 & 0xF;          //  4 Bits (Bits 5-8 ) => sequenceLength
            ResizeArrays(sequenceLength);
         }
         n++;
      }
      if (n < closedTickets) {
         ArrayResize(hist.tickets     , n);
         ArrayResize(hist.types       , n);
         ArrayResize(hist.lots        , n);
         ArrayResize(hist.openPrices  , n);
         ArrayResize(hist.openTimes   , n);
         ArrayResize(hist.closePrices , n);
         ArrayResize(hist.closeTimes  , n);
         ArrayResize(hist.swaps       , n);
         ArrayResize(hist.commissions , n);
         ArrayResize(hist.profits     , n);
         ArrayResize(hist.magicNumbers, n);
         ArrayResize(hist.comments    , n);
         closedTickets = n;
      }

      // (2.2) Hedges analysieren: relevante Daten der ersten Position zuordnen, hedgende Position verwerfen
      for (i=0; i < closedTickets; i++) {
         if (hist.tickets     [i] == 0) continue;                    // als 'verworfen' markiertes Ticket
         if (hist.magicNumbers[i] == 0) continue;                    // manueller Trade, der evt. als Hedge ben�tigt wird

         if (EQ(hist.lots[i], 0)) {                                  // hist.lots = 0.00: Hedge-Position
            if (!StringIStartsWith(hist.comments[i], "close hedge by #"))
               return(catch("ReadSequence(3)  ticket #"+ hist.tickets[i] +" - unknown comment for assumed hedging position: \""+ hist.comments[i] +"\"", ERR_RUNTIME_ERROR)==NO_ERROR);

            // Gegenst�ck suchen
            int ticket = StrToInteger(StringSubstr(hist.comments[i], 16));
            for (n=0; n < closedTickets; n++)
               if (hist.tickets[n] == ticket)
                  break;
            if (n == closedTickets) return(catch("ReadSequence(4)  cannot find ticket #"+ hist.tickets[i] +"'s counterpart (comment=\""+ hist.comments[i] +"\")", ERR_RUNTIME_ERROR)==NO_ERROR);
            if (i == n            ) return(catch("ReadSequence(5)  both hedged and hedging position have the same ticket #"+ hist.tickets[i] +" (comment=\""+ hist.comments[i] +"\")", ERR_RUNTIME_ERROR)==NO_ERROR);

            int first, second;
            if      (hist.openTimes[i] < hist.openTimes[n])                                      { first = i; second = n; }
            else if (hist.openTimes[i]== hist.openTimes[n] && hist.tickets[i] < hist.tickets[n]) { first = i; second = n; }
            else                                                                                 { first = n; second = i; }
            // ein manueller Trade mu� immer 'second' sein
            if (hist.magicNumbers[n]==0) /*&&*/ if (n != second)
               return(catch("ReadSequence(6)  manuel hedge #"+ hist.tickets[n] +" of sequence ticket #"+ hist.tickets[i] +" is not the younger trade", ERR_RUNTIME_ERROR)==NO_ERROR);

            // Ticketdaten korrigieren
            hist.lots[i] = hist.lots[n];                             // hist.lots[i] == 0.0 korrigieren
            if (i == first) {
               hist.closePrices[first] = hist.openPrices [second];   // alle Transaktionsdaten im ersten Ticket speichern
               hist.swaps      [first] = hist.swaps      [second];
               hist.commissions[first] = hist.commissions[second];
               hist.profits    [first] = hist.profits    [second];
            }
            hist.closeTimes[first] = hist.openTimes[second];
            hist.tickets  [second] = 0;                              // zweites Ticket als 'verworfen' markieren
         }
      }

      datetime last.closeTime;

      // (2.3) levels.* mit den geschlossenen Tickets aktualisieren
      for (i=0; i < closedTickets; i++) {
         if (hist.tickets     [i] == 0) continue;                    // als 'verworfen' markiertes Ticket
         if (hist.magicNumbers[i] == 0) continue;                    // manueller Trade, der evt. als Hedge ben�tigt wurde

         level = hist.magicNumbers[i] & 0xF;                         // 4 Bits (Bits 1-4) => progressionLevel
         if (level > sequenceLength) return(catch("ReadSequence(7)   illegal sequence state, progression level "+ level +" of ticket #"+ hist.magicNumbers[i] +" exceeds the value of sequenceLength = "+ sequenceLength, ERR_RUNTIME_ERROR)==NO_ERROR);

         if (level > progressionLevel)
            progressionLevel = level;
         level--;

         if (levels.ticket[level] == 0) {                            // unbelegter Level
            levels.ticket   [level] = hist.tickets   [i];
            levels.type     [level] = hist.types     [i];
            levels.openLots [level] = hist.lots      [i];
            levels.openPrice[level] = hist.openPrices[i];
            levels.openTime [level] = hist.openTimes [i];
            levels.closeTime[level] = hist.closeTimes[i];
         }
         else if (levels.type[level] != hist.types[i]) {
            return(catch("ReadSequence(8)  illegal sequence state, operation type "+ OperationTypeDescription(levels.type[level]) +" (level "+ (level+1) +") doesn't match "+ OperationTypeDescription(hist.types[i]) +" of closed position #"+ hist.tickets[i], ERR_RUNTIME_ERROR)==NO_ERROR);
         }
         levels.closedSwap      [level] += hist.swaps      [i];
         levels.closedCommission[level] += hist.commissions[i];
         levels.closedProfit    [level] += hist.profits    [i];

         if (hist.closeTimes[i] > last.closeTime) {
            last.closeTime  = hist.closeTimes [i];
            last.closePrice = hist.closePrices[i];
         }
      }


      // (3) falls kein Ticket existiert, anhand der Konfigurationsdatei pr�fen, ob der EA im STATUS_WAITING l�uft
      if (progressionLevel == 0) {
         if (IsFile(TerminalPath() +"\\experts\\presets\\FTP."+ sequenceId +".set")) {
            // Datei existiert und mu� vorher validiert worden sein: Konfigurationsdaten wiederherstellen
            Entry.iDirection = orig.Entry.iDirection;
            Entry.lastBid    = orig.Entry.lastBid;
            status           = orig.status;
            sequenceLength   = ArraySize(levels.lots);
            ResizeArrays(sequenceLength);

            if (!UpdateMaxProfitLoss()) return(false);               // Profit/Loss und Breakeven sind 0
            if (!VisualizeSequence()  ) return(false);

            return(catch("ReadSequence(9)")==NO_ERROR);
         }

         PlaySound("notify.wav");
         int button = MessageBox("No tickets found for sequence "+ sequenceId +".\nMore history data needed?", __SCRIPT__ +" - ReadSequence()", MB_ICONEXCLAMATION|MB_RETRYCANCEL);
         if (button == IDRETRY) {
            retry = true;
            continue;
         }
         SetLastError(ERR_CANCELLED_BY_USER);
         catch("ReadSequence(10)");
         return(false);
      }


      // (4) Tickets auf Vollst�ndigkeit pr�fen
      retry = false;
      for (i=0; i < progressionLevel; i++) {
         if (levels.ticket[i] == 0) {
            PlaySound("notify.wav");
            button = MessageBox("Ticket for progression level "+ (i+1) +" not found.\nMore history data needed.", __SCRIPT__ +" - ReadSequence()", MB_ICONEXCLAMATION|MB_RETRYCANCEL);
            if (button == IDRETRY) {
               retry = true;
               break;
            }
            SetLastError(ERR_CANCELLED_BY_USER);
            catch("ReadSequence(11)");
            return(false);
         }
      }
   }
   Entry.iDirection = levels.type[0];


   // (5) Sequenz mit Konfiguration abgleichen
   if (sequenceLength != ArraySize(levels.lots))
      return(catch("ReadSequence(12)   illegal state of sequence "+ sequenceId +", sequenceLength "+ sequenceLength +" doesn't match the number of configured levels ("+ ArraySize(levels.lots) +")", ERR_RUNTIME_ERROR)==NO_ERROR);

   if (progressionLevel > 0) {
      int last = progressionLevel-1;
      if (openPositions) /*&&*/ if (NE(MathAbs(effectiveLots), levels.lots[last]))
         return(catch("ReadSequence(13)   illegal state of sequence "+ sequenceId +", current effective lot size ("+ NumberToStr(effectiveLots, ".+") +" lots) doesn't match the configured level "+ progressionLevel +" lot size ("+ NumberToStr(levels.lots[last], ".+") +" lots)", ERR_RUNTIME_ERROR)==NO_ERROR);
      if (Entry.type == ENTRYTYPE_LIMIT) {
         if (levels.type[0]==ENTRYDIRECTION_LONG ) /*&&*/ if (Entry.Direction!="long" ) return(catch("ReadSequence(14)   illegal state of sequence "+ sequenceId +", the "+ OperationTypeDescription(levels.type[0]) +" order at level 1 doesn't match the configured Entry.Direction = \""+ Entry.Direction +"\"", ERR_RUNTIME_ERROR)==NO_ERROR);
         if (levels.type[0]==ENTRYDIRECTION_SHORT) /*&&*/ if (Entry.Direction!="short") return(catch("ReadSequence(15)   illegal state of sequence "+ sequenceId +", the "+ OperationTypeDescription(levels.type[0]) +" order at level 1 doesn't match the configured Entry.Direction = \""+ Entry.Direction +"\"", ERR_RUNTIME_ERROR)==NO_ERROR);
      }
   }


   // (6) P/L und Breakeven neuberechnen und alles visualisieren
   if (!UpdateProfitLoss()   ) return(false);
   if (!UpdateBreakeven()    ) return(false);
   if (!UpdateMaxProfitLoss()) return(false);
   if (!VisualizeSequence()  ) return(false);

   return(catch("ReadSequence(16)")==NO_ERROR);
}


/**
 * Beginnt eine neue Trade-Sequenz (Progression-Level 1).
 *
 * @return bool - Erfolgsstatus
 */
bool StartSequence() {
   if (firstTick) {                                                  // Sicherheitsabfrage, wenn der erste Tick sofort einen Trade triggert
      PlaySound("notify.wav");
      int button = MessageBox(ifString(!IsDemo(), "Live Account\n\n", "") +"Do you really want to start a new trade sequence now?", __SCRIPT__ +" - StartSequence()", MB_ICONQUESTION|MB_OKCANCEL);
      if (button != IDOK) {
         SetLastError(ERR_CANCELLED_BY_USER);
         catch("StartSequence(1)");
         return(false);
      }
      SaveConfiguration();                                           // bei firstTick=TRUE Konfiguration nach Best�tigung speichern
   }

   progressionLevel = 1;

   int ticket = OpenPosition(Entry.iDirection, levels.lots[0]);      // Position in Entry.Direction �ffnen
   if (ticket == -1) {
      progressionLevel--;
      return(catch("StartSequence(2)")==NO_ERROR);
   }

   // Sequenzdaten aktualisieren
   if (!OrderSelectByTicket(ticket)) {
      progressionLevel--;
      return(PeekLastError());
   }

   levels.ticket   [0] = OrderTicket();
   levels.type     [0] = OrderType();
   levels.openLots [0] = OrderLots();
   levels.openPrice[0] = OrderOpenPrice();
   levels.openTime [0] = OrderOpenTime();

   if (OrderType() == OP_BUY) effectiveLots =  OrderLots();
   else                       effectiveLots = -OrderLots();

   status = STATUS_PROGRESSING;

   // Sequenz neu einlesen
   if (!ReadSequence(sequenceId))
      return(false);
   return(catch("StartSequence(3)")==NO_ERROR);
}


/**
 * Wechselt in den n�chsten Level.
 *
 * @return bool - Erfolgsstatus
 */
bool IncreaseProgression() {
   if (firstTick) {                                                        // Sicherheitsabfrage, wenn der erste Tick sofort einen Trade triggert
      PlaySound("notify.wav");
      int button = MessageBox(ifString(!IsDemo(), "Live Account\n\n", "") +"Do you really want to increase the progression level now?", __SCRIPT__ +" - IncreaseProgression()", MB_ICONQUESTION|MB_OKCANCEL);
      if (button != IDOK) {
         SetLastError(ERR_CANCELLED_BY_USER);
         catch("IncreaseProgression(1)");
         return(false);
      }
   }

   int    last      = progressionLevel-1;
   double last.lots = levels.lots[last];
   int    new.type  = levels.type[last] ^ 1;                               // 0=>1, 1=>0

   progressionLevel++;

   int ticket = OpenPosition(new.type, last.lots + levels.lots[last+1]);   // n�chste Position �ffnen und alte dabei hedgen
   if (ticket == -1) {
      progressionLevel--;
      catch("IncreaseProgression(2)");
      return(false);
   }

   // Sequenzdaten aktualisieren
   if (!OrderSelectByTicket(ticket)) {
      progressionLevel--;
      return(false);
   }

   int this = progressionLevel-1;
   levels.ticket   [this] = OrderTicket();
   levels.type     [this] = OrderType();
   levels.openLots [this] = OrderLots();
   levels.openPrice[this] = OrderOpenPrice();
   levels.openTime [this] = OrderOpenTime();

   if (OrderType() == OP_BUY) effectiveLots += OrderLots();
   else                       effectiveLots -= OrderLots();

   // Sequenz neu einlesen
   if (!ReadSequence(sequenceId))
      return(false);
   return(catch("IncreaseProgression(3)")==NO_ERROR);
}


/**
 * Schlie�t alle offenen Positionen der aktuellen Sequenz.
 *
 * @return bool - Erfolgsstatus
 */
bool FinishSequence() {
   if (firstTick) {                                                  // Sicherheitsabfrage, wenn der erste Tick sofort einen Trade triggert
      PlaySound("notify.wav");
      int button = MessageBox(ifString(!IsDemo(), "Live Account\n\n", "") +"Do you really want to finish the sequence now?", __SCRIPT__ +" - FinishSequence()", MB_ICONQUESTION|MB_OKCANCEL);
      if (button != IDOK) {
         SetLastError(ERR_CANCELLED_BY_USER);
         catch("FinishSequence(1)");
         return(false);
      }
   }

   // zu schlie�ende Tickets ermitteln
   int tickets[]; ArrayResize(tickets, 0);

   for (int i=0; i < sequenceLength; i++) {
      if (levels.ticket[i] > 0) /*&&*/ if (levels.closeTime[i] == 0)
         ArrayPushInt(tickets, levels.ticket[i]);
   }

   // Tickets schlie�en
   if (!OrderMultiClose(tickets, 0.5, CLR_NONE)) {
      SetLastError(stdlib_PeekLastError());
      catch("FinishSequence(2)");
      return(false);
   }

   status = STATUS_FINISHED;

   // Sequenz neu einlesen
   if (!ReadSequence(sequenceId))
      return(false);
   return(catch("FinishSequence(3)")==NO_ERROR);
}


/**
 * �ffnet eine neue Position in angegebener Richtung und Gr��e.
 *
 * @param  int    type    - Ordertyp: OP_BUY | OP_SELL
 * @param  double lotsize - Lotsize der Order
 *
 * @return int - Ticket der neuen Position oder -1, falls ein Fehler auftrat
 */
int OpenPosition(int type, double lotsize) {
   if (type!=OP_BUY && type!=OP_SELL) {
      catch("OpenPosition(1)   illegal parameter type = "+ type, ERR_INVALID_FUNCTION_PARAMVALUE);
      return(-1);
   }
   if (LE(lotsize, 0)) {
      catch("OpenPosition(2)   illegal parameter lotsize = "+ NumberToStr(lotsize, ".+"), ERR_INVALID_FUNCTION_PARAMVALUE);
      return(-1);
   }

   int    magicNumber = CreateMagicNumber();
   string comment     = "FTP."+ sequenceId +"."+ progressionLevel;
   double slippage    = 0.5;

   int ticket = OrderSendEx(Symbol(), type, lotsize, NULL, slippage, NULL, NULL, comment, magicNumber, NULL, CLR_NONE);
   if (ticket == -1)
      SetLastError(stdlib_PeekLastError());

   if (catch("OpenPosition(3)") != NO_ERROR)
      return(-1);
   return(ticket);
}


/**
 * �berpr�ft die offenen Positionen auf �nderungen und berechnet den aktuellen P/L neu.
 *
 * @return bool - Erfolgsstatus
 */
bool UpdateProfitLoss() {
   // (1) offene Positionen auf �nderungen pr�fen
   for (int i=0; i < progressionLevel; i++) {
      if (levels.closeTime[i] == 0) {                                // Ticket pr�fen, wenn es beim letzten Aufruf noch offen war
         if (!OrderSelectByTicket(levels.ticket[i]))
            return(false);

         if (OrderCloseTime() != 0) {                                // OrderCloseTime: Ticket wurde geschlossen => gesamte Sequenz neu einlesen
            if (ReadSequence(sequenceId))
               break;
            return(false);
         }
         if (NE(OrderLots(), levels.openLots[i])) {                  // OrderLots: Ticket wurde teilweise geschlossen => gesamte Sequenz neu einlesen
            if (ReadSequence(sequenceId))
               break;
            return(false);
         }
         if (NE(OrderSwap(), levels.openSwap[i]))                    // OrderSwap: Swap hat sich ge�ndert => Wert aktualisieren
            levels.openSwap[i] = OrderSwap();
      }
   }


   // (2) aktuellen TickValue f�r P/L-Berechnung bestimmen           !!! TODO: wenn QuoteCurrency == AccountCurrency, ist es nur ein statt jedes Mal notwendig
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   int error = GetLastError();
   if (error!=NO_ERROR || tickValue < 0.1)                           // ERR_INVALID_MARKETINFO abfangen
      return(catch("UpdateProfitLoss(1)   TickValue = "+ NumberToStr(tickValue, ".+"), ifInt(error==NO_ERROR, ERR_INVALID_MARKETINFO, error))==NO_ERROR);


   // (3) Profit/Loss der Level mit offenen Positionen neu berechnen
   all.swaps       = 0;
   all.commissions = 0;
   all.profits     = 0;

   double priceDiff, tmp.openLots[];
   ArrayResize(tmp.openLots, 0);
   ArrayCopy(tmp.openLots, levels.openLots);

   for (i=0; i < progressionLevel; i++) {
      if (levels.closeTime[i] == 0) {
         if (!OrderSelectByTicket(levels.ticket[i]))
            return(false);
         levels.openProfit[i] = 0;

         if (GT(tmp.openLots[i], 0)) {                               // P/L offener Hedges verrechnen
            for (int n=i+1; n < progressionLevel; n++) {
               if (levels.closeTime[n]==0) /*&&*/ if (levels.type[i]!=levels.type[n]) /*&&*/ if (GT(tmp.openLots[n], 0)) { // offener und verrechenbarer Hedge
                  priceDiff = ifDouble(levels.type[i]==OP_BUY, levels.openPrice[n]-levels.openPrice[i], levels.openPrice[i]-levels.openPrice[n]);

                  if (LE(tmp.openLots[i], tmp.openLots[n])) {
                     levels.openProfit[i] += priceDiff / TickSize * tickValue * tmp.openLots[i];
                     tmp.openLots     [n] -= tmp.openLots[i];
                     tmp.openLots     [i]  = 0;
                     break;
                  }
                  else  /*(tmp.openLots[i] > tmp.openLots[n])*/ {
                     levels.openProfit[i] += priceDiff / TickSize * tickValue * tmp.openLots[n];
                     tmp.openLots     [i] -= tmp.openLots[n];
                     tmp.openLots     [n]  = 0;
                  }
               }
            }

            // P/L von Restpositionen anteilm��ig anhand des regul�ren OrderProfit() ermitteln
            if (GT(tmp.openLots[i], 0))
               levels.openProfit[i] += OrderProfit() / levels.openLots[i] * tmp.openLots[i];
         }

         // TODO: korrekte Commission-Berechnung der Hedges implementieren
         levels.openCommission[i] = OrderCommission();
      }
      levels.swap      [i] = levels.openSwap      [i] + levels.closedSwap      [i];
      levels.commission[i] = levels.openCommission[i] + levels.closedCommission[i];
      levels.profit    [i] = levels.openProfit    [i] + levels.closedProfit    [i];

      all.swaps       += levels.swap      [i];
      all.commissions += levels.commission[i];
      all.profits     += levels.profit    [i];
   }

   return(catch("UpdateProfitLoss(2)")==NO_ERROR);
}


/**
 * Aktualisiert den Breakeven-Point (in Pip und als absoluten Kurswert). Die Berechnung ben�tigt einen korrekten P/L-Wert (erfordert
 * vorheriges UpdateProfitLoss() und erfolgt je einmal nach Wechsel auf den n�chsten Level oder nach Neueinlesen der Sequenz.
 *
 * @return bool - Erfolgsstatus
 */
bool UpdateBreakeven() {
   double breakeven;

   if (progressionLevel > 0) {
      int last = progressionLevel-1;
      double pipValue = GetPipValue();
      if (EQ(pipValue, 0))
         return(false);

      double profitLoss     = all.swaps + all.commissions + all.profits;
      double profitLossPips = profitLoss / pipValue;

      //debug("UpdateBreakeven()   profitLoss="+ DoubleToStr(profitLoss, 2) +"   profitLossPips="+ NumberToStr(profitLossPips, ".1+"));
   }

   return(catch("UpdateBreakeven()")==NO_ERROR);
}


/**
 * Gibt den PipValue der angegebenen Lotsize im aktuellen Instrument zur�ck (mit Fehlerkontrolle).
 *
 * @param  double lots - Lotsize
 *
 * @return double - PipValue oder 0, wenn ein Fehler auftrat
 */
double GetPipValue(double lots = 1) {
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);          // !!! TODO: wenn QuoteCurrency == AccountCurrency, ist dies nur ein einziges Mal notwendig

   int error = GetLastError();
   if (error!=NO_ERROR || tickValue < 0.1)                           // ERR_INVALID_MARKETINFO abfangen
      return(catch("GetPipValue()   TickValue = "+ NumberToStr(tickValue, ".+"), ifInt(error==NO_ERROR, ERR_INVALID_MARKETINFO, error))==NO_ERROR);

   return(Pip / TickSize * tickValue * lots);
}


/**
 * Aktualisiert die maximal erreichbaren P/L-Werte der einzelnen Level. Wird nur einmal nach Wechsel auf den jeweils n�chsten Level ausgef�hrt.
 * Erfordert in einer laufenden Sequenz die vorherige Ausf�hrung von UpdateProfitLoss().
 *
 * @return bool - Erfolgsstatus
 */
bool UpdateMaxProfitLoss() {
   // aktuellen PipValue bestimmen                                   !!! TODO: wenn QuoteCurrency == AccountCurrency, ist dies nur ein einziges Mal notwendig
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   int error = GetLastError();
   if (error!=NO_ERROR || tickValue < 0.1)                           // ERR_INVALID_MARKETINFO abfangen
      return(catch("UpdateMaxProfitLoss(1)   TickValue = "+ NumberToStr(tickValue, ".+"), ifInt(error==NO_ERROR, ERR_INVALID_MARKETINFO, error))==NO_ERROR);
   double pipValue = Pip / TickSize * tickValue;

   // maximale P/L-Werte neu berechnen
   double drawdown, prevDrawdown;                                    // Drawdown in Pips

   for (int i=0; i < sequenceLength; i++) {
      if (i >= progressionLevel-1)       drawdown = StopLoss;                                               // aktueller und folgende Level: konfigurierten StopLoss verwenden
      else if (levels.type[i] == OP_BUY) drawdown = (levels.openPrice[i  ] - levels.openPrice[i+1]) / Pip;  // vorherige Level: tats�chlichen Drawdown verwenden
      else                               drawdown = (levels.openPrice[i+1] - levels.openPrice[i  ]) / Pip;

      // TODO: der tats�chliche Drawdown ist die Summe von Drawdown + Swaps + Commissions

      levels.maxDrawdown[i] = prevDrawdown - levels.lots[i] * drawdown   * pipValue;
      levels.maxProfit  [i] = prevDrawdown + levels.lots[i] * TakeProfit * pipValue;
      prevDrawdown          = levels.maxDrawdown[i];
   }

   return(catch("UpdateMaxProfitLoss(2)")==NO_ERROR);
}


/**
 * Setzt alle internen Daten der Sequenz zur�ck.
 *
 * @return int - Fehlerstatus
 */
int ResetAll() {
   Entry.iDirection = ENTRYDIRECTION_UNDEFINED;
   Entry.lastBid    = 0;

   sequenceId       = 0;
   sequenceLength   = 0;
   progressionLevel = 0;

   effectiveLots    = 0;
   all.swaps        = 0;
   all.commissions  = 0;
   all.profits      = 0;

   status = STATUS_UNDEFINED;

   if (ArraySize(levels.ticket) > 0)
      ResizeArrays(0);

   return(catch("ResetAll()"));
}


/**
 * Setzt die Gr��e der internen Arrays auf den angegebenen Wert.
 *
 * @param  int size - neue Gr��e
 *
 * @return void
 */
void ResizeArrays(int size) {
   // alle Arrays au�er levels.lots[]: enth�lt Konfiguration und wird nur in ValidateConfiguration() modifiziert

   ArrayResize(levels.ticket          , size);
   ArrayResize(levels.type            , size); if (size > 0) ArrayInitialize(levels.type, OP_UNDEFINED);
   ArrayResize(levels.openLots        , size);
   ArrayResize(levels.openPrice       , size);
   ArrayResize(levels.openTime        , size);
   ArrayResize(levels.closeTime       , size);

   ArrayResize(levels.swap            , size);
   ArrayResize(levels.commission      , size);
   ArrayResize(levels.profit          , size);

   ArrayResize(levels.openSwap        , size);
   ArrayResize(levels.openCommission  , size);
   ArrayResize(levels.openProfit      , size);

   ArrayResize(levels.closedSwap      , size);
   ArrayResize(levels.closedCommission, size);
   ArrayResize(levels.closedProfit    , size);

   ArrayResize(levels.maxProfit       , size);
   ArrayResize(levels.maxDrawdown     , size);
   ArrayResize(levels.breakeven       , size);
}


/**
 * Visualisiert die Sequenz.
 *
 * @return bool - Erfolgsstatus
 */
bool VisualizeSequence() {
   for (int i=0; i < progressionLevel; i++) {
      int type = levels.type  [i];

      // Verbinder
      if (i > 0) {
         string line = "FTP."+ sequenceId +"."+ i +" > "+ (i+1);
         if (ObjectFind(line) > -1)
            ObjectDelete(line);
         if (ObjectCreate(line, OBJ_TREND, 0, levels.openTime[i-1], levels.openPrice[i-1], levels.openTime[i], levels.openPrice[i])) {
            ObjectSet(line, OBJPROP_COLOR, ifInt(type==OP_SELL, Blue, Red));
            ObjectSet(line, OBJPROP_RAY,   false);
            ObjectSet(line, OBJPROP_STYLE, STYLE_DOT);
         }
         else GetLastError();
      }

      // Positionsmarker
      string arrow = "FTP."+ sequenceId +"."+ (i+1) +"   "+ ifString(type==OP_BUY, "Buy", "Sell") +" "+ NumberToStr(levels.lots[i], ".+") +" lot"+ ifString(EQ(levels.lots[i], 1), "", "s") +" at "+ NumberToStr(levels.openPrice[i], PriceFormat);
      if (ObjectFind(arrow) > -1)
         ObjectDelete(arrow);
      if (ObjectCreate(arrow, OBJ_ARROW, 0, levels.openTime[i], levels.openPrice[i])) {
         ObjectSet(arrow, OBJPROP_ARROWCODE, 1);
         ObjectSet(arrow, OBJPROP_COLOR, ifInt(type==OP_BUY, Blue, Red));
      }
      else GetLastError();
   }

   // Sequenzende
   if (progressionLevel > 0) /*&&*/ if (levels.closeTime[i-1] != 0) {
      // letzter Verbinder
      line = "FTP."+ sequenceId +"."+ progressionLevel;
      if (ObjectFind(line) > -1)
         ObjectDelete(line);
      if (ObjectCreate(line, OBJ_TREND, 0, levels.openTime[i-1], levels.openPrice[i-1], levels.closeTime[i-1], last.closePrice)) {
         ObjectSet(line, OBJPROP_COLOR, ifInt(levels.type[i-1]==OP_BUY, Blue, Red));
         ObjectSet(line, OBJPROP_RAY,   false);
         ObjectSet(line, OBJPROP_STYLE, STYLE_DOT);
      }
      else GetLastError();

      // letzter Marker
      arrow = "FTP."+ sequenceId +"."+ progressionLevel +"   Sequence finished at "+ NumberToStr(last.closePrice, PriceFormat);
      if (ObjectFind(arrow) > -1)
         ObjectDelete(arrow);
      if (ObjectCreate(arrow, OBJ_ARROW, 0, levels.closeTime[i-1], last.closePrice)) {
         ObjectSet(arrow, OBJPROP_ARROWCODE, 3);
         ObjectSet(arrow, OBJPROP_COLOR, Orange);
      }
      else GetLastError();
   }

   return(catch("VisualizeSequence()")==NO_ERROR);
}


/**
 * Zeigt den aktuellen Status der Sequenz an.
 *
 * @return int - Fehlerstatus
 */
int ShowStatus() {
   if (PeekLastError() != NO_ERROR)
      status = STATUS_DISABLED;

   // Zeile 3: Lotsizes der gesamten Sequenz
   static string str.levels.lots = "";
   if (levels.lots.changed) {
      str.levels.lots = JoinDoubles(levels.lots, ",  ");
      levels.lots.changed = false;
   }

   string msg = "";
   switch (status) {
      case STATUS_UNDEFINED:   msg = StringConcatenate(":  sequence ", sequenceId, " initialized");    break;
      case STATUS_WAITING:     if      (Entry.type       == ENTRYTYPE_LIMIT         ) msg = StringConcatenate(":  sequence ", sequenceId, " waiting to ", OperationTypeDescription(Entry.iDirection), " at ", NumberToStr(Entry.limit, PriceFormat));
                               else if (Entry.iDirection == ENTRYDIRECTION_UNDEFINED) msg = StringConcatenate(":  sequence ", sequenceId, " waiting for next ", Entry.Condition, " crossing");
                               else                                                   msg = StringConcatenate(":  sequence ", sequenceId, " waiting for ", Entry.Condition, ifString(Entry.iDirection==OP_BUY, " high", " low"), " crossing to ", OperationTypeDescription(Entry.iDirection), ":  ", NumberToStr(Entry.limit, PriceFormat));
                               break;
      case STATUS_PROGRESSING: msg = StringConcatenate(":  sequence ", sequenceId, " progressing..."); break;
      case STATUS_FINISHED:    msg = StringConcatenate(":  sequence ", sequenceId, " finished");       break;
      case STATUS_DISABLED:    msg = StringConcatenate(":  sequence ", sequenceId, " disabled");
                               int error = ifInt(init, init_error, last_error);
                               if (error != NO_ERROR)
                                  msg = StringConcatenate(msg, "  [", ErrorDescription(error), "]");
                               break;
      default:
         return(catch("ShowStatus(1)   illegal sequence status = "+ status, ERR_RUNTIME_ERROR));
   }
   msg = StringConcatenate(__SCRIPT__, msg,                                              NL,
                                                                                         NL,
                          "Progression Level:   ", progressionLevel, " / ", sequenceLength);

   double profitLoss, profitLossPips, lastPrice;
   int i;

   if (progressionLevel > 0) {
      i = progressionLevel-1;
      if (status == STATUS_FINISHED) {
         lastPrice = last.closePrice;
      }
      else {                                                         // TODO: NumberToStr(x, "+- ") implementieren
         msg         = StringConcatenate(msg, "  =  ", ifString(levels.type[i]==OP_BUY, "+", ""), NumberToStr(effectiveLots, ".+"), " lot");
         lastPrice = ifDouble(levels.type[i]==OP_BUY, Bid, Ask);
      }
      profitLossPips = ifDouble(levels.type[i]==OP_BUY, lastPrice-levels.openPrice[i], levels.openPrice[i]-lastPrice) / Pip;
      profitLoss     = all.swaps + all.commissions + all.profits;
   }
   else {
      i = 0;                                                         // in Progression-Level 0 TakeProfit- und StopLoss-Anzeige f�r ersten Level
   }

   if (sequenceLength > 0) {
      msg = StringConcatenate(msg,                                                                                                                                                                      NL,
                             "Lot sizes:               ", str.levels.lots, "  (", DoubleToStr(levels.maxProfit[sequenceLength-1], 2), " / ", DoubleToStr(levels.maxDrawdown[sequenceLength-1], 2), ")", NL,
                             "TakeProfit:            ",   TakeProfit, " pip = ", DoubleToStr(levels.maxProfit[i], 2),                                                                                   NL,
                             "StopLoss:              ",   StopLoss,   " pip = ", DoubleToStr(levels.maxDrawdown[i], 2),                                                                                 NL);
   }
   else {
      msg = StringConcatenate(msg,                                               NL,
                             "Lot sizes:               ", str.levels.lots,       NL,
                             "TakeProfit:            ",   TakeProfit, " pip = ", NL,
                             "StopLoss:              ",   StopLoss,   " pip = ", NL);
   }
      msg = StringConcatenate(msg,
                             "Breakeven:           ",   DoubleToStr(0, Digits-PipDigits), " pip = ", NumberToStr(0, PriceFormat),             NL,
                             "Profit/Loss:           ", DoubleToStr(profitLossPips, Digits-PipDigits), " pip = ", DoubleToStr(profitLoss, 2), NL);

   // einige Zeilen Abstand nach oben f�r Instrumentanzeige und ggf. vorhandene Legende
   Comment(StringConcatenate(NL, NL, NL, NL, NL, NL, msg));

   return(catch("ShowStatus(2)"));
}


/**
 * Ob in der Konfiguration ausdr�cklich eine zu benutzende Sequenz-ID angegeben wurde. Hier wird nur gepr�ft,
 * ob ein Wert angegeben wurde oder nicht. Die G�ltigkeit wird in ValidateSpecificSequenceId() �berpr�ft.
 *
 * @return bool
 */
bool IsSpecificSequenceId() {
   return(StringLen(StringTrim(Sequence.ID)) > 0);
}


/**
 * Validiert die in der Konfiguration angegebene ID der zu benutzenden Sequenz und restauriert bei Erfolg die interne Variable sequenceId.
 *
 * @return bool - ob eine g�ltige Sequenz-ID gefunden und restauriert wurde
 */
bool ValidateSpecificSequenceId() {
   if (IsSpecificSequenceId()) {
      string strValue = StringTrim(Sequence.ID);

      if (StringIsInteger(strValue)) {
         int iValue = StrToInteger(strValue);
         if (1000 <= iValue) /*&&*/ if (iValue <= 16383) {
            sequenceId  = iValue;
            Sequence.ID = strValue;
            return(true);
         }
      }
      catch("ValidateSpecificSequenceId()  Invalid input parameter Sequence.ID = \""+ Sequence.ID +"\"", ERR_INVALID_INPUT_PARAMVALUE);
   }
   return(false);
}


/**
 * Validiert die aktuelle Konfiguration.
 *
 * @return bool - ob die Konfiguration g�ltig ist
 */
bool ValidateConfiguration() {
   // TODO: Nach Progressionstart unm�gliche Parameter�nderungen abfangen, z.B. Parameter werden ge�ndert,
   //       ohne vorher im Input-Dialog die Konfigurationsdatei der Sequenz zu laden.

   // Entry.Condition
   string strValue = StringReplace(Entry.Condition, " ", "");
   string values[];
   // LimitValue | BollingerBands(35xM5, EMA, 2.0) | Envelopes(75xM15, ALMA, 2.0)
   if (Explode(strValue, "|", values, NULL) != 1)                    // vorerst wird nur eine Entry.Condition akzeptiert
      return(catch("ValidateConfiguration(1)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ strValue +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
   strValue = values[0];
   if (StringLen(strValue) == 0)
      return(catch("ValidateConfiguration(2)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ strValue +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
   // LimitValue
   if (StringIsNumeric(strValue)) {
      Entry.limit = StrToDouble(strValue);
      if (LT(Entry.limit, 0))
         return(catch("ValidateConfiguration(3)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ strValue +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
      Entry.type = ENTRYTYPE_LIMIT;
   }
   else if (!StringEndsWith(strValue, ")")) {
      return(catch("ValidateConfiguration(4)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ strValue +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
   }
   else {
      // [[Bollinger]Bands|Envelopes](35xM5, EMA, 2.0)
      strValue = StringToLower(StringLeft(strValue, -1));
      if (Explode(strValue, "(", values, NULL) != 2)
         return(catch("ValidateConfiguration(5)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ strValue +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
      if      (values[0] == "bands"         ) Entry.type = ENTRYTYPE_BANDS;
      else if (values[0] == "bollingerbands") Entry.type = ENTRYTYPE_BANDS;
      else if (values[0] == "env"           ) Entry.type = ENTRYTYPE_ENVELOPES;
      else if (values[0] == "envelopes"     ) Entry.type = ENTRYTYPE_ENVELOPES;
      else
         return(catch("ValidateConfiguration(6)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ values[0] +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
      // 35xM5, EMA, 2.0
      if (Explode(values[1], ",", values, NULL) != 3)
         return(catch("ValidateConfiguration(7)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ values[1] +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
      // MA-Deviation
      if (!StringIsNumeric(values[2]))
         return(catch("ValidateConfiguration(8)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ values[2] +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
      Entry.MA.deviation = StrToDouble(values[2]);
      if (LE(Entry.MA.deviation, 0))
         return(catch("ValidateConfiguration(9)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ values[2] +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
      // MA-Method
      Entry.MA.method = MovingAverageMethodToId(values[1]);
      if (Entry.MA.method == -1)
         return(catch("ValidateConfiguration(10)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ values[1] +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
      // MA-Periods(x)MA-Timeframe
      if (Explode(values[0], "x", values, NULL) != 2)
         return(catch("ValidateConfiguration(11)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ values[0] +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
      // MA-Periods
      if (!StringIsDigit(values[0]))
         return(catch("ValidateConfiguration(12)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ values[0] +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
      Entry.MA.periods = StrToInteger(values[0]);
      if (Entry.MA.periods < 1)
         return(catch("ValidateConfiguration(13)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ values[0] +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
      // MA-Timeframe
      Entry.MA.timeframe = PeriodToId(values[1]);
      if (Entry.MA.timeframe == -1)
         return(catch("ValidateConfiguration(14)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ values[1] +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);

      // F�r konstante Berechnungen bei Timeframe-Wechseln Timeframe m�glichst nach M5 umrechnen.
      Entry.MA.periods.orig   = Entry.MA.periods;
      Entry.MA.timeframe.orig = Entry.MA.timeframe;
      if (Entry.MA.timeframe > PERIOD_M5) {
         Entry.MA.periods   = Entry.MA.periods * Entry.MA.timeframe / PERIOD_M5;
         Entry.MA.timeframe = PERIOD_M5;
      }
   }

   // Entry.Direction
   strValue = StringToLower(StringTrim(Entry.Direction));
   if (StringLen(strValue) == 0) { Entry.Direction = "";  Entry.iDirection = ENTRYDIRECTION_LONGSHORT; }
   else {
      switch (StringGetChar(strValue, 0)) {
         case 'b':
         case 'l': Entry.Direction = "long";  Entry.iDirection = ENTRYDIRECTION_LONG;  break;
         case 's': Entry.Direction = "short"; Entry.iDirection = ENTRYDIRECTION_SHORT; break;
         default:
            return(catch("ValidateConfiguration(15)  Invalid input parameter Entry.Direction = \""+ Entry.Direction +"\" ("+ strValue +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
      }
   }

   // Entry.Condition <-> Entry.Direction
   if (Entry.type == ENTRYTYPE_LIMIT) {
      if (Entry.iDirection == ENTRYDIRECTION_LONGSHORT)
         return(catch("ValidateConfiguration(16)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ EntryTypeToStr(Entry.type) +" <-> "+ Entry.Direction +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
   }
   else if (Entry.iDirection != ENTRYDIRECTION_LONGSHORT)
      return(catch("ValidateConfiguration(17)  Invalid input parameter Entry.Condition = \""+ Entry.Condition +"\" ("+ EntryTypeToStr(Entry.type) +" <-> "+ Entry.Direction +")", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
   Entry.Condition = StringTrim(Entry.Condition);

   // TakeProfit
   if (TakeProfit < 1)
      return(catch("ValidateConfiguration(18)  Invalid input parameter TakeProfit = "+ TakeProfit, ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);

   // StopLoss
   if (StopLoss < 1)
      return(catch("ValidateConfiguration(19)  Invalid input parameter StopLoss = "+ StopLoss, ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);

   // Lotsizes
   int levels = ArrayResize(levels.lots, 0);
   levels.lots.changed = true;

   if (LE(Lotsize.Level.1, 0)) return(catch("ValidateConfiguration(20)  Invalid input parameter Lotsize.Level.1 = "+ NumberToStr(Lotsize.Level.1, ".+"), ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
   levels = ArrayPushDouble(levels.lots, Lotsize.Level.1);

   if (NE(Lotsize.Level.2, 0)) {
      if (LT(Lotsize.Level.2, Lotsize.Level.1)) return(catch("ValidateConfiguration(21)  Invalid input parameter Lotsize.Level.2 = "+ NumberToStr(Lotsize.Level.2, ".+"), ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
      levels = ArrayPushDouble(levels.lots, Lotsize.Level.2);

      if (NE(Lotsize.Level.3, 0)) {
         if (LT(Lotsize.Level.3, Lotsize.Level.2)) return(catch("ValidateConfiguration(22)  Invalid input parameter Lotsize.Level.3 = "+ NumberToStr(Lotsize.Level.3, ".+"), ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
         levels = ArrayPushDouble(levels.lots, Lotsize.Level.3);

         if (NE(Lotsize.Level.4, 0)) {
            if (LT(Lotsize.Level.4, Lotsize.Level.3)) return(catch("ValidateConfiguration(23)  Invalid input parameter Lotsize.Level.4 = "+ NumberToStr(Lotsize.Level.4, ".+"), ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
            levels = ArrayPushDouble(levels.lots, Lotsize.Level.4);

            if (NE(Lotsize.Level.5, 0)) {
               if (LT(Lotsize.Level.5, Lotsize.Level.4)) return(catch("ValidateConfiguration(24)  Invalid input parameter Lotsize.Level.5 = "+ NumberToStr(Lotsize.Level.5, ".+"), ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
               levels = ArrayPushDouble(levels.lots, Lotsize.Level.5);

               if (NE(Lotsize.Level.6, 0)) {
                  if (LT(Lotsize.Level.6, Lotsize.Level.5)) return(catch("ValidateConfiguration(25)  Invalid input parameter Lotsize.Level.6 = "+ NumberToStr(Lotsize.Level.6, ".+"), ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
                  levels = ArrayPushDouble(levels.lots, Lotsize.Level.6);

                  if (NE(Lotsize.Level.7, 0)) {
                     if (LT(Lotsize.Level.7, Lotsize.Level.6)) return(catch("ValidateConfiguration(26)  Invalid input parameter Lotsize.Level.7 = "+ NumberToStr(Lotsize.Level.7, ".+"), ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
                     levels = ArrayPushDouble(levels.lots, Lotsize.Level.7);
                  }
               }
            }
         }
      }
   }
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   int error = GetLastError();
   if (error != NO_ERROR)                             return(catch("ValidateConfiguration(27)   symbol=\""+ Symbol() +"\"", error)==NO_ERROR);

   for (int i=0; i < levels; i++) {
      if (LT(levels.lots[i], minLot))                 return(catch("ValidateConfiguration(28)   Invalid input parameter Lotsize.Level."+ (i+1) +" = "+ NumberToStr(levels.lots[i], ".+") +" (MinLot="+  NumberToStr(minLot, ".+" ) +")", ERR_INVALID_INPUT_PARAMVALUE));
      if (GT(levels.lots[i], maxLot))                 return(catch("ValidateConfiguration(29)   Invalid input parameter Lotsize.Level."+ (i+1) +" = "+ NumberToStr(levels.lots[i], ".+") +" (MaxLot="+  NumberToStr(maxLot, ".+" ) +")", ERR_INVALID_INPUT_PARAMVALUE));
      if (NE(MathModFix(levels.lots[i], lotStep), 0)) return(catch("ValidateConfiguration(30)   Invalid input parameter Lotsize.Level."+ (i+1) +" = "+ NumberToStr(levels.lots[i], ".+") +" (LotStep="+ NumberToStr(lotStep, ".+") +")", ERR_INVALID_INPUT_PARAMVALUE));
   }
   sequenceLength = ArraySize(levels.lots);

   // Sequence.ID: wurde schon in ValidateExplicitSequenceId() validiert

   // Konfiguration mit aktuellen Daten einer laufenden Sequenz vergleichen (greift nur UninitializeReason() == REASON_PARAMETERS)
   // TODO: nicht nur den letzten Level abgleichen, sondern sicherstellen, da� nur zuk�nftige Level ge�ndert wurden
   if (progressionLevel > 0) {
      if (NE(effectiveLots, 0)) {
         int last = progressionLevel-1;
         if (NE(levels.lots[last], MathAbs(effectiveLots)))
            return(catch("ValidateConfiguration(31)   illegal input parameter Lotsize.Level."+ progressionLevel +" ("+ NumberToStr(levels.lots[last], ".+") +" lots), it doesn't match the current effective lot size ("+ NumberToStr(effectiveLots, ".+") +" lots)", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
      }
      if (Entry.type==ENTRYTYPE_LIMIT) /*&&*/ if (levels.type[0]!=Entry.iDirection)
         return(catch("ValidateConfiguration(32)   illegal input parameter Entry.Direction = \""+ Entry.Direction +"\", it doesn't match "+ OperationTypeDescription(levels.type[0]) +" order at level 1", ERR_INVALID_INPUT_PARAMVALUE)==NO_ERROR);
   }

   return(catch("ValidateConfiguration(33)")==NO_ERROR);
}


/**
 * Speichert aktuelle Konfiguration und Laufzeitdaten der Instanz, um die nahtlose Wiederauf- und �bernahme durch eine
 * andere Instanz im selben oder einem anderen Terminal zu erm�glichen.
 *
 * @return int - Fehlerstatus
 */
int SaveConfiguration() {
   if (sequenceId == 0) {
      status = STATUS_DISABLED;
      return(catch("SaveConfiguration(1)   illegal value of sequenceId = "+ sequenceId, ERR_RUNTIME_ERROR));
   }
   debug("SaveConfiguration()   saving configuration for sequence "+ sequenceId);


   // (1) Daten zusammenstellen
   string lines[];  ArrayResize(lines, 0);
   ArrayPushString(lines, /*string*/ "Sequence.ID="     +             sequenceId            );
   ArrayPushString(lines, /*string*/ "Entry.Condition=" +             Entry.Condition       );
   ArrayPushString(lines, /*string*/ "Entry.Direction=" +             Entry.Direction       );
   ArrayPushString(lines, /*int   */ "TakeProfit="      +             TakeProfit            );
   ArrayPushString(lines, /*int   */ "StopLoss="        +             StopLoss              );
   ArrayPushString(lines, /*double*/ "Lotsize.Level.1=" + NumberToStr(Lotsize.Level.1, ".+"));
   ArrayPushString(lines, /*double*/ "Lotsize.Level.2=" + NumberToStr(Lotsize.Level.2, ".+"));
   ArrayPushString(lines, /*double*/ "Lotsize.Level.3=" + NumberToStr(Lotsize.Level.3, ".+"));
   ArrayPushString(lines, /*double*/ "Lotsize.Level.4=" + NumberToStr(Lotsize.Level.4, ".+"));
   ArrayPushString(lines, /*double*/ "Lotsize.Level.5=" + NumberToStr(Lotsize.Level.5, ".+"));
   ArrayPushString(lines, /*double*/ "Lotsize.Level.6=" + NumberToStr(Lotsize.Level.6, ".+"));
   ArrayPushString(lines, /*double*/ "Lotsize.Level.7=" + NumberToStr(Lotsize.Level.7, ".+"));


   // (2) Daten in lokale Datei schreiben
   string filename = "presets\\FTP."+ sequenceId +".set";            // ".\experts\files\presets" ist ein Softlink auf ".\experts\presets", dadurch ist
                                                                     // das Presets-Verzeichnis f�r die MQL-Dateifunktionen erreichbar.
   int hFile = FileOpen(filename, FILE_CSV|FILE_WRITE);
   if (hFile < 0) {
      status = STATUS_DISABLED;
      return(catch("SaveConfiguration(2)  FileOpen(file=\""+ filename +"\")"));
   }
   for (int i=0; i < ArraySize(lines); i++) {
      if (FileWrite(hFile, lines[i]) < 0) {
         int error = GetLastError();
         FileClose(hFile);
         status = STATUS_DISABLED;
         return(catch("SaveConfiguration(3)  FileWrite(line #"+ (i+1) +")", error));
      }
   }
   FileClose(hFile);


   // (3) Datei auf Server laden
   error = UploadConfiguration(ShortAccountCompany(), AccountNumber(), GetStandardSymbol(Symbol()), filename);
   if (error != NO_ERROR) {
      status = STATUS_DISABLED;
      return(error);
   }

   error = GetLastError();
   if (error != NO_ERROR) {
      status = STATUS_DISABLED;
      catch("SaveConfiguration(4)", error);
   }
   return(error);
}


/**
 * L�dt die angegebene Konfigurationsdatei auf den Server.
 *
 * @param  string company     - Account-Company
 * @param  int    account     - Account-Number
 * @param  string symbol      - Symbol der Konfiguration
 * @param  string presetsFile - Dateiname, relativ zu "{terminal-directory}\experts"
 *
 * @return int - Fehlerstatus
 */
int UploadConfiguration(string company, int account, string symbol, string presetsFile) {
   // TODO: Existenz von wget.exe pr�fen

   string parts[]; int size = Explode(presetsFile, "\\", parts, NULL);
   string file = parts[size-1];                                         // einfacher Dateiname ohne Verzeichnisse

   // Befehlszeile f�r Shellaufruf zusammensetzen
   string presetsPath  = TerminalPath() +"\\experts\\" + presetsFile;   // Dateinamen mit vollst�ndigen Pfaden
   string responsePath = presetsPath +".response";
   string logPath      = presetsPath +".log";
   string url          = "http://sub.domain.tld/uploadFTPConfiguration.php?company="+ UrlEncode(company) +"&account="+ account +"&symbol="+ UrlEncode(symbol) +"&name="+ UrlEncode(file);
   string cmdLine      = "wget.exe -b \""+ url +"\" --post-file=\""+ presetsPath +"\" --header=\"Content-Type: text/plain\" -O \""+ responsePath +"\" -a \""+ logPath +"\"";

   // Existenz der Datei pr�fen
   if (!IsFile(presetsPath))
      return(catch("UploadConfiguration(1)   file not found: \""+ presetsPath +"\"", ERR_FILE_NOT_FOUND));

   // Datei hochladen, WinExec() kehrt ohne zu warten zur�ck, wget -b beschleunigt zus�tzlich
   int error = WinExec(cmdLine, SW_HIDE);                               // SW_SHOWNORMAL|SW_HIDE
   if (error < 32)
      return(catch("UploadConfiguration(2)   execution of \""+ cmdLine +"\" failed with error="+ error +" ("+ ShellExecuteErrorToStr(error) +")", ERR_WINDOWS_ERROR));

   return(catch("UploadConfiguration(3)"));
}


/**
 * Liest die Konfiguration einer Sequenz ein und setzt die internen Variablen entsprechend. Ohne lokale Konfiguration
 * wird die Konfiguration vom Server geladen und lokal gespeichert.
 *
 * @return bool - ob die Konfiguration erfolgreich restauriert wurde
 */
bool RestoreConfiguration() {
   if (sequenceId == 0)
      return(catch("RestoreConfiguration(1)   illegal value of sequenceId = "+ sequenceId, ERR_RUNTIME_ERROR)==NO_ERROR);

   // TODO: Existenz von wget.exe pr�fen

   // (1) bei nicht existierender lokaler Konfiguration die Datei vom Server laden
   string filesDir = TerminalPath() +"\\experts\\files\\";           // ".\experts\files\presets" ist ein Softlink auf ".\experts\presets", dadurch
   string fileName = "presets\\FTP."+ sequenceId +".set";            // ist das Presets-Verzeichnis f�r die MQL-Dateifunktionen erreichbar.

   if (!IsFile(filesDir + fileName)) {
      // Befehlszeile f�r Shellaufruf zusammensetzen
      string url        = "http://sub.domain.tld/downloadFTPConfiguration.php?company="+ UrlEncode(ShortAccountCompany()) +"&account="+ AccountNumber() +"&symbol="+ UrlEncode(GetStandardSymbol(Symbol())) +"&sequence="+ sequenceId;
      string targetFile = filesDir +"\\"+ fileName;
      string logFile    = filesDir +"\\"+ fileName +".log";
      string cmdLine    = "wget.exe \""+ url +"\" -O \""+ targetFile +"\" -o \""+ logFile +"\"";

      debug("RestoreConfiguration()   downloading configuration for sequence "+ sequenceId);

      int error = WinExecAndWait(cmdLine, SW_HIDE);                  // SW_SHOWNORMAL|SW_HIDE
      if (error != NO_ERROR)
         return(SetLastError(error)==NO_ERROR);

      debug("RestoreConfiguration()   configuration for sequence "+ sequenceId +" successfully downloaded");
      FileDelete(fileName +".log");
   }

   // (2) Datei einlesen
   debug("RestoreConfiguration()   restoring configuration for sequence "+ sequenceId);
   string config[];
   int lines = FileReadLines(fileName, config, true);
   if (lines < 0)
      return(SetLastError(stdlib_PeekLastError())==NO_ERROR);
   if (lines == 0) {
      FileDelete(fileName);
      return(catch("RestoreConfiguration(2)   no configuration found for sequence "+ sequenceId, ERR_RUNTIME_ERROR)==NO_ERROR);
   }

   // (3) Zeilen in Schl�ssel-Wert-Paare aufbrechen, Datentypen validieren und Daten �bernehmen
   int keys[11]; ArrayInitialize(keys, 0);
   #define I_ENTRY_CONDITION  0
   #define I_ENTRY_DIRECTION  1
   #define I_TAKEPROFIT       2
   #define I_STOPLOSS         3
   #define I_LOTSIZE_LEVEL_1  4
   #define I_LOTSIZE_LEVEL_2  5
   #define I_LOTSIZE_LEVEL_3  6
   #define I_LOTSIZE_LEVEL_4  7
   #define I_LOTSIZE_LEVEL_5  8
   #define I_LOTSIZE_LEVEL_6  9
   #define I_LOTSIZE_LEVEL_7 10

   string parts[];
   for (int i=0; i < lines; i++) {
      if (Explode(config[i], "=", parts, 2) != 2) return(catch("RestoreConfiguration(3)   invalid configuration file \""+ fileName +"\" (line \""+ config[i] +"\")", ERR_RUNTIME_ERROR)==NO_ERROR);
      string key=parts[0], value=parts[1];

      Sequence.ID = sequenceId;

      if (key == "Entry.Condition") {
         Entry.Condition = value;
         keys[I_ENTRY_CONDITION] = 1;
      }
      else if (key == "Entry.Direction") {
         Entry.Direction = value;
         keys[I_ENTRY_DIRECTION] = 1;
      }
      else if (key == "TakeProfit") {
         if (!StringIsDigit(value))               return(catch("RestoreConfiguration(4)   invalid configuration file \""+ fileName +"\" (line \""+ config[i] +"\")", ERR_RUNTIME_ERROR)==NO_ERROR);
         TakeProfit = StrToInteger(value);
         keys[I_TAKEPROFIT] = 1;
      }
      else if (key == "StopLoss") {
         if (!StringIsDigit(value))               return(catch("RestoreConfiguration(5)   invalid configuration file \""+ fileName +"\" (line \""+ config[i] +"\")", ERR_RUNTIME_ERROR)==NO_ERROR);
         StopLoss = StrToInteger(value);
         keys[I_STOPLOSS] = 1;
      }
      else if (key == "Lotsize.Level.1") {
         if (!StringIsNumeric(value))             return(catch("RestoreConfiguration(6)   invalid configuration file \""+ fileName +"\" (line \""+ config[i] +"\")", ERR_RUNTIME_ERROR)==NO_ERROR);
         Lotsize.Level.1 = StrToDouble(value);
         keys[I_LOTSIZE_LEVEL_1] = 1;
      }
      else if (key == "Lotsize.Level.2") {
         if (!StringIsNumeric(value))             return(catch("RestoreConfiguration(7)   invalid configuration file \""+ fileName +"\" (line \""+ config[i] +"\")", ERR_RUNTIME_ERROR)==NO_ERROR);
         Lotsize.Level.2 = StrToDouble(value);
         keys[I_LOTSIZE_LEVEL_2] = 1;
      }
      else if (key == "Lotsize.Level.3") {
         if (!StringIsNumeric(value))             return(catch("RestoreConfiguration(8)   invalid configuration file \""+ fileName +"\" (line \""+ config[i] +"\")", ERR_RUNTIME_ERROR)==NO_ERROR);
         Lotsize.Level.3 = StrToDouble(value);
         keys[I_LOTSIZE_LEVEL_3] = 1;
      }
      else if (key == "Lotsize.Level.4") {
         if (!StringIsNumeric(value))             return(catch("RestoreConfiguration(9)   invalid configuration file \""+ fileName +"\" (line \""+ config[i] +"\")", ERR_RUNTIME_ERROR)==NO_ERROR);
         Lotsize.Level.4 = StrToDouble(value);
         keys[I_LOTSIZE_LEVEL_4] = 1;
      }
      else if (key == "Lotsize.Level.5") {
         if (!StringIsNumeric(value))             return(catch("RestoreConfiguration(10)   invalid configuration file \""+ fileName +"\" (line \""+ config[i] +"\")", ERR_RUNTIME_ERROR)==NO_ERROR);
         Lotsize.Level.5 = StrToDouble(value);
         keys[I_LOTSIZE_LEVEL_5] = 1;
      }
      else if (key == "Lotsize.Level.6") {
         if (!StringIsNumeric(value))             return(catch("RestoreConfiguration(11)   invalid configuration file \""+ fileName +"\" (line \""+ config[i] +"\")", ERR_RUNTIME_ERROR)==NO_ERROR);
         Lotsize.Level.6 = StrToDouble(value);
         keys[I_LOTSIZE_LEVEL_6] = 1;
      }
      else if (key == "Lotsize.Level.7") {
         if (!StringIsNumeric(value))             return(catch("RestoreConfiguration(12)   invalid configuration file \""+ fileName +"\" (line \""+ config[i] +"\")", ERR_RUNTIME_ERROR)==NO_ERROR);
         Lotsize.Level.7 = StrToDouble(value);
         keys[I_LOTSIZE_LEVEL_7] = 1;
      }
   }
   if (IntInArray(0, keys))                       return(catch("RestoreConfiguration(13)   one or more configuration values missing in file \""+ fileName +"\"", ERR_RUNTIME_ERROR)==NO_ERROR);

   return(catch("RestoreConfiguration(14)")==NO_ERROR);
}


/**
 * Gibt die lesbare Konstante eines Status-Codes zur�ck.
 *
 * @param  int status - Status-Code
 *
 * @return string
 */
string StatusToStr(int status) {
   switch (status) {
      case STATUS_UNDEFINED  : return("STATUS_UNDEFINED"  );
      case STATUS_WAITING    : return("STATUS_WAITING"    );
      case STATUS_PROGRESSING: return("STATUS_PROGRESSING");
      case STATUS_FINISHED   : return("STATUS_FINISHED"   );
      case STATUS_DISABLED   : return("STATUS_DISABLED"   );
   }
   catch("StatusToStr()  invalid parameter status = "+ status, ERR_INVALID_FUNCTION_PARAMVALUE);
   return("");
}


/**
 * Gibt die lesbare Konstante eines Entry-Types zur�ck.
 *
 * @param  int type - Entry-Type
 *
 * @return string
 */
string EntryTypeToStr(int type) {
   switch (type) {
      case ENTRYTYPE_UNDEFINED: return("ENTRYTYPE_UNDEFINED");
      case ENTRYTYPE_LIMIT    : return("ENTRYTYPE_LIMIT"    );
      case ENTRYTYPE_BANDS    : return("ENTRYTYPE_BANDS"    );
      case ENTRYTYPE_ENVELOPES: return("ENTRYTYPE_ENVELOPES");
   }
   catch("EntryTypeToStr()  invalid parameter type = "+ type, ERR_INVALID_FUNCTION_PARAMVALUE);
   return("");
}


/**
 * Gibt die Beschreibung eines Entry-Types zur�ck.
 *
 * @param  int type - Entry-Type
 *
 * @return string
 */
string EntryTypeDescription(int type) {
   switch (type) {
      case ENTRYTYPE_UNDEFINED: return("(undefined)"   );
      case ENTRYTYPE_LIMIT    : return("Limit"         );
      case ENTRYTYPE_BANDS    : return("BollingerBands");
      case ENTRYTYPE_ENVELOPES: return("Envelopes"     );
   }
   catch("EntryTypeToStr()  invalid parameter type = "+ type, ERR_INVALID_FUNCTION_PARAMVALUE);
   return("");
}


/**
 * Speichert die ID der aktuellen Sequenz im Chart, soda� sie nach einem Recompile-Event restauriert werden kann.
 *
 * @return int - Fehlerstatus
 */
int PersistIdForRecompile() {
   int hChWnd = WindowHandle(Symbol(), Period());

   string label = __SCRIPT__ +".hidden_storage";

   if (ObjectFind(label) != -1)
      ObjectDelete(label);
   ObjectCreate(label, OBJ_LABEL, 0, 0, 0);
   ObjectSet(label, OBJPROP_XDISTANCE, -sequenceId);                 // negative Werte (im nicht sichtbaren Bereich)
   ObjectSet(label, OBJPROP_YDISTANCE, -hChWnd);

   //debug("PersistIdForRecompile()     sequenceId="+ sequenceId +"   hWnd="+ WindowHandle(Symbol(), Period()));
   return(catch("PersistIdForRecompile()"));
}


/**
 * Restauriert die im Chart gespeicherte Sequenz-ID.
 *
 * @return bool - ob eine Sequenz-ID gefunden und restauriert wurde
 */
bool RestoreHiddenSequenceId() {
   string label = __SCRIPT__ +".hidden_storage";

   if (ObjectFind(label)!=-1) /*&&*/ if (ObjectType(label)==OBJ_LABEL) {
      int hWnd = MathAbs(ObjectGet(label, OBJPROP_YDISTANCE)) +0.1;
      int id   = MathAbs(ObjectGet(label, OBJPROP_XDISTANCE)) +0.1;  // (int) double

      if (hWnd == WindowHandle(Symbol(), Period())) {
         sequenceId = id;
         //debug("RestoreHiddenSequenceId()   restored sequenceId="+ id +" for hWnd="+ hWnd);
         return(catch("RestoreHiddenSequenceId(1)")==NO_ERROR);
      }
   }

   catch("RestoreHiddenSequenceId(2)");
   return(false);

   // Dummy-Calls, unterdr�cken Compilerwarnungen �ber unbenutzte Funktionen
   StatusToStr(NULL);
   EntryTypeToStr(NULL);
   EntryTypeDescription(NULL);
}

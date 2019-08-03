/**
 * SnowRoller - A pyramiding trade manager (aka an anti-martingale grid)
 *
 *
 * This EA is a trade manager and not a complete trading system. Entry and exit must be defined manually and the EA manages
 * the resulting trades in a pyramiding (i.e. anti-martingale) way. Martingale is as close to garantied total ruin as one can
 * get and accurately implemented anti-martingale is the exact opposite. By using this EA the trader forces the market into
 * the position of a martingale gambler and thus over time the market is destined to lose - against the trader. Credits for
 * theoretical background and proof of concept go to Bernd Kreuss aka 7bit and his publication "Snowballs and the Anti-Grid".
 *
 *  @see  https://sites.google.com/site/prof7bit/snowball
 *  @see  https://www.forexfactory.com/showthread.php?t=226059
 *  @see  https://www.forexfactory.com/showthread.php?t=239717
 *
 * Important:    The EA is not FIFO conforming, and will never be. Chose a decent broker!
 * Risk warning: A market can range longer than a trading account is able to survive. There's no free lunch.
 *
 *
 *  Actions, events and status changes:
 *  +------------------+---------------------+--------------------+----------+---------------+--------------------+
 *  | Action           |       Events        |        Status      | Position |    BE calc.   |     Detection      |
 *  +------------------+---------------------+--------------------+----------+---------------+--------------------+
 *  | EA.init()        |         -           | STATUS_UNDEFINED   |          |               |                    |
 *  |                  |                     |                    |          |               |                    |
 *  | EA.start()       |         -           | STATUS_WAITING     |          |               |                    |
 *  +------------------+---------------------+--------------------+----------+---------------+--------------------+
 *  | StartSequence()  | EV_SEQUENCE_START   | STATUS_PROGRESSING |    0     |       -       |                    | sequence.start.time = change to STATUS_PROGRESSING
 *  |                  |                     |                    |          |               |                    |
 *  | TrailGridbase    | EV_GRIDBASE_CHANGE  | STATUS_PROGRESSING |    0     |       -       |                    |
 *  |                  |                     |                    |          |               |                    |
 *  | OrderFilled      | EV_POSITION_OPEN    | STATUS_PROGRESSING |   1..n   |  yes (begin)  |   maxLevel != 0    |
 *  |                  |                     |                    |          |               |                    |
 *  | OrderStoppedOut  | EV_POSITION_STOPOUT | STATUS_PROGRESSING |   n..0   |      yes      |                    |
 *  |                  |                     |                    |          |               |                    |
 *  | TrailGridbase    | EV_GRIDBASE_CHANGE  | STATUS_PROGRESSING |    0     |      yes      |                    |
 *  |                  |                     |                    |          |               |                    |
 *  | StopSequence()   |         -           | STATUS_STOPPING    |    n     |  no (redraw)  | STATUS_STOPPING    |
 *  | PositionClose    | EV_POSITION_CLOSE   | STATUS_STOPPING    |   n..0   |     redraw    | PositionClose      |
 *  |                  | EV_SEQUENCE_STOP    | STATUS_STOPPED     |    0     | end of redraw | STATUS_STOPPED     | sequence.stop.time = change to STATUS_STOPPED
 *  +------------------+---------------------+--------------------+----------+---------------+--------------------+
 *  | ResumeSequence() |         -           | STATUS_STARTING    |    0     |       -       |                    | no valid gridbase yet
 *  | UpdateGridbase   | EV_GRIDBASE_CHANGE  | STATUS_STARTING    |    0     |       -       |                    |
 *  | PositionOpen     | EV_POSITION_OPEN    | STATUS_STARTING    |   0..n   |               |                    |
 *  |                  | EV_SEQUENCE_START   | STATUS_PROGRESSING |    n     |  yes (begin)  | STATUS_PROGRESSING | sequence.start.time = change to STATUS_PROGRESSING
 *  |                  |                     |                    |          |               |                    |
 *  | OrderFilled      | EV_POSITION_OPEN    | STATUS_PROGRESSING |   1..n   |      yes      |                    |
 *  |                  |                     |                    |          |               |                    |
 *  | OrderStoppedOut  | EV_POSITION_STOPOUT | STATUS_PROGRESSING |   n..0   |      yes      |                    |
 *  |                  |                     |                    |          |               |                    |
 *  | TrailGridbase    | EV_GRIDBASE_CHANGE  | STATUS_PROGRESSING |    0     |      yes      |                    |
 *  | ...              |                     |                    |          |               |                    |
 *  +------------------+---------------------+--------------------+----------+---------------+--------------------+
 */
#include <stddefines.mqh>
#include <app/SnowRoller/defines.mqh>
int   __INIT_FLAGS__[] = {INIT_TIMEZONE, INIT_PIPVALUE, INIT_CUSTOMLOG};
int __DEINIT_FLAGS__[];

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern string Sequence.ID             = "";
extern string GridDirection           = "Long | Short";  // there's no bi-directional mode (not profitable)
extern int    GridSize                = 20;
extern double LotSize                 = 0.1;
extern int    StartLevel              = 0;
extern string StartConditions         = "";              // @[bid|ask|price](double) && @time(datetime)
extern string StopConditions          = "";              // @[bid|ask|price](double) || @time(datetime) || @profit(double[%])
extern bool   ProfitDisplayInPercent  = true;            // whether PL values are displayed absolute or in percent

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#include <core/expert.mqh>
#include <stdfunctions.mqh>
#include <functions/JoinInts.mqh>
#include <functions/JoinStrings.mqh>
#include <rsfLibs.mqh>
#include <rsfHistory.mqh>
#include <structs/rsf/OrderExecution.mqh>
#include <win32api.mqh>

// ------------------------------------
string   last.Sequence.ID;                         // Variables for storing input parameters during INITREASON_PARAMETERS and
string   last.GridDirection;                       // INITREASON_TIMEFRAMECHANGE. On REASON_CHARTCHANGE programmatically loaded
int      last.GridSize;                            // input parameters (from presets file) get lost. Storing them allows comparison
double   last.LotSize;                             // of new with previous values and to fall-back in case of errors.
int      last.StartLevel;                          //
string   last.StartConditions;                     // see onInit()/onDeinit()
string   last.StopConditions;
bool     last.ProfitDisplayInPercent;

// ------------------------------------
int      sequence.id;
string   sequence.name;                            // "L.1234" | "S.2345"
int      sequence.status;
bool     sequence.isTest;                          // whether the sequence was created in tester (a finished test can be loaded in a live chart)
int      sequence.direction;
int      sequence.level;                           // current grid level:      -n...0...+n
int      sequence.maxLevel;                        // max. reached grid level: -n...0...+n
int      sequence.missedLevels[];                  // grid levels missed due to a fast moving market
double   sequence.startEquity;
int      sequence.stops;                           // number of stopped-out positions: 0...+n
double   sequence.stopsPL;                         // accumulated P/L of all stopped-out positions
double   sequence.closedPL;                        // accumulated P/L of all positions closed at sequence stop
double   sequence.floatingPL;                      // accumulated P/L of all open positions
double   sequence.totalPL;                         // current total P/L of the sequence: totalPL = stopsPL + closedPL + floatingPL
double   sequence.maxProfit;                       // max. experienced total sequence profit:   0...+n
double   sequence.maxDrawdown;                     // max. experienced total sequence drawdown: -n...0
double   sequence.commission;                      // commission value per grid level:          -n...0

// ------------------------------------
int      sequence.start.event [];                  // Start-Daten (Moment von Statuswechsel zu STATUS_PROGRESSING)
datetime sequence.start.time  [];
double   sequence.start.price [];
double   sequence.start.profit[];

int      sequence.stop.event  [];                  // Stop-Daten (Moment von Statuswechsel zu STATUS_STOPPED)
datetime sequence.stop.time   [];
double   sequence.stop.price  [];                  // average realized close price of all closed positions
double   sequence.stop.profit [];

// ------------------------------------
bool     start.conditions;                         // whether defined start conditions are active (all AND combined)

bool     start.price.condition;
int      start.price.type;                         // PRICE_BID|PRICE_ASK|PRICE_MEDIAN
double   start.price.value;
double   start.price.lastValue;

bool     start.time.condition;
datetime start.time.value;

// ------------------------------------
bool     stop.price.condition;                     // whether a defined stop price condition is active
int      stop.price.type;                          // PRICE_BID|PRICE_ASK|PRICE_MEDIAN
double   stop.price.value;
double   stop.price.lastValue;

bool     stop.time.condition;                      // whether a defined stop time condition is active
datetime stop.time.value;

bool     stop.profitAbs.condition;                 // whether a defined absolute stop profit condition is active
double   stop.profitAbs.value;

bool     stop.profitPct.condition;                 // whether a defined percentage stop profit condition is active
double   stop.profitPct.value;
double   stop.profitPct.absValue = INT_MAX;

// ------------------------------------
datetime weekend.stop.condition = D'1970.01.01 23:05';   // StopSequence()-Zeitpunkt vor Wochenend-Pause (Freitags abend)
datetime weekend.stop.time;
bool     weekend.stop.active;                            // Sequenz-Eigenschaft (unterscheidet zwischen vor�bergehend und dauerhaft gestoppter Sequenz)

datetime weekend.resume.condition = D'1970.01.01 01:10'; // sp�tester ResumeSequence()-Zeitpunkt nach Wochenend-Pause (Montags morgen)
datetime weekend.resume.time;
bool     weekend.resume.triggered;                       // ???

// ------------------------------------
double   grid.base;                                      // current grid base
int      grid.base.event  [];                            // grid base history
datetime grid.base.time   [];
double   grid.base.value  [];

// ------------------------------------
int      orders.ticket         [];
int      orders.level          [];                       // order grid level: -n...-1 | 1...+n
double   orders.gridBase       [];                       // grid base when the order was active

int      orders.pendingType    [];                       // pending order type (if applicable)        or -1
datetime orders.pendingTime    [];                       // time of OrderOpen() or last OrderModify() or  0
double   orders.pendingPrice   [];                       // pending entry limit                       or  0

int      orders.type           [];
int      orders.openEvent      [];
datetime orders.openTime       [];
double   orders.openPrice      [];
int      orders.closeEvent     [];
datetime orders.closeTime      [];
double   orders.closePrice     [];
double   orders.stopLoss       [];
bool     orders.clientsideLimit[];                       // whether a limit is managed client-side
bool     orders.closedBySL     [];

double   orders.swap           [];
double   orders.commission     [];
double   orders.profit         [];

// ------------------------------------
int      ignorePendingOrders  [];                        // orphaned tickets to ignore
int      ignoreOpenPositions  [];                        // ...
int      ignoreClosedPositions[];                        // ...

// ------------------------------------
string   statusFile      = "";                           // Dateiname der Statusdatei
string   statusDirectory = "";                           // Verzeichnisname der Statusdatei relativ zu "files/"

// ------------------------------------
int      startStopDisplayMode = SDM_PRICE;               // whether start/stop markers are displayed
int      orderDisplayMode     = ODM_PYRAMID;             // current order display mode

// ------------------------------------
string   str.LotSize               = "";                 // Zwischenspeicher zur schnelleren Abarbeitung von ShowStatus()
string   str.grid.base             = "";
string   str.sequence.direction    = "";
string   str.sequence.missedLevels = "";
string   str.sequence.stops        = "";
string   str.sequence.stopsPL      = "";
string   str.sequence.totalPL      = "";
string   str.sequence.maxProfit    = "";
string   str.sequence.maxDrawdown  = "";
string   str.sequence.plStats      = "";
string   str.startConditions       = "";
string   str.stopConditions        = "";


#include <app/SnowRoller/init.mqh>
#include <app/SnowRoller/deinit.mqh>


/**
 * Main function
 *
 * @return int - error status
 */
int onTick() {
   if (sequence.status == STATUS_UNDEFINED)
      return(NO_ERROR);

   // process chart commands
   HandleEvent(EVENT_CHART_CMD);

   bool gridChanged;                                        // whether the current grid base or level changed
   int  activatedLimits[];                                  // order indexes of activated client-side limits

   // ...sequence either waits for start signal...
   if (sequence.status == STATUS_WAITING) {
      if (IsStartSignal()) StartSequence();
   }

   // ...or sequence waits for resume signal...
   else if (sequence.status == STATUS_STOPPED) {
      if  (IsResumeSignal()) ResumeSequence();
      else return(last_error);
   }

   // ...or sequence is running...
   else if (UpdateStatus(gridChanged, activatedLimits)) {
      if (IsStopSignal()) StopSequence();
      else {
         if (ArraySize(activatedLimits) > 0) ProcessLocalLimits(activatedLimits);
         if (gridChanged)                    UpdatePendingOrders();
      }
   }

   // update equity value for equity recorder
   if (EA.RecordEquity)
      test.equity.value = sequence.startEquity + sequence.totalPL;
   return(last_error);
}


/**
 * Handler f�r ChartCommand-Events.
 *
 * @param  string commands[] - die �bermittelten Kommandos
 *
 * @return bool - success status
 */
bool onChartCommand(string commands[]) {
   if (ArraySize(commands) == 0)
      return(_true(warn("onChartCommand(1)  empty parameter commands = {}")));

   string cmd = commands[0];

   if (cmd == "start") {
      switch (sequence.status) {
         case STATUS_WAITING: StartSequence();  break;
         case STATUS_STOPPED: ResumeSequence(); break;
      }
      return(true);
   }

   else if (cmd == "stop") {
      switch (sequence.status) {
         case STATUS_WAITING:
         case STATUS_PROGRESSING:
            bool bNull;
            int  iNull[];
            if (UpdateStatus(bNull, iNull)) StopSequence();
      }
      return(true);
   }

   else if (cmd ==     "orderdisplay") return(!ToggleOrderDisplayMode()    );
   else if (cmd == "startstopdisplay") return(!ToggleStartStopDisplayMode());

   // unbekannte Commands anzeigen, aber keinen Fehler setzen (EA soll weiterlaufen)
   return(_true(warn("onChartCommand(2)  unknown command \""+ cmd +"\"")));
}


/**
 * Startet eine neue Trade-Sequenz.
 *
 * @return bool - Erfolgsstatus
 */
bool StartSequence() {
   if (IsLastError())                     return( false);
   if (sequence.status != STATUS_WAITING) return(_false(catch("StartSequence(1)  cannot start "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("StartSequence()", "Do you really want to start a new sequence now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   sequence.status = STATUS_STARTING;
   if (__LOG()) log("StartSequence(2)  starting sequence "+ sequence.name);

   // Startvariablen setzen
   sequence.level       = ifInt(sequence.direction==D_LONG, StartLevel, -StartLevel);
   sequence.maxLevel    = sequence.level;
   sequence.startEquity = NormalizeDouble(AccountEquity()-AccountCredit(), 2);

   datetime startTime  = TimeCurrentEx("StartSequence(3)");
   double   startPrice = ifDouble(sequence.direction==D_SHORT, Bid, Ask);

   ArrayPushInt   (sequence.start.event,  CreateEventId());
   ArrayPushInt   (sequence.start.time,   startTime      );
   ArrayPushDouble(sequence.start.price,  startPrice     );
   ArrayPushDouble(sequence.start.profit, 0              );

   ArrayPushInt   (sequence.stop.event,   0              );          // Gr��e von sequence.starts/stops synchron halten
   ArrayPushInt   (sequence.stop.time,    0              );
   ArrayPushDouble(sequence.stop.price,   0              );
   ArrayPushDouble(sequence.stop.profit,  0              );

   // Gridbasis setzen (Event zeitlich nach sequence.start.time)
   double gridBase = NormalizeDouble(startPrice - sequence.level*GridSize*Pips, Digits);
   GridBase.Reset(startTime, gridBase);

   // ggf. Startpositionen in den Markt legen und Sequence-StartPrice aktualisieren
   if (sequence.level != 0) {
      datetime dNull;
      if (!RestorePositions(dNull, startPrice)) return(false);
      sequence.start.price[ArraySize(sequence.start.price)-1] = startPrice;
   }

   sequence.status = STATUS_PROGRESSING;

   // Stop-Orders in den Markt legen
   if (!UpdatePendingOrders()) return(false);

   // StartConditions deaktivieren, Weekend-Stop aktualisieren
   start.conditions = false; SS.StartStopConditions();
   UpdateWeekendStop();
   RedrawStartStop();

   if (__LOG()) log("StartSequence(4)  sequence "+ sequence.name +" started at "+ NumberToStr(startPrice, PriceFormat) + ifString(sequence.level, " and level "+ sequence.level, ""));
   return(!last_error|catch("StartSequence(5)"));
}


/**
 * Schlie�t alle PendingOrders und offenen Positionen der Sequenz.
 *
 * @return bool - Erfolgsstatus: ob die Sequenz erfolgreich gestoppt wurde
 */
bool StopSequence() {
   if (IsLastError())                             return( false);
   if (IsTestSequence()) /*&&*/ if (!IsTesting()) return(_false(catch("StopSequence(1)", ERR_ILLEGAL_STATE)));

   if (sequence.status!=STATUS_WAITING) /*&&*/ if (sequence.status!=STATUS_PROGRESSING) /*&&*/ if (sequence.status!=STATUS_STOPPING)
      if (!IsTesting() || __WHEREAMI__!=CF_DEINIT || sequence.status!=STATUS_STOPPED) // ggf. wird nach Testende nur aufger�umt
         return(_false(catch("StopSequence(2)  cannot stop "+ sequenceStatusDescr[sequence.status] +" sequence "+ sequence.name, ERR_RUNTIME_ERROR)));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("StopSequence()", "Do you really want to stop sequence "+ sequence.name +" now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   // eine wartende Sequenz ist noch nicht gestartet und wird gecanceled
   if (sequence.status == STATUS_WAITING) {
      if (IsTesting()) Tester.Pause();
      SetLastError(ERR_CANCELLED_BY_USER);
      return(_false(catch("StopSequence(3)")));
   }

   if (sequence.status != STATUS_STOPPED) {
      sequence.status = STATUS_STOPPING;
      if (__LOG()) log("StopSequence(4)  stopping sequence "+ sequence.name +" at level "+ sequence.level);
   }

   // PendingOrders und OpenPositions einlesen
   int pendings[], positions[], sizeOfTickets=ArraySize(orders.ticket);
   ArrayResize(pendings, 0);
   ArrayResize(positions, 0);

   for (int i=sizeOfTickets-1; i >= 0; i--) {
      if (!orders.closeTime[i]) {                                                                  // Ticket pr�fen: wenn es beim letzten Aufruf noch offen war
         if (orders.ticket[i] < 0) {
            if (!Grid.DropData(i)) return(false);                                                  // client-seitige Pending-Orders k�nnen intern gel�scht werden
            sizeOfTickets--;
            continue;
         }
         if (!SelectTicket(orders.ticket[i], "StopSequence(5)")) return(false);
         if (!OrderCloseTime()) {                                                                  // offene Tickets je nach Typ zwischenspeichern
            if (IsPendingTradeOperation(OrderType())) ArrayPushInt(pendings,                i);    // Grid.DeleteOrder() erwartet den Array-Index
            else                                      ArrayPushInt(positions, orders.ticket[i]);   // OrderMultiClose() erwartet das Orderticket
         }
      }
   }

   // zuerst Pending-Orders streichen (ansonsten k�nnten sie w�hrend OrderClose() noch getriggert werden)
   int sizeOfPendings = ArraySize(pendings);
   for (i=0; i < sizeOfPendings; i++) {
      if (!Grid.DeleteOrder(pendings[i])) return(false);
   }

   // dann offene Positionen schlie�en                // TODO: Wurde eine PendingOrder inzwischen getriggert, mu� sie hier mit verarbeitet werden.
   int      sizeOfPositions=ArraySize(positions), n=ArraySize(sequence.stop.event)-1;
   datetime closeTime;
   double   closePrice;

   if (sizeOfPositions > 0) {
      int oeFlags = NULL;
      int oes[][ORDER_EXECUTION.intSize];
      if (!OrderMultiClose(positions, NULL, CLR_CLOSE, oeFlags, oes)) return(false);

      for (i=0; i < sizeOfPositions; i++) {
         int pos = SearchIntArray(orders.ticket, positions[i]);

         orders.closeEvent[pos] = CreateEventId();
         orders.closeTime [pos] = oes.CloseTime (oes, i);
         orders.closePrice[pos] = oes.ClosePrice(oes, i);
         orders.closedBySL[pos] = false;
         orders.swap      [pos] = oes.Swap      (oes, i);
         orders.commission[pos] = oes.Commission(oes, i);
         orders.profit    [pos] = oes.Profit    (oes, i);

         sequence.closedPL = NormalizeDouble(sequence.closedPL + orders.swap[pos] + orders.commission[pos] + orders.profit[pos], 2);

         closeTime   = Max(closeTime, orders.closeTime[pos]);        // die Close-Werte k�nnen unterschiedlich sein
         closePrice += orders.closePrice[pos];                       // (i.d.R. sind sie �berall gleich)
      }
      closePrice /= Abs(sequence.level);                             // avg(ClosePrice) TODO: falsch, wenn bereits ein Teil der Positionen geschlossen war
      /*
      sequence.floatingPL  = ...                                     // unten in UpdateStatus() werden diese Werte automatisch aktualisiert
      sequence.totalPL     = ...
      sequence.maxProfit   = ...
      sequence.maxDrawdown = ...
      */
      sequence.stop.event[n] = CreateEventId();
      sequence.stop.time [n] = closeTime;
      sequence.stop.price[n] = NormalizeDouble(closePrice, Digits);
   }

   // keine offenen Positionen
   else if (sequence.status != STATUS_STOPPED) {
      sequence.stop.event[n] = CreateEventId();
      sequence.stop.time [n] = TimeCurrentEx("StopSequence(6)");
      sequence.stop.price[n] = ifDouble(sequence.direction==D_LONG, Bid, Ask);
   }

   // StopPrice begrenzen (darf nicht schon den n�chsten Level triggern)
   if (!StopSequence.LimitStopPrice())
      return(false);

   if (sequence.status != STATUS_STOPPED) {
      sequence.status = STATUS_STOPPED;
      if (__LOG()) log("StopSequence(7)  sequence "+ sequence.name +" stopped at "+ NumberToStr(sequence.stop.price[n], PriceFormat) +", level "+ sequence.level);
   }

   // ResumeConditions aktualisieren
   if (IsWeekendStopSignal())
      UpdateWeekendResumeTime();

   // Status aktualisieren
   bool bNull;
   int  iNull[];
   if (!UpdateStatus(bNull, iNull)) return(false);
   sequence.stop.profit[n] = sequence.totalPL;

   // Status speichern
   if (!SaveStatus()) return(false);
   RedrawStartStop();

   // ggf. Tester stoppen
   if (IsTesting()) {
      if (IsVisualMode())              Tester.Pause();
      else if (!IsWeekendStopSignal()) Tester.Stop();
   }
   return(!last_error|catch("StopSequence(8)"));
}


/**
 * Der StopPrice darf nicht schon den n�chsten Level triggern, da sonst bei ResumeSequence() Fehler auftreten.
 *
 * @return bool - Erfolgsstatus
 */
bool StopSequence.LimitStopPrice() {
   if (IsLastError())                                                                return( false);
   if (IsTestSequence()) /*&&*/ if (!IsTesting())                                    return(_false(catch("StopSequence.LimitStopPrice(1)", ERR_ILLEGAL_STATE)));
   if (sequence.status!=STATUS_STOPPING) /*&&*/ if (sequence.status!=STATUS_STOPPED) return(_false(catch("StopSequence.LimitStopPrice(2)  cannot limit stop price of "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));

   double nextTrigger;
   int i = ArraySize(sequence.stop.price) - 1;

   if (sequence.direction == D_LONG) {
      nextTrigger = grid.base + (sequence.level+1)*GridSize*Pip;
      sequence.stop.price[i] = MathMin(nextTrigger-1*Pip, sequence.stop.price[i]);  // max. 1 Pip unterm Trigger des n�chsten Levels
   }

   if (sequence.direction == D_SHORT) {
      nextTrigger = grid.base + (sequence.level-1)*GridSize*Pip;
      sequence.stop.price[i] = MathMax(nextTrigger+1*Pip, sequence.stop.price[i]);  // min. 1 Pip �berm Trigger des n�chsten Levels
   }
   sequence.stop.price[i] = NormalizeDouble(sequence.stop.price[i], Digits);

   return(!last_error|catch("StopSequence.LimitStopPrice(3)"));
}


/**
 * Setzt eine gestoppte Sequenz fort.
 *
 * @return bool - Erfolgsstatus
 */
bool ResumeSequence() {
   if (IsLastError())                                                                return( false);
   if (IsTestSequence()) /*&&*/ if (!IsTesting())                                    return(_false(catch("ResumeSequence(1)", ERR_ILLEGAL_STATE)));
   if (sequence.status!=STATUS_STOPPED) /*&&*/ if (sequence.status!=STATUS_STARTING) return(_false(catch("ResumeSequence(2)  cannot resume "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("ResumeSequence()", "Do you really want to resume sequence "+ sequence.name +" now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   datetime startTime;
   double   gridBase, startPrice, lastStopPrice = sequence.stop.price[ArraySize(sequence.stop.price)-1];

   sequence.status = STATUS_STARTING;
   if (__LOG()) log("ResumeSequence(3)  resuming sequence "+ sequence.name +" at level "+ sequence.level +" (stopped at "+ NumberToStr(lastStopPrice, PriceFormat) +", gridbase "+ NumberToStr(grid.base, PriceFormat) +")");

   // Wird ResumeSequence() nach einem Fehler erneut aufgerufen, kann es sein, da� einige Level bereits offen sind und andere noch fehlen.
   if (sequence.level > 0) {
      for (int level=1; level <= sequence.level; level++) {
         int i = Grid.FindOpenPosition(level);
         if (i != -1) {
            gridBase = orders.gridBase[i];                     // look-up a previously used gridbase
            break;
         }
      }
   }
   else if (sequence.level < 0) {
      for (level=-1; level >= sequence.level; level--) {
         i = Grid.FindOpenPosition(level);
         if (i != -1) {
            gridBase = orders.gridBase[i];
            break;
         }
      }
   }

   // Gridbasis neu setzen, wenn keine offenen Positionen gefunden wurden.
   if (!gridBase) {
      startTime  = TimeCurrentEx("ResumeSequence(4)");
      startPrice = ifDouble(sequence.direction==D_SHORT, Bid, Ask);
      GridBase.Change(startTime, grid.base + startPrice - lastStopPrice);
   }
   else {
      grid.base = NormalizeDouble(gridBase, Digits);           // Gridbasis der vorhandenen Positionen �bernehmen (sollte schon gesetzt sein, doch wer wei�...)
   }

   // vorherige Positionen wieder in den Markt legen und last(OrderOpenTime) und avg(OrderOpenPrice) erhalten
   if (!RestorePositions(startTime, startPrice)) return(false);

   // neuen Sequenzstart speichern
   ArrayPushInt   (sequence.start.event,  CreateEventId() );
   ArrayPushInt   (sequence.start.time,   startTime       );
   ArrayPushDouble(sequence.start.price,  startPrice      );
   ArrayPushDouble(sequence.start.profit, sequence.totalPL);   // entspricht dem letzten Stop-Wert

   ArrayPushInt   (sequence.stop.event,  0);                   // sequence.starts/stops synchron halten
   ArrayPushInt   (sequence.stop.time,   0);
   ArrayPushDouble(sequence.stop.price,  0);
   ArrayPushDouble(sequence.stop.profit, 0);

   sequence.status = STATUS_PROGRESSING;                       // TODO: correct the resulting gridbase and adjust the previously set stoplosses

   // Stop-Orders vervollst�ndigen
   if (!UpdatePendingOrders()) return(false);

   // StartConditions deaktivieren und Weekend-Stop aktualisieren
   start.conditions         = false; SS.StartStopConditions();
   weekend.resume.triggered = false;
   weekend.resume.time      = 0;
   UpdateWeekendStop();

   // Status aktualisieren und speichern
   bool changes;
   int  iNull[];                                               // Wurde in RestorePositions()->Grid.AddPosition() ein Magic-Ticket #-2 for "Spread violation"
   if (!UpdateStatus(changes, iNull)) return(false);           // erzeugt, wird es in UpdateStatus() mit PL=0.00 "geschlossen" und der Sequence-Level verringert.
   if (changes) UpdatePendingOrders();                         // In diesem Fall m�ssen die Pending-Orders nochmal aktualisiert werden.
   if (!SaveStatus()) return(false);

   // Anzeige aktualisieren
   RedrawStartStop();

   if (__LOG()) log("ResumeSequence(7)  sequence "+ sequence.name +" resumed at level "+ sequence.level +" (start price "+ NumberToStr(startPrice, PriceFormat) +", new gridbase "+ NumberToStr(grid.base, PriceFormat) +")");
   return(!last_error|catch("ResumeSequence(8)"));
}


/**
 * Restore open positions and limit orders for missed sequence levels. Called from StartSequence() and ResumeSequence().
 *
 * @param  datetime &lpOpenTime  - variable receiving the OpenTime of the last opened position
 * @param  double   &lpOpenPrice - variable receiving the average OpenPrice of all open positions
 *
 * @return bool - success status
 *
 * NOTE: If the sequence is at level 0 the passed variables are not modified.
 */
bool RestorePositions(datetime &lpOpenTime, double &lpOpenPrice) {
   if (IsLastError())                             return( false);
   if (IsTestSequence()) /*&&*/ if (!IsTesting()) return(_false(catch("RestorePositions(1)", ERR_ILLEGAL_STATE)));
   if (sequence.status != STATUS_STARTING)        return(_false(catch("RestorePositions(2)  cannot restore positions of "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));

   int i, level, missedLevels=ArraySize(sequence.missedLevels);
   bool isMissedLevel, success;
   datetime openTime;
   double openPrice;

   // Long
   if (sequence.level > 0) {
      for (level=1; level <= sequence.level; level++) {
         isMissedLevel = IntInArray(sequence.missedLevels, level);
         i = Grid.FindOpenPosition(level);
         if (i == -1) {
            if (isMissedLevel) success = Grid.AddPendingOrder(level);
            else               success = Grid.AddPosition(level);
            if (!success) return(false);
            i = ArraySize(orders.ticket) - 1;
         }
         else {
            // TODO: check/update the stoploss
         }
         if (!isMissedLevel) {
            openTime   = Max(openTime, orders.openTime[i]);
            openPrice += orders.openPrice[i];
         }
      }
      openPrice /= (Abs(sequence.level)-missedLevels);                  // avg(OpenPrice)
   }

   // Short
   else if (sequence.level < 0) {
      for (level=-1; level >= sequence.level; level--) {
         isMissedLevel = IntInArray(sequence.missedLevels, level);
         i = Grid.FindOpenPosition(level);
         if (i == -1) {
            if (isMissedLevel) success = Grid.AddPendingOrder(level);
            else               success = Grid.AddPosition(level);
            if (!success) return(false);
            i = ArraySize(orders.ticket) - 1;
         }
         else {
            // TODO: check/update the stoploss
         }
         if (!isMissedLevel) {
            openTime   = Max(openTime, orders.openTime[i]);
            openPrice += orders.openPrice[i];
         }
      }
      openPrice /= (Abs(sequence.level)-missedLevels);                  // avg(OpenPrice)
   }

   if (sequence.level != 0) {
      if (!SaveStatus()) return(false);
   }

   // write-back results to the passed variables
   if (openTime != 0) {                                                 // sequence.level != 0
      lpOpenTime  = openTime;
      lpOpenPrice = NormalizeDouble(openPrice, Digits);
   }
   return(!last_error|catch("RestorePositions(3)"));
}


/**
 * Pr�ft und synchronisiert die im EA gespeicherten mit den aktuellen Laufzeitdaten.
 *
 * @param  _Out_ bool &gridChanged       - variable indicating whether the current grid base or level changed
 * @param  _Out_ int   activatedLimits[] - array receiving the order indexes of activated client-side limits
 *
 * @return bool - success status
 */
bool UpdateStatus(bool &gridChanged, int activatedLimits[]) {
   gridChanged = gridChanged!=0;

   ArrayResize(activatedLimits, 0);
   if (IsLastError())                     return(false);
   if (sequence.status == STATUS_WAITING) return(true);

   bool wasPending, isClosed, openPositions, updateStatusLocation;
   int  closed[][2], close[2], sizeOfTickets=ArraySize(orders.ticket); ArrayResize(closed, 0);
   sequence.floatingPL = 0;

   // Tickets aktualisieren
   for (int i=0; i < sizeOfTickets; i++) {
      if (!orders.closeTime[i]) {                                                // Ticket pr�fen, wenn es beim letzten Aufruf offen war
         wasPending = (orders.type[i] == OP_UNDEFINED);

         // client-seitige PendingOrders pr�fen
         if (wasPending) /*&&*/ if (orders.ticket[i] == -1) {
            if (IsStopTriggered(orders.pendingType[i], orders.pendingPrice[i])) {
               if (__LOG()) log("UpdateStatus(1)  "+ UpdateStatus.StopTriggerMsg(i));
               ArrayPushInt(activatedLimits, i);
            }
            continue;
         }

         // Magic-Ticket #-2 pr�fen (wird sofort hier "geschlossen")
         if (orders.ticket[i] == -2) {
            orders.closeEvent[i] = CreateEventId();                              // Event-ID kann sofort vergeben werden.
            orders.closeTime [i] = TimeCurrentEx("UpdateStatus(2)");
            orders.closePrice[i] = orders.openPrice[i];
            orders.closedBySL[i] = true;
            Chart.MarkPositionClosed(i);
            if (__LOG()) log("UpdateStatus(3)  "+ UpdateStatus.StopLossMsg(i));

            sequence.level  -= Sign(orders.level[i]);
            sequence.stops++; SS.Stops();
          //sequence.stopsPL = ...                                               // unver�ndert, da P/L des Magic-Tickets #-2 immer 0.00 ist
            gridChanged      = true;
            continue;
         }

         // regul�re server-seitige Tickets
         if (!SelectTicket(orders.ticket[i], "UpdateStatus(4)")) return(false);

         if (wasPending) {
            // beim letzten Aufruf Pending-Order
            if (OrderType() != orders.pendingType[i]) {                          // order limit was executed
               orders.type      [i] = OrderType();
               orders.openEvent [i] = CreateEventId();
               orders.openTime  [i] = OrderOpenTime();
               orders.openPrice [i] = OrderOpenPrice();
               orders.swap      [i] = OrderSwap();
               orders.commission[i] = OrderCommission(); sequence.commission = OrderCommission(); SS.LotSize();
               orders.profit    [i] = OrderProfit();
               Chart.MarkOrderFilled(i);
               if (__LOG()) log("UpdateStatus(5)  "+ UpdateStatus.OrderFillMsg(i));

               if (IsStopOrder(i)) {
                  sequence.level   += Sign(orders.level[i]);
                  sequence.maxLevel = Sign(orders.level[i]) * Max(Abs(sequence.level), Abs(sequence.maxLevel));
                  gridChanged       = true;
               }
               else {
                  ArrayDropInt(sequence.missedLevels, orders.level[i]);          // update missed grid levels
                  SS.MissedLevels();
               }
               updateStatusLocation = updateStatusLocation || !sequence.maxLevel;// what's this needed for???
            }
         }
         else {
            // beim letzten Aufruf offene Position
            orders.swap      [i] = OrderSwap();
            orders.commission[i] = OrderCommission();
            orders.profit    [i] = OrderProfit();
         }

         isClosed = OrderCloseTime() != 0;                                       // Bei Spikes kann eine Pending-Order ausgef�hrt *und* bereits geschlossen sein.
         if (!isClosed) {                                                        // weiterhin offenes Ticket
            if (orders.type[i] != OP_UNDEFINED) {
               openPositions = true;
               if (orders.clientsideLimit[i]) /*&&*/ if (IsStopTriggered(orders.type[i], orders.stopLoss[i])) {
                  if (__LOG()) log("UpdateStatus(6)  "+ UpdateStatus.StopTriggerMsg(i));
                  ArrayPushInt(activatedLimits, i);
               }
            }
            sequence.floatingPL = NormalizeDouble(sequence.floatingPL + orders.swap[i] + orders.commission[i] + orders.profit[i], 2);
         }
         else if (orders.type[i] == OP_UNDEFINED) {                              // jetzt geschlossenes Ticket: gestrichene Pending-Order
            Grid.DropData(i);
            sizeOfTickets--; i--;
         }
         else {
            orders.closeTime [i] = OrderCloseTime();                             // jetzt geschlossenes Ticket: geschlossene Position
            orders.closePrice[i] = OrderClosePrice();
            orders.closedBySL[i] = IsOrderClosedBySL();
            Chart.MarkPositionClosed(i);

            if (orders.closedBySL[i]) {                                          // ausgestoppt
               orders.closeEvent[i] = CreateEventId();                           // Event-ID kann sofort vergeben werden.
               if (__LOG()) log("UpdateStatus(7)  "+ UpdateStatus.StopLossMsg(i));
               sequence.level  -= Sign(orders.level[i]);
               sequence.stops++;
               sequence.stopsPL = NormalizeDouble(sequence.stopsPL + orders.swap[i] + orders.commission[i] + orders.profit[i], 2); SS.Stops();
               gridChanged      = true;
            }
            else {                                                               // rekursiver Aufruf durch StopSequence() oder Auto-Close durch Tester bei Testende
               close[0] = OrderCloseTime();
               close[1] = OrderTicket();                                         // Geschlossene Positionen werden zwischengespeichert, um ihnen Event-IDs
               ArrayPushInts(closed, close);                                     // zeitlich *nach* den ausgestoppten Positionen zuweisen zu k�nnen.

               if (sequence.status != STATUS_STOPPED)
                  sequence.status = STATUS_STOPPING;
               if (__LOG()) log("UpdateStatus(8)  "+ UpdateStatus.PositionCloseMsg(i));
               sequence.closedPL = NormalizeDouble(sequence.closedPL + orders.swap[i] + orders.commission[i] + orders.profit[i], 2);
            }
         }
      }
   }

   // Event-IDs geschlossener Positionen setzen (zeitlich nach allen ausgestoppten Positionen)
   int sizeOfClosed = ArrayRange(closed, 0);
   if (sizeOfClosed > 0) {
      ArraySort(closed);
      for (i=0; i < sizeOfClosed; i++) {
         int n = SearchIntArray(orders.ticket, closed[i][1]);
         if (n == -1) return(_false(catch("UpdateStatus(9)  closed ticket #"+ closed[i][1] +" not found in order arrays", ERR_RUNTIME_ERROR)));
         orders.closeEvent[n] = CreateEventId();
      }
      ArrayResize(closed, 0);
   }

   // update PL numbers
   sequence.totalPL = NormalizeDouble(sequence.stopsPL + sequence.closedPL + sequence.floatingPL, 2); SS.TotalPL();
   if      (sequence.totalPL > sequence.maxProfit  ) { sequence.maxProfit   = sequence.totalPL; SS.MaxProfit();   }
   else if (sequence.totalPL < sequence.maxDrawdown) { sequence.maxDrawdown = sequence.totalPL; SS.MaxDrawdown(); }

   // ggf. Status aktualisieren
   if (sequence.status == STATUS_STOPPING) {
      if (!openPositions) {                                                      // rekursiver Aufruf durch StopSequence() oder Auto-Close durch Tester bei Testende
         n = ArraySize(sequence.stop.event) - 1;
         sequence.stop.event [n] = CreateEventId();
         sequence.stop.time  [n] = UpdateStatus.CalculateStopTime();  if (!sequence.stop.time [n]) return(false);
         sequence.stop.price [n] = UpdateStatus.CalculateStopPrice(); if (!sequence.stop.price[n]) return(false);
         sequence.stop.profit[n] = sequence.totalPL;

         if (!StopSequence.LimitStopPrice())                                     //  StopPrice begrenzen (darf nicht schon den n�chsten Level triggern)
            return(false);

         sequence.status = STATUS_STOPPED;
         if (__LOG()) log("UpdateStatus(10)  STATUS_STOPPED");
         RedrawStartStop();
      }
   }

   // ggf. Gridbasis trailen
   else if (sequence.status == STATUS_PROGRESSING) {
      if (!sequence.level) {
         double last = grid.base;
         if (sequence.direction == D_LONG) grid.base = MathMin(grid.base, NormalizeDouble((Bid + Ask)/2, Digits));
         else                              grid.base = MathMax(grid.base, NormalizeDouble((Bid + Ask)/2, Digits));

         if (NE(grid.base, last, Digits)) {
            GridBase.Change(TimeCurrentEx("UpdateStatus(11)"), grid.base);
            gridChanged = true;
         }
         // Gridbasis des letzten Tickets inspizieren
         else if (NE(orders.gridBase[sizeOfTickets-1], grid.base, Digits)) {
            gridChanged = true;
         }
      }
   }

   // ggf. Ort der Statusdatei aktualisieren
   if (updateStatusLocation)
      UpdateStatusLocation();
   return(!last_error|catch("UpdateStatus(12)"));
}


/**
 * Compose a log message for a filled entry order.
 *
 * @param  int i - order index
 *
 * @return string
 */
string UpdateStatus.OrderFillMsg(int i) {
   // #1 Stop Sell 0.1 GBPUSD at 1.5457'2 ("SR.8692.+17") was filled[ at 1.5457'2 (0.3 pip [positive ]slippage)]
   string sType         = OperationTypeDescription(orders.pendingType[i]);
   string sPendingPrice = NumberToStr(orders.pendingPrice[i], PriceFormat);
   string comment       = "SR."+ sequence.id +"."+ NumberToStr(orders.level[i], "+.");
   string message       = "#"+ orders.ticket[i] +" "+ sType +" "+ NumberToStr(LotSize, ".+") +" "+ Symbol() +" at "+ sPendingPrice +" (\""+ comment +"\") was filled";

   if (NE(orders.pendingPrice[i], orders.openPrice[i])) {
      double slippage = (orders.openPrice[i] - orders.pendingPrice[i])/Pip;
         if (orders.type[i] == OP_SELL)
            slippage = -slippage;
      string sSlippage;
      if (slippage > 0) sSlippage = DoubleToStr(slippage, Digits & 1) +" pip slippage";
      else              sSlippage = DoubleToStr(-slippage, Digits & 1) +" pip positive slippage";
      message = message +" at "+ NumberToStr(orders.openPrice[i], PriceFormat) +" ("+ sSlippage +")";
   }
   return(message);
}


/**
 * Compose a log message for a closed position.
 *
 * @param  int i - order index
 *
 * @return string
 */
string UpdateStatus.PositionCloseMsg(int i) {
   // #1 Sell 0.1 GBPUSD at 1.5457'2 ("SR.8692.+17") was closed at 1.5457'2
   string sType       = OperationTypeDescription(orders.type[i]);
   string sOpenPrice  = NumberToStr(orders.openPrice[i], PriceFormat);
   string sClosePrice = NumberToStr(orders.closePrice[i], PriceFormat);
   string comment     = "SR."+ sequence.id +"."+ NumberToStr(orders.level[i], "+.");
   string message     = "#"+ orders.ticket[i] +" "+ sType +" "+ NumberToStr(LotSize, ".+") +" "+ Symbol() +" at "+ sOpenPrice +" (\""+ comment +"\") was closed at "+ sClosePrice;

   return(message);
}


/**
 * Compose a log message for an executed stoploss.
 *
 * @param  int i - order index
 *
 * @return string
 */
string UpdateStatus.StopLossMsg(int i) {
   // [magic ticket ]#1 Sell 0.1 GBPUSD at 1.5457'2 ("SR.8692.+17"), [client-side ]stoploss 1.5457'2 was executed[ at 1.5457'2 (0.3 pip [positive ]slippage)]
   string sMagic     = ifString(orders.ticket[i]==-2, "magic ticket ", "");
   string sType      = OperationTypeDescription(orders.type[i]);
   string sOpenPrice = NumberToStr(orders.openPrice[i], PriceFormat);
   string sStopSide  = ifString(orders.clientsideLimit[i], "client-side ", "");
   string sStopLoss  = NumberToStr(orders.stopLoss[i], PriceFormat);
   string comment    = "SR."+ sequence.id +"."+ NumberToStr(orders.level[i], "+.");
   string message    = sMagic +"#"+ orders.ticket[i] +" "+ sType +" "+ NumberToStr(LotSize, ".+") +" "+ Symbol() +" at "+ sOpenPrice +" (\""+ comment +"\"), "+ sStopSide +"stoploss "+ sStopLoss +" was executed";

   if (NE(orders.closePrice[i], orders.stopLoss[i])) {
      double slippage = (orders.stopLoss[i] - orders.closePrice[i])/Pip;
         if (orders.type[i] == OP_SELL)
            slippage = -slippage;
      string sSlippage;
      if (slippage > 0) sSlippage = DoubleToStr(slippage, Digits & 1) +" pip slippage";
      else              sSlippage = DoubleToStr(-slippage, Digits & 1) +" pip positive slippage";
      message = message +" at "+ NumberToStr(orders.closePrice[i], PriceFormat) +" ("+ sSlippage +")";
   }
   return(message);
}


/**
 * Compose a log message for a triggered client-side stop.
 *
 * @param  int i - order index
 *
 * @return string
 */
string UpdateStatus.StopTriggerMsg(int i) {
   string comment = "SR."+ sequence.id +"."+ NumberToStr(orders.level[i], "+.");

   if (orders.type[i] == OP_UNDEFINED) {
      // client-side Stop Buy at 1.5457'2 ("SR.8692.+17") was triggered
      return("client-side "+ OperationTypeDescription(orders.pendingType[i]) +" at "+ NumberToStr(orders.pendingPrice[i], PriceFormat) +" (\""+ comment +"\") was triggered");
   }
   else {
      // #1 client-side stoploss at 1.5457'2 ("SR.8692.+17") was triggered
      return("#"+ orders.ticket[i] +" client-side stoploss at "+ NumberToStr(orders.stopLoss[i], PriceFormat) +" (\""+ comment +"\") was triggered");
   }
}


/**
 * Ermittelt die StopTime der aktuell gestoppten Sequenz. Aufruf nur nach externem SnowRoller.Stop().
 *
 * @return datetime - Zeitpunkt oder NULL, falls ein Fehler auftrat
 */
datetime UpdateStatus.CalculateStopTime() {
   if (sequence.status != STATUS_STOPPING) return(_NULL(catch("UpdateStatus.CalculateStopTime(1)  cannot calculate stop time for "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));
   if (!sequence.level)                    return(_NULL(catch("UpdateStatus.CalculateStopTime(2)  cannot calculate stop time for sequence at level "+ sequence.level, ERR_RUNTIME_ERROR)));

   datetime stopTime;
   int n=sequence.level, sizeofTickets=ArraySize(orders.ticket);

   for (int i=sizeofTickets-1; n != 0; i--) {
      if (orders.closeTime[i] == 0) {
         if (IsTesting() && __WHEREAMI__==CF_DEINIT && orders.type[i]==OP_UNDEFINED)
            continue;                                                // offene Pending-Orders ignorieren
         return(_NULL(catch("UpdateStatus.CalculateStopTime(3)  #"+ orders.ticket[i] +" is not closed", ERR_RUNTIME_ERROR)));
      }
      if (orders.type[i] == OP_UNDEFINED)                            // gestrichene Pending-Orders ignorieren
         continue;
      if (orders.closedBySL[i])                                      // ausgestoppte Positionen ignorieren
         continue;

      if (orders.level[i] != n)
         return(_NULL(catch("UpdateStatus.CalculateStopTime(4)  #"+ orders.ticket[i] +" (level "+ orders.level[i] +") doesn't match the expected level "+ n, ERR_RUNTIME_ERROR)));

      stopTime = Max(stopTime, orders.closeTime[i]);
      n -= Sign(n);
   }
   return(stopTime);
}


/**
 * Ermittelt den durchschnittlichen StopPrice der aktuell gestoppten Sequenz. Aufruf nur nach externem SnowRoller.Stop().
 *
 * @return double - Preis oder NULL, falls ein Fehler auftrat
 */
double UpdateStatus.CalculateStopPrice() {
   if (sequence.status != STATUS_STOPPING) return(_NULL(catch("UpdateStatus.CalculateStopPrice(1)  cannot calculate stop price for "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));
   if (!sequence.level)                    return(_NULL(catch("UpdateStatus.CalculateStopPrice(2)  cannot calculate stop price for sequence at level "+ sequence.level, ERR_RUNTIME_ERROR)));

   double stopPrice;
   int n=sequence.level, sizeofTickets=ArraySize(orders.ticket);

   for (int i=sizeofTickets-1; n != 0; i--) {
      if (orders.closeTime[i] == 0) {
         if (IsTesting() && __WHEREAMI__==CF_DEINIT && orders.type[i]==OP_UNDEFINED)
            continue;                                                // offene Pending-Orders ignorieren
         return(_NULL(catch("UpdateStatus.CalculateStopPrice(3)  #"+ orders.ticket[i] +" is not closed", ERR_RUNTIME_ERROR)));
      }
      if (orders.type[i] == OP_UNDEFINED)                            // gestrichene Pending-Orders ignorieren
         continue;
      if (orders.closedBySL[i])                                      // ausgestoppte Positionen ignorieren
         continue;

      if (orders.level[i] != n)
         return(_NULL(catch("UpdateStatus.CalculateStopPrice(4)  #"+ orders.ticket[i] +" (level "+ orders.level[i] +") doesn't match the expected level "+ n, ERR_RUNTIME_ERROR)));

      stopPrice += orders.closePrice[i];
      n -= Sign(n);
   }

   return(NormalizeDouble(stopPrice/Abs(sequence.level), Digits));
}


/**
 * Whether a chart command was sent to the expert. If so, the command is retrieved and stored.
 *
 * @param  string commands[] - array to store received commands in
 *
 * @return bool
 */
bool EventListener_ChartCommand(string &commands[]) {
   if (!__CHART()) return(false);

   static string label, mutex; if (!StringLen(label)) {
      label = __NAME() +".command";
      mutex = "mutex."+ label;
   }

   // check non-synchronized (read-only) for a command to prevent aquiring the lock on each tick
   if (ObjectFind(label) == 0) {
      // aquire the lock for write-access if there's indeed a command
      if (!AquireLock(mutex, true)) return(false);

      ArrayPushString(commands, ObjectDescription(label));
      ObjectDelete(label);
      return(ReleaseLock(mutex));
   }
   return(false);
}


/**
 * Ob die aktuell selektierte Order durch den StopLoss geschlossen wurde (client- oder server-seitig).
 *
 * @return bool
 */
bool IsOrderClosedBySL() {
   bool position   = OrderType()==OP_BUY || OrderType()==OP_SELL;
   bool closed     = OrderCloseTime() != 0;                          // geschlossene Position
   bool closedBySL = false;

   if (closed) /*&&*/ if (position) {
      if (StrEndsWithI(OrderComment(), "[sl]")) {
         closedBySL = true;
      }
      else {
         // StopLoss aus Orderdaten verwenden (ist bei client-seitiger Verwaltung nur dort gespeichert)
         int i = SearchIntArray(orders.ticket, OrderTicket());

         if (i == -1)             return(_false(catch("IsOrderClosedBySL(1)  closed position #"+ OrderTicket() +" not found in order arrays", ERR_RUNTIME_ERROR)));
         if (!orders.stopLoss[i]) return(_false(catch("IsOrderClosedBySL(2)  cannot resolve status of position #"+ OrderTicket() +" (closed but has neither local nor remote SL attached)", ERR_RUNTIME_ERROR)));

         if      (orders.closedBySL[i])   closedBySL = true;
         else if (OrderType() == OP_BUY ) closedBySL = LE(OrderClosePrice(), orders.stopLoss[i]);
         else if (OrderType() == OP_SELL) closedBySL = GE(OrderClosePrice(), orders.stopLoss[i]);
      }
   }
   return(closedBySL);
}


/**
 * Signalgeber f�r StartSequence(). Die einzelnen Bedingungen sind AND-verkn�pft.
 *
 * @return bool - ob die konfigurierten Startbedingungen erf�llt sind
 */
bool IsStartSignal() {
   if (IsLastError())                                                               return(false);
   if (sequence.status!=STATUS_WAITING) /*&&*/ if (sequence.status!=STATUS_STOPPED) return(false);
   string message;

   if (start.conditions) {

      // -- start.price: erf�llt, wenn der aktuelle Preis den Wert ber�hrt oder kreuzt -----------------------------
      if (start.price.condition) {
         bool triggered = false;
         double price;
         switch (start.price.type) {
            case PRICE_BID:    price =  Bid;        break;
            case PRICE_ASK:    price =  Ask;        break;
            case PRICE_MEDIAN: price = (Bid+Ask)/2; break;
         }
         if (start.price.lastValue != 0) {
            if (start.price.lastValue < start.price.value) triggered = (price >= start.price.value);  // price crossed upwards
            else                                           triggered = (price <= start.price.value);  // price crossed downwards
         }
         start.price.lastValue = price;
         if (!triggered) return(false);

         string sPrice = "@"+ StrToLower(PriceTypeDescription(start.price.type)) +"("+ NumberToStr(start.price.value, PriceFormat) +")";
         message = "IsStartSignal(1)  sequence "+ sequence.name +" start condition \""+ sPrice +"\" fulfilled";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
      }

      // -- start.time: zum angegebenen Zeitpunkt oder danach erf�llt ---------------------------------------------------
      if (start.time.condition) {
         if (TimeCurrentEx("IsStartSignal(2)") < start.time.value)
            return(false);

         message = "IsStartSignal(3)  sequence "+ sequence.name +" start condition \"@time("+ TimeToStr(start.time.value) +")\" fulfilled";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
      }

      // -- alle Bedingungen sind erf�llt (AND-Verkn�pfung) -------------------------------------------------------------
   }
   else {
      // no start conditions are a valid start signal, too
      if (ArraySize(sequence.start.event) > 0) {                           // log only if not at the start of a new sequence
         if (__LOG()) log("IsStartSignal(4)  sequence "+ sequence.name +" no start conditions defined");
      }
   }
   return(true);
}


/**
 * Whether a resume condition is satisfied for a stopped sequence.
 *
 * @return bool
 */
bool IsResumeSignal() {
   if (IsLastError() || sequence.status!=STATUS_STOPPED) return(false);

   if (start.conditions)
      return(IsStartSignal());

   // TODO: if (IsSessionResumeSignal())

   return(IsWeekendResumeSignal());
}


/**
 * Signalgeber f�r ResumeSequence(). Pr�ft, ob die Weekend-Resume-Bedingung erf�llt ist.
 *
 * @return bool
 */
bool IsWeekendResumeSignal() {
   if (IsLastError())                                                                                                                return(false);
   if (sequence.status!=STATUS_STOPPED) /*&&*/ if (sequence.status!=STATUS_STARTING) /*&&*/ if (sequence.status!=STATUS_PROGRESSING) return(false);

   if (weekend.resume.triggered) return( true);
   if (weekend.resume.time == 0) return(false);


   int now=TimeCurrentEx("IsWeekendResumeSignal(1)"), dayNow=now/DAYS, dayResume=weekend.resume.time/DAYS;


   // (1) Resume-Bedingung wird erst ab Resume-Session oder deren Premarket getestet (ist u.U. der vorherige Wochentag)
   if (dayNow < dayResume-1)
      return(false);


   // (2) Bedingung ist erf�llt, wenn der Marktpreis gleich dem oder g�nstiger als der Stop-Preis ist
   double stopPrice = sequence.stop.price[ArraySize(sequence.stop.price)-1];
   bool   result;

   if (sequence.direction == D_LONG) result = (Ask <= stopPrice);
   else                              result = (Bid >= stopPrice);
   if (result) {
      weekend.resume.triggered = true;
      if (__LOG()) log(StringConcatenate("IsWeekendResumeSignal(2)  sequence "+ sequence.name +" weekend stop price \"", NumberToStr(stopPrice, PriceFormat), "\" fulfilled"));
      return(true);
   }


   // (3) Bedingung ist sp�testens zur konfigurierten Resume-Zeit erf�llt
   if (weekend.resume.time <= now) {
      if (__LOG()) log(StringConcatenate("IsWeekendResumeSignal(3)  sequence "+ sequence.name +" resume condition '", GmtTimeFormat(weekend.resume.time, "%a, %Y.%m.%d %H:%M:%S"), "' fulfilled"));
      return(true);
   }
   return(false);
}


/**
 * Aktualisiert die Bedingungen f�r ResumeSequence() nach der Wochenend-Pause.
 */
void UpdateWeekendResumeTime() {
   if (IsLastError())                     return;
   if (sequence.status != STATUS_STOPPED) return(_NULL(catch("UpdateWeekendResumeTime(1)  cannot update weekend resume conditions of "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));
   if (!IsWeekendStopSignal())            return(_NULL(catch("UpdateWeekendResumeTime(2)  cannot update weekend resume conditions without weekend stop", ERR_RUNTIME_ERROR)));

   weekend.resume.triggered = false;

   datetime monday, stop=ServerToFxtTime(sequence.stop.time[ArraySize(sequence.stop.time)-1]);

   switch (TimeDayOfWeekFix(stop)) {
      case SUNDAY   : monday = stop + 1*DAYS; break;
      case MONDAY   : monday = stop + 0*DAYS; break;
      case TUESDAY  : monday = stop + 6*DAYS; break;
      case WEDNESDAY: monday = stop + 5*DAYS; break;
      case THURSDAY : monday = stop + 4*DAY ; break;
      case FRIDAY   : monday = stop + 3*DAYS; break;
      case SATURDAY : monday = stop + 2*DAYS; break;
   }
   weekend.resume.time = FxtToServerTime((monday/DAYS)*DAYS + weekend.resume.condition%DAYS);
}


/**
 * Whether a stop condition is satisfied for a progressing sequence. All stop conditions are OR combined.
 *
 * @return bool
 */
bool IsStopSignal() {
   if (IsLastError() || sequence.status!=STATUS_PROGRESSING) return(false);
   string message;

   // User-definierte StopConditions pr�fen
   // -- stop.price: erf�llt, wenn der aktuelle Preis den Wert ber�hrt oder kreuzt ------------------------------------------
   if (stop.price.condition) {
      bool triggered = false;
      double price;
      switch (stop.price.type) {
         case PRICE_BID:    price =  Bid;        break;
         case PRICE_ASK:    price =  Ask;        break;
         case PRICE_MEDIAN: price = (Bid+Ask)/2; break;
      }
      if (stop.price.lastValue != 0) {
         if (stop.price.lastValue < stop.price.value) triggered = (price >= stop.price.value);  // price crossed upwards
         else                                         triggered = (price <= stop.price.value);  // price crossed downwards
      }
      stop.price.lastValue = price;

      if (triggered) {
         string sPrice = "@"+ StrToLower(PriceTypeDescription(stop.price.type)) +"("+ NumberToStr(stop.price.value, PriceFormat) +")";
         message = "IsStopSignal(1)  sequence "+ sequence.name +" stop condition \""+ sPrice +"\" fulfilled";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
         return(true);
      }
   }

   // -- stop.time: zum angegebenen Zeitpunkt oder danach erf�llt -----------------------------------------------------------
   if (stop.time.condition) {
      if (TimeCurrentEx("IsStopSignal(2)") >= stop.time.value) {
         message = "IsStopSignal(3)  sequence "+ sequence.name +" stop condition \"@time("+ TimeToStr(stop.time.value) +")\" fulfilled";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
         return(true);
      }
   }

   // -- stop.profitAbs: ----------------------------------------------------------------------------------------------------
   if (stop.profitAbs.condition) {
      if (sequence.totalPL >= stop.profitAbs.value) {
         message = "IsStopSignal(4)  sequence "+ sequence.name +" stop condition \"@profit("+ NumberToStr(stop.profitAbs.value, ".2") +")\" fulfilled";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
         return(true);
      }
   }

   // -- stop.profitPct: ----------------------------------------------------------------------------------------------------
   if (stop.profitPct.condition) {
      if (stop.profitPct.absValue == INT_MAX) {
         stop.profitPct.absValue = stop.profitPct.value/100 * sequence.startEquity;
      }
      if (sequence.totalPL >= stop.profitPct.absValue) {
         message = "IsStopSignal(5)  sequence "+ sequence.name +" stop condition \"@profit("+ NumberToStr(stop.profitPct.value, ".+") +"%)\" fulfilled";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
         return(true);
      }
   }

   // -- session break ------------------------------------------------------------------------------------------------------
   if (IsWeekendStopSignal())
      return(true);

   return(false);
}


/**
 * Whether a stop condition caused by a trade session break is satisfied for a progressing sequence.
 *
 * @return bool
 */
bool IsWeekendStopSignal() {
   if (IsLastError())                                                                                                                return(false);
   if (sequence.status!=STATUS_PROGRESSING) /*&&*/ if (sequence.status!=STATUS_STOPPING) /*&&*/ if (sequence.status!=STATUS_STOPPED) return(false);

   if (weekend.stop.active) return(true);
   if (!weekend.stop.time)  return(false);

   datetime now = TimeCurrentEx("IsWeekendStopSignal(1)");

   if (now >= weekend.stop.time) {
      if (weekend.stop.time/DAYS == now/DAYS) {                               // stellt sicher, da� Signal nicht von altem Datum getriggert wird
         weekend.stop.active = true;
         if (__LOG()) log(StringConcatenate("IsWeekendStopSignal(2)  sequence "+ sequence.name +" stop condition '", GmtTimeFormat(weekend.stop.time, "%a, %Y.%m.%d %H:%M:%S"), "' fulfilled"));
         return(true);
      }
   }
   return(false);
}


/**
 * Aktualisiert die Stopbedingung f�r die n�chste Wochenend-Pause.
 */
void UpdateWeekendStop() {
   weekend.stop.active = false;

   datetime friday, now=ServerToFxtTime(TimeCurrentEx("UpdateWeekendStop(1)"));

   switch (TimeDayOfWeekFix(now)) {
      case SUNDAY   : friday = now + 5*DAYS; break;
      case MONDAY   : friday = now + 4*DAYS; break;
      case TUESDAY  : friday = now + 3*DAYS; break;
      case WEDNESDAY: friday = now + 2*DAYS; break;
      case THURSDAY : friday = now + 1*DAY ; break;
      case FRIDAY   : friday = now + 0*DAYS; break;
      case SATURDAY : friday = now + 6*DAYS; break;
   }
   weekend.stop.time = (friday/DAYS)*DAYS + weekend.stop.condition%DAYS;
   if (weekend.stop.time < now)
      weekend.stop.time = (friday/DAYS)*DAYS + D'1970.01.01 23:55'%DAYS;   // wenn Aufruf nach Weekend-Stop, erfolgt neuer Stop 5 Minuten vor Handelsschlu�
   weekend.stop.time = FxtToServerTime(weekend.stop.time);
}


/**
 * Management getriggerter client-seitiger Limits. Kann eine getriggerte Stop-Entry-Order oder ein getriggerter StopLoss
 * einer offenen Position sein. Aufruf nur aus onTick().
 *
 * @param  int stops[] - Array-Indizes der Orders mit getriggerten Limits
 *
 * @return bool - Erfolgsstatus
 */
bool ProcessLocalLimits(int stops[]) {
   if (IsLastError())                             return( false);
   if (IsTestSequence()) /*&&*/ if (!IsTesting()) return(_false(catch("ProcessLocalLimits(1)", ERR_ILLEGAL_STATE)));
   if (sequence.status != STATUS_PROGRESSING)     return(_false(catch("ProcessLocalLimits(2)  cannot process client-side stops of "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));

   int sizeOfStops = ArraySize(stops);
   if (!sizeOfStops) return(true);

   int button, ticket;
   int oe[];

   // Der Stop kann eine getriggerte Entry-Order (OP_BUYSTOP, OP_SELLSTOP) oder ein getriggerter StopLoss sein.
   for (int i, n=0; n < sizeOfStops; n++) {
      i = stops[n];
      if (i >= ArraySize(orders.ticket))     return(_false(catch("ProcessLocalLimits(3)  illegal value "+ i +" in parameter stops = "+ IntsToStr(stops, NULL), ERR_INVALID_PARAMETER)));

      // getriggerte Entry-Order (OP_BUYSTOP, OP_SELLSTOP)
      if (orders.ticket[i] == -1) {
         if (orders.type[i] != OP_UNDEFINED) return(_false(catch("ProcessLocalLimits(4)  client-side "+ OperationTypeDescription(orders.pendingType[i]) +" order at index "+ i +" is already marked as open", ERR_ILLEGAL_STATE)));

         if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("ProcessLocalLimits()", "Do you really want to execute a triggered client-side "+ OperationTypeDescription(orders.pendingType[i]) +" order now?"))
            return(!SetLastError(ERR_CANCELLED_BY_USER));

         int type  = orders.pendingType[i] - 4;
         int level = orders.level      [i];
         bool clientSL = false;                                               // zuerst versuchen, server-seitigen StopLoss zu setzen...

         ticket = SubmitMarketOrder(type, level, clientSL, oe);

         // ab dem letzten Level ggf. client-seitige Stop-Verwaltung
         orders.clientsideLimit[i] = (ticket <= 0);

         if (ticket <= 0) {
            if (level != sequence.level)          return(false);
            if (oe.Error(oe) != ERR_INVALID_STOP) return(false);
            // if market violated
            if (ticket == -1) {
               return(_false(catch("ProcessLocalLimits(6)  SR."+ sequence.id +"."+ NumberToStr(level, "+.") +" "+ NumberToStr(level, "+.") +"\" spread violated ("+ NumberToStr(oe.Bid(oe), PriceFormat) +"/"+ NumberToStr(oe.Ask(oe), PriceFormat) +") by "+ OperationTypeDescription(type) +" at "+ NumberToStr(oe.OpenPrice(oe), PriceFormat) +", sl="+ NumberToStr(oe.StopLoss(oe), PriceFormat), oe.Error(oe))));
            }
            // if stop distance violated
            else if (ticket == -2) {
               clientSL = true;
               ticket = SubmitMarketOrder(type, level, clientSL, oe);         // danach client-seitige Stop-Verwaltung (ab dem letzten Level)
               if (ticket <= 0) return(false);
               warn("ProcessLocalLimits(7)  SR."+ sequence.id +"."+ NumberToStr(level, "+.") +" "+ NumberToStr(level, "+.") +"\" #"+ ticket +" client-side stoploss at "+ NumberToStr(oe.StopLoss(oe), PriceFormat) +" installed");
            }
            // on all other errors
            else return(_false(catch("ProcessLocalLimits(5)  �nknown ticket value "+ ticket, oe.Error(oe))));
         }
         orders.ticket[i] = ticket;
         continue;
      }

      // getriggerter StopLoss
      if (orders.clientsideLimit[i]) {
         if (orders.ticket[i] == -2)         return(_false(catch("ProcessLocalLimits(8)  cannot process client-side stoploss of magic ticket #"+ orders.ticket[i], ERR_RUNTIME_ERROR)));
         if (orders.type[i] == OP_UNDEFINED) return(_false(catch("ProcessLocalLimits(9)  #"+ orders.ticket[i] +" with client-side stoploss still marked as pending", ERR_ILLEGAL_STATE)));
         if (orders.closeTime[i] != 0)       return(_false(catch("ProcessLocalLimits(10)  #"+ orders.ticket[i] +" with client-side stoploss already marked as closed", ERR_ILLEGAL_STATE)));

         if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("ProcessLocalLimits()", "Do you really want to execute a triggered client-side stoploss now?"))
            return(!SetLastError(ERR_CANCELLED_BY_USER));

         double lots        = NULL;
         double price       = NULL;
         double slippage    = 0.1;
         color  markerColor = CLR_NONE;
         int    oeFlags     = NULL;
         if (!OrderCloseEx(orders.ticket[i], lots, price, slippage, markerColor, oeFlags, oe))
            return(!SetLastError(oe.Error(oe)));

         orders.closedBySL[i] = true;
      }
   }
   ArrayResize(oe, 0);

   // Status aktualisieren und speichern
   bool bNull;
   int  iNull[];
   if (!UpdateStatus(bNull, iNull)) return(false);
   if (!SaveStatus()) return(false);

   return(!last_error|catch("ProcessLocalLimits(11)"));
}


/**
 * Trail existing, open missing and delete obsolete pending orders.
 *
 * @return bool - success status
 */
bool UpdatePendingOrders() {
   if (IsLastError())                             return( false);
   if (IsTestSequence()) /*&&*/ if (!IsTesting()) return(_false(catch("UpdatePendingOrders(1)", ERR_ILLEGAL_STATE)));
   if (sequence.status != STATUS_PROGRESSING)     return(_false(catch("UpdatePendingOrders(2)  cannot update orders of "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));

   int nextLevel=sequence.level + ifInt(sequence.direction==D_LONG, 1, -1), sizeOfTickets=ArraySize(orders.ticket);
   bool nextOrderExists, ordersChanged;

   for (int i=sizeOfTickets-1; i >= 0; i--) {
      // TODO: improve loop, no need to iterate over the full array
      if (!orders.closeTime[i]) /*&&*/ if (orders.type[i]==OP_UNDEFINED) { // if (isOpen && isPending)...
         if (orders.level[i] == nextLevel) {
            nextOrderExists = true;
            if (!sequence.level) /*&&*/ if (NE(grid.base, orders.gridBase[i], Digits)) {
               static int lastTrailed = INT_MIN;

               if (IsTesting() || GetTickCount()-lastTrailed > 3000) {     // Prevent ERR_TOO_MANY_REQUESTS caused by contacting the trade server
                  if (!Grid.TrailPendingOrder(i)) return(false);           // at each tick. Wait 3 seconds between consecutive order trailings.
                  lastTrailed = GetTickCount();
                  ordersChanged = true;
                  if (sequence.level == nextLevel) {                       // Grid.TrailPendingOrder() missed a level due a fast moving market
                     nextLevel = sequence.level + ifInt(sequence.direction==D_LONG, 1, -1);
                     nextOrderExists = false;
                  }
               }
            }
            continue;
         }
         else if (Abs(orders.level[i]) > Abs(nextLevel)) {
            if (!Grid.DeleteOrder(i)) return(false);                       // unn�tige Pending-Orders l�schen
            sizeOfTickets--;
            ordersChanged = true;
         }
      }
   }

   if (!nextOrderExists) {
      string sMissedLevels = "";
      int limitOrders, type = OP_BUYSTOP;
      while (!nextOrderExists || type < OP_BUYSTOP) {                      // a limit order was opened: add all missing ones
         if (type < OP_BUYSTOP) {
            limitOrders++;
            ArrayPushInt(sequence.missedLevels, nextLevel);
            sMissedLevels     = sMissedLevels +", "+ nextLevel;
            sequence.level   += Sign(nextLevel);
            sequence.maxLevel = Max(Abs(sequence.level), Abs(sequence.maxLevel)) * Sign(nextLevel);
            nextLevel        += Sign(nextLevel);
         }
         type = Grid.AddPendingOrder(nextLevel); if (!type) return(false);
         nextOrderExists = true;
      }
      if (limitOrders > 0) {
         sMissedLevels = StrRight(sMissedLevels, -2); SS.MissedLevels();
         warn("UpdatePendingOrders(3)  sequence "+ sequence.name +" opened "+ limitOrders +" limit order"+ ifString(limitOrders==1, " for level", "s for levels") +" ["+ sMissedLevels +"] in a fast moving market");
      }
      ordersChanged = true;
   }

   if (ordersChanged)
      if (!SaveStatus()) return(false);
   return(!last_error|catch("UpdatePendingOrders(4)"));
}


/**
 * L�scht alle gespeicherten �nderungen der Gridbasis und initialisiert sie mit dem angegebenen Wert.
 *
 * @param  datetime time  - Zeitpunkt
 * @param  double   value - neue Gridbasis
 *
 * @return double - neue Gridbasis oder 0, falls ein Fehler auftrat
 */
double GridBase.Reset(datetime time, double value) {
   if (IsLastError()) return(0);

   ArrayResize(grid.base.event, 0);
   ArrayResize(grid.base.time,  0);
   ArrayResize(grid.base.value, 0);

   return(GridBase.Change(time, value));
}


/**
 * Speichert eine �nderung der Gridbasis.
 *
 * @param  datetime time  - Zeitpunkt der �nderung
 * @param  double   value - neue Gridbasis
 *
 * @return double - die neue Gridbasis
 */
double GridBase.Change(datetime time, double value) {
   value = NormalizeDouble(value, Digits);

   if (sequence.maxLevel == 0) {                            // vor dem ersten ausgef�hrten Trade werden vorhandene Werte �berschrieben
      ArrayResize(grid.base.event, 0);
      ArrayResize(grid.base.time,  0);
      ArrayResize(grid.base.value, 0);
   }

   int size = ArraySize(grid.base.event);                   // ab dem ersten ausgef�hrten Trade werden neue Werte angef�gt
   if (size == 0) {
      ArrayPushInt   (grid.base.event, CreateEventId());
      ArrayPushInt   (grid.base.time,  time           );
      ArrayPushDouble(grid.base.value, value          );
      size++;
   }
   else {
      datetime lastStartTime = sequence.start.time[ArraySize(sequence.start.time)-1];
      int minute=time/MINUTE, lastMinute=grid.base.time[size-1]/MINUTE;

      if (time<=lastStartTime || minute!=lastMinute) {      // store all events
         ArrayPushInt   (grid.base.event, CreateEventId());
         ArrayPushInt   (grid.base.time,  time           );
         ArrayPushDouble(grid.base.value, value          );
         size++;
      }
      else {                                                // compact redundant events, store only the last one per minute
         grid.base.event[size-1] = CreateEventId();
         grid.base.time [size-1] = time;
         grid.base.value[size-1] = value;
      }
   }

   grid.base = value; SS.GridBase();
   return(value);
}


/**
 * Open a pending entry order at the price of the specified grid level and add it to the order arrays. Depending on the market
 * the function opens a stop or a limit order.
 *
 * @param  int level - grid level of the order to open: -n...1 | 1...+n
 *
 * @return int - operation type of the openend order or NULL in case of errors
 */
int Grid.AddPendingOrder(int level) {
   if (IsLastError())                                                           return(NULL);
   if (IsTestSequence()) /*&&*/ if (!IsTesting())                               return(!catch("Grid.AddPendingOrder(1)", ERR_ILLEGAL_STATE));
   if (sequence.status!=STATUS_STARTING && sequence.status!=STATUS_PROGRESSING) return(!catch("Grid.AddPendingOrder(2)  cannot add order to "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR));

   int orderType = ifInt(sequence.direction==D_LONG, OP_BUYSTOP, OP_SELLSTOP);

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("Grid.AddPendingOrder()", "Do you really want to submit a new "+ OperationTypeDescription(orderType) +" order now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   // first try to open a stop order
   int oe[];
   int ticket = SubmitStopOrder(orderType, level, oe);

   if (ticket <= 0) {
      if (oe.Error(oe) != ERR_INVALID_STOP) return(false);
      // if market violated
      if (ticket == -1) {
         if (__LOG()) log("Grid.AddPendingOrder(3)  SR."+ sequence.id +"."+ NumberToStr(level, "+.") +" "+ NumberToStr(level, "+.") +"\" illegal price "+ OperationTypeDescription(orderType) +" at "+ NumberToStr(oe.OpenPrice(oe), PriceFormat) +" (market "+ NumberToStr(oe.Bid(oe), PriceFormat) +"/"+ NumberToStr(oe.Ask(oe), PriceFormat) +"), opening a limit order instead", oe.Error(oe));
         orderType -= 2;
         ticket = SubmitLimitOrder(orderType, level, oe);                           // open a limit order instead
         if (ticket <= 0) return(!catch("Grid.AddPendingOrder(4)", oe.Error(oe)));
      }
      // if stop distance violated
      else if (ticket == -2) {
         ticket = -1;                                                               // use client-side stop management
         warn("Grid.AddPendingOrder(5)  SR."+ sequence.id +"."+ NumberToStr(level, "+.") +" "+ NumberToStr(level, "+.") +"\" client-side limit for "+ OperationTypeDescription(orderType) +" at "+ NumberToStr(oe.OpenPrice(oe), PriceFormat) +" installed");
      }
      // on all other errors
      else return(!catch("Grid.AddPendingOrder(6)  unknown ticket value "+ ticket, oe.Error(oe)));
   }

   // prepare order dataset
   //int    ticket       = ...                     // use as is
   //int    level        = ...                     // ...
   //double grid.base    = ...                     // ...

   int      pendingType  = orderType;
   datetime pendingTime  = oe.OpenTime(oe); if (ticket < 0) pendingTime = TimeCurrentEx("Grid.AddPendingOrder(7)");
   double   pendingPrice = oe.OpenPrice(oe);

   int      type         = OP_UNDEFINED;
   int      openEvent    = NULL;
   datetime openTime     = NULL;
   double   openPrice    = NULL;
   int      closeEvent   = NULL;
   datetime closeTime    = NULL;
   double   closePrice   = NULL;
   double   stopLoss     = oe.StopLoss(oe);
   bool     clientLimit  = (ticket <= 0);
   bool     closedBySL   = false;

   double   swap         = NULL;
   double   commission   = NULL;
   double   profit       = NULL;

   ArrayResize(oe, 0);

   // store dataset
   if (!Grid.PushData(ticket, level, grid.base, pendingType, pendingTime, pendingPrice, type, openEvent, openTime, openPrice, closeEvent, closeTime, closePrice, stopLoss, clientLimit, closedBySL, swap, commission, profit))
      return(NULL);

   if (last_error || catch("Grid.AddPendingOrder(8)"))
      return(NULL);
   return(pendingType);
}


/**
 * �ffnet eine Position zum aktuellen Preis.
 *
 * @param  _In_  int  type         - Ordertyp: OP_BUY | OP_SELL
 * @param  _In_  int  level        - Gridlevel der Order
 * @param  _In_  bool clientsideSL - ob der StopLoss client-seitig verwaltet wird
 * @param  _Out_ int  oe[]         - execution details (struct ORDER_EXECUTION)
 *
 * @return int - Orderticket (positiver Wert) oder ein anderer Wert, falls ein Fehler auftrat
 *
 * Spezielle Return-Codes:
 * -----------------------
 * -1: der StopLoss verletzt den aktuellen Spread
 * -2: der StopLoss verletzt die StopDistance des Brokers
 */
int SubmitMarketOrder(int type, int level, bool clientsideSL, int oe[]) {
   clientsideSL = clientsideSL!=0;

   if (IsLastError())                                                                    return(0);
   if (IsTestSequence()) /*&&*/ if (!IsTesting())                                        return(_NULL(catch("SubmitMarketOrder(1)", ERR_ILLEGAL_STATE)));
   if (sequence.status!=STATUS_STARTING) /*&&*/ if (sequence.status!=STATUS_PROGRESSING) return(_NULL(catch("SubmitMarketOrder(2)  cannot submit market order for "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));
   if (type!=OP_BUY && type!=OP_SELL)                                                    return(_NULL(catch("SubmitMarketOrder(3)  illegal parameter type = "+ type, ERR_INVALID_PARAMETER)));
   if (type==OP_BUY && level<=0)                                                         return(_NULL(catch("SubmitMarketOrder(4)  illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));
   if (type==OP_SELL && level>=0)                                                        return(_NULL(catch("SubmitMarketOrder(5)  illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));

   double   price       = NULL;
   double   slippage    = 0.1;
   double   stopLoss    = ifDouble(clientsideSL, NULL, grid.base + (level-Sign(level))*GridSize*Pips);
   double   takeProfit  = NULL;
   int      magicNumber = CreateMagicNumber(level);
   datetime expires     = NULL;
   string   comment     = "SR."+ sequence.id +"."+ NumberToStr(level, "+.");
   color    markerColor = ifInt(level > 0, CLR_LONG, CLR_SHORT); if (!orderDisplayMode) markerColor = CLR_NONE;
   int      oeFlags     = NULL;

   if (!clientsideSL) /*&&*/ if (Abs(level) >= Abs(sequence.level))
      oeFlags |= F_ERR_INVALID_STOP;            // ab dem letzten Level bei server-seitigem StopLoss ERR_INVALID_STOP abfangen

   int ticket = OrderSendEx(Symbol(), type, LotSize, price, slippage, stopLoss, takeProfit, comment, magicNumber, expires, markerColor, oeFlags, oe);
   if (ticket > 0) return(ticket);

   int error = oe.Error(oe);
   if (oeFlags & F_ERR_INVALID_STOP && 1) {
      if (error == ERR_INVALID_STOP) {          // Der StopLoss liegt entweder innerhalb des Spreads (-1) oder innerhalb der StopDistance (-2).
         bool insideSpread;
         if (type == OP_BUY) insideSpread = GE(oe.StopLoss(oe), oe.Bid(oe));
         else                insideSpread = LE(oe.StopLoss(oe), oe.Ask(oe));
         if (insideSpread)
            return(-1);
         return(-2);
      }
   }
   return(_NULL(SetLastError(error)));
}


/**
 * Open a pending stop order.
 *
 * @param  _In_  int type  - order type: OP_BUYSTOP | OP_SELLSTOP
 * @param  _In_  int level - order grid level
 * @param  _Out_ int oe[]  - execution details (struct ORDER_EXECUTION)
 *
 * @return int - order ticket (positive value) on success or another value in case of errors, especially:
 *               -1 if the limit violates the current market or
 *               -2 if the limit violates the broker's stop distance (MODE_STOPLEVEL)
 */
int SubmitStopOrder(int type, int level, int oe[]) {
   if (IsLastError())                                                                    return(0);
   if (IsTestSequence()) /*&&*/ if (!IsTesting())                                        return(_NULL(catch("SubmitStopOrder(1)", ERR_ILLEGAL_STATE)));
   if (sequence.status!=STATUS_STARTING) /*&&*/ if (sequence.status!=STATUS_PROGRESSING) return(_NULL(catch("SubmitStopOrder(2)  cannot submit stop order for "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));
   if (type!=OP_BUYSTOP && type!=OP_SELLSTOP)                                            return(_NULL(catch("SubmitStopOrder(3)  illegal parameter type = "+ type, ERR_INVALID_PARAMETER)));
   if (type==OP_BUYSTOP && level<=0)                                                     return(_NULL(catch("SubmitStopOrder(4)  illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));
   if (type==OP_SELLSTOP && level>=0)                                                    return(_NULL(catch("SubmitStopOrder(5)  illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));

   double   stopPrice   = grid.base + level*GridSize*Pips;
   double   slippage    = NULL;
   double   stopLoss    = stopPrice - Sign(level)*GridSize*Pips;
   double   takeProfit  = NULL;
   int      magicNumber = CreateMagicNumber(level);
   datetime expires     = NULL;
   string   comment     = StringConcatenate("SR.", sequence.id, ".", NumberToStr(level, "+."));
   color    markerColor = CLR_PENDING; if (!orderDisplayMode) markerColor = CLR_NONE;
   int      oeFlags     = F_ERR_INVALID_STOP;      // accept ERR_INVALID_STOP

   int ticket = OrderSendEx(Symbol(), type, LotSize, stopPrice, slippage, stopLoss, takeProfit, comment, magicNumber, expires, markerColor, oeFlags, oe);
   if (ticket > 0) return(ticket);

   int error = oe.Error(oe);
   if (error == ERR_INVALID_STOP) {                // Der StopPrice liegt entweder innerhalb des Marktes (-1) oder innerhalb der StopDistance (-2).
      bool insideMarket;
      if (!oe.StopDistance(oe))    insideMarket = true;
      else if (type == OP_BUYSTOP) insideMarket = LE(oe.OpenPrice(oe), oe.Ask(oe));
      else                         insideMarket = GE(oe.OpenPrice(oe), oe.Bid(oe));
      return(ifInt(insideMarket, -1, -2));
   }
   return(_NULL(SetLastError(error)));
}


/**
 * Open a pending limit order.
 *
 * @param  _In_  int type  - order type: OP_BUYLIMIT | OP_SELLLIMIT
 * @param  _In_  int level - order grid level
 * @param  _Out_ int oe[]  - order execution details (struct ORDER_EXECUTION)
 *
 * @return int - order ticket (positive value) on success or another value in case of errors, especially:
 *               -1 if the limit violates the current market or
 *               -2 if the limit violates the broker's MODE_STOPLEVEL
 */
int SubmitLimitOrder(int type, int level, int oe[]) {
   if (IsLastError())                                                                    return(0);
   if (IsTestSequence()) /*&&*/ if (!IsTesting())                                        return(_NULL(catch("SubmitLimitOrder(1)", ERR_ILLEGAL_STATE)));
   if (sequence.status!=STATUS_STARTING) /*&&*/ if (sequence.status!=STATUS_PROGRESSING) return(_NULL(catch("SubmitLimitOrder(2)  cannot submit limit order for "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));
   if (type!=OP_BUYLIMIT && type!=OP_SELLLIMIT)                                          return(_NULL(catch("SubmitLimitOrder(3)  illegal parameter type = "+ type, ERR_INVALID_PARAMETER)));
   if (type==OP_BUYLIMIT && level<=0)                                                    return(_NULL(catch("SubmitLimitOrder(4)  illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));
   if (type==OP_SELLLIMIT && level>=0)                                                   return(_NULL(catch("SubmitLimitOrder(5)  illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));

   double   limitPrice  = grid.base + level*GridSize*Pips;
   double   slippage    = NULL;
   double   stopLoss    = limitPrice - Sign(level)*GridSize*Pips;
   double   takeProfit  = NULL;
   int      magicNumber = CreateMagicNumber(level);
   datetime expires     = NULL;
   string   comment     = StringConcatenate("SR.", sequence.id, ".", NumberToStr(level, "+."));
   color    markerColor = CLR_PENDING; if (!orderDisplayMode) markerColor = CLR_NONE;
   int      oeFlags     = F_ERR_INVALID_STOP;      // accept ERR_INVALID_STOP

   int ticket = OrderSendEx(Symbol(), type, LotSize, limitPrice, slippage, stopLoss, takeProfit, comment, magicNumber, expires, markerColor, oeFlags, oe);
   if (ticket > 0) return(ticket);

   int error = oe.Error(oe);
   if (error == ERR_INVALID_STOP) {                // either the entry limit violates the market (-1) or the broker's stop distance (-2).
      bool violatedMarket;
      if (!oe.StopDistance(oe))     violatedMarket = true;
      else if (type == OP_BUYLIMIT) violatedMarket = GE(oe.OpenPrice(oe), oe.Ask(oe));
      else                          violatedMarket = LE(oe.OpenPrice(oe), oe.Bid(oe));
      return(ifInt(violatedMarket, -1, -2));
   }
   return(_NULL(SetLastError(error)));
}


/**
 * Modify stop price and stoploss of a pending stop order (i.e. trailing of a first level order).
 *
 * @param  _Out_ int oe[] - order execution details (struct ORDER_EXECUTION)
 *
 * @return int - error status: NULL on success or another value in case of errors, especially
 *               -1 if the new entry price violates the current market or
 *               -2 if the new entry price violates the broker's stop distance (MODE_STOPLEVEL)
 */
int ModifyStopOrder(int ticket, double stopPrice, double stopLoss, int oe[]) {
   if (IsLastError())                                                                    return(last_error);
   if (IsTestSequence()) /*&&*/ if (!IsTesting())                                        return(catch("ModifyStopOrder(1)", ERR_ILLEGAL_STATE));
   if (sequence.status!=STATUS_STARTING) /*&&*/ if (sequence.status!=STATUS_PROGRESSING) return(catch("ModifyStopOrder(2)  cannot modify order for "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR));

   color markerColor = CLR_PENDING;
   int oeFlags = F_ERR_INVALID_STOP;            // accept ERR_INVALID_STOP

   bool success = OrderModifyEx(ticket, stopPrice, stopLoss, NULL, NULL, markerColor, oeFlags, oe);
   if (success) return(NO_ERROR);

   int error = oe.Error(oe);
   if (error == ERR_INVALID_STOP) {             // either the entry price violates the market (-1) or it violates the broker's stop distance (-2).
      bool violatedMarket;
      if (!oe.StopDistance(oe))           violatedMarket = true;
      else if (oe.Type(oe) == OP_BUYSTOP) violatedMarket = GE(oe.Ask(oe), stopPrice);
      else                                violatedMarket = LE(oe.Bid(oe), stopPrice);
      return(ifInt(violatedMarket, -1, -2));
   }
   return(SetLastError(error));
}


/**
 * Legt die angegebene Position in den Markt und f�gt den Gridarrays deren Daten hinzu. Aufruf nur in RestoreActiveGridLevels().
 *
 * @param  int level - Gridlevel der Position
 *
 * @return bool - Erfolgsstatus
 */
bool Grid.AddPosition(int level) {
   if (IsLastError())                             return( false);
   if (IsTestSequence()) /*&&*/ if (!IsTesting()) return(_false(catch("Grid.AddPosition(1)", ERR_ILLEGAL_STATE)));
   if (sequence.status != STATUS_STARTING)        return(_false(catch("Grid.AddPosition(2)  cannot add market position to "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));
   if (!level)                                    return(_false(catch("Grid.AddPosition(3)  illegal parameter level = "+ level, ERR_INVALID_PARAMETER)));

   int orderType = ifInt(sequence.direction==D_LONG, OP_BUY, OP_SELL);

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("Grid.AddPosition()", "Do you really want to submit a Market "+ OperationTypeDescription(orderType) +" order now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   // Position �ffnen
   bool clientsideSL = false;
   int oe[];
   int ticket = SubmitMarketOrder(orderType, level, clientsideSL, oe);     // zuerst server-seitigen StopLoss setzen (clientsideSL=FALSE)

   if (ticket <= 0) {
      if (oe.Error(oe) != ERR_INVALID_STOP) return(false);
      // if market violated
      if (ticket == -1) {
         ticket = -2;                                                      // assign ticket #-2 for decreased grid level, UpdateStatus() will "close" it with PL=0.00
         clientsideSL = true;
         oe.setOpenTime(oe, TimeCurrentEx("Grid.AddPosition(4)"));
         warn("Grid.AddPosition(5)  sequence "+ sequence.name +" position at level "+ level +" would be closed immediately by SL="+ NumberToStr(oe.StopLoss(oe), PriceFormat) +" (market: "+ NumberToStr(oe.Bid(oe), PriceFormat) +"/"+ NumberToStr(oe.Ask(oe), PriceFormat) +"), decreasing grid level...");
      }
      // if stop distance violated
      else if (ticket == -2) {
         clientsideSL = true;
         ticket = SubmitMarketOrder(orderType, level, clientsideSL, oe);   // use client-side stop management
         if (ticket <= 0) return(false);
         warn("Grid.AddPosition(6)  sequence "+ sequence.name +" level "+ level +" #"+ ticket +" client-side stoploss installed at "+ NumberToStr(oe.StopLoss(oe), PriceFormat));
      }
      // on all other errors
      else return(_false(catch("Grid.AddPosition(7)  unknown ticket value "+ ticket, oe.Error(oe))));
   }

   // Daten speichern
   //int    ticket       = ...                     // unver�ndert
   //int    level        = ...                     // unver�ndert
   //double grid.base    = ...                     // unver�ndert

   int      pendingType  = OP_UNDEFINED;
   datetime pendingTime  = NULL;
   double   pendingPrice = NULL;

   int      type         = orderType;
   int      openEvent    = CreateEventId();
   datetime openTime     = oe.OpenTime (oe);
   double   openPrice    = oe.OpenPrice(oe);
   int      closeEvent   = NULL;
   datetime closeTime    = NULL;
   double   closePrice   = NULL;
   double   stopLoss     = oe.StopLoss(oe);
   //bool   clientsideSL = ...                     // unver�ndert
   bool     closedBySL   = false;

   double   swap         = oe.Swap      (oe);      // falls Swap bereits bei OrderOpen gesetzt sein sollte
   double   commission   = oe.Commission(oe);
   double   profit       = NULL;

   if (!Grid.PushData(ticket, level, grid.base, pendingType, pendingTime, pendingPrice, type, openEvent, openTime, openPrice, closeEvent, closeTime, closePrice, stopLoss, clientsideSL, closedBySL, swap, commission, profit))
      return(false);

   ArrayResize(oe, 0);
   return(!last_error|catch("Grid.AddPosition(8)"));
}


/**
 * Justiert PendingOpenPrice() und StopLoss() der angegebenen Order und aktualisiert die Orderarrays.
 *
 * @param  int i - Orderindex
 *
 * @return bool - success status
 */
bool Grid.TrailPendingOrder(int i) {
   if (IsLastError())                             return( false);
   if (IsTestSequence()) /*&&*/ if (!IsTesting()) return(_false(catch("Grid.TrailPendingOrder(1)", ERR_ILLEGAL_STATE)));
   if (sequence.status != STATUS_PROGRESSING)     return(_false(catch("Grid.TrailPendingOrder(2)  cannot trail order of "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));
   if (orders.type[i] != OP_UNDEFINED)            return(_false(catch("Grid.TrailPendingOrder(3)  cannot trail "+ OperationTypeDescription(orders.type[i]) +" position #"+ orders.ticket[i], ERR_RUNTIME_ERROR)));
   if (orders.closeTime[i] != 0)                  return(_false(catch("Grid.TrailPendingOrder(4)  cannot trail cancelled "+ OperationTypeDescription(orders.type[i]) +" order #"+ orders.ticket[i], ERR_RUNTIME_ERROR)));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("Grid.TrailPendingOrder()", "Do you really want to modify the "+ OperationTypeDescription(orders.pendingType[i]) +" order #"+ orders.ticket[i] +" now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   // store/calculate data which (posibly) changes
   int    ticket          = orders.ticket[i];
   int    level           = orders.level[i];
   int    pendingType     = orders.pendingType[i];
   double pendingPrice    = NormalizeDouble(grid.base +          level * GridSize * Pips, Digits);
   double stopLoss        = NormalizeDouble(pendingPrice - Sign(level) * GridSize * Pips, Digits);
   bool   clientsideLimit = orders.clientsideLimit[i];

   if (ticket < 0) {                                                 // client-side managed limit
      // TODO: update chart markers
   }
   else {                                                            // server-side managed limit
      int oe[];
      int error = ModifyStopOrder(ticket, pendingPrice, stopLoss, oe);

      if (IsError(error)) {
         if (oe.Error(oe) != ERR_INVALID_STOP) return(!SetLastError(oe.Error(oe)));
         // if market violated: delete existing stop order and submit a new limit order instead
         if (error == -1) {
            if (!OrderDeleteEx(ticket, CLR_NONE, NULL, oe)) return(!SetLastError(oe.Error(oe)));
            pendingType -= 2;
            ticket = SubmitLimitOrder(pendingType, level, oe);
            if (ticket <= 0) return(!catch("Grid.TrailPendingOrder(5)", oe.Error(oe)));
            ArrayPushInt(sequence.missedLevels, level); SS.MissedLevels();
            sequence.level   += Sign(level);
            sequence.maxLevel = Max(Abs(sequence.level), Abs(sequence.maxLevel)) * Sign(level);
            warn("Grid.TrailPendingOrder(6)  sequence "+ sequence.name +" opened 1 limit order for level "+ level +" in a fast moving market");
         }
         // if stop distance violated: use client-side stop management
         else if (error == -2) {
            // TODO: implement client-side stop management
            return(!catch("Grid.TrailPendingOrder(7)  stop distance violated", oe.Error(oe)));
         }
         // on all other errors
         else return(!catch("Grid.TrailPendingOrder(8)  unknown error "+ error, oe.Error(oe)));
      }
      ArrayResize(oe, 0);
   }

   // update possibly changed data
   orders.ticket         [i] = ticket;
   orders.gridBase       [i] = grid.base;

   orders.pendingType    [i] = pendingType;
   orders.pendingTime    [i] = TimeCurrentEx("Grid.TrailPendingOrder(9)");
   orders.pendingPrice   [i] = pendingPrice;

   orders.stopLoss       [i] = stopLoss;
   orders.clientsideLimit[i] = clientsideLimit;

   return(!last_error|catch("Grid.TrailPendingOrder(10)"));
}


/**
 * Cancel the specified order and remove it from the order arrays.
 *
 * @param  int i - order index
 *
 * @return bool - success status
 */
bool Grid.DeleteOrder(int i) {
   if (IsLastError())                                                                 return( false);
   if (IsTestSequence()) /*&&*/ if (!IsTesting())                                     return(_false(catch("Grid.DeleteOrder(1)", ERR_ILLEGAL_STATE)));
   if (sequence.status!=STATUS_PROGRESSING) /*&&*/ if (sequence.status!=STATUS_STOPPING)
      if (!IsTesting() || __WHEREAMI__!=CF_DEINIT || sequence.status!=STATUS_STOPPED) return(_false(catch("Grid.DeleteOrder(2)  cannot delete order of "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));
   if (orders.type[i] != OP_UNDEFINED)                                                return(_false(catch("Grid.DeleteOrder(3)  cannot delete "+ ifString(orders.closeTime[i]==0, "open", "closed") +" "+ OperationTypeDescription(orders.type[i]) +" position", ERR_RUNTIME_ERROR)));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("Grid.DeleteOrder()", "Do you really want to cancel the "+ OperationTypeDescription(orders.pendingType[i]) +" order at level "+ orders.level[i] +" now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   if (orders.ticket[i] > 0) {
      int oeFlags = NULL;
      int oe[];
      if (!OrderDeleteEx(orders.ticket[i], CLR_NONE, oeFlags, oe)) return(!SetLastError(oe.Error(oe)));
      ArrayResize(oe, 0);
   }
   if (!Grid.DropData(i))
      return(false);

   return(!last_error|catch("Grid.DeleteOrder(4)"));
}


/**
 * F�gt den Datenarrays der Sequenz die angegebenen Daten hinzu.
 *
 * @param  int      ticket
 * @param  int      level
 * @param  double   gridBase
 *
 * @param  int      pendingType
 * @param  datetime pendingTime
 * @param  double   pendingPrice
 *
 * @param  int      type
 * @param  int      openEvent
 * @param  datetime openTime
 * @param  double   openPrice
 * @param  int      closeEvent
 * @param  datetime closeTime
 * @param  double   closePrice
 * @param  double   stopLoss
 * @param  bool     clientLimit
 * @param  bool     closedBySL
 *
 * @param  double   swap
 * @param  double   commission
 * @param  double   profit
 *
 * @return bool - Erfolgsstatus
 */
bool Grid.PushData(int ticket, int level, double gridBase, int pendingType, datetime pendingTime, double pendingPrice, int type, int openEvent, datetime openTime, double openPrice, int closeEvent, datetime closeTime, double closePrice, double stopLoss, bool clientLimit, bool closedBySL, double swap, double commission, double profit) {
   clientLimit = clientLimit!=0;
   closedBySL  = closedBySL!=0;
   return(Grid.SetData(-1, ticket, level, gridBase, pendingType, pendingTime, pendingPrice, type, openEvent, openTime, openPrice, closeEvent, closeTime, closePrice, stopLoss, clientLimit, closedBySL, swap, commission, profit));
}


/**
 * Schreibt die angegebenen Daten an die angegebene Position der Gridarrays.
 *
 * @param  int      offset - Arrayposition: Ist dieser Wert -1 oder sind die Gridarrays zu klein, werden sie vergr��ert.
 *
 * @param  int      ticket
 * @param  int      level
 * @param  double   gridBase
 *
 * @param  int      pendingType
 * @param  datetime pendingTime
 * @param  double   pendingPrice
 *
 * @param  int      type
 * @param  int      openEvent
 * @param  datetime openTime
 * @param  double   openPrice
 * @param  int      closeEvent
 * @param  datetime closeTime
 * @param  double   closePrice
 * @param  double   stopLoss
 * @param  bool     clientLimit
 * @param  bool     closedBySL
 *
 * @param  double   swap
 * @param  double   commission
 * @param  double   profit
 *
 * @return bool - Erfolgsstatus
 */
bool Grid.SetData(int offset, int ticket, int level, double gridBase, int pendingType, datetime pendingTime, double pendingPrice, int type, int openEvent, datetime openTime, double openPrice, int closeEvent, datetime closeTime, double closePrice, double stopLoss, bool clientLimit, bool closedBySL, double swap, double commission, double profit) {
   clientLimit = clientLimit!=0;
   closedBySL  = closedBySL!=0;

   if (offset < -1)
      return(_false(catch("Grid.SetData(1)  illegal parameter offset = "+ offset, ERR_INVALID_PARAMETER)));

   int i=offset, size=ArraySize(orders.ticket);

   if      (offset ==    -1) i = ResizeArrays(  size+1)-1;
   else if (offset > size-1) i = ResizeArrays(offset+1)-1;

   orders.ticket         [i] = ticket;
   orders.level          [i] = level;
   orders.gridBase       [i] = NormalizeDouble(gridBase, Digits);

   orders.pendingType    [i] = pendingType;
   orders.pendingTime    [i] = pendingTime;
   orders.pendingPrice   [i] = NormalizeDouble(pendingPrice, Digits);

   orders.type           [i] = type;
   orders.openEvent      [i] = openEvent;
   orders.openTime       [i] = openTime;
   orders.openPrice      [i] = NormalizeDouble(openPrice, Digits);
   orders.closeEvent     [i] = closeEvent;
   orders.closeTime      [i] = closeTime;
   orders.closePrice     [i] = NormalizeDouble(closePrice, Digits);
   orders.stopLoss       [i] = NormalizeDouble(stopLoss, Digits);
   orders.clientsideLimit[i] = clientLimit;
   orders.closedBySL     [i] = closedBySL;

   orders.swap           [i] = NormalizeDouble(swap,       2);
   orders.commission     [i] = NormalizeDouble(commission, 2); if (type != OP_UNDEFINED) { sequence.commission = orders.commission[i]; SS.LotSize(); }
   orders.profit         [i] = NormalizeDouble(profit,     2);

   return(!catch("Grid.SetData(2)"));
}


/**
 * Remove order data at the speciefied index from the order arrays.
 *
 * @param  int i - order index
 *
 * @return bool - success status
 */
bool Grid.DropData(int i) {
   if (i < 0 || i >= ArraySize(orders.ticket)) return(_false(catch("Grid.DropData(1)  illegal parameter i = "+ i, ERR_INVALID_PARAMETER)));

   // Eintr�ge entfernen
   ArraySpliceInts   (orders.ticket,          i, 1);
   ArraySpliceInts   (orders.level,           i, 1);
   ArraySpliceDoubles(orders.gridBase,        i, 1);

   ArraySpliceInts   (orders.pendingType,     i, 1);
   ArraySpliceInts   (orders.pendingTime,     i, 1);
   ArraySpliceDoubles(orders.pendingPrice,    i, 1);

   ArraySpliceInts   (orders.type,            i, 1);
   ArraySpliceInts   (orders.openEvent,       i, 1);
   ArraySpliceInts   (orders.openTime,        i, 1);
   ArraySpliceDoubles(orders.openPrice,       i, 1);
   ArraySpliceInts   (orders.closeEvent,      i, 1);
   ArraySpliceInts   (orders.closeTime,       i, 1);
   ArraySpliceDoubles(orders.closePrice,      i, 1);
   ArraySpliceDoubles(orders.stopLoss,        i, 1);
   ArraySpliceBools  (orders.clientsideLimit, i, 1);
   ArraySpliceBools  (orders.closedBySL,      i, 1);

   ArraySpliceDoubles(orders.swap,            i, 1);
   ArraySpliceDoubles(orders.commission,      i, 1);
   ArraySpliceDoubles(orders.profit,          i, 1);

   return(!last_error|catch("Grid.DropData(2)"));
}


/**
 * Sucht eine als offene markierte Position des angegebenen Levels und gibt ihren Index zur�ck. Je Level kann es maximal nur
 * eine offene Position geben.
 *
 * @param  int level - Level der zu suchenden Position
 *
 * @return int - Index der gefundenen Position oder -1 (EMPTY), wenn keine offene Position des angegebenen Levels gefunden wurde
 */
int Grid.FindOpenPosition(int level) {
   if (!level) return(_EMPTY(catch("Grid.FindOpenPosition(1)  illegal parameter level = "+ level, ERR_INVALID_PARAMETER)));

   int size = ArraySize(orders.ticket);
   for (int i=size-1; i >= 0; i--) {                                 // r�ckw�rts iterieren, um Zeit zu sparen
      if (orders.level[i] != level)       continue;                  // Orderlevel mu� �bereinstimmen
      if (orders.type[i] == OP_UNDEFINED) continue;                  // Order darf nicht pending sein (also Position)
      if (orders.closeTime[i] != 0)       continue;                  // Position darf nicht geschlossen sein
      return(i);
   }
   return(EMPTY);
}


/**
 * Generiert f�r den angegebenen Gridlevel eine MagicNumber.
 *
 * @param  int level - Gridlevel
 *
 * @return int - MagicNumber oder -1 (EMPTY), falls ein Fehler auftrat
 */
int CreateMagicNumber(int level) {
   if (sequence.id < SID_MIN) return(_EMPTY(catch("CreateMagicNumber(1)  illegal sequence.id = "+ sequence.id, ERR_RUNTIME_ERROR)));
   if (!level)                return(_EMPTY(catch("CreateMagicNumber(2)  illegal parameter level = "+ level, ERR_INVALID_PARAMETER)));

   // F�r bessere Obfuscation ist die Reihenfolge der Werte [ea,level,sequence] und nicht [ea,sequence,level], was aufeinander folgende Werte w�ren.
   int ea       = STRATEGY_ID & 0x3FF << 22;                         // 10 bit (Bits gr��er 10 l�schen und auf 32 Bit erweitern)  | Position in MagicNumber: Bits 23-32
       level    = Abs(level);                                        // der Level in MagicNumber ist immer positiv                |
       level    = level & 0xFF << 14;                                //  8 bit (Bits gr��er 8 l�schen und auf 22 Bit erweitern)   | Position in MagicNumber: Bits 15-22
   int sequence = sequence.id & 0x3FFF;                              // 14 bit (Bits gr��er 14 l�schen                            | Position in MagicNumber: Bits  1-14

   return(ea + level + sequence);
}


/**
 * Zeigt den aktuellen Laufzeitstatus an.
 *
 * @param  int error - anzuzeigender Fehler
 *
 * @return int - derselbe Fehler oder der aktuelle Fehlerstatus, falls kein Fehler �bergeben wurde
 */
int ShowStatus(int error=NO_ERROR) {
   if (!__CHART()) return(error);

   string msg, str.error;

   if      (__STATUS_INVALID_INPUT) str.error = StringConcatenate("  [", ErrorDescription(ERR_INVALID_INPUT_PARAMETER), "]");
   else if (__STATUS_OFF          ) str.error = StringConcatenate("  [", ErrorDescription(__STATUS_OFF.reason         ), "]");

   switch (sequence.status) {
      case STATUS_UNDEFINED:   msg =                                      " not initialized"; break;
      case STATUS_WAITING:     msg = StringConcatenate("  ", Sequence.ID, " waiting");        break;
      case STATUS_STARTING:    msg = StringConcatenate("  ", Sequence.ID, " starting at level ",    sequence.level, "  (max: ", sequence.maxLevel, str.sequence.missedLevels, ")"); break;
      case STATUS_PROGRESSING: msg = StringConcatenate("  ", Sequence.ID, " progressing at level ", sequence.level, "  (max: ", sequence.maxLevel, str.sequence.missedLevels, ")"); break;
      case STATUS_STOPPING:    msg = StringConcatenate("  ", Sequence.ID, " stopping at level ",    sequence.level, "  (max: ", sequence.maxLevel, str.sequence.missedLevels, ")"); break;
      case STATUS_STOPPED:     msg = StringConcatenate("  ", Sequence.ID, " stopped at level ",     sequence.level, "  (max: ", sequence.maxLevel, str.sequence.missedLevels, ")"); break;
      default:
         return(catch("ShowStatus(1)  illegal sequence status = "+ sequence.status, ERR_RUNTIME_ERROR));
   }

   msg = StringConcatenate(__NAME(), msg, str.error,                                                      NL,
                                                                                                          NL,
                           "Grid:             ", GridSize, " pip", str.grid.base, str.sequence.direction, NL,
                           "LotSize:         ",  str.LotSize,                                             NL,
                           "Stops:           ",  str.sequence.stops, str.sequence.stopsPL,                NL,
                           "Profit/Loss:    ",   str.sequence.totalPL, str.sequence.plStats,              NL,
                           str.startConditions,                                        // enth�lt bereits NL, wenn gesetzt
                           str.stopConditions);                                        // enth�lt bereits NL, wenn gesetzt

   // 1 Zeile Abstand nach oben f�r Instrumentanzeige
   Comment(StringConcatenate(NL, msg));
   if (__WHEREAMI__ == CF_INIT)
      WindowRedraw();


   // f�r Fernbedienung: versteckten Status im Chart speichern
   string label = "SnowRoller.status";
   if (ObjectFind(label) != 0) {
      if (!ObjectCreate(label, OBJ_LABEL, 0, 0, 0))
         return(catch("ShowStatus(2)"));
      ObjectSet(label, OBJPROP_TIMEFRAMES, OBJ_PERIODS_NONE);
   }
   if (sequence.status == STATUS_UNDEFINED) ObjectDelete(label);
   else                                     ObjectSetText(label, StringConcatenate(Sequence.ID, "|", sequence.status), 1);

   if (!catch("ShowStatus(3)"))
      return(error);
   return(last_error);
}


/**
 * ShowStatus(): Aktualisiert alle in ShowStatus() verwendeten String-Repr�sentationen.
 */
void SS.All() {
   if (!__CHART()) return;

   SS.SequenceId();
   SS.GridBase();
   SS.GridDirection();
   SS.MissedLevels();
   SS.LotSize();
   SS.StartStopConditions();
   SS.Stops();
   SS.TotalPL();
   SS.MaxProfit();
   SS.MaxDrawdown();
}


/**
 * ShowStatus(): Aktualisiert die Anzeige der Sequenz-ID in der Titelzeile des Testers.
 */
void SS.SequenceId() {
   if (IsTesting()) {
      if (!SetWindowTextA(FindTesterWindow(), StringConcatenate("Tester - SR.", sequence.id)))
         catch("SS.SequenceId(1)->user32::SetWindowTextA()", ERR_WIN32_ERROR);
   }
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentation von grid.base.
 */
void SS.GridBase() {
   if (!__CHART()) return;
   if (ArraySize(grid.base.event) > 0) {
      str.grid.base = StringConcatenate(" @ ", NumberToStr(grid.base, PriceFormat));
   }
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentation von sequence.direction.
 */
void SS.GridDirection() {
   if (!__CHART()) return;
   str.sequence.direction = StringConcatenate("  (", StrToLower(directionDescr[sequence.direction]), ")");
}


/**
 * ShowStatus(): Update the string presentation of sequence.missedLevels.
 */
void SS.MissedLevels() {
   if (!__CHART()) return;

   int size = ArraySize(sequence.missedLevels);
   if (!size) str.sequence.missedLevels = "";
   else       str.sequence.missedLevels = StringConcatenate(", missed: ", size);
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentation von LotSize.
 */
void SS.LotSize() {
   if (!__CHART()) return;
   double stopSize = GridSize * PipValue(LotSize) - sequence.commission;

   if (ProfitDisplayInPercent) str.LotSize = StringConcatenate(NumberToStr(LotSize, ".+"), " lot = ", DoubleToStr(MathDiv(stopSize, sequence.startEquity) * 100, 2), "%/stop");
   else                        str.LotSize = StringConcatenate(NumberToStr(LotSize, ".+"), " lot = ", DoubleToStr(stopSize, 2), "/stop");
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentation von start/stopConditions.
 */
void SS.StartStopConditions() {
   if (!__CHART()) return;
   str.startConditions = "";
   str.stopConditions  = "";

   if (StartConditions != "") str.startConditions = StringConcatenate("Start:            ", StartConditions, NL);
   if (StopConditions  != "") str.stopConditions  = StringConcatenate("Stop:            ", StopConditions,  NL);
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentationen von sequence.stops und sequence.stopsPL.
 */
void SS.Stops() {
   if (!__CHART()) return;
   str.sequence.stops = StringConcatenate(sequence.stops, " stop", ifString(sequence.stops==1, "", "s"));

   // Anzeige wird nicht vor der ersten ausgestoppten Position gesetzt
   if (sequence.stops > 0) {
      if (ProfitDisplayInPercent) str.sequence.stopsPL = StringConcatenate(" = ", DoubleToStr(MathDiv(sequence.stopsPL, sequence.startEquity) * 100, 2), "%");
      else                        str.sequence.stopsPL = StringConcatenate(" = ", DoubleToStr(sequence.stopsPL, 2));
   }
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentation von sequence.totalPL.
 */
void SS.TotalPL() {
   if (!__CHART()) return;
   if (sequence.maxLevel == 0)      str.sequence.totalPL = "-";           // Anzeige wird nicht vor der ersten offenen Position gesetzt
   else if (ProfitDisplayInPercent) str.sequence.totalPL = StringConcatenate(NumberToStr(MathDiv(sequence.totalPL, sequence.startEquity) * 100, "+.2"), "%");
   else                             str.sequence.totalPL =                   NumberToStr(sequence.totalPL, "+.2");
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentation von sequence.maxProfit.
 */
void SS.MaxProfit() {
   if (!__CHART()) return;
   if (ProfitDisplayInPercent) str.sequence.maxProfit = StringConcatenate(NumberToStr(MathDiv(sequence.maxProfit, sequence.startEquity) * 100, "+.2"), "%");
   else                        str.sequence.maxProfit =                   NumberToStr(sequence.maxProfit, "+.2");
   SS.PLStats();
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentation von sequence.maxDrawdown.
 */
void SS.MaxDrawdown() {
   if (!__CHART()) return;
   if (ProfitDisplayInPercent) str.sequence.maxDrawdown = StringConcatenate(NumberToStr(MathDiv(sequence.maxDrawdown, sequence.startEquity) * 100, "+.2"), "%");
   else                        str.sequence.maxDrawdown =                   NumberToStr(sequence.maxDrawdown, "+.2");
   SS.PLStats();
}


/**
 * ShowStatus(): Aktualisiert die kombinierte String-Repr�sentation der P/L-Statistik.
 */
void SS.PLStats() {
   if (!__CHART()) return;
   // Anzeige wird nicht vor der ersten offenen Position gesetzt
   if (sequence.maxLevel != 0)
      str.sequence.plStats = StringConcatenate("  (", str.sequence.maxProfit, "/", str.sequence.maxDrawdown, ")");
}


/**
 * Store sequence id and transient status in the chart before recompilation or terminal restart.
 *
 * @return int - error status
 */
int StoreRuntimeStatus() {
   string name = __NAME();
   Chart.StoreString(name +".runtime.Sequence.ID",            Sequence.ID                      );
   Chart.StoreInt   (name +".runtime.startStopDisplayMode",   startStopDisplayMode             );
   Chart.StoreInt   (name +".runtime.orderDisplayMode",       orderDisplayMode                 );
   Chart.StoreBool  (name +".runtime.__STATUS_INVALID_INPUT", __STATUS_INVALID_INPUT           );
   Chart.StoreBool  (name +".runtime.CANCELLED_BY_USER",      last_error==ERR_CANCELLED_BY_USER);
   return(catch("StoreRuntimeStatus(1)"));
}


/**
 * Restore sequence id and transient status found in the chart after recompilation or terminal restart.
 *
 * @return bool - whether a sequence id was found and restored
 */
bool RestoreRuntimeStatus() {
   string name = __NAME();
   string key  = name +".runtime.Sequence.ID", sValue = "";

   if (ObjectFind(key) == 0) {
      Chart.RestoreString(key, sValue);

      if (StrStartsWith(sValue, "T")) {
         sequence.isTest = true;
         sValue = StrRight(sValue, -1);
      }
      int iValue = StrToInteger(sValue);
      if (!iValue) {
         sequence.status = STATUS_UNDEFINED;
      }
      else {
         sequence.id     = iValue; SS.SequenceId();
         Sequence.ID     = ifString(IsTestSequence(), "T", "") + sequence.id;
         sequence.name   = StrLeft(directionDescr[sequence.direction], 1) +"."+ sequence.id;
         sequence.status = STATUS_WAITING;
         SetCustomLog(sequence.id, NULL);
      }
      bool bValue;
      Chart.RestoreInt (name +".runtime.startStopDisplayMode",   startStopDisplayMode  );
      Chart.RestoreInt (name +".runtime.orderDisplayMode",       orderDisplayMode      );
      Chart.RestoreBool(name +".runtime.__STATUS_INVALID_INPUT", __STATUS_INVALID_INPUT);
      Chart.RestoreBool(name +".runtime.CANCELLED_BY_USER",      bValue                ); if (bValue) SetLastError(ERR_CANCELLED_BY_USER);
      catch("RestoreRuntimeStatus(1)");
      return(iValue != 0);
   }
   return(false);
}


/**
 * L�scht alle im Chart gespeicherten Sequenzdaten.
 *
 * @return int - Fehlerstatus
 */
int DeleteChartStatus() {
   string label, prefix=__NAME() +".runtime.";

   for (int i=ObjectsTotal()-1; i>=0; i--) {
      label = ObjectName(i);
      if (StrStartsWith(label, prefix)) /*&&*/ if (ObjectFind(label) == 0)
         ObjectDelete(label);
   }
   return(catch("DeleteChartStatus(1)"));
}


/**
 * Ermittelt die aktuell laufenden Sequenzen.
 *
 * @param  int ids[] - Array zur Aufnahme der gefundenen Sequenz-IDs
 *
 * @return bool - ob mindestens eine laufende Sequenz gefunden wurde
 */
bool GetRunningSequences(int ids[]) {
   ArrayResize(ids, 0);
   int id;

   for (int i=OrdersTotal()-1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))               // FALSE: w�hrend des Auslesens wurde in einem anderen Thread eine offene Order entfernt
         continue;

      if (IsMyOrder()) {
         id = OrderMagicNumber() & 0x3FFF;                           // 14 Bits (Bits 1-14) => sequence.id
         if (!IntInArray(ids, id))
            ArrayPushInt(ids, id);
      }
   }

   if (ArraySize(ids) != 0)
      return(ArraySort(ids));
   return(false);
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
      if (OrderMagicNumber() >> 22 == STRATEGY_ID) {
         if (sequenceId == NULL)
            return(true);
         return(sequenceId == OrderMagicNumber() & 0x3FFF);          // 14 Bits (Bits 1-14) => sequence.id
      }
   }
   return(false);
}


/**
 * Validiert und setzt nur die in der Konfiguration angegebene Sequenz-ID.
 *
 * @param  bool interactive - ob fehlerhafte Parameter interaktiv korrigiert werden k�nnen
 *
 * @return bool - ob eine g�ltige Sequenz-ID gefunden und restauriert wurde
 */
bool ValidateConfig.ID(bool interactive) {
   interactive = interactive!=0;

   bool parameterChange = (UninitializeReason() == UR_PARAMETERS);
   if (parameterChange)
      interactive = true;

   string strValue = StrToUpper(StrTrim(Sequence.ID));

   if (!StringLen(strValue))
      return(false);

   if (StrLeft(strValue, 1) == "T") {
      sequence.isTest = true;
      strValue = StrRight(strValue, -1);
   }
   if (!StrIsDigit(strValue))
      return(_false(ValidateConfig.HandleError("ValidateConfig.ID(1)", "Illegal input parameter Sequence.ID = \""+ Sequence.ID +"\"", interactive)));

   int iValue = StrToInteger(strValue);
   if (iValue < SID_MIN || iValue > SID_MAX)
      return(_false(ValidateConfig.HandleError("ValidateConfig.ID(2)", "Illegal input parameter Sequence.ID = \""+ Sequence.ID +"\"", interactive)));

   sequence.id   = iValue; SS.SequenceId();
   Sequence.ID   = ifString(IsTestSequence(), "T", "") + sequence.id;
   sequence.name = StrLeft(directionDescr[sequence.direction], 1) +"."+ sequence.id;
   SetCustomLog(sequence.id, NULL);

   return(true);
}


/**
 * Validiert die aktuelle Konfiguration.
 *
 * @param  bool interactive - ob fehlerhafte Parameter interaktiv korrigiert werden k�nnen
 *
 * @return bool - ob die Konfiguration g�ltig ist
 */
bool ValidateConfig(bool interactive) {
   interactive = interactive!=0;
   if (IsLastError()) return(false);

   bool reasonParameters = (UninitializeReason() == UR_PARAMETERS);
   if (reasonParameters)
      interactive = true;

   // Sequence.ID
   if (reasonParameters) {
      if (sequence.status == STATUS_UNDEFINED) {
         if (Sequence.ID != last.Sequence.ID) {    return(_false(ValidateConfig.HandleError("ValidateConfig(1)", "Loading of another sequence not yet implemented!", interactive)));
            if (ValidateConfig.ID(interactive)) {
               // TODO: neue Sequenz laden
            }
         }
      }
      else {
         if (Sequence.ID == "")                    return(_false(ValidateConfig.HandleError("ValidateConfig(2)", "Sequence.ID missing!", interactive)));
         if (Sequence.ID != last.Sequence.ID) {    return(_false(ValidateConfig.HandleError("ValidateConfig(3)", "Loading of another sequence not yet implemented!", interactive)));
            if (ValidateConfig.ID(interactive)) {
               // TODO: neue Sequenz laden
            }
         }
      }
   }
   else if (!StringLen(Sequence.ID)) {             // wir m�ssen im STATUS_UNDEFINED sein (sequence.id = 0)
      if (sequence.id != 0)                        return(_false(catch("ValidateConfig(4)  illegal Sequence.ID = \""+ Sequence.ID +"\" (sequence.id="+ sequence.id +")", ERR_RUNTIME_ERROR)));
   }
   else {}                                         // wenn gesetzt, ist die ID schon validiert und die Sequenz geladen (sonst landen wir hier nicht)

   // GridDirection
   if (reasonParameters) {
      if (GridDirection != last.GridDirection)
         if (ArraySize(sequence.start.event) > 0)  return(_false(ValidateConfig.HandleError("ValidateConfig(5)", "Cannot change GridDirection of "+ sequenceStatusDescr[sequence.status] +" sequence", interactive)));
   }
   string sValue = StrToLower(StrTrim(GridDirection));
   if      (StrStartsWith("long",  sValue)) sequence.direction = D_LONG;
   else if (StrStartsWith("short", sValue)) sequence.direction = D_SHORT;
   else                                            return(_false(ValidateConfig.HandleError("ValidateConfig(6)", "Invalid GridDirection = \""+ GridDirection +"\"", interactive)));
   GridDirection = directionDescr[sequence.direction]; SS.GridDirection();
   sequence.name = StrLeft(GridDirection, 1) +"."+ sequence.id;

   // GridSize
   if (reasonParameters) {
      if (GridSize != last.GridSize)
         if (ArraySize(sequence.start.event) > 0)  return(_false(ValidateConfig.HandleError("ValidateConfig(7)", "Cannot change GridSize of "+ sequenceStatusDescr[sequence.status] +" sequence", interactive)));
   }
   if (GridSize < 1)                               return(_false(ValidateConfig.HandleError("ValidateConfig(8)", "Invalid GridSize = "+ GridSize, interactive)));

   // LotSize
   if (reasonParameters) {
      if (NE(LotSize, last.LotSize))
         if (ArraySize(sequence.start.event) > 0)  return(_false(ValidateConfig.HandleError("ValidateConfig(9)", "Cannot change LotSize of "+ sequenceStatusDescr[sequence.status] +" sequence", interactive)));
   }
   if (LE(LotSize, 0))                             return(_false(ValidateConfig.HandleError("ValidateConfig(10)", "Invalid LotSize = "+ NumberToStr(LotSize, ".+"), interactive)));
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT );
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT );
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   int error = GetLastError();
   if (IsError(error))                             return(_false(catch("ValidateConfig(11)  symbol=\""+ Symbol() +"\"", error)));
   if (LT(LotSize, minLot))                        return(_false(ValidateConfig.HandleError("ValidateConfig(12)", "Invalid LotSize = "+ NumberToStr(LotSize, ".+") +" (MinLot="+  NumberToStr(minLot, ".+" ) +")", interactive)));
   if (GT(LotSize, maxLot))                        return(_false(ValidateConfig.HandleError("ValidateConfig(13)", "Invalid LotSize = "+ NumberToStr(LotSize, ".+") +" (MaxLot="+  NumberToStr(maxLot, ".+" ) +")", interactive)));
   if (MathModFix(LotSize, lotStep) != 0)          return(_false(ValidateConfig.HandleError("ValidateConfig(14)", "Invalid LotSize = "+ NumberToStr(LotSize, ".+") +" (LotStep="+ NumberToStr(lotStep, ".+") +")", interactive)));
   SS.LotSize();

   // StartLevel
   if (reasonParameters) {
      if (StartLevel != last.StartLevel)
         if (ArraySize(sequence.start.event) > 0)  return(_false(ValidateConfig.HandleError("ValidateConfig(15)", "Cannot change StartLevel of "+ sequenceStatusDescr[sequence.status] +" sequence", interactive)));
   }
   if (sequence.direction == D_LONG) {
      if (StartLevel < 0)                          return(_false(ValidateConfig.HandleError("ValidateConfig(16)", "Invalid StartLevel = "+ StartLevel, interactive)));
   }
   StartLevel = Abs(StartLevel);

   // StartConditions, AND-verkn�pft: @[bid|ask|price](1.33) && @time(12:00)
   // ----------------------------------------------------------------------
   if (!reasonParameters || StartConditions!=last.StartConditions) {
      // Bei Parameter�nderung Werte nur �bernehmen, wenn sie sich tats�chlich ge�ndert haben, soda� StartConditions nur bei �nderung (re-)aktiviert werden.
      start.conditions      = false;
      start.price.condition = false;
      start.time.condition  = false;

      // (6.1) StartConditions in einzelne Ausdr�cke zerlegen
      string exprs[], expr, elems[], key, value;
      int    iValue, time, sizeOfElems, sizeOfExprs = Explode(StartConditions, "&&", exprs, NULL);
      double dValue;

      // (6.2) jeden Ausdruck parsen und validieren
      for (int i=0; i < sizeOfExprs; i++) {
         start.conditions = false;                 // im Fehlerfall ist start.conditions deaktiviert
         expr = StrTrim(exprs[i]);
         if (!StringLen(expr)) {
            if (sizeOfExprs > 1)                   return(_false(ValidateConfig.HandleError("ValidateConfig(17)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
            break;
         }
         if (StringGetChar(expr, 0) != '@')        return(_false(ValidateConfig.HandleError("ValidateConfig(18)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
         if (Explode(expr, "(", elems, NULL) != 2) return(_false(ValidateConfig.HandleError("ValidateConfig(19)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
         if (!StrEndsWith(elems[1], ")"))          return(_false(ValidateConfig.HandleError("ValidateConfig(20)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
         key   = StrTrim(elems[0]);
         value = StrTrim(StrLeft(elems[1], -1));
         if (!StringLen(value))                    return(_false(ValidateConfig.HandleError("ValidateConfig(21)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));

         if (key=="@bid" || key=="@ask" || key=="@median" || key=="@price") {
            if (start.price.condition)             return(_false(ValidateConfig.HandleError("ValidateConfig(22)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions) +" (multiple price conditions)", interactive)));
            value = StrReplace(value, "'", "");
            if (!StrIsNumeric(value))              return(_false(ValidateConfig.HandleError("ValidateConfig(23)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
            dValue = StrToDouble(value);
            if (dValue <= 0)                       return(_false(ValidateConfig.HandleError("ValidateConfig(24)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
            start.price.condition = true;
            start.price.value     = NormalizeDouble(dValue, Digits);
            start.price.lastValue = NULL;
            if      (key == "@bid") start.price.type = PRICE_BID;
            else if (key == "@ask") start.price.type = PRICE_ASK;
            else                    start.price.type = PRICE_MEDIAN;

            exprs[i] = NumberToStr(start.price.value, PriceFormat);
            if (StrEndsWith(exprs[i], "'0"))       // cut a "'0" for improved readability
               exprs[i] = StrLeft(exprs[i], -2);
            exprs[i] = key +"("+ exprs[i] +")";
         }

         else if (key == "@time") {
            if (start.time.condition)              return(_false(ValidateConfig.HandleError("ValidateConfig(25)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions) +" (multiple time conditions)", interactive)));
            time = StrToTime(value);
            if (IsError(GetLastError()))           return(_false(ValidateConfig.HandleError("ValidateConfig(26)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
            // TODO: Validierung von @time ist unzureichend
            start.time.condition = true;
            start.time.value     = time;
            exprs[i]             = key +"("+ TimeToStr(time) +")";
         }
         else                                      return(_false(ValidateConfig.HandleError("ValidateConfig(27)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
         start.conditions = true;
      }
      if (start.conditions) StartConditions = JoinStrings(exprs, " && ");
      else                  StartConditions = "";
   }

   // StopConditions, OR-verkn�pft: @[bid|ask|price](1.33) || @time(12:00) || @profit(1234[%])
   // ----------------------------------------------------------------------------------------
   // Bei Parameter�nderung Werte nur �bernehmen, wenn sie sich tats�chlich ge�ndert haben, soda� StopConditions nur bei �nderung (re-)aktiviert werden.
   if (!reasonParameters || StopConditions!=last.StopConditions) {
      stop.price.condition     = false;
      stop.time.condition      = false;
      stop.profitAbs.condition = false;
      stop.profitPct.condition = false;

      // (7.1) StopConditions in einzelne Ausdr�cke zerlegen
      sizeOfExprs = Explode(StrTrim(StopConditions), "||", exprs, NULL);

      // (7.2) jeden Ausdruck parsen und validieren
      for (i=0; i < sizeOfExprs; i++) {
         expr = StrToLower(StrTrim(exprs[i]));
         if (!StringLen(expr)) {
            if (sizeOfExprs > 1)                   return(_false(ValidateConfig.HandleError("ValidateConfig(28)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            break;
         }
         if (StringGetChar(expr, 0) != '@')        return(_false(ValidateConfig.HandleError("ValidateConfig(29)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
         if (Explode(expr, "(", elems, NULL) != 2) return(_false(ValidateConfig.HandleError("ValidateConfig(30)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
         if (!StrEndsWith(elems[1], ")"))          return(_false(ValidateConfig.HandleError("ValidateConfig(31)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
         key   = StrTrim(elems[0]);
         value = StrTrim(StrLeft(elems[1], -1));
         if (!StringLen(value))                    return(_false(ValidateConfig.HandleError("ValidateConfig(32)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));

         if (key=="@bid" || key=="@ask" || key=="@median" || key=="@price") {
            if (stop.price.condition)              return(_false(ValidateConfig.HandleError("ValidateConfig(33)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions) +" (multiple price conditions)", interactive)));
            value = StrReplace(value, "'", "");
            if (!StrIsNumeric(value))              return(_false(ValidateConfig.HandleError("ValidateConfig(34)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            dValue = StrToDouble(value);
            if (dValue <= 0)                       return(_false(ValidateConfig.HandleError("ValidateConfig(35)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            stop.price.condition = true;
            stop.price.value     = NormalizeDouble(dValue, Digits);
            stop.price.lastValue = NULL;
            if      (key == "@bid") stop.price.type = PRICE_BID;
            else if (key == "@ask") stop.price.type = PRICE_ASK;
            else                    stop.price.type = PRICE_MEDIAN;

            exprs[i] = NumberToStr(stop.price.value, PriceFormat);
            if (StrEndsWith(exprs[i], "'0"))       // 0-Subpips "'0" f�r bessere Lesbarkeit entfernen
               exprs[i] = StrLeft(exprs[i], -2);
            exprs[i] = key +"("+ exprs[i] +")";
         }

         else if (key == "@time") {
            if (stop.time.condition)               return(_false(ValidateConfig.HandleError("ValidateConfig(36)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions) +" (multiple time conditions)", interactive)));
            time = StrToTime(value);
            if (IsError(GetLastError()))           return(_false(ValidateConfig.HandleError("ValidateConfig(37)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            // TODO: Validierung von @time ist unzureichend
            stop.time.condition = true;
            stop.time.value     = time;
            exprs[i]            = key +"("+ TimeToStr(time) +")";
         }

         else if (key == "@profit") {
            if (stop.profitAbs.condition || stop.profitPct.condition)
                                                   return(_false(ValidateConfig.HandleError("ValidateConfig(38)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions) +" (multiple profit conditions)", interactive)));
            sizeOfElems = Explode(value, "%", elems, NULL);
            if (sizeOfElems > 2)                   return(_false(ValidateConfig.HandleError("ValidateConfig(39)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            value = StrTrim(elems[0]);
            if (!StringLen(value))                 return(_false(ValidateConfig.HandleError("ValidateConfig(40)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            if (!StrIsNumeric(value))              return(_false(ValidateConfig.HandleError("ValidateConfig(41)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            dValue = StrToDouble(value);
            if (sizeOfElems == 1) {
               stop.profitAbs.condition = true;
               stop.profitAbs.value     = NormalizeDouble(dValue, 2);
               exprs[i]                 = key +"("+ NumberToStr(dValue, ".2") +")";
            }
            else {
               stop.profitPct.condition = true;
               stop.profitPct.value     = dValue;
               stop.profitPct.absValue  = INT_MAX;
               exprs[i]                 = key +"("+ NumberToStr(dValue, ".+") +"%)";
            }
         }
         else                                      return(_false(ValidateConfig.HandleError("ValidateConfig(42)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
      }
      StopConditions = JoinStrings(exprs, " || ");
   }

   // __STATUS_INVALID_INPUT zur�cksetzen
   if (interactive)
      __STATUS_INVALID_INPUT = false;
   return(!last_error|catch("ValidateConfig(43)"));
}


/**
 * Exception-Handler f�r ung�ltige Input-Parameter. Je nach Situation wird der Fehler an den Default-Errorhandler �bergeben
 * oder zur Korrektur aufgefordert.
 *
 * @param  string location    - Ort, an dem der Fehler auftrat
 * @param  string message     - Fehlermeldung
 * @param  bool   interactive - ob der Fehler interaktiv behandelt werden kann
 *
 * @return int - der resultierende Fehlerstatus
 */
int ValidateConfig.HandleError(string location, string message, bool interactive) {
   interactive = interactive!=0;
   if (IsTesting() || !interactive)
      return(catch(location +"   "+ message, ERR_INVALID_CONFIG_VALUE));

   int error = ERR_INVALID_INPUT_PARAMETER;
   __STATUS_INVALID_INPUT = true;

   if (__LOG()) log(location +"   "+ message, error);
   PlaySoundEx("Windows Chord.wav");
   int button = MessageBoxEx(__NAME() +" - "+ location, message, MB_ICONERROR|MB_RETRYCANCEL);
   if (button == IDRETRY)
      __STATUS_RELAUNCH_INPUT = true;
   return(error);
}


/**
 * Speichert die aktuelle Konfiguration zwischen, um sie bei Fehleingaben nach Parameter�nderungen restaurieren zu k�nnen.
 * Called only from onInitParameters().
 */
void BackupConfiguration() {
   StoreConfiguration(true);
}


/**
 * Restauriert eine zuvor gespeicherte Konfiguration. Called only from onInitParameters().
 */
void RestoreConfiguration() {
   StoreConfiguration(false);
}


/**
 *
 */
void StoreConfiguration(bool save) {
   save = save!=0;

   static string   _Sequence.ID;
   static string   _GridDirection;
   static int      _GridSize;
   static double   _LotSize;
   static int      _StartLevel;
   static string   _StartConditions;
   static string   _StopConditions;
   static bool     _ProfitDisplayInPercent;

   static int      _sequence.direction;

   static bool     _start.conditions;

   static bool     _start.price.condition;
   static int      _start.price.type;
   static double   _start.price.value;

   static bool     _start.time.condition;
   static datetime _start.time.value;

   static bool     _stop.price.condition;
   static int      _stop.price.type;
   static double   _stop.price.value;

   static bool     _stop.time.condition;
   static datetime _stop.time.value;

   static bool     _stop.profitAbs.condition;
   static double   _stop.profitAbs.value;

   static bool     _stop.profitPct.condition;
   static double   _stop.profitPct.value;
   static double   _stop.profitPct.absValue;

   if (save) {
      _Sequence.ID              = StringConcatenate(Sequence.ID,     "");  // String-Inputvariablen sind C-Literale und read-only (siehe MQL.doc)
      _GridDirection            = StringConcatenate(GridDirection,   "");
      _GridSize                 = GridSize;
      _LotSize                  = LotSize;
      _StartLevel               = StartLevel;
      _StartConditions          = StringConcatenate(StartConditions, "");
      _StopConditions           = StringConcatenate(StopConditions,  "");
      _ProfitDisplayInPercent   = ProfitDisplayInPercent;

      _sequence.direction       = sequence.direction;

      _start.conditions         = start.conditions;

      _start.price.condition    = start.price.condition;
      _start.price.type         = start.price.type;
      _start.price.value        = start.price.value;

      _start.time.condition     = start.time.condition;
      _start.time.value         = start.time.value;

      _stop.price.condition     = stop.price.condition;
      _stop.price.type          = stop.price.type;
      _stop.price.value         = stop.price.value;

      _stop.time.condition      = stop.time.condition;
      _stop.time.value          = stop.time.value;

      _stop.profitAbs.condition = stop.profitAbs.condition;
      _stop.profitAbs.value     = stop.profitAbs.value;

      _stop.profitPct.condition = stop.profitPct.condition;
      _stop.profitPct.value     = stop.profitPct.value;
      _stop.profitPct.absValue  = stop.profitPct.absValue;
   }
   else {
      Sequence.ID               = _Sequence.ID;
      GridDirection             = _GridDirection;
      GridSize                  = _GridSize;
      LotSize                   = _LotSize;
      StartLevel                = _StartLevel;
      StartConditions           = _StartConditions;
      StopConditions            = _StopConditions;
      ProfitDisplayInPercent    = _ProfitDisplayInPercent;

      sequence.direction        = _sequence.direction;
      sequence.name             = StrLeft(directionDescr[sequence.direction], 1) +"."+ sequence.id;

      start.conditions          = _start.conditions;

      start.price.condition     = _start.price.condition;
      start.price.type          = _start.price.type;
      start.price.value         = _start.price.value;

      start.time.condition      = _start.time.condition;
      start.time.value          = _start.time.value;

      stop.price.condition      = _stop.price.condition;
      stop.price.type           = _stop.price.type;
      stop.price.value          = _stop.price.value;

      stop.time.condition       = _stop.time.condition;
      stop.time.value           = _stop.time.value;

      stop.profitAbs.condition  = _stop.profitAbs.condition;
      stop.profitAbs.value      = _stop.profitAbs.value;

      stop.profitPct.condition  = _stop.profitPct.condition;
      stop.profitPct.value      = _stop.profitPct.value;
      stop.profitPct.absValue   = _stop.profitPct.absValue;
   }
}


/**
 * Initialisiert die Dateinamensvariablen der Statusdatei mit den Ausgangswerten einer neuen Sequenz.
 *
 * @return bool - success status
 */
bool InitStatusLocation() {
   if (IsLastError()) return( false);
   if (!sequence.id)  return(_false(catch("InitStatusLocation(1)  illegal value of sequence.id = "+ sequence.id, ERR_RUNTIME_ERROR)));

   if      (IsTesting())      statusDirectory = "presets\\";
   else if (IsTestSequence()) statusDirectory = "presets\\tester\\";
   else                       statusDirectory = "presets\\"+ ShortAccountCompany() +"\\";

   statusFile = StrToLower(StdSymbol()) +".SR."+ sequence.id +".set";
   return(true);
}


/**
 * Aktualisiert die Dateinamensvariablen der Statusdatei. SaveStatus() erkennt die �nderung und verschiebt die Datei automatisch.
 *
 * @return bool - success status
 */
bool UpdateStatusLocation() {
   if (IsLastError()) return( false);
   if (!sequence.id)  return(_false(catch("UpdateStatusLocation(1)  illegal value of sequence.id = "+ sequence.id, ERR_RUNTIME_ERROR)));

   // TODO: Pr�fen, ob statusFile existiert und ggf. aktualisieren

   if      (IsTesting())      statusDirectory = "presets\\";
   else if (IsTestSequence()) statusDirectory = "presets\\tester\\";
   else                       statusDirectory = "presets\\"+ ShortAccountCompany() +"\\";
   return(true);
}


/**
 * Restauriert anhand der verf�gbaren Informationen Ort und Namen der Statusdatei, wird nur aus RestoreStatus() heraus aufgerufen.
 *
 * @return bool - Erfolgsstatus
 */
bool ResolveStatusLocation() {
   if (IsLastError()) return(false);

   // Location-Variablen zur�cksetzen
   InitStatusLocation();
   string filesDirectory  = GetFullMqlFilesPath() +"\\";
   string statusDirectory = MQL.GetStatusDirName();
   string directory="", subdirs[], subdir="", location="", file="";

   while (true) {
      if (location != "") {
         // mit location: das angegebene Unterverzeichnis durchsuchen
         directory = filesDirectory + statusDirectory + StdSymbol() +"\\"+ location +"\\";
         if (ResolveStatusLocation.FindFile(directory, file))
            break;
         return(false);
      }

      // ohne location: zuerst Basisverzeichnis durchsuchen...
      directory = filesDirectory + statusDirectory;
      if (ResolveStatusLocation.FindFile(directory, file))
         break;
      if (IsLastError()) return(false);

      // ohne location: ...dann Unterverzeichnisse des jeweiligen Symbols durchsuchen
      directory = directory + StdSymbol() +"\\";
      int size = FindFileNames(directory +"*", subdirs, FF_DIRSONLY); if (size == -1) return(false);

      for (int i=0; i < size; i++) {
         subdir = directory + subdirs[i] +"\\";
         if (ResolveStatusLocation.FindFile(subdir, file)) {
            directory = subdir;
            location  = subdirs[i];
            break;
         }
         if (IsLastError()) return(false);
      }
      if (StringLen(file) > 0)
         break;
      return(!catch("ResolveStatusLocation(1)  status file not found", ERR_FILE_NOT_FOUND));
   }

   statusDirectory = StrRight(directory, -StringLen(filesDirectory));
   statusFile      = file;
   return(true);
}


/**
 * Durchsucht das angegebene Verzeichnis nach einer passenden Statusdatei und schreibt das Ergebnis in die �bergebene Variable.
 *
 * @param  string directory - vollst�ndiger Name des zu durchsuchenden Verzeichnisses
 * @param  string lpFile    - Zeiger auf Variable zur Aufnahme des gefundenen Dateinamens
 *
 * @return bool - success status
 */
bool ResolveStatusLocation.FindFile(string directory, string &lpFile) {
   if (IsLastError()) return( false);
   if (!sequence.id)  return(_false(catch("ResolveStatusLocation.FindFile(1)  illegal value of sequence.id = "+ sequence.id, ERR_RUNTIME_ERROR)));

   if (!StrEndsWith(directory, "\\"))
      directory = StringConcatenate(directory, "\\");

   string sequencePattern = StringConcatenate("SR*", sequence.id);               // * steht f�r [._-] (? f�r ein einzelnes Zeichen funktioniert nicht)
   string sequenceNames[2];
          sequenceNames[0]= StringConcatenate("SR.", sequence.id, ".");
          sequenceNames[1]= StringConcatenate("SR.", sequence.id, "_");

   string filePattern = StringConcatenate(directory, "*", sequencePattern, "*set");
   string files[];

   int size = FindFileNames(filePattern, files, FF_FILESONLY);                   // Dateien suchen, die den Sequenznamen enthalten und mit "set" enden
   if (size == -1) return(false);

   for (int i=0; i < size; i++) {
      if (!StrStartsWithI(files[i], sequenceNames[0]))
         if (!StrStartsWithI(files[i], sequenceNames[1]))
            if (!StrContainsI(files[i], "."+ sequenceNames[0]))
               if (!StrContainsI(files[i], "."+ sequenceNames[1]))
         continue;
      if (StrEndsWithI(files[i], ".set")) {
         lpFile = files[i];                                                      // Abbruch nach Fund der ersten .set-Datei
         return(true);
      }
   }

   lpFile = "";
   return(false);
}


/**
 * Return the name of the status file directory relative to "files/".
 *
 * @return string - directory name ending with a backslash
 */
string MQL.GetStatusDirName() {
   return(statusDirectory);
}


/**
 * Return the name of the status file relative to "files/".
 *
 * @return string
 */
string MQL.GetStatusFileName() {
   return(StringConcatenate(statusDirectory, statusFile));
}


int lastEventId;


/**
 * Generiert eine neue Event-ID.
 *
 * @return int - ID (ein fortlaufender Z�hler)
 */
int CreateEventId() {
   lastEventId++;
   return(lastEventId);
}


/**
 * Speichert den aktuellen Sequenzstatus, um sp�ter die nahtlose Re-Initialisierung im selben oder einem anderen Terminal
 * zu erm�glichen.
 *
 * @return bool - success status
 */
bool SaveStatus() {
   if (IsLastError())                             return(false);
   if (!sequence.id)                              return(!catch("SaveStatus(1)  illegal value of sequence.id = "+ sequence.id, ERR_RUNTIME_ERROR));
   if (IsTestSequence()) /*&&*/ if (!IsTesting()) return(true);

   // Im Tester wird der Status zur Performancesteigerung nur beim ersten und letzten Aufruf gespeichert,
   // oder wenn die Sequenz gestoppt wurde.
   if (IsTesting() /*&& !__LOG()*/) {                                // enable !__LOG() to always save if logging is enabled
      static bool statusSaved = false;
      if (statusSaved && sequence.status!=STATUS_STOPPED && __WHEREAMI__!=CF_DEINIT)
         return(true);                                               // skip saving
   }

   /*
   Speichernotwendigkeit der einzelnen Variablen
   ---------------------------------------------
   int      sequence.id;                  // nein: wird aus Statusdatei ermittelt
   int      sequence.status;              // nein: kann aus Orderdaten und offenen Positionen restauriert werden
   bool     sequence.isTest;              // nein: wird aus Statusdatei ermittelt
   int      sequence.direction;           // nein: wird aus Statusdatei ermittelt
   int      sequence.level;               // nein: kann aus Orderdaten restauriert werden
   int      sequence.maxLevel;            // nein: kann aus Orderdaten restauriert werden
   int      sequence.missedLevels[];      // optional: wird gespeichert, wenn belegt
   double   sequence.startEquity;         // ja
   int      sequence.stops;               // nein: kann aus Orderdaten restauriert werden
   double   sequence.stopsPL;             // nein: kann aus Orderdaten restauriert werden
   double   sequence.closedPL;            // nein: kann aus Orderdaten restauriert werden
   double   sequence.floatingPL;          // nein: kann aus offenen Positionen restauriert werden
   double   sequence.totalPL;             // nein: kann aus stopsPL, closedPL und floatingPL restauriert werden
   double   sequence.maxProfit;           // ja
   double   sequence.maxDrawdown;         // ja
   double   sequence.commission;          // nein: wird aus Config ermittelt

   int      sequence.start.event [];      // ja
   datetime sequence.start.time  [];      // ja
   double   sequence.start.price [];      // ja
   double   sequence.start.profit[];      // ja

   int      sequence.stop.event [];       // ja
   datetime sequence.stop.time  [];       // ja
   double   sequence.stop.price [];       // ja
   double   sequence.stop.profit[];       // ja

   bool     start.*.condition;            // nein: wird aus StartConditions abgeleitet
   bool     stop.*.condition;             // nein: wird aus StopConditions abgeleitet
   bool     weekend.stop.active;          // ja

   double   grid.base;                    // nein: wird aus Gridbase-History restauriert
   int      grid.base.event[];            // ja
   datetime grid.base.time [];            // ja
   double   grid.base.value[];            // ja

   int      orders.ticket         [];     // ja:  0
   int      orders.level          [];     // ja:  1
   double   orders.gridBase       [];     // ja:  2
   int      orders.pendingType    [];     // ja:  3
   datetime orders.pendingTime    [];     // ja:  4   kein Event
   double   orders.pendingPrice   [];     // ja:  5
   int      orders.type           [];     // ja:  6
   int      orders.openEvent      [];     // ja:  7
   datetime orders.openTime       [];     // ja:  8   EV_POSITION_OPEN
   double   orders.openPrice      [];     // ja:  9
   int      orders.closeEvent     [];     // ja: 10
   datetime orders.closeTime      [];     // ja: 11   EV_POSITION_STOPOUT | EV_POSITION_CLOSE
   double   orders.closePrice     [];     // ja: 12
   double   orders.stopLoss       [];     // ja: 13
   bool     orders.clientsideLimit[];     // ja: 14
   bool     orders.closedBySL     [];     // ja: 15
   double   orders.swap           [];     // ja: 16
   double   orders.commission     [];     // ja: 17
   double   orders.profit         [];     // ja: 18

   int      ignorePendingOrders  [];      // optional (werden nur gespeichert, wenn belegt)
   int      ignoreOpenPositions  [];      // optional (werden nur gespeichert, wenn belegt)
   int      ignoreClosedPositions[];      // optional (werden nur gespeichert, wenn belegt)
   */

   // Dateiinhalt zusammenstellen: Konfiguration und Input-Parameter
   string lines[]; ArrayResize(lines, 0);
   ArrayPushString(lines, /*string*/ "Account="+ ShortAccountCompany() +":"+ GetAccountNumber());
      int sizeOfStarts = ArraySize(sequence.start.event);
      if (!sizeOfStarts) datetime created = TimeCurrentEx("SaveStatus(2)");
      else                        created = sequence.start.time[0];
   ArrayPushString(lines, /*string*/ "Created="        + GmtTimeFormat(created, "%a, %Y.%m.%d %H:%M:%S"));
   ArrayPushString(lines, /*string*/ "Symbol="         +               Symbol()       );
   ArrayPushString(lines, /*string*/ "Sequence.ID="    +               Sequence.ID    );
      if (!StringLen(Sequence.ID)) warn("SaveStatus(3)  sequence (int)"+ sequence.id +", writing illegal input parameter Sequence.ID to status file: \"\"");
   ArrayPushString(lines, /*string*/ "GridDirection="  +               GridDirection  );
   ArrayPushString(lines, /*int   */ "GridSize="       +               GridSize       );
   ArrayPushString(lines, /*double*/ "LotSize="        +   NumberToStr(LotSize, ".+") );
   ArrayPushString(lines, /*int   */ "StartLevel="     +               StartLevel     );
   ArrayPushString(lines, /*string*/ "StartConditions="+               StartConditions);
   ArrayPushString(lines, /*string*/ "StopConditions=" +               StopConditions );

   // Laufzeit-Variablen
   ArrayPushString(lines, /*double*/ "rt.sequence.startEquity="+ NumberToStr(sequence.startEquity, ".+"));
      string values[]; ArrayResize(values, 0);
   ArrayPushString(lines, /*double*/ "rt.sequence.maxProfit="   + NumberToStr(sequence.maxProfit, ".+"));
   ArrayPushString(lines, /*double*/ "rt.sequence.maxDrawdown=" + NumberToStr(sequence.maxDrawdown, ".+"));
      int size = sizeOfStarts;
      for (int i=0; i < size; i++)
         ArrayPushString(values, StringConcatenate(sequence.start.event[i], "|", sequence.start.time[i], "|", NumberToStr(sequence.start.price[i], ".+"), "|", NumberToStr(sequence.start.profit[i], ".+")));
      if (size == 0)
         ArrayPushString(values, "0|0|0|0");
   ArrayPushString(lines, /*string*/ "rt.sequence.starts="+ JoinStrings(values, ", "));
      ArrayResize(values, 0);
      size = ArraySize(sequence.stop.event);
      for (i=0; i < size; i++)
         ArrayPushString(values, StringConcatenate(sequence.stop.event[i], "|", sequence.stop.time[i], "|", NumberToStr(sequence.stop.price[i], ".+"), "|", NumberToStr(sequence.stop.profit[i], ".+")));
      if (size == 0)
         ArrayPushString(values, "0|0|0|0");
   ArrayPushString(lines, /*string*/ "rt.sequence.stops="       + JoinStrings(values, ", "));
      if (ArraySize(sequence.missedLevels) > 0)
   ArrayPushString(lines, /*string*/ "rt.sequence.missedLevels="+ JoinInts(sequence.missedLevels, ","));
      if (sequence.status==STATUS_STOPPED) /*&&*/ if (IsWeekendStopSignal())
   ArrayPushString(lines, /*int*/    "rt.weekendStop="          + 1);
      if (ArraySize(ignorePendingOrders) > 0)
   ArrayPushString(lines, /*string*/ "rt.ignorePendingOrders="  + JoinInts(ignorePendingOrders, ","));
      if (ArraySize(ignoreOpenPositions) > 0)
   ArrayPushString(lines, /*string*/ "rt.ignoreOpenPositions="  + JoinInts(ignoreOpenPositions, ","));
      if (ArraySize(ignoreClosedPositions) > 0)
   ArrayPushString(lines, /*string*/ "rt.ignoreClosedPositions="+ JoinInts(ignoreClosedPositions, ","));
      ArrayResize(values, 0);
      size = ArraySize(grid.base.event);
      for (i=0; i < size; i++)
         ArrayPushString(values, StringConcatenate(grid.base.event[i], "|", grid.base.time[i], "|", NumberToStr(grid.base.value[i], ".+")));
      if (size == 0)
         ArrayPushString(values, "0|0|0");
   ArrayPushString(lines, /*string*/ "rt.grid.base="            + JoinStrings(values, ", "));

   size = ArraySize(orders.ticket);
   for (i=0; i < size; i++) {
      int      ticket       = orders.ticket         [i];    //  0
      int      level        = orders.level          [i];    //  1
      double   gridBase     = orders.gridBase       [i];    //  2
      int      pendingType  = orders.pendingType    [i];    //  3
      datetime pendingTime  = orders.pendingTime    [i];    //  4
      double   pendingPrice = orders.pendingPrice   [i];    //  5
      int      type         = orders.type           [i];    //  6
      int      openEvent    = orders.openEvent      [i];    //  7
      datetime openTime     = orders.openTime       [i];    //  8
      double   openPrice    = orders.openPrice      [i];    //  9
      int      closeEvent   = orders.closeEvent     [i];    // 10
      datetime closeTime    = orders.closeTime      [i];    // 11
      double   closePrice   = orders.closePrice     [i];    // 12
      double   stopLoss     = orders.stopLoss       [i];    // 13
      bool     clientLimit  = orders.clientsideLimit[i];    // 14
      bool     closedBySL   = orders.closedBySL     [i];    // 15
      double   swap         = orders.swap           [i];    // 16
      double   commission   = orders.commission     [i];    // 17
      double   profit       = orders.profit         [i];    // 18
      ArrayPushString(lines, StringConcatenate("rt.order.", i, "=", ticket, ",", level, ",", NumberToStr(NormalizeDouble(gridBase, Digits), ".+"), ",", pendingType, ",", pendingTime, ",", NumberToStr(NormalizeDouble(pendingPrice, Digits), ".+"), ",", type, ",", openEvent, ",", openTime, ",", NumberToStr(NormalizeDouble(openPrice, Digits), ".+"), ",", closeEvent, ",", closeTime, ",", NumberToStr(NormalizeDouble(closePrice, Digits), ".+"), ",", NumberToStr(NormalizeDouble(stopLoss, Digits), ".+"), ",", clientLimit, ",", closedBySL, ",", NumberToStr(swap, ".+"), ",", NumberToStr(commission, ".+"), ",", NumberToStr(profit, ".+")));
      //rt.order.{i}={ticket},{level},{gridBase},{pendingType},{pendingTime},{pendingPrice},{type},{openEvent},{openTime},{openPrice},{closeEvent},{closeTime},{closePrice},{stopLoss},{clientLimit},{closedBySL},{swap},{commission},{profit}
   }

   // alles speichern
   string filename = MQL.GetStatusFileName();
   int hFile = FileOpen(filename, FILE_CSV|FILE_WRITE);
   if (hFile < 0) return(_false(catch("SaveStatus(4)->FileOpen(\""+ filename +"\")")));

   for (i=0; i < ArraySize(lines); i++) {
      if (FileWrite(hFile, lines[i]) < 0) {
         int error = GetLastError();
         catch("SaveStatus(5)->FileWrite(line #"+ (i+1) +") failed to \""+ filename +"\"", ifInt(error, error, ERR_RUNTIME_ERROR));
         FileClose(hFile);
         return(false);
      }
   }
   FileClose(hFile);
   statusSaved = true;
   //debug("SaveStatus(0.1)  ok");

   ArrayResize(lines,  0);
   ArrayResize(values, 0);
   return(!last_error|catch("SaveStatus(6)"));
}


/**
 * Liest den Status einer Sequenz aus der entsprechenden Datei ein und restauriert die internen Variablen.
 *
 * @return bool - ob der Status erfolgreich restauriert wurde
 */
bool RestoreStatus() {
   if (IsLastError()) return( false);
   if (!sequence.id)  return(_false(catch("RestoreStatus(1)  illegal value of sequence.id = "+ sequence.id, ERR_RUNTIME_ERROR)));

   // Pfade und Dateinamen bestimmen
   string fileName = MQL.GetStatusFileName();
   if (!MQL.IsFile(fileName)) {
      if (!ResolveStatusLocation()) return(false);
      fileName = MQL.GetStatusFileName();
   }

   // Datei einlesen
   string lines[];
   int size = FileReadLines(fileName, lines, true); if (size < 0) return(false);
   if (size == 0) {
      FileDelete(fileName);
      return(_false(catch("RestoreStatus(2)  status for sequence "+ ifString(IsTestSequence(), "T", "") + sequence.id +" not found", ERR_RUNTIME_ERROR)));
   }

   // notwendige Schl�ssel definieren
   string keys[] = { "Account", "Symbol", "Sequence.ID", "GridDirection", "GridSize", "LotSize", "rt.sequence.startEquity", "rt.sequence.maxProfit", "rt.sequence.maxDrawdown", "rt.sequence.starts", "rt.sequence.stops", "rt.grid.base" };
   /*                "Account"                 ,                        // Der Compiler kommt mit den Zeilennummern durcheinander, wenn der Initializer
                   //"Created"                 ,                        //  nicht in einer einzigen Zeile steht.
                     "Symbol"                  ,
                     "Sequence.ID"             ,
                   //"Sequence.Status.Location",                        // optional
                     "GridDirection"           ,
                     "GridSize"                ,
                     "LotSize"                 ,
                   //"StartLevel"              ,                        // optional
                   //"StartConditions"         ,                        // optional
                   //"StopConditions"          ,                        // optional
                     ---------------------------
                     "rt.sequence.startEquity" ,
                     "rt.sequence.maxProfit"   ,
                     "rt.sequence.maxDrawdown" ,
                     "rt.sequence.starts"      ,
                     "rt.sequence.stops"       ,
                   //"rt.sequence.missedLevels",                        // optional
                   //"rt.weekendStop"          ,                        // optional
                   //"rt.ignorePendingOrders"  ,                        // optional
                   //"rt.ignoreOpenPositions"  ,                        // optional
                   //"rt.ignoreClosedPositions",                        // optional
                     "rt.grid.base"            ,
   */


   // (3.1) Nicht-Runtime-Settings auslesen, validieren und �bernehmen
   string parts[], key, value, accountValue;
   int    accountLine;

   for (int i=0; i < size; i++) {
      if (StrStartsWith(StrTrim(lines[i]), "#"))          // Kommentare �berspringen
         continue;

      if (Explode(lines[i], "=", parts, 2) < 2)           return(_false(catch("RestoreStatus(3)  invalid status file \""+ fileName +"\" (line \""+ lines[i] +"\")", ERR_RUNTIME_ERROR)));
      key   = StrTrim(parts[0]);
      value = StrTrim(parts[1]);

      if (key == "Account") {
         accountValue = value;
         accountLine  = i;
         ArrayDropString(keys, key);                      // Abh�ngigkeit Account <=> Sequence.ID (siehe 3.2)
      }
      else if (key == "Symbol") {
         if (value != Symbol())                           return(_false(catch("RestoreStatus(4)  symbol mis-match \""+ value +"\"/\""+ Symbol() +"\" in status file \""+ fileName +"\" (line \""+ lines[i] +"\")", ERR_RUNTIME_ERROR)));
         ArrayDropString(keys, key);
      }
      else if (key == "Sequence.ID") {
         value = StrToUpper(value);
         if (StrLeft(value, 1) == "T") {
            sequence.isTest = true;
            value  = StrRight(value, -1);
         }
         if (value != StringConcatenate("", sequence.id)) return(_false(catch("RestoreStatus(5)  invalid status file \""+ fileName +"\" (line \""+ lines[i] +"\")", ERR_RUNTIME_ERROR)));
         Sequence.ID = ifString(IsTestSequence(), "T", "") + sequence.id;
         ArrayDropString(keys, key);
      }
      else if (key == "GridDirection") {
         if (value == "")                                 return(_false(catch("RestoreStatus(6)  invalid status file \""+ fileName +"\" (line \""+ lines[i] +"\")", ERR_RUNTIME_ERROR)));
         GridDirection = value;
         ArrayDropString(keys, key);
      }
      else if (key == "GridSize") {
         if (!StrIsDigit(value))                          return(_false(catch("RestoreStatus(7)  invalid status file \""+ fileName +"\" (line \""+ lines[i] +"\")", ERR_RUNTIME_ERROR)));
         GridSize = StrToInteger(value);
         ArrayDropString(keys, key);
      }
      else if (key == "LotSize") {
         if (!StrIsNumeric(value))                        return(_false(catch("RestoreStatus(8)  invalid status file \""+ fileName +"\" (line \""+ lines[i] +"\")", ERR_RUNTIME_ERROR)));
         LotSize = StrToDouble(value);
         ArrayDropString(keys, key);
      }
      else if (key == "StartLevel") {
         if (!StrIsDigit(value))                          return(_false(catch("RestoreStatus(9)  invalid status file \""+ fileName +"\" (line \""+ lines[i] +"\")", ERR_RUNTIME_ERROR)));
         StartLevel = StrToInteger(value);
         ArrayDropString(keys, key);
      }
      else if (key == "StartConditions") {
         StartConditions = value;
         ArrayDropString(keys, key);
      }
      else if (key == "StopConditions") {
         StopConditions = value;
         ArrayDropString(keys, key);
      }
   }

   // Abh�ngigkeiten validieren
   // Account: Eine Testsequenz kann in einem anderen Account visualisiert werden, solange die Zeitzonen beider Accounts �bereinstimmen.
   if (accountValue != ShortAccountCompany()+":"+GetAccountNumber()) {
      if (IsTesting() || !IsTestSequence() || !StrStartsWithI(accountValue, ShortAccountCompany() +":"))
         return(_false(catch("RestoreStatus(10)  account mis-match "+ DoubleQuoteStr(ShortAccountCompany() +":"+ GetAccountNumber()) +"/"+ DoubleQuoteStr(accountValue) +" in status file "+ DoubleQuoteStr(fileName) +" (line "+ DoubleQuoteStr(lines[accountLine]) +")", ERR_RUNTIME_ERROR)));
   }

   // Runtime-Settings auslesen, validieren und �bernehmen
   ArrayResize(sequence.start.event,  0);
   ArrayResize(sequence.start.time,   0);
   ArrayResize(sequence.start.price,  0);
   ArrayResize(sequence.start.profit, 0);
   ArrayResize(sequence.stop.event,   0);
   ArrayResize(sequence.stop.time,    0);
   ArrayResize(sequence.stop.price,   0);
   ArrayResize(sequence.stop.profit,  0);
   ArrayResize(sequence.missedLevels, 0);
   ArrayResize(ignorePendingOrders,   0);
   ArrayResize(ignoreOpenPositions,   0);
   ArrayResize(ignoreClosedPositions, 0);
   ArrayResize(grid.base.event,       0);
   ArrayResize(grid.base.time,        0);
   ArrayResize(grid.base.value,       0);
   lastEventId = 0;

   for (i=0; i < size; i++) {
      if (Explode(lines[i], "=", parts, 2) < 2)                            return(_false(catch("RestoreStatus(11)  invalid status file \""+ fileName +"\" (line \""+ lines[i] +"\")", ERR_RUNTIME_ERROR)));
      key   = StrTrim(parts[0]);
      value = StrTrim(parts[1]);

      if (StrStartsWith(key, "rt.")) {
         if (!RestoreStatus.Runtime(fileName, lines[i], key, value, keys)) return(false);
      }
   }
   if (ArraySize(keys) > 0)                                                return(_false(catch("RestoreStatus(12)  "+ ifString(ArraySize(keys)==1, "entry", "entries") +" \""+ JoinStrings(keys, "\", \"") +"\" missing in file \""+ fileName +"\"", ERR_RUNTIME_ERROR)));

   // Abh�ngigkeiten validieren
   if (ArraySize(sequence.start.event) != ArraySize(sequence.stop.event))  return(_false(catch("RestoreStatus(13)  sequence.starts("+ ArraySize(sequence.start.event) +") / sequence.stops("+ ArraySize(sequence.stop.event) +") mis-match in file \""+ fileName +"\"", ERR_RUNTIME_ERROR)));
   if (IntInArray(orders.ticket, 0))                                       return(_false(catch("RestoreStatus(14)  one or more order entries missing in file \""+ fileName +"\"", ERR_RUNTIME_ERROR)));

   ArrayResize(lines, 0);
   ArrayResize(keys,  0);
   ArrayResize(parts, 0);
   return(!last_error|catch("RestoreStatus(15)"));
}


/**
 * Restauriert eine oder mehrere Laufzeitvariablen.
 *
 * @param  string file   - Name der Statusdatei, aus der die Einstellung stammt (f�r evt. Fehlermeldung)
 * @param  string line   - Statuszeile der Einstellung                          (f�r evt. Fehlermeldung)
 * @param  string key    - Schl�ssel der Einstellung
 * @param  string value  - Wert der Einstellung
 * @param  string keys[] - Array f�r R�ckmeldung des restaurierten Schl�ssels
 *
 * @return bool - success status
 */
bool RestoreStatus.Runtime(string file, string line, string key, string value, string keys[]) {
   if (IsLastError()) return(false);
   /*
   double   rt.sequence.startEquity=7801.13
   double   rt.sequence.maxProfit=200.13
   double   rt.sequence.maxDrawdown=-127.80
   string   rt.sequence.starts=1|1328701713|1.32677|1000, 2|1329999999|1.33215|1200
   string   rt.sequence.stops=3|1328701999|1.32734|1200, 0|0|0|0
   string   rt.sequence.missedLevels=-6,-7,-8,-14
   int      rt.weekendStop=1
   string   rt.ignorePendingOrders=66064890,66064891,66064892
   string   rt.ignoreOpenPositions=66064890,66064891,66064892
   string   rt.ignoreClosedPositions=66064890,66064891,66064892
   string   rt.grid.base=4|1331710960|1.56743, 5|1331711010|1.56714
   string   rt.order.0=62544847,1,1.32067,4,1330932525,1.32067,1,100,1330936196,1.32067,0,101,1330938698,1.31897,1.31897,0,1,0,0,-17

            rt.order.{i}={ticket},{level},{gridBase},{pendingType},{pendingTime},{pendingPrice},{type},{openEvent},{openTime},{openPrice},{closeEvent},{closeTime},{closePrice},{stopLoss},{clientLimit},{closedBySL},{swap},{commission},{profit}
            -----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
            int      ticket       = values[ 0];
            int      level        = values[ 1];
            double   gridBase     = values[ 2];
            int      pendingType  = values[ 3];
            datetime pendingTime  = values[ 4];
            double   pendingPrice = values[ 5];
            int      type         = values[ 6];
            int      openEvent    = values[ 7];
            datetime openTime     = values[ 8];
            double   openPrice    = values[ 9];
            int      closeEvent   = values[10];
            datetime closeTime    = values[11];
            double   closePrice   = values[12];
            double   stopLoss     = values[13];
            bool     clientLimit  = values[14];
            bool     closedBySL   = values[15];
            double   swap         = values[16];
            double   commission   = values[17];
            double   profit       = values[18];
   */
   string values[], data[];


   if (key == "rt.sequence.startEquity") {
      if (!StrIsNumeric(value))                                               return(_false(catch("RestoreStatus.Runtime(1)  illegal sequence.startEquity \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      sequence.startEquity = StrToDouble(value);
      if (LT(sequence.startEquity, 0))                                        return(_false(catch("RestoreStatus.Runtime(2)  illegal sequence.startEquity "+ DoubleToStr(sequence.startEquity, 2) +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      ArrayDropString(keys, key);
   }
   else if (key == "rt.sequence.maxProfit") {
      if (!StrIsNumeric(value))                                               return(_false(catch("RestoreStatus.Runtime(3)  illegal sequence.maxProfit \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      sequence.maxProfit = StrToDouble(value); SS.MaxProfit();
      ArrayDropString(keys, key);
   }
   else if (key == "rt.sequence.maxDrawdown") {
      if (!StrIsNumeric(value))                                               return(_false(catch("RestoreStatus.Runtime(4)  illegal sequence.maxDrawdown \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      sequence.maxDrawdown = StrToDouble(value); SS.MaxDrawdown();
      ArrayDropString(keys, key);
   }
   else if (key == "rt.sequence.starts") {
      // rt.sequence.starts=1|1331710960|1.56743|1000, 2|1331711010|1.56714|1200
      int sizeOfValues = Explode(value, ",", values, NULL);
      for (int i=0; i < sizeOfValues; i++) {
         values[i] = StrTrim(values[i]);
         if (Explode(values[i], "|", data, NULL) != 4)                        return(_false(catch("RestoreStatus.Runtime(5)  illegal number of sequence.starts["+ i +"] details (\""+ values[i] +"\" = "+ ArraySize(data) +") in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

         value = StrTrim(data[0]);                 // sequence.start.event
         if (!StrIsDigit(value))                                              return(_false(catch("RestoreStatus.Runtime(6)  illegal sequence.start.event["+ i +"] \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         int startEvent = StrToInteger(value);
         if (startEvent == 0) {
            if (sizeOfValues==1 && values[i]=="0|0|0|0") {
               if (NE(sequence.startEquity, 0))                               return(_false(catch("RestoreStatus.Runtime(7)  sequence.startEquity/sequence.start["+ i +"] mis-match "+ NumberToStr(sequence.startEquity, ".2") +"/\""+ values[i] +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
               break;
            }
            return(_false(catch("RestoreStatus.Runtime(8)  illegal sequence.start.event["+ i +"] "+ startEvent +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         }
         if (EQ(sequence.startEquity, 0))                                     return(_false(catch("RestoreStatus.Runtime(9)  sequence.startEquity/sequence.start["+ i +"] mis-match "+ NumberToStr(sequence.startEquity, ".2") +"/\""+ values[i] +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

         value = StrTrim(data[1]);                 // sequence.start.time
         if (!StrIsDigit(value))                                              return(_false(catch("RestoreStatus.Runtime(10)  illegal sequence.start.time["+ i +"] \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         datetime startTime = StrToInteger(value);
         if (!startTime)                                                      return(_false(catch("RestoreStatus.Runtime(11)  illegal sequence.start.time["+ i +"] "+ startTime +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

         value = StrTrim(data[2]);                 // sequence.start.price
         if (!StrIsNumeric(value))                                            return(_false(catch("RestoreStatus.Runtime(12)  illegal sequence.start.price["+ i +"] \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         double startPrice = StrToDouble(value);
         if (LE(startPrice, 0))                                               return(_false(catch("RestoreStatus.Runtime(13)  illegal sequence.start.price["+ i +"] "+ NumberToStr(startPrice, PriceFormat) +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

         value = StrTrim(data[3]);                 // sequence.start.profit
         if (!StrIsNumeric(value))                                            return(_false(catch("RestoreStatus.Runtime(14)  illegal sequence.start.profit["+ i +"] \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         double startProfit = StrToDouble(value);

         ArrayPushInt   (sequence.start.event,  startEvent );
         ArrayPushInt   (sequence.start.time,   startTime  );
         ArrayPushDouble(sequence.start.price,  startPrice );
         ArrayPushDouble(sequence.start.profit, startProfit);
         lastEventId = Max(lastEventId, startEvent);
      }
      ArrayDropString(keys, key);
   }
   else if (key == "rt.sequence.stops") {
      // rt.sequence.stops=1|1331710960|1.56743|1200, 0|0|0|0
      sizeOfValues = Explode(value, ",", values, NULL);
      for (i=0; i < sizeOfValues; i++) {
         values[i] = StrTrim(values[i]);
         if (Explode(values[i], "|", data, NULL) != 4)                        return(_false(catch("RestoreStatus.Runtime(15)  illegal number of sequence.stops["+ i +"] details (\""+ values[i] +"\" = "+ ArraySize(data) +") in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

         value = StrTrim(data[0]);                 // sequence.stop.event
         if (!StrIsDigit(value))                                              return(_false(catch("RestoreStatus.Runtime(16)  illegal sequence.stop.event["+ i +"] \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         int stopEvent = StrToInteger(value);
         if (stopEvent == 0) {
            if (i < sizeOfValues-1)                                           return(_false(catch("RestoreStatus.Runtime(17)  illegal sequence.stop["+ i +"] \""+ values[i] +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
            if (values[i] != "0|0|0|0")                                       return(_false(catch("RestoreStatus.Runtime(18)  illegal sequence.stop["+ i +"] \""+ values[i] +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
            if (i==0 && ArraySize(sequence.start.event)==0)
               break;
         }

         value = StrTrim(data[1]);                 // sequence.stop.time
         if (!StrIsDigit(value))                                              return(_false(catch("RestoreStatus.Runtime(19)  illegal sequence.stop.time["+ i +"] \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         datetime stopTime = StrToInteger(value);
         if (!stopTime && stopEvent!=0)                                       return(_false(catch("RestoreStatus.Runtime(20)  illegal sequence.stop.time["+ i +"] "+ stopTime +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         if (i >= ArraySize(sequence.start.event))                            return(_false(catch("RestoreStatus.Runtime(21)  sequence.starts("+ ArraySize(sequence.start.event) +") / sequence.stops("+ sizeOfValues +") mis-match in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         if (stopTime!=0 && stopTime < sequence.start.time[i])                return(_false(catch("RestoreStatus.Runtime(22)  sequence.start.time["+ i +"]/sequence.stop.time["+ i +"] mis-match '"+ TimeToStr(sequence.start.time[i], TIME_FULL) +"'/'"+ TimeToStr(stopTime, TIME_FULL) +"' in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

         value = StrTrim(data[2]);                 // sequence.stop.price
         if (!StrIsNumeric(value))                                            return(_false(catch("RestoreStatus.Runtime(23)  illegal sequence.stop.price["+ i +"] \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         double stopPrice = StrToDouble(value);
         if (LT(stopPrice, 0))                                                return(_false(catch("RestoreStatus.Runtime(24)  illegal sequence.stop.price["+ i +"] "+ NumberToStr(stopPrice, PriceFormat) +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         if (EQ(stopPrice, 0) && stopEvent!=0)                                return(_false(catch("RestoreStatus.Runtime(25)  sequence.stop.time["+ i +"]/sequence.stop.price["+ i +"] mis-match '"+ TimeToStr(stopTime, TIME_FULL) +"'/"+ NumberToStr(stopPrice, PriceFormat) +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

         value = StrTrim(data[3]);                 // sequence.stop.profit
         if (!StrIsNumeric(value))                                            return(_false(catch("RestoreStatus.Runtime(26)  illegal sequence.stop.profit["+ i +"] \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         double stopProfit = StrToDouble(value);

         ArrayPushInt   (sequence.stop.event,  stopEvent );
         ArrayPushInt   (sequence.stop.time,   stopTime  );
         ArrayPushDouble(sequence.stop.price,  stopPrice );
         ArrayPushDouble(sequence.stop.profit, stopProfit);
         lastEventId = Max(lastEventId, stopEvent);
      }
      ArrayDropString(keys, key);
   }
   else if (key == "rt.sequence.missedLevels") {
      // rt.sequence.missedLevels=-6,-7,-8,-14
      if (StringLen(value) > 0) {
         sizeOfValues = Explode(value, ",", values, NULL);
         for (i=0; i < sizeOfValues; i++) {
            string sLevel = StrTrim(values[i]);
            if (!StrIsInteger(sLevel))                                        return(_false(catch("RestoreStatus.Runtime(27)  illegal missed grid level \""+ sLevel +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
            int level = StrToInteger(sLevel);
            if (!level)                                                       return(_false(catch("RestoreStatus.Runtime(28)  illegal missed grid level "+ level +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
            ArrayPushInt(sequence.missedLevels, level);
         }
      }
   }
   else if (key == "rt.weekendStop") {
      if (!StrIsDigit(value))                                                 return(_false(catch("RestoreStatus.Runtime(29)  illegal weekendStop \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      weekend.stop.active = (StrToInteger(value));
   }
   else if (key == "rt.ignorePendingOrders") {
      // rt.ignorePendingOrders=66064890,66064891,66064892
      if (StringLen(value) > 0) {
         sizeOfValues = Explode(value, ",", values, NULL);
         for (i=0; i < sizeOfValues; i++) {
            string sTicket = StrTrim(values[i]);
            if (!StrIsDigit(sTicket))                                         return(_false(catch("RestoreStatus.Runtime(30)  illegal ticket \""+ sTicket +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
            int ticket = StrToInteger(sTicket);
            if (!ticket)                                                      return(_false(catch("RestoreStatus.Runtime(31)  illegal ticket #"+ ticket +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
            ArrayPushInt(ignorePendingOrders, ticket);
         }
      }
   }
   else if (key == "rt.ignoreOpenPositions") {
      // rt.ignoreOpenPositions=66064890,66064891,66064892
      if (StringLen(value) > 0) {
         sizeOfValues = Explode(value, ",", values, NULL);
         for (i=0; i < sizeOfValues; i++) {
            sTicket = StrTrim(values[i]);
            if (!StrIsDigit(sTicket))                                         return(_false(catch("RestoreStatus.Runtime(32)  illegal ticket \""+ sTicket +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
            ticket = StrToInteger(sTicket);
            if (!ticket)                                                      return(_false(catch("RestoreStatus.Runtime(33)  illegal ticket #"+ ticket +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
            ArrayPushInt(ignoreOpenPositions, ticket);
         }
      }
   }
   else if (key == "rt.ignoreClosedPositions") {
      // rt.ignoreClosedPositions=66064890,66064891,66064892
      if (StringLen(value) > 0) {
         sizeOfValues = Explode(value, ",", values, NULL);
         for (i=0; i < sizeOfValues; i++) {
            sTicket = StrTrim(values[i]);
            if (!StrIsDigit(sTicket))                                         return(_false(catch("RestoreStatus.Runtime(34)  illegal ticket \""+ sTicket +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
            ticket = StrToInteger(sTicket);
            if (!ticket)                                                      return(_false(catch("RestoreStatus.Runtime(35)  illegal ticket #"+ ticket +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
            ArrayPushInt(ignoreClosedPositions, ticket);
         }
      }
   }
   else if (key == "rt.grid.base") {
      // rt.grid.base=1|1331710960|1.56743, 2|1331711010|1.56714
      sizeOfValues = Explode(value, ",", values, NULL);
      for (i=0; i < sizeOfValues; i++) {
         if (Explode(values[i], "|", data, NULL) != 3)                        return(_false(catch("RestoreStatus.Runtime(36)  illegal number of grid.base["+ i +"] details (\""+ values[i] +"\" = "+ ArraySize(data) +") in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

         value = StrTrim(data[0]);                 // GridBase-Event
         if (!StrIsDigit(value))                                              return(_false(catch("RestoreStatus.Runtime(37)  illegal grid.base.event["+ i +"] \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         int gridBaseEvent = StrToInteger(value);
         int starts = ArraySize(sequence.start.event);
         if (gridBaseEvent == 0) {
            if (sizeOfValues==1 && values[0]=="0|0|0") {
               if (starts > 0)                                                return(_false(catch("RestoreStatus.Runtime(38)  sequence.start/grid.base["+ i +"] mis-match '"+ TimeToStr(sequence.start.time[0], TIME_FULL) +"'/\""+ values[i] +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
               break;
            }                                                                 return(_false(catch("RestoreStatus.Runtime(39)  illegal grid.base.event["+ i +"] "+ gridBaseEvent +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         }
         else if (!starts)                                                    return(_false(catch("RestoreStatus.Runtime(40)  sequence.start/grid.base["+ i +"] mis-match "+ starts +"/\""+ values[i] +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

         value = StrTrim(data[1]);                 // GridBase-Zeitpunkt
         if (!StrIsDigit(value))                                              return(_false(catch("RestoreStatus.Runtime(41)  illegal grid.base.time["+ i +"] \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         datetime gridBaseTime = StrToInteger(value);
         if (!gridBaseTime)                                                   return(_false(catch("RestoreStatus.Runtime(42)  illegal grid.base.time["+ i +"] "+ gridBaseTime +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

         value = StrTrim(data[2]);                 // GridBase-Wert
         if (!StrIsNumeric(value))                                            return(_false(catch("RestoreStatus.Runtime(43)  illegal grid.base.value["+ i +"] \""+ value +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         double gridBaseValue = StrToDouble(value);
         if (LE(gridBaseValue, 0))                                            return(_false(catch("RestoreStatus.Runtime(44)  illegal grid.base.value["+ i +"] "+ NumberToStr(gridBaseValue, PriceFormat) +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

         ArrayPushInt   (grid.base.event, gridBaseEvent);
         ArrayPushInt   (grid.base.time,  gridBaseTime );
         ArrayPushDouble(grid.base.value, gridBaseValue);
         lastEventId = Max(lastEventId, gridBaseEvent);
      }
      ArrayDropString(keys, key);
   }
   else if (StrStartsWith(key, "rt.order.")) {
      // rt.order.{i}={ticket},{level},{gridBase},{pendingType},{pendingTime},{pendingPrice},{type},{openEvent},{openTime},{openPrice},{closeEvent},{closeTime},{closePrice},{stopLoss},{clientLimit},{closedBySL},{swap},{commission},{profit}
      // Orderindex
      string strIndex = StrRight(key, -9);
      if (!StrIsDigit(strIndex))                                              return(_false(catch("RestoreStatus.Runtime(45)  illegal order index \""+ key +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      i = StrToInteger(strIndex);
      if (ArraySize(orders.ticket) > i) /*&&*/ if (orders.ticket[i]!=0)       return(_false(catch("RestoreStatus.Runtime(46)  duplicate order index "+ key +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // Orderdaten
      if (Explode(value, ",", values, NULL) != 19)                            return(_false(catch("RestoreStatus.Runtime(47)  illegal number of order details ("+ ArraySize(values) +") in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // ticket
      sTicket = StrTrim(values[0]);
      if (!StrIsInteger(sTicket))                                             return(_false(catch("RestoreStatus.Runtime(48)  illegal ticket \""+ sTicket +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      ticket = StrToInteger(sTicket);
      if (ticket > 0) {
         if (IntInArray(orders.ticket, ticket))                               return(_false(catch("RestoreStatus.Runtime(49)  duplicate ticket #"+ ticket +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      }
      else if (ticket!=-1 && ticket!=-2)                                      return(_false(catch("RestoreStatus.Runtime(50)  illegal ticket #"+ ticket +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // level
      sLevel = StrTrim(values[1]);
      if (!StrIsInteger(sLevel))                                              return(_false(catch("RestoreStatus.Runtime(51)  illegal grid level \""+ sLevel +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      level = StrToInteger(sLevel);
      if (!level)                                                             return(_false(catch("RestoreStatus.Runtime(52)  illegal grid level "+ level +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // gridBase
      string sGridBase = StrTrim(values[2]);
      if (!StrIsNumeric(sGridBase))                                           return(_false(catch("RestoreStatus.Runtime(53)  illegal order gridbase \""+ sGridBase +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      double gridBase = StrToDouble(sGridBase);
      if (LE(gridBase, 0))                                                    return(_false(catch("RestoreStatus.Runtime(54)  illegal order gridbase "+ NumberToStr(gridBase, PriceFormat) +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // pendingType
      string sPendingType = StrTrim(values[3]);
      if (!StrIsInteger(sPendingType))                                        return(_false(catch("RestoreStatus.Runtime(55)  illegal pending order type \""+ sPendingType +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      int pendingType = StrToInteger(sPendingType);
      if (pendingType!=OP_UNDEFINED && !IsPendingTradeOperation(pendingType)) return(_false(catch("RestoreStatus.Runtime(56)  illegal pending order type \""+ sPendingType +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // pendingTime
      string sPendingTime = StrTrim(values[4]);
      if (!StrIsDigit(sPendingTime))                                          return(_false(catch("RestoreStatus.Runtime(57)  illegal pending order time \""+ sPendingTime +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      datetime pendingTime = StrToInteger(sPendingTime);
      if (pendingType==OP_UNDEFINED && pendingTime!=0)                        return(_false(catch("RestoreStatus.Runtime(58)  pending order type/time mis-match "+ OperationTypeToStr(pendingType) +"/'"+ TimeToStr(pendingTime, TIME_FULL) +"' in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      if (pendingType!=OP_UNDEFINED && !pendingTime)                          return(_false(catch("RestoreStatus.Runtime(59)  pending order type/time mis-match "+ OperationTypeToStr(pendingType) +"/"+ pendingTime +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // pendingPrice
      string sPendingPrice = StrTrim(values[5]);
      if (!StrIsNumeric(sPendingPrice))                                       return(_false(catch("RestoreStatus.Runtime(60)  illegal pending order price \""+ sPendingPrice +"\" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      double pendingPrice = StrToDouble(sPendingPrice);
      if (LT(pendingPrice, 0))                                                return(_false(catch("RestoreStatus.Runtime(61)  illegal pending order price "+ NumberToStr(pendingPrice, PriceFormat) +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      if (pendingType==OP_UNDEFINED && NE(pendingPrice, 0))                   return(_false(catch("RestoreStatus.Runtime(62)  pending order type/price mis-match "+ OperationTypeToStr(pendingType) +"/"+ NumberToStr(pendingPrice, PriceFormat) +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      if (pendingType!=OP_UNDEFINED) {
         if (EQ(pendingPrice, 0))                                             return(_false(catch("RestoreStatus.Runtime(63)  pending order type/price mis-match "+ OperationTypeToStr(pendingType) +"/"+ NumberToStr(pendingPrice, PriceFormat) +" in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         if (NE(pendingPrice, gridBase+level*GridSize*Pips, Digits))          return(_false(catch("RestoreStatus.Runtime(64)  gridbase/pending order price mis-match "+ NumberToStr(gridBase, PriceFormat) +"/"+ NumberToStr(pendingPrice, PriceFormat) +" (level "+ level +") in status file "+ DoubleQuoteStr(file) +" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      }

      // type
      string sType = StrTrim(values[6]);
      if (!StrIsInteger(sType))                                               return(_false(catch("RestoreStatus.Runtime(65)  illegal order type \""+ sType +"\" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      int type = StrToInteger(sType);
      if (type!=OP_UNDEFINED && !IsTradeOperation(type))                      return(_false(catch("RestoreStatus.Runtime(66)  illegal order type \""+ sType +"\" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      if (pendingType == OP_UNDEFINED) {
         if (type == OP_UNDEFINED)                                            return(_false(catch("RestoreStatus.Runtime(67)  pending order type/open order type mis-match "+ OperationTypeToStr(pendingType) +"/"+ OperationTypeToStr(type) +" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      }
      else if (type != OP_UNDEFINED) {
         if (IsLongTradeOperation(pendingType)!=IsLongTradeOperation(type))   return(_false(catch("RestoreStatus.Runtime(68)  pending order type/open order type mis-match "+ OperationTypeToStr(pendingType) +"/"+ OperationTypeToStr(type) +" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      }

      // openEvent
      string sOpenEvent = StrTrim(values[7]);
      if (!StrIsDigit(sOpenEvent))                                            return(_false(catch("RestoreStatus.Runtime(69)  illegal order open event \""+ sOpenEvent +"\" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      int openEvent = StrToInteger(sOpenEvent);
      if (type!=OP_UNDEFINED && !openEvent)                                   return(_false(catch("RestoreStatus.Runtime(70)  illegal order open event "+ openEvent +" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // openTime
      string sOpenTime = StrTrim(values[8]);
      if (!StrIsDigit(sOpenTime))                                             return(_false(catch("RestoreStatus.Runtime(71)  illegal order open time \""+ sOpenTime +"\" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      datetime openTime = StrToInteger(sOpenTime);
      if (type==OP_UNDEFINED && openTime!=0)                                  return(_false(catch("RestoreStatus.Runtime(72)  order type/time mis-match "+ OperationTypeToStr(type) +"/'"+ TimeToStr(openTime, TIME_FULL) +"' in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      if (type!=OP_UNDEFINED && !openTime)                                    return(_false(catch("RestoreStatus.Runtime(73)  order type/time mis-match "+ OperationTypeToStr(type) +"/"+ openTime +" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // openPrice
      string sOpenPrice = StrTrim(values[9]);
      if (!StrIsNumeric(sOpenPrice))                                          return(_false(catch("RestoreStatus.Runtime(74)  illegal order open price \""+ sOpenPrice +"\" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      double openPrice = StrToDouble(sOpenPrice);
      if (LT(openPrice, 0))                                                   return(_false(catch("RestoreStatus.Runtime(75)  illegal order open price "+ NumberToStr(openPrice, PriceFormat) +" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      if (type==OP_UNDEFINED && NE(openPrice, 0))                             return(_false(catch("RestoreStatus.Runtime(76)  order type/price mis-match "+ OperationTypeToStr(type) +"/"+ NumberToStr(openPrice, PriceFormat) +" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      if (type!=OP_UNDEFINED && EQ(openPrice, 0))                             return(_false(catch("RestoreStatus.Runtime(77)  order type/price mis-match "+ OperationTypeToStr(type) +"/"+ NumberToStr(openPrice, PriceFormat) +" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // closeEvent
      string sCloseEvent = StrTrim(values[10]);
      if (!StrIsDigit(sCloseEvent))                                           return(_false(catch("RestoreStatus.Runtime(78)  illegal order close event \""+ sCloseEvent +"\" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      int closeEvent = StrToInteger(sCloseEvent);

      // closeTime
      string sCloseTime = StrTrim(values[11]);
      if (!StrIsDigit(sCloseTime))                                            return(_false(catch("RestoreStatus.Runtime(79)  illegal order close time \""+ sCloseTime +"\" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      datetime closeTime = StrToInteger(sCloseTime);
      if (closeTime != 0) {
         if (closeTime < pendingTime)                                         return(_false(catch("RestoreStatus.Runtime(80)  pending order time/delete time mis-match '"+ TimeToStr(pendingTime, TIME_FULL) +"'/'"+ TimeToStr(closeTime, TIME_FULL) +"' in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
         if (closeTime < openTime)                                            return(_false(catch("RestoreStatus.Runtime(81)  order open/close time mis-match '"+ TimeToStr(openTime, TIME_FULL) +"'/'"+ TimeToStr(closeTime, TIME_FULL) +"' in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      }
      if (closeTime!=0 && !closeEvent)                                        return(_false(catch("RestoreStatus.Runtime(82)  illegal order close event "+ closeEvent +" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // closePrice
      string sClosePrice = StrTrim(values[12]);
      if (!StrIsNumeric(sClosePrice))                                         return(_false(catch("RestoreStatus.Runtime(83)  illegal order close price \""+ sClosePrice +"\" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      double closePrice = StrToDouble(sClosePrice);
      if (LT(closePrice, 0))                                                  return(_false(catch("RestoreStatus.Runtime(84)  illegal order close price "+ NumberToStr(closePrice, PriceFormat) +" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // stopLoss
      string sStopLoss = StrTrim(values[13]);
      if (!StrIsNumeric(sStopLoss))                                           return(_false(catch("RestoreStatus.Runtime(85)  illegal order stoploss \""+ sStopLoss +"\" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      double stopLoss = StrToDouble(sStopLoss);
      if (LE(stopLoss, 0))                                                    return(_false(catch("RestoreStatus.Runtime(86)  illegal order stoploss "+ NumberToStr(stopLoss, PriceFormat) +" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      if (NE(stopLoss, gridBase+(level-Sign(level))*GridSize*Pips, Digits))   return(_false(catch("RestoreStatus.Runtime(87)  gridbase/stoploss mis-match "+ NumberToStr(gridBase, PriceFormat) +"/"+ NumberToStr(stopLoss, PriceFormat) +" (level "+ level +") in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // clientLimit
      string sClientLimit = StrTrim(values[14]);
      if (!StrIsDigit(sClientLimit))                                          return(_false(catch("RestoreStatus.Runtime(88)  illegal clientLimit value \""+ sClientLimit +"\" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      bool clientLimit = _bool(StrToInteger(sClientLimit));

      // closedBySL
      string sClosedBySL = StrTrim(values[15]);
      if (!StrIsDigit(sClosedBySL))                                           return(_false(catch("RestoreStatus.Runtime(89)  illegal closedBySL value \""+ sClosedBySL +"\" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      bool closedBySL = _bool(StrToInteger(sClosedBySL));

      // swap
      string sSwap = StrTrim(values[16]);
      if (!StrIsNumeric(sSwap))                                               return(_false(catch("RestoreStatus.Runtime(90)  illegal order swap \""+ sSwap +"\" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      double swap = StrToDouble(sSwap);
      if (type==OP_UNDEFINED && NE(swap, 0))                                  return(_false(catch("RestoreStatus.Runtime(91)  pending order/swap mis-match "+ OperationTypeToStr(pendingType) +"/"+ DoubleToStr(swap, 2) +" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // commission
      string sCommission = StrTrim(values[17]);
      if (!StrIsNumeric(sCommission))                                         return(_false(catch("RestoreStatus.Runtime(92)  illegal order commission \""+ sCommission +"\" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      double commission = StrToDouble(sCommission);
      if (type==OP_UNDEFINED && NE(commission, 0))                            return(_false(catch("RestoreStatus.Runtime(93)  pending order/commission mis-match "+ OperationTypeToStr(pendingType) +"/"+ DoubleToStr(commission, 2) +" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));

      // profit
      string sProfit = StrTrim(values[18]);
      if (!StrIsNumeric(sProfit))                                             return(_false(catch("RestoreStatus.Runtime(94)  illegal order profit \""+ sProfit +"\" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));
      double profit = StrToDouble(sProfit);
      if (type==OP_UNDEFINED && NE(profit, 0))                                return(_false(catch("RestoreStatus.Runtime(95)  pending order/profit mis-match "+ OperationTypeToStr(pendingType) +"/"+ DoubleToStr(profit, 2) +" in status file \""+ file +"\" (line \""+ line +"\")", ERR_RUNTIME_ERROR)));


      // Daten speichern
      Grid.SetData(i, ticket, level, gridBase, pendingType, pendingTime, pendingPrice, type, openEvent, openTime, openPrice, closeEvent, closeTime, closePrice, stopLoss, clientLimit, closedBySL, swap, commission, profit);
      lastEventId = Max(lastEventId, Max(openEvent, closeEvent));
      // rt.order.{i}={ticket},{level},{gridBase},{pendingType},{pendingTime},{pendingPrice},{type},{openEvent},{openTime},{openPrice},{closeEvent},{closeTime},{closePrice},{stopLoss},{clientLimit},{closedBySL},{swap},{commission},{profit}
   }

   ArrayResize(values, 0);
   ArrayResize(data,   0);
   return(!last_error|catch("RestoreStatus.Runtime(96)"));
}


/**
 * Gleicht den in der Instanz gespeicherten Laufzeitstatus mit den Online-Daten der laufenden Sequenz ab.
 * Aufruf nur direkt nach ValidateConfig()
 *
 * @return bool - Erfolgsstatus
 */
bool SynchronizeStatus() {
   if (IsLastError()) return(false);

   bool permanentStatusChange, permanentTicketChange, pendingOrder, openPosition;

   int orphanedPendingOrders  []; ArrayResize(orphanedPendingOrders,   0);
   int orphanedOpenPositions  []; ArrayResize(orphanedOpenPositions,   0);
   int orphanedClosedPositions[]; ArrayResize(orphanedClosedPositions, 0);

   int closed[][2], close[2], sizeOfTickets=ArraySize(orders.ticket); ArrayResize(closed, 0);


   // (1.1) alle offenen Tickets in Datenarrays synchronisieren, gestrichene PendingOrders l�schen
   for (int i=0; i < sizeOfTickets; i++) {
      if (orders.ticket[i] < 0)                                            // client-seitige PendingOrders �berspringen
         continue;

      if (!IsTestSequence() || !IsTesting()) {                             // keine Synchronization f�r abgeschlossene Tests
         if (orders.closeTime[i] == 0) {
            if (!IsTicket(orders.ticket[i])) {                             // bei fehlender History zur Erweiterung auffordern
               PlaySoundEx("Windows Notify.wav");
               int button = MessageBoxEx(__NAME() +" - SynchronizeStatus()", "Ticket #"+ orders.ticket[i] +" not found.\nPlease expand the available trade history.", MB_ICONERROR|MB_RETRYCANCEL);
               if (button != IDRETRY)
                  return(!SetLastError(ERR_CANCELLED_BY_USER));
               return(SynchronizeStatus());
            }
            if (!SelectTicket(orders.ticket[i], "SynchronizeStatus(1)  cannot synchronize "+ OperationTypeDescription(ifInt(orders.type[i]==OP_UNDEFINED, orders.pendingType[i], orders.type[i])) +" order (#"+ orders.ticket[i] +" not found)"))
               return(false);
            if (!Sync.UpdateOrder(i, permanentTicketChange))
               return(false);
            permanentStatusChange = permanentStatusChange || permanentTicketChange;
         }
      }

      if (orders.closeTime[i] != 0) {
         if (orders.type[i] == OP_UNDEFINED) {
            if (!Grid.DropData(i))                                         // geschlossene PendingOrders l�schen
               return(false);
            sizeOfTickets--; i--;
            permanentStatusChange = true;
         }
         else if (!orders.closedBySL[i]) /*&&*/ if (!orders.closeEvent[i]) {
            close[0] = orders.closeTime[i];                                // bei StopSequence() geschlossene Position: Ticket zur sp�teren Vergabe der Event-ID zwichenspeichern
            close[1] = orders.ticket   [i];
            ArrayPushInts(closed, close);
         }
      }
   }

   // (1.2) Event-IDs geschlossener Positionen setzen (erst nach evt. ausgestoppten Positionen)
   int sizeOfClosed = ArrayRange(closed, 0);
   if (sizeOfClosed > 0) {
      ArraySort(closed);
      for (i=0; i < sizeOfClosed; i++) {
         int n = SearchIntArray(orders.ticket, closed[i][1]);
         if (n == -1)
            return(_false(catch("SynchronizeStatus(2)  closed ticket #"+ closed[i][1] +" not found in grid arrays", ERR_RUNTIME_ERROR)));
         orders.closeEvent[n] = CreateEventId();
      }
      ArrayResize(closed, 0);
      ArrayResize(close,  0);
   }

   // (1.3) alle erreichbaren Tickets der Sequenz auf lokale Referenz �berpr�fen (au�er f�r abgeschlossene Tests)
   if (!IsTestSequence() || IsTesting()) {
      for (i=OrdersTotal()-1; i >= 0; i--) {                               // offene Tickets
         if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))                  // FALSE: w�hrend des Auslesens wurde in einem anderen Thread eine offene Order entfernt
            continue;
         if (IsMyOrder(sequence.id)) /*&&*/ if (!IntInArray(orders.ticket, OrderTicket())) {
            pendingOrder = IsPendingTradeOperation(OrderType());           // kann PendingOrder oder offene Position sein
            openPosition = !pendingOrder;
            if (pendingOrder) /*&&*/ if (!IntInArray(ignorePendingOrders, OrderTicket())) ArrayPushInt(orphanedPendingOrders, OrderTicket());
            if (openPosition) /*&&*/ if (!IntInArray(ignoreOpenPositions, OrderTicket())) ArrayPushInt(orphanedOpenPositions, OrderTicket());
         }
      }

      for (i=OrdersHistoryTotal()-1; i >= 0; i--) {                        // geschlossene Tickets
         if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))                 // FALSE: w�hrend des Auslesens wurde der Anzeigezeitraum der History verk�rzt
            continue;
         if (IsPendingTradeOperation(OrderType()))                         // gestrichene PendingOrders ignorieren
            continue;
         if (IsMyOrder(sequence.id)) /*&&*/ if (!IntInArray(orders.ticket, OrderTicket())) {
            if (!IntInArray(ignoreClosedPositions, OrderTicket()))         // kann nur geschlossene Position sein
               ArrayPushInt(orphanedClosedPositions, OrderTicket());
         }
      }
   }

   // (1.4) Vorgehensweise f�r verwaiste Tickets erfragen
   int size = ArraySize(orphanedPendingOrders);                            // TODO: Ignorieren nicht m�glich; wenn die Tickets �bernommen werden sollen,
   if (size > 0) {                                                         //       m�ssen sie richtig einsortiert werden.
      return(_false(catch("SynchronizeStatus(3)  unknown pending orders found: #"+ JoinInts(orphanedPendingOrders, ", #"), ERR_RUNTIME_ERROR)));
      //ArraySort(orphanedPendingOrders);
      //PlaySoundEx("Windows Notify.wav");
      //int button = MessageBoxEx(__NAME() +" - SynchronizeStatus()", ifString(IsDemoFix(), "", "- Real Account -\n\n") +"Orphaned pending order"+ ifString(size==1, "", "s") +" found: #"+ JoinInts(orphanedPendingOrders, ", #") +"\nDo you want to ignore "+ ifString(size==1, "it", "them") +"?", MB_ICONWARNING|MB_OKCANCEL);
      //if (button != IDOK) {
      //   SetLastError(ERR_CANCELLED_BY_USER);
      //   return(_false(catch("SynchronizeStatus(4)")));
      //}
      ArrayResize(orphanedPendingOrders, 0);
   }
   size = ArraySize(orphanedOpenPositions);                                // TODO: Ignorieren nicht m�glich; wenn die Tickets �bernommen werden sollen,
   if (size > 0) {                                                         //       m�ssen sie richtig einsortiert werden.
      return(_false(catch("SynchronizeStatus(5)  unknown open positions found: #"+ JoinInts(orphanedOpenPositions, ", #"), ERR_RUNTIME_ERROR)));
      //ArraySort(orphanedOpenPositions);
      //PlaySoundEx("Windows Notify.wav");
      //button = MessageBoxEx(__NAME() +" - SynchronizeStatus()", ifString(IsDemoFix(), "", "- Real Account -\n\n") +"Orphaned open position"+ ifString(size==1, "", "s") +" found: #"+ JoinInts(orphanedOpenPositions, ", #") +"\nDo you want to ignore "+ ifString(size==1, "it", "them") +"?", MB_ICONWARNING|MB_OKCANCEL);
      //if (button != IDOK) {
      //   SetLastError(ERR_CANCELLED_BY_USER);
      //   return(_false(catch("SynchronizeStatus(6)")));
      //}
      ArrayResize(orphanedOpenPositions, 0);
   }
   size = ArraySize(orphanedClosedPositions);
   if (size > 0) {
      ArraySort(orphanedClosedPositions);
      PlaySoundEx("Windows Notify.wav");
      button = MessageBoxEx(__NAME() +" - SynchronizeStatus()", ifString(IsDemoFix(), "", "- Real Account -\n\n") +"Orphaned closed position"+ ifString(size==1, "", "s") +" found: #"+ JoinInts(orphanedClosedPositions, ", #") +"\nDo you want to ignore "+ ifString(size==1, "it", "them") +"?", MB_ICONWARNING|MB_OKCANCEL);
      if (button != IDOK) {
         SetLastError(ERR_CANCELLED_BY_USER);
         return(_false(catch("SynchronizeStatus(7)")));
      }
      MergeIntArrays(ignoreClosedPositions, orphanedClosedPositions, ignoreClosedPositions);
      ArraySort(ignoreClosedPositions);
      permanentStatusChange = true;
      ArrayResize(orphanedClosedPositions, 0);
   }

   if (ArraySize(sequence.start.event) > 0) /*&&*/ if (ArraySize(grid.base.event)==0)
      return(_false(catch("SynchronizeStatus(8)  illegal number of grid.base events = "+ 0, ERR_RUNTIME_ERROR)));


   // (2) Status und Variablen synchronisieren
   /*int   */ lastEventId         = 0;
   /*int   */ sequence.status     = STATUS_WAITING;
   /*int   */ sequence.level      = 0;
   /*int   */ sequence.maxLevel   = 0;
   /*int   */ sequence.stops      = 0;
   /*double*/ sequence.stopsPL    = 0;
   /*double*/ sequence.closedPL   = 0;
   /*double*/ sequence.floatingPL = 0;
   /*double*/ sequence.totalPL    = 0;

   datetime   stopTime;
   double     stopPrice;

   // (2.1)
   if (!Sync.ProcessEvents(stopTime, stopPrice))
      return(false);

   // (2.2) Wurde die Sequenz au�erhalb gestoppt, EV_SEQUENCE_STOP erzeugen
   if (sequence.status == STATUS_STOPPING) {
      i = ArraySize(sequence.stop.event) - 1;
      if (sequence.stop.time[i] != 0)
         return(_false(catch("SynchronizeStatus(9)  unexpected sequence.stop.time = "+ IntsToStr(sequence.stop.time, NULL), ERR_RUNTIME_ERROR)));

      sequence.stop.event [i] = CreateEventId();
      sequence.stop.time  [i] = stopTime;
      sequence.stop.price [i] = NormalizeDouble(stopPrice, Digits);
      sequence.stop.profit[i] = sequence.totalPL;

      if (!StopSequence.LimitStopPrice())                                  // StopPrice begrenzen (darf nicht schon den n�chsten Level triggern)
         return(false);

      sequence.status       = STATUS_STOPPED;
      permanentStatusChange = true;
   }


   // (3) Daten f�r Wochenend-Pause aktualisieren
   if (weekend.stop.active) /*&&*/ if (sequence.status!=STATUS_STOPPED)
      return(_false(catch("SynchronizeStatus(10)  weekend.stop.active="+ weekend.stop.active +" / sequence.status="+ StatusToStr(sequence.status)+ " mis-match", ERR_RUNTIME_ERROR)));

   if (sequence.status == STATUS_PROGRESSING) UpdateWeekendStop();
   else if (sequence.status == STATUS_STOPPED) {
      if (weekend.stop.active)                UpdateWeekendResumeTime();
   }


   // (4) permanente Status�nderungen speichern
   if (permanentStatusChange)
      if (!SaveStatus())
         return(false);


   // (5) Anzeigen aktualisieren, ShowStatus() folgt nach Funktionsende
   SS.All();
   RedrawStartStop();
   RedrawOrders();

   return(!last_error|catch("SynchronizeStatus(11)"));
}


/**
 * Aktualisiert die Daten des lokal als offen markierten Tickets mit dem Online-Status. Wird nur in SynchronizeStatus() verwendet.
 *
 * @param  int   i                 - Ticketindex
 * @param  bool &lpPermanentChange - Zeiger auf Variable, die anzeigt, ob dauerhafte Ticket�nderungen vorliegen
 *
 * @return bool - Erfolgsstatus
 */
bool Sync.UpdateOrder(int i, bool &lpPermanentChange) {
   lpPermanentChange = lpPermanentChange!=0;

   if (i < 0 || i > ArraySize(orders.ticket)-1) return(_false(catch("Sync.UpdateOrder(1)  illegal parameter i = "+ i, ERR_INVALID_PARAMETER)));
   if (orders.closeTime[i] != 0)                return(_false(catch("Sync.UpdateOrder(2)  cannot update ticket #"+ orders.ticket[i] +" (marked as closed in grid arrays)", ERR_RUNTIME_ERROR)));

   // das Ticket ist selektiert
   bool   wasPending = orders.type[i] == OP_UNDEFINED;               // vormals PendingOrder
   bool   wasOpen    = !wasPending;                                  // vormals offene Position
   bool   isPending  = IsPendingTradeOperation(OrderType());         // jetzt PendingOrder
   bool   isClosed   = OrderCloseTime() != 0;                        // jetzt geschlossen oder gestrichen
   bool   isOpen     = !isPending && !isClosed;                      // jetzt offene Position
   double lastSwap   = orders.swap[i];


   // (1) Ticketdaten aktualisieren
   //orders.ticket       [i]                                         // unver�ndert
   //orders.level        [i]                                         // unver�ndert
   //orders.gridBase     [i]                                         // unver�ndert

   if (isPending) {
    //orders.pendingType [i]                                         // unver�ndert
    //orders.pendingTime [i]                                         // unver�ndert
      orders.pendingPrice[i] = OrderOpenPrice();
   }
   else if (wasPending) {
      orders.type        [i] = OrderType();
      orders.openEvent   [i] = CreateEventId();
      orders.openTime    [i] = OrderOpenTime();
      orders.openPrice   [i] = OrderOpenPrice();
   }

   if (EQ(OrderStopLoss(), 0)) {
      if (!orders.clientsideLimit[i]) {
         orders.stopLoss       [i] = NormalizeDouble(grid.base + (orders.level[i]-Sign(orders.level[i]))*GridSize*Pips, Digits);
         orders.clientsideLimit[i] = true;
         lpPermanentChange         = true;
      }
   }
   else {
      orders.stopLoss[i] = OrderStopLoss();
      if (orders.clientsideLimit[i]) {
         orders.clientsideLimit[i] = false;
         lpPermanentChange         = true;
      }
   }

   if (isClosed) {
      orders.closeTime   [i] = OrderCloseTime();
      orders.closePrice  [i] = OrderClosePrice();
      orders.closedBySL  [i] = IsOrderClosedBySL();
      if (orders.closedBySL[i])
         orders.closeEvent[i] = CreateEventId();                     // Event-IDs f�r ausgestoppte Positionen werden sofort, f�r geschlossene Positionen erst sp�ter vergeben.
   }

   if (!isPending) {
      orders.swap        [i] = OrderSwap();
      orders.commission  [i] = OrderCommission(); sequence.commission = OrderCommission(); SS.LotSize();
      orders.profit      [i] = OrderProfit();
   }

   // (2) lpPermanentChange aktualisieren
   if      (wasPending) lpPermanentChange = lpPermanentChange || isOpen || isClosed;
   else if (  isClosed) lpPermanentChange = true;
   else                 lpPermanentChange = lpPermanentChange || NE(lastSwap, OrderSwap());

   return(!last_error|catch("Sync.UpdateOrder(3)"));
}


/**
 * F�gt den Breakeven-relevanten Events ein weiteres hinzu.
 *
 * @param  double   events[] - Event-Array
 * @param  int      id       - Event-ID
 * @param  datetime time     - Zeitpunkt des Events
 * @param  int      type     - Event-Typ
 * @param  double   gridBase - Gridbasis des Events
 * @param  int      index    - Index des origin�ren Datensatzes innerhalb des entsprechenden Arrays
 */
void Sync.PushEvent(double &events[][], int id, datetime time, int type, double gridBase, int index) {
   if (type==EV_SEQUENCE_STOP) /*&&*/ if (!time)
      return;                                                        // nicht initialisierte Sequenz-Stops ignorieren (ggf. immer der letzte Stop)

   int size = ArrayRange(events, 0);
   ArrayResize(events, size+1);

   events[size][0] = id;
   events[size][1] = time;
   events[size][2] = type;
   events[size][3] = gridBase;
   events[size][4] = index;
}


/**
 *
 * @param  datetime &sequenceStopTime  - Variable, die die Sequenz-StopTime aufnimmt (falls die Stopdaten fehlen)
 * @param  double   &sequenceStopPrice - Variable, die den Sequenz-StopPrice aufnimmt (falls die Stopdaten fehlen)
 *
 * @return bool - Erfolgsstatus
 */
bool Sync.ProcessEvents(datetime &sequenceStopTime, double &sequenceStopPrice) {
   int    sizeOfTickets = ArraySize(orders.ticket);
   int    openLevels[]; ArrayResize(openLevels, 0);
   double events[][5];  ArrayResize(events,     0);
   bool   pendingOrder, openPosition, closedPosition, closedBySL;


   // (1) Breakeven-relevante Events zusammenstellen
   // (1.1) Sequenzstarts und -stops
   int sizeOfStarts = ArraySize(sequence.start.event);
   for (int i=0; i < sizeOfStarts; i++) {
    //Sync.PushEvent(events, id, time, type, gridBase, index);
      Sync.PushEvent(events, sequence.start.event[i], sequence.start.time[i], EV_SEQUENCE_START, NULL, i);
      Sync.PushEvent(events, sequence.stop.event [i], sequence.stop.time [i], EV_SEQUENCE_STOP,  NULL, i);
   }

   // (1.2) GridBase-�nderungen
   int sizeOfGridBase = ArraySize(grid.base.event);
   for (i=0; i < sizeOfGridBase; i++) {
      Sync.PushEvent(events, grid.base.event[i], grid.base.time[i], EV_GRIDBASE_CHANGE, grid.base.value[i], i);
   }

   // (1.3) Tickets
   for (i=0; i < sizeOfTickets; i++) {
      pendingOrder   = orders.type[i]  == OP_UNDEFINED;
      openPosition   = !pendingOrder   && orders.closeTime[i]==0;
      closedPosition = !pendingOrder   && !openPosition;
      closedBySL     =  closedPosition && orders.closedBySL[i];

      // nach offenen Levels darf keine geschlossene Position folgen
      if (closedPosition && !closedBySL)
         if (ArraySize(openLevels) > 0)                  return(_false(catch("Sync.ProcessEvents(1)  illegal sequence status, both open (#?) and closed (#"+ orders.ticket[i] +") positions found", ERR_RUNTIME_ERROR)));

      if (!pendingOrder) {
         Sync.PushEvent(events, orders.openEvent[i], orders.openTime[i], EV_POSITION_OPEN, NULL, i);

         if (openPosition) {
            if (IntInArray(openLevels, orders.level[i])) return(_false(catch("Sync.ProcessEvents(2)  duplicate order level "+ orders.level[i] +" of open position #"+ orders.ticket[i], ERR_RUNTIME_ERROR)));
            ArrayPushInt(openLevels, orders.level[i]);
            sequence.floatingPL = NormalizeDouble(sequence.floatingPL + orders.swap[i] + orders.commission[i] + orders.profit[i], 2);
         }
         else if (closedBySL) {
            Sync.PushEvent(events, orders.closeEvent[i], orders.closeTime[i], EV_POSITION_STOPOUT, NULL, i);
         }
         else /*(closed)*/ {
            Sync.PushEvent(events, orders.closeEvent[i], orders.closeTime[i], EV_POSITION_CLOSE, NULL, i);
         }
      }
      if (IsLastError()) return(false);
   }
   if (ArraySize(openLevels) != 0) {
      int min = openLevels[ArrayMinimum(openLevels)];
      int max = openLevels[ArrayMaximum(openLevels)];
      int maxLevel = Max(Abs(min), Abs(max));
      if (ArraySize(openLevels) != maxLevel) return(_false(catch("Sync.ProcessEvents(3)  illegal sequence status, missing one or more open positions", ERR_RUNTIME_ERROR)));
      ArrayResize(openLevels, 0);
   }


   // (2) Laufzeitvariablen restaurieren
   int      id, lastId, nextId, minute, lastMinute, type, lastType, nextType, index, nextIndex, iPositionMax, ticket, lastTicket, nextTicket, closedPositions, reopenedPositions;
   datetime time, lastTime, nextTime;
   double   gridBase;
   int      orderEvents[] = {EV_POSITION_OPEN, EV_POSITION_STOPOUT, EV_POSITION_CLOSE};
   int      sizeOfEvents = ArrayRange(events, 0);

   // (2.1) Events sortieren
   if (sizeOfEvents > 0) {
      ArraySort(events);
      int firstType = MathRound(events[0][2]);
      if (firstType != EV_SEQUENCE_START) return(_false(catch("Sync.ProcessEvents(4)  illegal first status event "+ StatusEventToStr(firstType) +" (id="+ Round(events[0][0]) +"   time='"+ TimeToStr(events[0][1], TIME_FULL) +"')", ERR_RUNTIME_ERROR)));
   }

   for (i=0; i < sizeOfEvents; i++) {
      id       = events[i][0];
      time     = events[i][1];
      type     = events[i][2];
      gridBase = events[i][3];
      index    = events[i][4];

      ticket     = 0; if (IntInArray(orderEvents, type)) { ticket = orders.ticket[index]; iPositionMax = Max(iPositionMax, index); }
      nextTicket = 0;
      if (i < sizeOfEvents-1) { nextId = events[i+1][0]; nextTime = events[i+1][1]; nextType = events[i+1][2]; nextIndex = events[i+1][4]; if (IntInArray(orderEvents, nextType)) nextTicket = orders.ticket[nextIndex]; }
      else                    { nextId = 0;              nextTime = 0;              nextType = 0;                                                                                               nextTicket = 0;                        }

      // (2.2) Events auswerten
      // -- EV_SEQUENCE_START --------------
      if (type == EV_SEQUENCE_START) {
         if (i && sequence.status!=STATUS_STARTING && sequence.status!=STATUS_STOPPED)   return(_false(catch("Sync.ProcessEvents(5)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         if (sequence.status==STATUS_STARTING && reopenedPositions!=Abs(sequence.level)) return(_false(catch("Sync.ProcessEvents(6)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") and before "+ StatusEventToStr(nextType) +" ("+ nextId +", "+ ifString(nextTicket, "#"+ nextTicket +", ", "") +"time="+ nextTime +", "+ TimeToStr(nextTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         reopenedPositions = 0;
         sequence.status   = STATUS_PROGRESSING;
         sequence.start.event[index] = id;
      }
      // -- EV_GRIDBASE_CHANGE -------------
      else if (type == EV_GRIDBASE_CHANGE) {
         if (sequence.status!=STATUS_PROGRESSING && sequence.status!=STATUS_STOPPED)     return(_false(catch("Sync.ProcessEvents(7)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         grid.base = gridBase;
         if (sequence.status == STATUS_PROGRESSING) {
            if (sequence.level != 0)                                                     return(_false(catch("Sync.ProcessEvents(8)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         }
         else { // STATUS_STOPPED
            reopenedPositions = 0;
            sequence.status   = STATUS_STARTING;
         }
         grid.base.event[index] = id;
      }
      // -- EV_POSITION_OPEN ---------------
      else if (type == EV_POSITION_OPEN) {
         if (sequence.status!=STATUS_STARTING && sequence.status!=STATUS_PROGRESSING)    return(_false(catch("Sync.ProcessEvents(9)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         if (sequence.status == STATUS_PROGRESSING) {                                    // nicht bei PositionReopen
            sequence.level   += Sign(orders.level[index]);
            sequence.maxLevel = ifInt(sequence.direction==D_LONG, Max(sequence.level, sequence.maxLevel), Min(sequence.level, sequence.maxLevel));
         }
         else {
            reopenedPositions++;
         }
         orders.openEvent[index] = id;
      }
      // -- EV_POSITION_STOPOUT ------------
      else if (type == EV_POSITION_STOPOUT) {
         if (sequence.status != STATUS_PROGRESSING)                                      return(_false(catch("Sync.ProcessEvents(10)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         sequence.level  -= Sign(orders.level[index]);
         sequence.stops++;
         sequence.stopsPL = NormalizeDouble(sequence.stopsPL + orders.swap[index] + orders.commission[index] + orders.profit[index], 2);
         orders.closeEvent[index] = id;
      }
      // -- EV_POSITION_CLOSE --------------
      else if (type == EV_POSITION_CLOSE) {
         if (sequence.status!=STATUS_PROGRESSING && sequence.status!=STATUS_STOPPING)    return(_false(catch("Sync.ProcessEvents(11)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         sequence.closedPL = NormalizeDouble(sequence.closedPL + orders.swap[index] + orders.commission[index] + orders.profit[index], 2);
         if (sequence.status == STATUS_PROGRESSING)
            closedPositions = 0;
         closedPositions++;
         sequence.status = STATUS_STOPPING;
         orders.closeEvent[index] = id;
      }
      // -- EV_SEQUENCE_STOP ---------------
      else if (type == EV_SEQUENCE_STOP) {
         if (sequence.status!=STATUS_PROGRESSING && sequence.status!=STATUS_STOPPING)    return(_false(catch("Sync.ProcessEvents(12)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         if (closedPositions != Abs(sequence.level))                                     return(_false(catch("Sync.ProcessEvents(13)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") and before "+ StatusEventToStr(nextType) +" ("+ nextId +", "+ ifString(nextTicket, "#"+ nextTicket +", ", "") +"time="+ nextTime +", "+ TimeToStr(nextTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         closedPositions = 0;
         sequence.status = STATUS_STOPPED;
         sequence.stop.event[index] = id;
      }
      // -----------------------------------
      sequence.totalPL = NormalizeDouble(sequence.stopsPL + sequence.closedPL + sequence.floatingPL, 2);

      lastId     = id;
      lastTime   = time;
      lastType   = type;
      lastTicket = ticket;
   }
   lastEventId = id;


   // (4) Wurde die Sequenz au�erhalb gestoppt, fehlende Stop-Daten ermitteln
   if (sequence.status == STATUS_STOPPING) {
      if (closedPositions != Abs(sequence.level)) return(_false(catch("Sync.ProcessEvents(14)  unexpected number of closed positions in "+ sequenceStatusDescr[sequence.status] +" sequence", ERR_RUNTIME_ERROR)));

      // (4.1) Stopdaten ermitteln
      int level = Abs(sequence.level);
      double stopPrice;
      for (i=sizeOfEvents-level; i < sizeOfEvents; i++) {
         time  = events[i][1];
         type  = events[i][2];
         index = events[i][4];
         if (type != EV_POSITION_CLOSE)
            return(_false(catch("Sync.ProcessEvents(15)  unexpected "+ StatusEventToStr(type) +" at index "+ i, ERR_RUNTIME_ERROR)));
         stopPrice += orders.closePrice[index];
      }
      stopPrice /= level;

      // (4.2) Stopdaten zur�ckgeben
      sequenceStopTime  = time;
      sequenceStopPrice = NormalizeDouble(stopPrice, Digits);
   }

   ArrayResize(events,      0);
   ArrayResize(orderEvents, 0);
   return(!last_error|catch("Sync.ProcessEvents(16)"));
}


/**
 * Redraw the sequence's start/stop marker.
 */
void RedrawStartStop() {
   if (!__CHART()) return;

   datetime time;
   double   price;
   double   profit;
   string   label;
   int starts = ArraySize(sequence.start.event);

   // start
   for (int i=0; i < starts; i++) {
      time   = sequence.start.time  [i];
      price  = sequence.start.price [i];
      profit = sequence.start.profit[i];

      label = StringConcatenate("SR.", sequence.id, ".start.", i+1);
      if (ObjectFind(label) == 0)
         ObjectDelete(label);

      if (startStopDisplayMode != SDM_NONE) {
         ObjectCreate (label, OBJ_ARROW, 0, time, price);
         ObjectSet    (label, OBJPROP_ARROWCODE, startStopDisplayMode);
         ObjectSet    (label, OBJPROP_BACK,      false               );
         ObjectSet    (label, OBJPROP_COLOR,     Blue                );
         ObjectSetText(label, StringConcatenate("Profit: ", DoubleToStr(profit, 2)));
      }
   }

   // stop
   for (i=0; i < starts; i++) {
      if (sequence.stop.time[i] > 0) {
         time   = sequence.stop.time [i];
         price  = sequence.stop.price[i];
         profit = sequence.stop.profit[i];

         label = StringConcatenate("SR.", sequence.id, ".stop.", i+1);
         if (ObjectFind(label) == 0)
            ObjectDelete(label);

         if (startStopDisplayMode != SDM_NONE) {
            ObjectCreate (label, OBJ_ARROW, 0, time, price);
            ObjectSet    (label, OBJPROP_ARROWCODE, startStopDisplayMode);
            ObjectSet    (label, OBJPROP_BACK,      false               );
            ObjectSet    (label, OBJPROP_COLOR,     Blue                );
            ObjectSetText(label, StringConcatenate("Profit: ", DoubleToStr(profit, 2)));
         }
      }
   }
   catch("RedrawStartStop(1)");
}


/**
 * Zeichnet die ChartMarker aller Orders neu.
 */
void RedrawOrders() {
   if (!__CHART()) return;

   bool wasPending, isPending, closedPosition;
   int  size = ArraySize(orders.ticket);

   for (int i=0; i < size; i++) {
      wasPending     = orders.pendingType[i] != OP_UNDEFINED;
      isPending      = orders.type[i] == OP_UNDEFINED;
      closedPosition = !isPending && orders.closeTime[i]!=0;

      if    (isPending)                         Chart.MarkOrderSent(i);
      else /*openPosition || closedPosition*/ {                                  // openPosition ist Folge einer
         if (wasPending)                        Chart.MarkOrderFilled(i);        // ...ausgef�hrten Pending-Order
         else                                   Chart.MarkOrderSent(i);          // ...oder Market-Order
         if (closedPosition)                    Chart.MarkPositionClosed(i);
      }
   }
}


/**
 * Wechselt den Modus der Start/Stopanzeige.
 *
 * @return int - Fehlerstatus
 */
int ToggleStartStopDisplayMode() {
   // Mode wechseln
   int i = SearchIntArray(startStopDisplayModes, startStopDisplayMode);    // #define SDM_NONE        - keine Anzeige -
   if (i == -1) {                                                          // #define SDM_PRICE       Markierung mit Preisangabe
      startStopDisplayMode = SDM_PRICE;           // default
   }
   else {
      int size = ArraySize(startStopDisplayModes);
      startStopDisplayMode = startStopDisplayModes[(i+1) % size];
   }

   // Anzeige aktualisieren
   RedrawStartStop();

   return(catch("ToggleStartStopDisplayMode()"));
}


/**
 * Wechselt den Modus der Orderanzeige.
 *
 * @return int - Fehlerstatus
 */
int ToggleOrderDisplayMode() {
   int pendings   = CountPendingOrders();
   int open       = CountOpenPositions();
   int stoppedOut = CountStoppedOutPositions();
   int closed     = CountClosedPositions();

   // Modus wechseln, dabei Modes ohne entsprechende Orders �berspringen
   int oldMode      = orderDisplayMode;
   int size         = ArraySize(orderDisplayModes);
   orderDisplayMode = (orderDisplayMode+1) % size;

   while (orderDisplayMode != oldMode) {                                   // #define ODM_NONE        - keine Anzeige -
      if (orderDisplayMode == ODM_NONE) {                                  // #define ODM_STOPS       Pending,       StoppedOut
         break;                                                            // #define ODM_PYRAMID     Pending, Open,             Closed
      }                                                                    // #define ODM_ALL         Pending, Open, StoppedOut, Closed
      else if (orderDisplayMode == ODM_STOPS) {
         if (pendings+stoppedOut > 0)
            break;
      }
      else if (orderDisplayMode == ODM_PYRAMID) {
         if (pendings+open+closed > 0)
            if (open+stoppedOut+closed > 0)                                // ansonsten ist Anzeige identisch zu vorherigem Mode
               break;
      }
      else if (orderDisplayMode == ODM_ALL) {
         if (pendings+open+stoppedOut+closed > 0)
            if (stoppedOut > 0)                                            // ansonsten ist Anzeige identisch zu vorherigem Mode
               break;
      }
      orderDisplayMode = (orderDisplayMode+1) % size;
   }


   // Anzeige aktualisieren
   if (orderDisplayMode != oldMode) {
      RedrawOrders();
   }
   else {
      // nothing to change, Anzeige bleibt unver�ndert
      PlaySoundEx("Plonk.wav");
   }
   return(catch("ToggleOrderDisplayMode()"));
}


/**
 * Gibt die Anzahl der Pending-Orders der Sequenz zur�ck.
 *
 * @return int
 */
int CountPendingOrders() {
   int count, size=ArraySize(orders.ticket);

   for (int i=0; i < size; i++) {
      if (orders.type[i]==OP_UNDEFINED) /*&&*/ if (orders.closeTime[i]==0)
         count++;
   }
   return(count);
}


/**
 * Gibt die Anzahl der offenen Positionen der Sequenz zur�ck.
 *
 * @return int
 */
int CountOpenPositions() {
   int count, size=ArraySize(orders.ticket);

   for (int i=0; i < size; i++) {
      if (orders.type[i]!=OP_UNDEFINED) /*&&*/ if (orders.closeTime[i]==0)
         count++;
   }
   return(count);
}


/**
 * Gibt die Anzahl der ausgestoppten Positionen der Sequenz zur�ck.
 *
 * @return int
 */
int CountStoppedOutPositions() {
   int count, size=ArraySize(orders.ticket);

   for (int i=0; i < size; i++) {
      if (orders.closedBySL[i])
         count++;
   }
   return(count);
}


/**
 * Gibt die Anzahl der durch StopSequence() geschlossenen Positionen der Sequenz zur�ck.
 *
 * @return int
 */
int CountClosedPositions() {
   int count, size=ArraySize(orders.ticket);

   for (int i=0; i < size; i++) {
      if (orders.type[i]!=OP_UNDEFINED) /*&&*/ if (orders.closeTime[i]!=0) /*&&*/ if (!orders.closedBySL[i])
         count++;
   }
   return(count);
}


/**
 * Korrigiert die vom Terminal beim Abschicken einer Pending- oder Market-Order gesetzten oder nicht gesetzten Chart-Marker.
 *
 * @param  int i - Orderindex
 *
 * @return bool - success status
 */
bool Chart.MarkOrderSent(int i) {
   if (!__CHART()) return(true);
   /*
   #define ODM_NONE     0     // - keine Anzeige -
   #define ODM_STOPS    1     // Pending,       ClosedBySL
   #define ODM_PYRAMID  2     // Pending, Open,             Closed
   #define ODM_ALL      3     // Pending, Open, ClosedBySL, Closed
   */
   bool pending = orders.pendingType[i] != OP_UNDEFINED;

   int      type        =    ifInt(pending, orders.pendingType [i], orders.type     [i]);
   datetime openTime    =    ifInt(pending, orders.pendingTime [i], orders.openTime [i]);
   double   openPrice   = ifDouble(pending, orders.pendingPrice[i], orders.openPrice[i]);
   string   comment     = StringConcatenate("SR.", sequence.id, ".", NumberToStr(orders.level[i], "+."));
   color    markerColor = CLR_NONE;

   if (orderDisplayMode != ODM_NONE) {
      if      (pending)                         markerColor = CLR_PENDING;
      else if (orderDisplayMode >= ODM_PYRAMID) markerColor = ifInt(IsLongTradeOperation(type), CLR_LONG, CLR_SHORT);
   }
   return(ChartMarker.OrderSent_B(orders.ticket[i], Digits, markerColor, type, LotSize, Symbol(), openTime, openPrice, orders.stopLoss[i], 0, comment));
}


/**
 * Korrigiert die vom Terminal beim Ausf�hren einer Pending-Order gesetzten oder nicht gesetzten Chart-Marker.
 *
 * @param  int i - Orderindex
 *
 * @return bool - success status
 */
bool Chart.MarkOrderFilled(int i) {
   if (!__CHART()) return(true);
   /*
   #define ODM_NONE     0     // - keine Anzeige -
   #define ODM_STOPS    1     // Pending,       ClosedBySL
   #define ODM_PYRAMID  2     // Pending, Open,             Closed
   #define ODM_ALL      3     // Pending, Open, ClosedBySL, Closed
   */
   string comment     = StringConcatenate("SR.", sequence.id, ".", NumberToStr(orders.level[i], "+."));
   color  markerColor = CLR_NONE;

   if (orderDisplayMode >= ODM_PYRAMID)
      markerColor = ifInt(orders.type[i]==OP_BUY, CLR_LONG, CLR_SHORT);

   return(ChartMarker.OrderFilled_B(orders.ticket[i], orders.pendingType[i], orders.pendingPrice[i], Digits, markerColor, LotSize, Symbol(), orders.openTime[i], orders.openPrice[i], comment));
}


/**
 * Korrigiert den vom Terminal beim Schlie�en einer Position gesetzten oder nicht gesetzten Chart-Marker.
 *
 * @param  int i - Orderindex
 *
 * @return bool - success status
 */
bool Chart.MarkPositionClosed(int i) {
   if (!__CHART()) return(true);
   /*
   #define ODM_NONE     0     // - keine Anzeige -
   #define ODM_STOPS    1     // Pending,       ClosedBySL
   #define ODM_PYRAMID  2     // Pending, Open,             Closed
   #define ODM_ALL      3     // Pending, Open, ClosedBySL, Closed
   */
   color markerColor = CLR_NONE;

   if (orderDisplayMode != ODM_NONE) {
      if ( orders.closedBySL[i]) /*&&*/ if (orderDisplayMode != ODM_PYRAMID) markerColor = CLR_CLOSE;
      if (!orders.closedBySL[i]) /*&&*/ if (orderDisplayMode >= ODM_PYRAMID) markerColor = CLR_CLOSE;
   }
   return(ChartMarker.PositionClosed_B(orders.ticket[i], Digits, markerColor, orders.type[i], LotSize, Symbol(), orders.openTime[i], orders.openPrice[i], orders.closeTime[i], orders.closePrice[i]));
}


/**
 * Whether the current sequence was created in tester and thus is a test. Considers the fact that a test sequence may be
 * loaded in an online chart after the test (for visualization).
 *
 * @return bool
 */
bool IsTestSequence() {
   return(sequence.isTest || IsTesting());
}


/**
 * Setzt die Gr��e der Datenarrays auf den angegebenen Wert.
 *
 * @param  int  size  - neue Gr��e
 * @param  bool reset - ob die Arrays komplett zur�ckgesetzt werden sollen
 *                      (default: nur neu hinzugef�gte Felder werden initialisiert)
 *
 * @return int - neue Gr��e der Arrays
 */
int ResizeArrays(int size, bool reset=false) {
   reset = reset!=0;

   int oldSize = ArraySize(orders.ticket);

   if (size != oldSize) {
      ArrayResize(orders.ticket,          size);
      ArrayResize(orders.level,           size);
      ArrayResize(orders.gridBase,        size);
      ArrayResize(orders.pendingType,     size);
      ArrayResize(orders.pendingTime,     size);
      ArrayResize(orders.pendingPrice,    size);
      ArrayResize(orders.type,            size);
      ArrayResize(orders.openEvent,       size);
      ArrayResize(orders.openTime,        size);
      ArrayResize(orders.openPrice,       size);
      ArrayResize(orders.closeEvent,      size);
      ArrayResize(orders.closeTime,       size);
      ArrayResize(orders.closePrice,      size);
      ArrayResize(orders.stopLoss,        size);
      ArrayResize(orders.clientsideLimit, size);
      ArrayResize(orders.closedBySL,      size);
      ArrayResize(orders.swap,            size);
      ArrayResize(orders.commission,      size);
      ArrayResize(orders.profit,          size);
   }

   if (reset) {                                                      // alle Felder zur�cksetzen
      if (size != 0) {
         ArrayInitialize(orders.ticket,                 0);
         ArrayInitialize(orders.level,                  0);
         ArrayInitialize(orders.gridBase,               0);
         ArrayInitialize(orders.pendingType, OP_UNDEFINED);
         ArrayInitialize(orders.pendingTime,            0);
         ArrayInitialize(orders.pendingPrice,           0);
         ArrayInitialize(orders.type,        OP_UNDEFINED);
         ArrayInitialize(orders.openEvent,              0);
         ArrayInitialize(orders.openTime,               0);
         ArrayInitialize(orders.openPrice,              0);
         ArrayInitialize(orders.closeEvent,             0);
         ArrayInitialize(orders.closeTime,              0);
         ArrayInitialize(orders.closePrice,             0);
         ArrayInitialize(orders.stopLoss,               0);
         ArrayInitialize(orders.clientsideLimit,    false);
         ArrayInitialize(orders.closedBySL,         false);
         ArrayInitialize(orders.swap,                   0);
         ArrayInitialize(orders.commission,             0);
         ArrayInitialize(orders.profit,                 0);
      }
   }
   else {
      for (int i=oldSize; i < size; i++) {
         orders.pendingType[i] = OP_UNDEFINED;                       // Hinzugef�gte pendingType- und type-Felder immer re-initialisieren,
         orders.type       [i] = OP_UNDEFINED;                       // 0 ist ein g�ltiger Wert und daher als Default unzul�ssig.
      }
   }
   return(size);
}


/**
 * Gibt die lesbare Konstante eines Status-Events zur�ck.
 *
 * @param  int type - Event-Type
 *
 * @return string
 */
string StatusEventToStr(int type) {
   switch (type) {
      case EV_SEQUENCE_START  : return("EV_SEQUENCE_START"  );
      case EV_SEQUENCE_STOP   : return("EV_SEQUENCE_STOP"   );
      case EV_GRIDBASE_CHANGE : return("EV_GRIDBASE_CHANGE" );
      case EV_POSITION_OPEN   : return("EV_POSITION_OPEN"   );
      case EV_POSITION_STOPOUT: return("EV_POSITION_STOPOUT");
      case EV_POSITION_CLOSE  : return("EV_POSITION_CLOSE"  );
   }
   return(_EMPTY_STR(catch("StatusEventToStr(1)  illegal parameter type = "+ type, ERR_INVALID_PARAMETER)));
}


/**
 * Generiert eine neue Sequenz-ID.
 *
 * @return int - Sequenz-ID im Bereich 1000-16383 (mindestens 4-stellig, maximal 14 bit)
 */
int CreateSequenceId() {
   MathSrand(GetTickCount());
   int id;                                               // TODO: Im Tester m�ssen fortlaufende IDs generiert werden.
   while (id < SID_MIN || id > SID_MAX) {
      id = MathRand();
   }
   return(id);                                           // TODO: ID auf Eindeutigkeit pr�fen
}


/**
 * Holt eine Best�tigung f�r einen Trade-Request beim ersten Tick ein (um Programmfehlern vorzubeugen).
 *
 * @param  string location - Ort der Best�tigung
 * @param  string message  - Meldung
 *
 * @return bool - Ergebnis
 */
bool ConfirmFirstTickTrade(string location, string message) {
   static bool done, confirmed;
   if (!done) {
      if (Tick > 1 || IsTesting()) {
         confirmed = true;
      }
      else {
         PlaySoundEx("Windows Notify.wav");
         confirmed = (IDOK == MessageBoxEx(__NAME() + ifString(!StringLen(location), "", " - "+ location), ifString(IsDemoFix(), "", "- Real Account -\n\n") + message, MB_ICONQUESTION|MB_OKCANCEL));
         if (Tick > 0) RefreshRates();                   // bei Tick==0, also Aufruf in init(), ist RefreshRates() unn�tig
      }
      done = true;
   }
   return(confirmed);
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
      case STATUS_STARTING   : return("STATUS_STARTING"   );
      case STATUS_PROGRESSING: return("STATUS_PROGRESSING");
      case STATUS_STOPPING   : return("STATUS_STOPPING"   );
      case STATUS_STOPPED    : return("STATUS_STOPPED"    );
   }
   return(_EMPTY_STR(catch("StatusToStr()  invalid parameter status = "+ status, ERR_INVALID_PARAMETER)));
}


/**
 * Ob der angegebene StopPrice erreicht wurde.
 *
 * @param  int    type  - Stop-Typ: OP_BUYSTOP|OP_SELLSTOP|OP_BUY|OP_SELL
 * @param  double price - StopPrice
 *
 * @return bool
 */
bool IsStopTriggered(int type, double price) {
   if (type == OP_BUYSTOP ) return(Ask >= price);        // pending Buy-Stop
   if (type == OP_SELLSTOP) return(Bid <= price);        // pending Sell-Stop

   if (type == OP_BUY     ) return(Bid <= price);        // Long-StopLoss
   if (type == OP_SELL    ) return(Ask >= price);        // Short-StopLoss

   return(!catch("IsStopTriggered()  illegal parameter type = "+ type, ERR_INVALID_PARAMETER));
}


/**
 * Whether the origin of the order at the specified order index was a pending stop order.
 *
 * @param  int index - order index
 *
 * @return bool
 */
bool IsStopOrder(int index) {
   int size = ArraySize(orders.ticket);
   if (index < 0 || index >= size) return(!catch("IsStopOrder(1)  illegal parameter index = "+ index, ERR_INVALID_PARAMETER));

   return(orders.pendingType[index]==OP_BUYSTOP || orders.pendingType[index]==OP_SELLSTOP);
   IsLimitOrder(NULL); // dummy call
}


/**
 * Whether the origin of the order at the specified order index was a pending limit order.
 *
 * @param  int index - order index
 *
 * @return bool
 */
bool IsLimitOrder(int index) {
   int size = ArraySize(orders.ticket);
   if (index < 0 || index >= size) return(!catch("IsLimitOrder(1)  illegal parameter index = "+ index, ERR_INVALID_PARAMETER));

   return(orders.pendingType[index]==OP_BUYLIMIT || orders.pendingType[index]==OP_SELLLIMIT);
}

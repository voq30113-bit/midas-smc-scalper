//+------------------------------------------------------------------+
//| MIDAS_DukaImport.mq5 - load a Dukascopy M1 CSV into an MT5 custom |
//| symbol cloned from a broker symbol (same digits/contract/margin). |
//| CSV (MQL5\Files, no header): date,time,open,high,low,close,       |
//|                               tickvol,realvol,spread_points       |
//| Timestamps are UTC: test with InpServerGMT = 0.                   |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

input string InpSymbol = "XAUUSD.D";     // custom symbol to create / refill
input string InpOrigin = "XAUUSD";       // broker symbol to clone the specification from
input string InpFile   = "duka_xau.csv"; // CSV in MQL5\Files
input int    InpChunk  = 100000;         // bars per CustomRatesReplace call

void OnStart()
{
   if(!SymbolInfoInteger(InpOrigin, SYMBOL_EXIST)) { PrintFormat("DUKA: origin %s not found", InpOrigin); return; }
   if(!SymbolInfoInteger(InpSymbol, SYMBOL_EXIST))
   {
      if(!CustomSymbolCreate(InpSymbol, "MIDAS\\" + InpSymbol, InpOrigin)) { PrintFormat("DUKA: create failed %d", GetLastError()); return; }
   }
   else
   {
      CustomRatesDelete(InpSymbol, 0, D'2100.01.01');                 // refill from scratch
   }
   SymbolSelect(InpSymbol, true);

   int h = FileOpen(InpFile, FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) { PrintFormat("DUKA: cannot open %s (err %d)", InpFile, GetLastError()); return; }

   MqlRates buf[]; ArrayResize(buf, InpChunk);
   int n = 0; long total = 0; datetime first = 0, last = 0;
   string parts[];
   while(!FileIsEnding(h))
   {
      string ln = FileReadString(h);
      if(StringLen(ln) < 20) continue;
      if(StringSplit(ln, ',', parts) < 9) continue;
      datetime t = StringToTime(parts[0] + " " + parts[1]);
      buf[n].time = t;
      buf[n].open = StringToDouble(parts[2]); buf[n].high = StringToDouble(parts[3]);
      buf[n].low  = StringToDouble(parts[4]); buf[n].close = StringToDouble(parts[5]);
      buf[n].tick_volume = (long)StringToInteger(parts[6]); buf[n].real_volume = 0;
      buf[n].spread = (int)StringToInteger(parts[8]);
      if(first == 0) first = t;
      last = t; n++;
      if(n >= InpChunk)
      {
         int r = CustomRatesUpdate(InpSymbol, buf, n);
         if(r <= 0) { PrintFormat("DUKA: CustomRatesUpdate failed %d", GetLastError()); break; }
         total += n; n = 0;
      }
   }
   if(n > 0)
   {
      ArrayResize(buf, n);
      int r = CustomRatesUpdate(InpSymbol, buf, n);
      if(r <= 0) PrintFormat("DUKA: final CustomRatesUpdate failed %d", GetLastError()); else total += n;
   }
   FileClose(h);
   PrintFormat("DUKA: %s loaded %I64d M1 bars %s -> %s", InpSymbol, total, TimeToString(first), TimeToString(last));
}

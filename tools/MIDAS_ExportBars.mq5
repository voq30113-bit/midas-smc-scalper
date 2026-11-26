// Exports M5 bars (with spread in points) of a symbol list to Common\Files\MIDAS\bars\<symbol>.csv for offline research.
// Reads market data only: no trading functions.
#property script_show_inputs
input string InpSymbols = "XAUUSD,XAUEUR,XAUGBP,US30,US500,USTEC,DE30,UK100,JP225,BTCUSD,ETHUSD,XAGUSD,USOIL,EURUSD,GBPUSD,USDJPY,XAUUSD.D,USTEC.D,DE30.D";
input datetime InpFrom = D'2021.01.01';

void OnStart()
{
   string s[];
   int n = StringSplit(InpSymbols, ',', s);
   for(int i = 0; i < n; i++)
   {
      string sym = s[i];
      if(!SymbolSelect(sym, true)) { Print("skip ", sym); continue; }
      MqlRates r[];
      int got = -1;
      for(int t = 0; t < 20 && got <= 0; t++) { got = CopyRates(sym, PERIOD_M5, InpFrom, TimeCurrent() + 86400, r); if(got <= 0) Sleep(1000); }
      if(got <= 0) { Print("no data ", sym); continue; }
      int h = FileOpen("MIDAS\\bars\\" + sym + ".csv", FILE_WRITE | FILE_ANSI | FILE_TXT | FILE_COMMON);
      if(h == INVALID_HANDLE) { Print("cannot write ", sym); continue; }
      int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      FileWriteString(h, "point," + DoubleToString(SymbolInfoDouble(sym, SYMBOL_POINT), 8) + "\n");
      for(int k = 0; k < got; k++)
         FileWriteString(h, StringFormat("%I64d,%s,%s,%s,%s,%d\n", (long)r[k].time, DoubleToString(r[k].open, d), DoubleToString(r[k].high, d),
                                         DoubleToString(r[k].low, d), DoubleToString(r[k].close, d), r[k].spread));
      FileClose(h);
      Print(sym, " bars ", got);
   }
   Print("MIDAS export done");
}

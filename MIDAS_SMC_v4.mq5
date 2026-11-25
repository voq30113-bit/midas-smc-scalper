//+------------------------------------------------------------------+
//|                                              MIDAS_SMC_v4.mq5     |
//|   M I D A S  v4.0  -  multi-asset SMC scalper (V3 engine only)    |
//|                                                                  |
//|  v4.0 CHANGELOG  (built from v3.4; the V3 decision logic -        |
//|  pools -> grab -> MSS -> limit in the zone -> exits - is kept)    |
//|  -------------------------------------------------------------   |
//|  1. LEGACY (v2.1) ENGINE REMOVED. One engine, one code path.      |
//|     (A/B against LEGACY is still done with the v3.4 binary.)      |
//|  2. NO DOLLAR INPUTS.  Every distance is a multiple of ATR(M5):   |
//|       InpSLBufferUSD / InpMaxSL_USD   -> InpSLBufferATR/MaxSL_ATR |
//|       InpBE_LockUSD                   -> InpBE_LockATR            |
//|       InpStructTrailUSD               -> InpStructTrailATR        |
//|       InpMaxSpreadUSD                 -> InpMaxSpreadATR          |
//|     Spread is gated TWICE: x ATR (market too wide) and as a %     |
//|     of R (this trade's stop too tight to pay the spread).         |
//|  3. NOTIONAL CAP replaces the ounce cap: lots are limited so that |
//|     lots x contract x price (account currency) <= InpMaxNotionalX |
//|     x equity. Correct for any contract size (gold, index, FX,     |
//|     crypto). A min-lot trade that would risk more than            |
//|     InpMinLotRiskMult x the configured risk is REJECTED (v3.4     |
//|     silently rounded it up to the minimum lot).                   |
//|  4. ASSET PROFILES.  Session, blackouts, overnight/Asia window,   |
//|     weekend flatten, day roll and the 3 market gates come from a  |
//|     per-symbol profile: built-in preset (auto-detected from the   |
//|     symbol) + optional override file                              |
//|        <Common>\Files\MIDAS\profile_<SYMBOL>.ini                  |
//|     which is the gateway for Python / the Agent. Only SAFE keys   |
//|     can be set from the file (never risk %, floors, magic) and    |
//|     every value is clamped. The EA re-reads it live and writes an |
//|     acknowledgement to status_<SYMBOL>_<magic>.ini.               |
//|  5. ACCOUNT RISK MANAGER (in the EA, so it is backtestable).      |
//|     Reads the open risk of every MIDAS magic (positions to their  |
//|     stop + resting limits) and refuses a new limit that would     |
//|     push the total over InpMaxOpenRiskPct / InpMaxOpenPositions.  |
//|  6. TRADE JOURNAL (CSV) in <Common>\Files\MIDAS\ - one row per    |
//|     closed trade with R, MFE/MAE in R, setup tag, volatility and  |
//|     trend regime at entry, exit type. Python reads this to score  |
//|     each symbol and each regime.                                  |
//|  7. Server clock in the tester: AUTO now means FIXED with         |
//|     InpServerGMT (Exness = 0), not the MetaQuotes NYCLOSE guess.  |
//|                                                                  |
//|  v4.1: SHOCK GUARD (a bar >= InpSpikeRangeATR x ATR pauses new setups and cancels resting ones for a few bars - news,
//|  flash moves), profile keys halt_from_utc / halt_until_utc (the Agent pauses the bot around scheduled news), funnel counters
//|  printed at the end of every test, OnTester() score = edge x sqrt(trades) / drawdown for optimisation.
//|
//|  v4.2: second entry engine ENGINE_PULLBACK = trend scalper (pullback to the fast EMA inside an ADX-confirmed trend,
//|  market entry on the confirmation bar, stop beyond the pullback, TP1 in R). Built for frequency (hundreds of trades a year)
//|  and for instruments where the sweep/MSS reversal has no edge (indices). ENGINE_SWEEP is the v4.1 logic, unchanged.
//|
//|  ATTACH TO AN M5 CHART.  One instance per symbol, one magic per   |
//|  symbol, all inside [InpRiskMagicLo, InpRiskMagicHi].             |
//+------------------------------------------------------------------+
#property copyright "Built with Claude for Bean"
#property version   "4.50"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================//
//  PART 1 - INPUTS                                                  //
//==================================================================//
input group "=== General ==="
input long   InpMagic          = 580001;           // Magic number: ONE PER SYMBOL, inside the Risk Manager range
input string InpComment        = "MIDAS_v4";       // Order comment prefix (setup tag is appended)

enum ENUM_DIR { DIR_BOTH=0, DIR_LONG_ONLY=1, DIR_SHORT_ONLY=2 };
input ENUM_DIR InpDirection    = DIR_BOTH;         // Which side(s) may trade

enum ENUM_ENGINE { ENGINE_SWEEP = 0, ENGINE_PULLBACK = 1, ENGINE_ORB = 2 };
input ENUM_ENGINE InpEntryEngine = ENGINE_SWEEP;    // SWEEP = liquidity grab -> MSS -> limit. PULLBACK = trend scalper. ORB = breakout of the overnight/Asia range

input group "=== PULLBACK engine (trend scalper) ==="
input int    InpPbFast         = 20;               // Fast EMA (M5) - the value area price pulls back to
input int    InpPbSlow         = 50;               // Slow EMA (M5) - trend = fast above/below slow and price on the right side
input double InpPbAdxMin       = 20.0;             // ADX(14, M5) must be at least this (0 = off)
input int    InpPbHTFEma       = 50;               // H1 EMA period whose slope must agree with the trade (0 = off)
input double InpPbTouchATR     = 0.15;             // The trigger bar low/high must come within this x ATR of the fast EMA
input double InpPbMinBodyATR   = 0.25;             // Trigger candle body >= this x ATR (real rejection, not a doji)
input double InpPbSLBufATR     = 0.20;             // Stop beyond the pullback extreme, x ATR
input double InpPbMinSL_ATR    = 0.60;             // Skip if the stop is tighter than this x ATR (spread would eat it)
input double InpPbMaxSL_ATR    = 2.00;             // Skip if the stop is wider than this x ATR
input double InpPbTP1_R        = 1.00;             // First target in R (then BE lock + structural trail)
input int    InpPbCooldownBars = 3;                // M5 bars between two entries
input double InpPbRandomPct    = 0.0;              // PLACEBO: >0 replaces the trigger by a random entry (this % of bars, random side) with the same stop/target rules - the benchmark every real trigger must beat
input double InpPbRandSL_ATR   = 1.0;              // PLACEBO stop distance, x ATR
input bool   InpPbNoTrend      = false;            // Drop the trend filters (EMA/ADX/H1) - keeps the pullback trigger only

input group "=== ORB engine (breakout of the profile's overnight/Asia range) ==="
input double InpOrbBufATR      = 0.10;             // Close must clear the range by this x ATR
input double InpOrbMinRangeATR = 1.0;              // Skip a day whose range is smaller than this x ATR (no energy stored)
input double InpOrbMaxRangeATR = 8.0;              // ...or larger (move already happened)
input int    InpOrbSLMode      = 1;                // 0 = stop at the opposite range extreme, 1 = at the range midpoint
input double InpOrbMinSL_ATR   = 0.60;             // Skip if the stop is tighter than this x ATR
input double InpOrbMaxSL_ATR   = 2.50;             // Skip if the stop is wider than this x ATR
input double InpOrbTP1_R       = 1.00;             // First target in R (then BE lock + structural trail)
input int    InpOrbMaxPerDay   = 1;                // Max breakouts per clock day

input group "=== Asset profile (sessions / blackouts / weekend / day roll) ==="
enum ENUM_PROFILE
{
   PROF_AUTO      = 0,   // detect from the symbol
   PROF_GOLD      = 1,   // XAU*
   PROF_SILVER    = 2,   // XAG* (same clock as gold)
   PROF_FX        = 3,   // currency pairs
   PROF_INDEX_US  = 4,   // USTEC / US500 / US30 (NY cash session)
   PROF_INDEX_EU  = 5,   // DE30 / UK100 / FR40 (Frankfurt/London session)
   PROF_OIL       = 6,   // USOIL / UKOIL
   PROF_CRYPTO    = 7    // BTC / ETH (24/7, UTC day)
};
input ENUM_PROFILE InpProfile  = PROF_AUTO;        // Built-in preset (AUTO = from the symbol name / path)
input bool   InpUseProfileFile = true;             // Apply overrides from MIDAS\profile_<SYMBOL>.ini (Common\Files) if it exists
input string InpProfileFile    = "";               // Custom override path ("" = MIDAS\profile_<SYMBOL>.ini)
input int    InpProfileReloadBars = 2;             // Live only: look for a changed profile file every N M5 bars (2 = 10 min)

input group "=== Broker normalisation (SET THIS PER BROKER) ==="
enum ENUM_SRVCLOCK
{
   SRV_AUTO    = 0,   // AUTO: live = measured from the terminal; tester = FIXED with InpServerGMT
   SRV_NYCLOSE = 1,   // NYCLOSE (UTC+2, UTC+3 in US DST - MetaQuotes servers)
   SRV_FIXED   = 2    // FIXED (InpServerGMT, e.g. 0 for Exness)
};
input ENUM_SRVCLOCK InpServerClock = SRV_AUTO;     // Broker server clock -> UTC
input int    InpServerGMT      = 0;                // FIXED / tester: server offset from UTC in hours (Exness = 0). 99 = measure live
input bool   InpLogNormalise   = true;             // Print the resolved offset / symbol spec at init

input group "=== Multi-Timeframe Bias ==="
input bool   InpUseHTFBias     = true;             // Gate entries by higher-TF trend
input ENUM_TIMEFRAMES InpHTF   = PERIOD_H1;        // Higher timeframe for bias
input int    InpHTFSwing       = 2;                // HTF fractal half-width
input int    InpHTFLookback    = 220;              // HTF bars scanned
input bool   InpUseHTFZone     = false;            // Also require HTF discount/premium

input group "=== Market Structure (M5 swings) ==="
input int    InpSwingStrength  = 2;                // M5 fractal half-width (structure + trail)
input int    InpStructLookback = 180;              // M5 bars scanned

input group "=== STEP 1 - Liquidity pools (what counts as liquidity) ==="
input int    InpPoolPivot      = 10;               // Pivot half-width for a pool. 8-15
input int    InpPoolLookback   = 400;              // M5 bars scanned for pools
input int    InpMaxPools       = 14;               // Max live pools kept per side
input double InpEqTolATR       = 0.15;             // Equal-high/low merge tolerance (x ATR)
input bool   InpUseSessionPools= true;             // Add the overnight/Asia range H/L and PDH/PDL as pools (window = profile)

input group "=== STEP 2 - The grab (sweep that actually swept) ==="
input double InpGrabWickFrac   = 0.35;             // Min wick / candle-range on the grab bar
input double InpGrabMinPokeATR = 0.05;             // Wick must clear the pool by this x ATR
input int    InpGrabCooldown   = 3;                // Bars before the same side may grab again

input group "=== STEP 3 - Market-structure shift (the trigger) ==="
input int    InpMSSPivot       = 2;                // Fractal half-width of the minor swing the MSS must break
input int    InpMSSLookback    = 15;               // Bars searched for that minor swing
input int    InpMSSMaxBars     = 5;                // MSS must arrive within N bars of the grab
input double InpMinFVGATR      = 0.35;             // Displacement FVG must be >= this x ATR

input group "=== STEP 4 - The entry (limit order in the zone) - all distances in ATR ==="
input double InpZoneEntryFrac  = 0.30;             // 0 = proximal edge (fills most), 0.5 = FVG midpoint
input bool   InpZoneFallbackOB = true;             // If the leg left no qualifying FVG, use the order block
input double InpSLBufferATR    = 0.25;             // Stop beyond the swept extreme, x ATR
input double InpMaxSL_ATR      = 2.20;             // Reject the setup if the stop is wider than this x ATR (profile default)
input int    InpArmExpiryBars  = 10;               // Cancel the resting limit after N M5 bars
input bool   InpRequirePool    = true;             // Reject unless a real pool sits >= InpMinTP1_R away
input bool   InpUseRangeFilter = true;             // Entry must sit in the discount/premium half of the swept leg

input group "=== Growth ladder ==="
input bool   InpUseHyperGrowth = true;             // Step risk up as REALIZED balance grows
input double InpBaseRiskPct    = 1.0;              // Starting risk % per trade
input double InpScaleStepPct   = 10.0;             // One risk step per this % of START balance gained
input double InpScaleAddPct    = 0.5;              // Risk % added per step
input double InpMaxRiskPct     = 2.0;              // Hard cap on risk % per trade

input group "=== CAPITAL FLOOR (the preservation feature) ==="
input bool   InpUseCapitalFloor = true;            // Act when equity falls this far below its PEAK
input double InpCapitalFloorDD  = 50.0;            // % below the equity peak
enum ENUM_FLOOR_ACT { FLOOR_HALT=0, FLOOR_THROTTLE=1 };
input ENUM_FLOOR_ACT InpFloorAction = FLOOR_HALT;  // HALT = stop for the run. THROTTLE = keep trading at reduced size
input double InpFloorRiskMult   = 0.25;            // Risk multiplier when THROTTLE is chosen

input group "=== Milestone ratchet (RETURN-NEUTRAL) ==="
input bool   InpUseRatchet      = false;           // Re-anchor the ladder at each milestone
input double InpRatchetPct      = 25.0;            // Re-anchor after this % gain over the anchor

input group "=== DRAWDOWN CONTROL ==="
input bool   InpUseDDThrottle  = false;            // Cut risk as equity draws down from its peak
input double InpThrottleStartDD= 8.0;              // Start cutting at this % DD from the equity peak
input double InpThrottleFullDD = 25.0;             // Fully cut at this % DD
input double InpThrottleMinMult= 0.25;             // Risk multiplier at/below full DD
input bool   InpUseStreakBrake = false;            // Cut risk after consecutive losing trades
input int    InpStreakTrigger  = 3;                // Consecutive losses before braking
input double InpStreakMult     = 0.50;             // Multiplier compounded per loss past the trigger
input double InpStreakFloor    = 0.25;             // Never brake below this multiplier
input bool   InpUseVault       = false;            // Lock a share of banked profit out of the sizing base
input double InpVaultPct       = 30.0;             // % of peak profit locked away
input bool   InpFlatBeforeWeekend = true;          // Master switch: flatten + cancel before the weekend (profile decides the hour, crypto = off)
input double InpCutLossAtR     = 0.0;              // Partial-close when a trade is this far offside in R (0 = off)
input double InpCutLossPct     = 50.0;             // % of the position closed at that point

input group "=== Risk & Sizing ==="
input bool   InpUseFixedLot    = false;            // Fixed lot instead of % risk
input double InpFixedLot       = 0.01;             // Fixed lot
input double InpRiskPercent    = 0.15;             // Base risk % of balance (used when HyperGrowth is OFF)
input double InpMaxNotionalX   = 15.0;             // Max notional (lots x contract x price, account ccy) as a multiple of EQUITY. 0 = off
input double InpMinLotRiskMult = 1.5;              // Reject if the MIN lot would risk more than this x the configured risk (0 = allow, v3.4 behaviour)
input bool   InpGrowthMode     = true;             // (funded shell) risk a fraction of drawdown headroom
input double InpHeadroomRiskPct= 10.0;             // GrowthMode: risk this % of (equity - floor) per trade
input double InpGrowthMaxRiskPct= 1.00;            // GrowthMode: hard cap, % of balance per trade

input group "=== SMC Exits - distances in ATR ==="
input bool   InpUseRunner      = true;             // Partial at TP1 + let a runner go
input double InpPartialPct     = 50.0;             // % closed at TP1 (first pool)
input double InpBE_LockATR     = 0.04;             // Locked at BE after TP1, x ATR (v3.4: $0.20 on gold = 0.04 ATR)
input double InpMinTP1_R       = 1.5;              // First pool must be >= this many R away
input int    InpLiqLookback    = 180;              // Bars scanned for target pools
input double InpStructTrailATR = 0.06;             // Structural trail buffer, x ATR (v3.4: $0.30 on gold = 0.06 ATR)
input double InpFallbackTP1_R  = 1.5;              // Fallback TP1 (R) when no pool ahead
input bool   InpUseLadder      = true;             // Liquidity-ladder stop (SL climbs pool rungs)
input int    InpMaxRungs       = 4;                // Max pool rungs in the ladder

input group "=== Side tunes ==="
input bool   InpLongHTFStrict  = true;             // Longs require a real HTF uptrend
input bool   InpLongUsePremDisc= true;             // Longs only in discount
input double InpLongDiscountPct= 0.50;             // How low in the range a long is allowed
input bool   InpShortHTFStrict = true;             // Shorts require an HTF downtrend
input bool   InpShortUsePremDisc= true;            // Shorts only in premium

input group "=== Shock guard (news / flash moves) ==="
input double InpSpikeRangeATR  = 3.0;              // A closed M5 bar with range >= this x ATR starts a pause (0 = off)
input int    InpSpikeCooldownBars = 6;             // ...for this many M5 bars: no new setups, resting limits cancelled

input group "=== Market gates (profile defaults; the profile file may override) ==="
input double InpMaxSpreadATR   = 0.25;             // Skip a NEW setup if spread > this x ATR
input double InpMaxSpreadRPct  = 15.0;             // ...or if spread > this % of THIS trade's R (stop too tight to pay for)
input int    InpMaxTradesDay   = 3;                // Max FILLS per day (per symbol)
input double InpDailyLossPct   = 2.0;              // Flatten + block for the day at this DD % (account equity)

input group "=== Account Risk Manager (all MIDAS magics) ==="
input bool   InpUseRiskMgr     = true;             // Refuse a new limit when the account-wide open risk would exceed the cap
input long   InpRiskMagicLo    = 580000;           // First magic counted as MIDAS
input long   InpRiskMagicHi    = 589999;           // Last magic counted as MIDAS
input double InpMaxOpenRiskPct = 4.0;              // Max total risk-to-stop of all open positions + resting limits, % of balance
input int    InpMaxOpenPositions = 4;              // Max positions + resting limits across all MIDAS magics (0 = off)

input group "=== Trade journal (CSV for Python / Agent) ==="
input bool   InpJournal        = true;             // Write one CSV row per closed trade
input string InpJournalDir     = "MIDAS";          // Subfolder of <Common>\Files
input bool   InpJournalTester  = true;             // Also write in the tester (file name gets _TEST and is reset each run)

input group "=== Funded-account shell (match YOUR firm) ==="
input bool   InpFundedMode     = false;            // Prop guardrails ON
input double InpFundedStartBal = 0;                // Funded starting balance (0 = auto-detect)
input double InpStaticFloorPct = 3.0;              // HALT this % below the initial balance
input double InpTrailingDDPct  = 0;                // HALT this % from the equity peak (0 = off)
input double InpMinMarginLevel = 200.0;            // Refuse/shrink a trade below this margin level %
input bool   InpFlattenOnHalt  = true;             // Close open trades on a hard halt
input bool   InpDeriskInDD     = true;             // Shrink risk near the floor (ignored when GrowthMode ON)
input double InpDeriskMinFactor= 0.35;             // Risk multiplier AT the floor
input int    InpMaxPositions   = 1;                // Max concurrent positions per symbol (pendings count as exposure)
input bool   InpResetState     = false;            // ON once to wipe saved day/floor state

input group "=== Dashboard ==="
input bool   InpShowPanel      = true;             // Top-right info panel
input bool   InpPanelBox       = false;            // Background box behind the panel
input int    InpPanelX         = 80;               // Right margin (px)
input int    InpPanelY         = 22;               // Top margin (px)

//==================================================================//
//  PART 2 - GLOBALS                                                 //
//==================================================================//
enum ENUM_CLOCK { CLOCK_NY7 = 0, CLOCK_UTC = 1, CLOCK_EU = 2 };   // NY+7 (day rolls 17:00 New York) | UTC | EU (CET/CEST, day rolls at local midnight)

// One profile per symbol: everything that depends on WHERE and WHEN the market trades.
struct SProfile
{
   string name;
   int    clock;                       // ENUM_CLOCK: the clock every hour below is read in (and the day rolls on)
   bool   useSession; int sessS, sessE;
   bool   blk1; int b1S, b1E;
   bool   blk2; int b2S, b2E;
   int    asiaS, asiaE;                // overnight / Asia window for the session pool
   bool   flatWeekend; int flatHour;   // Friday flatten hour on the profile clock
   int    maxTradesDay;
   double maxSpreadATR, maxSpreadRPct, maxSL_ATR;
   datetime haltFrom, haltUntil;       // UTC window in which NO new setups are made (set by the Agent around news); 0 = none
};
SProfile  g_p;
datetime  g_profStamp  = 0;             // modify time of the profile file last applied
bool      g_profFile   = false;         // an override file is active

MqlRates  g_m5[];               // M5 series, [0] = forming bar
MqlRates  g_htf[];              // HTF series
datetime  g_lastBarTime = 0;

int       g_m5Trend     = 0;    // M5 running bias (+1/-1/0)
int       g_lastBreakDir= 0;    // last M5 break direction
string    g_lastBreakTxt= "-";
int       g_htfTrend    = 0;    // HTF bias (+1/-1/0)
double    g_htfHigh     = 0, g_htfLow = 0;
double    g_m5High      = 0, g_m5Low  = 0;

long      g_dayKey      = 0;
double    g_dayStartEq  = 0;
double    g_fundedStart = 0;
double    g_equityPeak  = 0;
bool      g_hardHalt    = false;
int       g_tradesToday = 0;
bool      g_blockedToday= false;

double    g_point;
int       g_digits;
double    g_contract   = 1.0;    // contract size (read from the symbol)
int       g_srvGMT     = 0;      // resolved server->UTC offset in hours
ENUM_SRVCLOCK g_srvMode = SRV_FIXED;   // effective server-clock mode
int       g_dstYear    = 0;      // IsUSDST() cache
datetime  g_dstYrLo    = 0, g_dstYrHi = 0;
datetime  g_dstOn      = 0, g_dstOff  = 0;
int       g_euYear     = 0;      // IsEUDST() cache
datetime  g_euYrLo     = 0, g_euYrHi = 0;
datetime  g_euOn       = 0, g_euOff  = 0;
datetime  g_modBlockBar = 0;     // M5 bar of the last MARKET_CLOSED modify reply (0 = none)
int       g_atrHandle  = INVALID_HANDLE;
int       g_hEmaF = INVALID_HANDLE, g_hEmaS = INVALID_HANDLE, g_hAdx = INVALID_HANDLE, g_hEmaH = INVALID_HANDLE;   // pullback engine
int       g_pbLastBar = -999;
int       g_k = 1;               // bar scale (M1 = 5)
long      g_orbDay = -1;
int       g_orbCount = 0;
double    g_atr        = 0;      // ATR(14) on M5, in price units
int       g_minLotNotes = 0;     // log throttles
int       g_spikeUntilBar = 0;   // shock guard: new setups blocked while g_barCounter < this
int       g_fGrab=0, g_fMSS=0, g_fArm=0, g_fFill=0, g_fSpikes=0;   // funnel counters
string    g_dropWhy[40]; int g_dropN[40]; int g_nDrop=0;
int       g_rmNotes     = 0;

// per-direction runner tracking
ulong     g_tkLong=0,   g_tkShort=0;
double    g_riskLong=0, g_riskShort=0;
double    g_tp1Long=0,  g_tp1Short=0;
bool      g_doneLong=false, g_doneShort=false;
double    g_ladderL[12], g_ladderS[12];
int       g_nRungsL=0,  g_nRungsS=0;
int       g_reachedL=0, g_reachedS=0;

// ---- pool map (rebuilt from bars every M5 close - stateless by design) ----
struct SPool
{
   double price;      // the level
   int    idx;        // bar index where it formed
   int    hits;       // how many pivots merged into it
   int    kind;       // 0 pivot, 1 Asia/overnight range, 2 previous day
};
SPool  g_bsl[];       // buy-side pools (highs) - live only
SPool  g_ssl[];       // sell-side pools (lows) - live only
double g_bMaxTo[];    // running max BodyHi over bars 1..i-1 (pool invalidation, O(1))
double g_bMinTo[];    // running min BodyLo over bars 1..i-1

// ---- setup state machine (one live setup per side) ----
#define ST_NONE   0
#define ST_SWEPT  1
#define ST_ARMED  2
struct SSetup
{
   int    state;
   int    dir;           // +1 long, -1 short
   int    age;           // bars since the grab
   double poolPrice;     // the pool that got run
   int    poolKind;
   double sweepExt;      // extreme of the grab candle (the invalidation)
   double mssLevel;      // level a close must break to confirm
   double zoneLo, zoneHi;
   double entry, sl, riskDist;
   double lot, riskMoney, spread;   // journal inputs captured at arm time
   ulong  ticket;        // resting limit order
   string tag;
};
SSetup g_setL, g_setS;

// ---- trade journal (one open record per direction, like the runner tracking) ----
struct SJrn
{
   bool     on;
   long     posId;
   datetime tOpen;
   double   entry, sl0, riskDist, lot, riskMoney, atr, spread, mfe, mae;
   bool     tp1;
   int      htf;
   string   tag, volReg, trendReg;
   int      hour;
};
SJrn g_jL, g_jS;

// ---- risk-layer state ----
bool   g_floorHalt   = false;  // capital floor breached
int    g_ceilHits    = 0;      // times the notional cap overrode the risk setting
double g_startBal    = 0;      // actual starting balance - the ladder anchor
double g_peakBal     = 0;      // realized balance high-water (vault basis)
double g_vault       = 0;      // profit locked out of the sizing base
int    g_lossStreak  = 0;      // consecutive full-trade losses
bool   g_cutLong=false, g_cutShort=false;   // InpCutLossAtR already fired this trade
long   g_accId[8];             // per-position P&L accumulator (partial closes)
double g_accPnl[8];
int    g_lastGrabBarL = -999, g_lastGrabBarS = -999;
int    g_barCounter   = 0;      // monotonic M5 bar counter for cooldowns

string PFX = "midas4_";

//==================================================================//
//  PART 3 - INIT / DEINIT                                           //
//==================================================================//
void ClearSetup(SSetup &s)
{
   s.state=ST_NONE; s.dir=0; s.age=0; s.poolPrice=0; s.poolKind=0;
   s.sweepExt=0; s.mssLevel=0; s.zoneLo=0; s.zoneHi=0;
   s.entry=0; s.sl=0; s.riskDist=0; s.lot=0; s.riskMoney=0; s.spread=0;
   s.ticket=0; s.tag="";
}

void ClearJrn(SJrn &j)
{
   j.on=false; j.posId=0; j.tOpen=0; j.entry=0; j.sl0=0; j.riskDist=0; j.lot=0; j.riskMoney=0;
   j.atr=0; j.spread=0; j.mfe=0; j.mae=0; j.tp1=false; j.htf=0; j.tag=""; j.volReg=""; j.trendReg=""; j.hour=0;
}

int OnInit()
{
   g_point  = _Point;
   g_digits = _Digits;
   g_contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(g_contract <= 0) g_contract = 1.0;

   {
      int tfm = (int)(PeriodSeconds(PERIOD_CURRENT) / 60);
      g_k = (tfm > 0 && tfm < 5) ? 5 / tfm : 1;      // bars-per-M5: M1 -> 5, M5 and above -> 1 (scales the day-long look-backs)
      PrintFormat("MIDAS v4 base timeframe %s (bar scale x%d). Bar-count inputs are in BARS of this timeframe.", EnumToString((ENUM_TIMEFRAMES)Period()), g_k);
   }
   if(InpMagic < InpRiskMagicLo || InpMagic > InpRiskMagicHi)
      PrintFormat("MIDAS v4 WARNING: magic %I64d is outside the Risk Manager range [%I64d..%I64d] - this instance's risk will NOT be counted.",
                  InpMagic, InpRiskMagicLo, InpRiskMagicHi);

   ArraySetAsSeries(g_m5,  true);
   ArraySetAsSeries(g_htf, true);

   ClearSetup(g_setL); ClearSetup(g_setS);
   ClearJrn(g_jL); ClearJrn(g_jS);
   ArrayInitialize(g_accId, 0);
   ArrayInitialize(g_accPnl, 0.0);
   g_startBal = (InpFundedStartBal > 0) ? InpFundedStartBal : AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakBal  = AccountInfoDouble(ACCOUNT_BALANCE);

   {
      double liveBal = AccountInfoDouble(ACCOUNT_BALANCE);
      if(InpFundedStartBal > 0 && liveBal > 0 &&
         (InpFundedStartBal > liveBal*1.5 || InpFundedStartBal < liveBal*0.67))
         PrintFormat("MIDAS v4 WARNING: InpFundedStartBal=%.2f but the balance is %.2f. "
                     "The risk ladder anchors on that number - set it to the real starting "
                     "balance or leave it 0 to auto-detect.", InpFundedStartBal, liveBal);
   }

   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   if(g_atrHandle == INVALID_HANDLE){ Print("MIDAS v4: ATR handle failed"); return(INIT_FAILED); }

   if(InpEntryEngine == ENGINE_PULLBACK)
   {
      g_hEmaF = iMA(_Symbol, PERIOD_CURRENT, InpPbFast, 0, MODE_EMA, PRICE_CLOSE);
      g_hEmaS = iMA(_Symbol, PERIOD_CURRENT, InpPbSlow, 0, MODE_EMA, PRICE_CLOSE);
      g_hAdx  = iADX(_Symbol, PERIOD_CURRENT, 14);
      if(InpPbHTFEma > 0) g_hEmaH = iMA(_Symbol, PERIOD_H1, InpPbHTFEma, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hEmaF == INVALID_HANDLE || g_hEmaS == INVALID_HANDLE || g_hAdx == INVALID_HANDLE || (InpPbHTFEma > 0 && g_hEmaH == INVALID_HANDLE))
      { Print("MIDAS v4.2: pullback indicator handles failed"); return(INIT_FAILED); }
   }
   ResolveServerClock();
   LoadProfile(true);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   InitDayState();
   InitFundedState();

   PrintFormat("MIDAS v4 margin mode: %s -> partial closes via %s",
               MarginModeName(), (IsHedgingAccount() ? "PositionClosePartial()" : "opposite market deal"));

   if(InpLogNormalise)
   {
      PrintFormat("MIDAS v4 init | %s digits=%d point=%.5f contract=%.4f | server=%s UTC%+d | profile=%s clock=%s",
                  _Symbol, g_digits, g_point, g_contract, SrvModeName(), SrvOffsetNow(), g_p.name, ClockName());
      ClockSelfTest();
   }

   JournalInit();
   WriteStatus("init");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, PFX);
   Comment("");
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   PrintFunnel();
   WriteStatus("deinit");
}

// How server time becomes UTC. FIXED = InpServerGMT. AUTO live = measured from the
// terminal (re-measured across DST); AUTO in the tester cannot measure anything
// (TimeGMT()==TimeTradeServer()) so it uses InpServerGMT, NOT the MetaQuotes guess.
void ResolveServerClock()
{
   bool tester = (MQLInfoInteger(MQL_TESTER) != 0);
   g_srvMode = InpServerClock;
   if(g_srvMode == SRV_NYCLOSE) return;
   if(g_srvMode == SRV_AUTO)
   {
      if(tester)
      {
         g_srvMode = SRV_FIXED;
         g_srvGMT  = (InpServerGMT == 99) ? 0 : InpServerGMT;
         PrintFormat("MIDAS v4 NOTE: InpServerClock=AUTO cannot measure the server offset in the tester - using FIXED UTC%+d (InpServerGMT). "
                     "Exness = 0, MetaQuotes/most props = SRV_NYCLOSE.", g_srvGMT);
         return;
      }
      g_srvMode = SRV_FIXED;
      g_srvGMT = (int)MathRound((double)((long)TimeTradeServer() - (long)TimeGMT()) / 3600.0);
      return;
   }
   // SRV_FIXED
   if(InpServerGMT != 99){ g_srvGMT = InpServerGMT; return; }
   if(tester){ g_srvGMT = 0; Print("MIDAS v4 WARNING: InpServerGMT=99 has no meaning in the tester - assuming UTC+0."); return; }
   g_srvGMT = (int)MathRound((double)((long)TimeTradeServer() - (long)TimeGMT()) / 3600.0);
}

bool ServerClockIsMeasured()
{
   if(MQLInfoInteger(MQL_TESTER)) return false;
   return (InpServerClock == SRV_AUTO) || (InpServerClock == SRV_FIXED && InpServerGMT == 99);
}

bool IsHedgingAccount()
{
   return ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

string MarginModeName()
{
   ENUM_ACCOUNT_MARGIN_MODE mm = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(mm == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) return "HEDGING";
   if(mm == ACCOUNT_MARGIN_MODE_EXCHANGE)       return "EXCHANGE";
   return "NETTING";
}

//==================================================================//
//  PART 4 - PRICE / TIME ACCESSORS                                  //
//==================================================================//
double H(const MqlRates &r[], int i){ return r[i].high;  }
double L(const MqlRates &r[], int i){ return r[i].low;   }
double C(const MqlRates &r[], int i){ return r[i].close; }
double O(const MqlRates &r[], int i){ return r[i].open;  }
double BodyHi(const MqlRates &r[], int i){ return MathMax(r[i].open, r[i].close); }
double BodyLo(const MqlRates &r[], int i){ return MathMin(r[i].open, r[i].close); }

//------------------------------------------------------------------//
//  MARKET CLOCK                                                      //
//  server time --ServerToUTC()--> UTC --> the PROFILE's clock.       //
//  NY7 = New York + 7 (UTC+2, UTC+3 in US DST): day rolls 17:00 NY.  //
//  EU  = CET/CEST (UTC+1, UTC+2 in EU DST): day rolls at midnight.   //
//  UTC = plain UTC (crypto).                                         //
//------------------------------------------------------------------//
// The nth Sunday of year/mon at hourUTC, as a UTC datetime.
datetime NthSundayUTC(int year, int mon, int nth, int hourUTC)
{
   MqlDateTime d;
   d.year = year; d.mon = mon; d.day = 1; d.hour = 0; d.min = 0; d.sec = 0;
   d.day_of_week = 0; d.day_of_year = 0;
   MqlDateTime f;
   TimeToStruct(StructToTime(d), f);                  // f.day_of_week: 0 = Sunday
   d.day  = 1 + (7 - f.day_of_week) % 7 + 7*(nth - 1);
   d.hour = hourUTC;
   return StructToTime(d);
}

// US DST: 2nd Sunday of March 07:00 UTC (02:00 EST) until the 1st Sunday of
// November 06:00 UTC (02:00 EDT). The window is cached per year because this is
// called several times per tick.
bool IsUSDST(datetime utc)
{
   if(g_dstYear == 0 || utc < g_dstYrLo || utc >= g_dstYrHi)
   {
      MqlDateTime d; TimeToStruct(utc, d);
      MqlDateTime j;
      j.year = d.year; j.mon = 1; j.day = 1; j.hour = 0; j.min = 0; j.sec = 0;
      j.day_of_week = 0; j.day_of_year = 0;
      g_dstYrLo = StructToTime(j);
      j.year    = d.year + 1;
      g_dstYrHi = StructToTime(j);
      g_dstOn   = NthSundayUTC(d.year, 3, 2, 7);
      g_dstOff  = NthSundayUTC(d.year, 11, 1, 6);
      g_dstYear = d.year;
   }
   return (utc >= g_dstOn && utc < g_dstOff);
}

// Last Sunday of a 31-day month (March / October) at hourUTC.
datetime LastSundayUTC(int year, int mon, int hourUTC)
{
   MqlDateTime d;
   d.year = year; d.mon = mon; d.day = 31; d.hour = 0; d.min = 0; d.sec = 0;
   d.day_of_week = 0; d.day_of_year = 0;
   MqlDateTime f;
   TimeToStruct(StructToTime(d), f);                  // f.day_of_week: 0 = Sunday
   d.day  = 31 - f.day_of_week;
   d.hour = hourUTC;
   return StructToTime(d);
}

// EU DST: last Sunday of March 01:00 UTC until the last Sunday of October 01:00 UTC.
bool IsEUDST(datetime utc)
{
   if(g_euYear == 0 || utc < g_euYrLo || utc >= g_euYrHi)
   {
      MqlDateTime d; TimeToStruct(utc, d);
      MqlDateTime j;
      j.year = d.year; j.mon = 1; j.day = 1; j.hour = 0; j.min = 0; j.sec = 0;
      j.day_of_week = 0; j.day_of_year = 0;
      g_euYrLo = StructToTime(j);
      j.year   = d.year + 1;
      g_euYrHi = StructToTime(j);
      g_euOn   = LastSundayUTC(d.year, 3, 1);
      g_euOff  = LastSundayUTC(d.year, 10, 1);
      g_euYear = d.year;
   }
   return (utc >= g_euOn && utc < g_euOff);
}

datetime SrvToUTCMode(datetime srv, ENUM_SRVCLOCK mode, int fixedOff)
{
   if(mode == SRV_NYCLOSE)
   {
      int off = IsUSDST((datetime)((long)srv - 7200)) ? 3 : 2;
      return (datetime)((long)srv - (long)off*3600);
   }
   return (datetime)((long)srv - (long)fixedOff*3600);
}
datetime UTCToClockMode(datetime utc, int clk)
{
   if(clk == CLOCK_UTC) return utc;
   if(clk == CLOCK_EU)  return (datetime)((long)utc + (long)(IsEUDST(utc) ? 2 : 1)*3600);
   return (datetime)((long)utc + (long)(IsUSDST(utc) ? 3 : 2)*3600);     // NY7
}

datetime ServerToUTC(datetime srv){ return SrvToUTCMode(srv, g_srvMode, g_srvGMT); }
datetime ToClock(datetime srv)    { return UTCToClockMode(ServerToUTC(srv), g_p.clock); }
int      ClockHour(datetime srv){ MqlDateTime d; TimeToStruct(ToClock(srv), d); return d.hour; }
long     ClockDayKey(datetime srv)
{
   MqlDateTime d; TimeToStruct(ToClock(srv), d);
   return (long)d.year*10000 + (long)d.mon*100 + (long)d.day;
}

int    SrvOffsetNow(){ datetime s = TimeCurrent(); return (int)(((long)s - (long)ServerToUTC(s)) / 3600); }
string ClockNameOf(int c){ return (c == CLOCK_NY7) ? "NY+7" : (c == CLOCK_EU ? "EU" : "UTC"); }
string ClockName()   { return ClockNameOf(g_p.clock); }
string SrvModeName()
{
   if(g_srvMode == SRV_NYCLOSE) return "NYCLOSE";
   if(g_srvMode == SRV_AUTO)    return "AUTO";
   return "FIXED";
}

void ClockSelfTest()
{
   datetime srv[6] = { D'2024.01.15 10:00', D'2024.07.15 10:00',
                       D'2024.03.10 08:00', D'2024.03.10 10:00',
                       D'2024.11.03 07:00', D'2024.11.03 10:00' };
   datetime exU[6] = { D'2024.01.15 08:00', D'2024.07.15 07:00',
                       D'2024.03.10 06:00', D'2024.03.10 07:00',
                       D'2024.11.03 04:00', D'2024.11.03 08:00' };
   int fails = 0;
   for(int i=0;i<6;i++)
   {
      datetime u = SrvToUTCMode(srv[i], SRV_NYCLOSE, 0);
      datetime c = UTCToClockMode(u, CLOCK_NY7);
      if(!(u == exU[i] && c == srv[i])) fails++;
   }
   bool e1 = !IsUSDST(D'2024.03.10 06:59') &&  IsUSDST(D'2024.03.10 07:00');
   bool e2 =  IsUSDST(D'2024.11.03 05:59') && !IsUSDST(D'2024.11.03 06:00');
   bool e3 = !IsEUDST(D'2024.03.31 00:59') &&  IsEUDST(D'2024.03.31 01:00');
   bool e4 =  IsEUDST(D'2024.10.27 00:59') && !IsEUDST(D'2024.10.27 01:00');
   bool eu = (UTCToClockMode(D'2024.01.15 08:00', CLOCK_EU) == D'2024.01.15 09:00') &&
             (UTCToClockMode(D'2024.07.15 08:00', CLOCK_EU) == D'2024.07.15 10:00');
   if(!e1) fails++; if(!e2) fails++; if(!e3) fails++; if(!e4) fails++; if(!eu) fails++;
   PrintFormat("CLOCK TEST %s (%d failure%s) | US DST edges %s/%s | EU DST edges %s/%s",
               (fails==0 ? "PASSED" : "FAILED"), fails, (fails==1 ? "" : "s"),
               (e1?"OK":"FAIL"), (e2?"OK":"FAIL"), (e3?"OK":"FAIL"), (e4?"OK":"FAIL"));
   datetime now = TimeCurrent();
   PrintFormat("CLOCK active: server=%s clock=%s | srv %s -> UTC %s -> %s %s",
               SrvModeName(), ClockName(), TimeToString(now, TIME_DATE|TIME_MINUTES),
               TimeToString(ServerToUTC(now), TIME_DATE|TIME_MINUTES),
               ClockName(), TimeToString(ToClock(now), TIME_DATE|TIME_MINUTES));
}

//==================================================================//
//  PART 4b - ASSET PROFILES                                         //
//==================================================================//
// A profile answers "WHEN does this market trade and what does a bad moment look
// like". It is the gate through which Python / the Agent changes behaviour later:
// they write MIDAS\profile_<SYMBOL>.ini, never the EA inputs.
//   SAFE keys only: clock, sessions, blackouts, overnight window, weekend flatten,
//   max trades/day, spread gates, max stop width. Risk %, floors, magic, engine
//   logic are CRITICAL and cannot be set from the file. Every value is clamped.
string ProfName(int p)
{
   switch(p)
   {
      case PROF_GOLD:     return "GOLD";
      case PROF_SILVER:   return "SILVER";
      case PROF_FX:       return "FX";
      case PROF_INDEX_US: return "INDEX_US";
      case PROF_INDEX_EU: return "INDEX_EU";
      case PROF_OIL:      return "OIL";
      case PROF_CRYPTO:   return "CRYPTO";
   }
   return "AUTO";
}

int ProfFromName(string s)
{
   StringToUpper(s); StringTrimLeft(s); StringTrimRight(s);
   for(int p=PROF_GOLD; p<=PROF_CRYPTO; p++) if(ProfName(p) == s) return p;
   return -1;
}

bool Has(const string &s, string key){ return StringFind(s, key) >= 0; }

bool IsFxPair(const string &s)
{
   if(StringLen(s) < 6) return false;
   string ccy[] = {"USD","EUR","GBP","JPY","CHF","AUD","NZD","CAD","SGD","HKD","SEK","NOK","DKK","PLN","CZK","HUF","TRY","ZAR","MXN"};
   string a = StringSubstr(s,0,3), b = StringSubstr(s,3,3);
   bool ha=false, hb=false;
   for(int i=0;i<ArraySize(ccy);i++){ if(ccy[i]==a) ha=true; if(ccy[i]==b) hb=true; }
   return ha && hb;
}

int DetectProfile()
{
   string s = _Symbol;  StringToUpper(s);
   string path = SymbolInfoString(_Symbol, SYMBOL_PATH); StringToUpper(path);
   if(Has(s,"XAU") || Has(s,"GOLD"))                                         return PROF_GOLD;
   if(Has(s,"XAG") || Has(s,"SILVER") || Has(s,"XPT") || Has(s,"XPD"))       return PROF_SILVER;
   if(Has(s,"USTEC") || Has(s,"US500") || Has(s,"US30") || Has(s,"NAS") || Has(s,"NDX") ||
      Has(s,"SPX")   || Has(s,"US100") || Has(s,"DJI")  || Has(s,"WS30"))    return PROF_INDEX_US;
   if(Has(s,"DE30") || Has(s,"DE40") || Has(s,"GER") || Has(s,"DAX") || Has(s,"UK100") ||
      Has(s,"FR40") || Has(s,"STOXX") || Has(s,"EU50") || Has(s,"ES35"))     return PROF_INDEX_EU;
   if(Has(s,"OIL") || Has(s,"WTI") || Has(s,"BRENT") || Has(s,"XTI") || Has(s,"XBR")) return PROF_OIL;
   if(Has(s,"BTC") || Has(s,"ETH") || Has(s,"LTC") || Has(s,"XRP") || Has(s,"SOL") ||
      Has(s,"DOGE")|| Has(s,"BNB") || Has(s,"ADA"))                          return PROF_CRYPTO;
   if(Has(path,"CRYPTO"))                                                    return PROF_CRYPTO;
   if(Has(path,"METAL"))                                                     return PROF_GOLD;
   if(Has(path,"ENERG"))                                                     return PROF_OIL;
   if(Has(path,"INDIC") || Has(path,"INDEX"))                                return PROF_INDEX_US;
   if(IsFxPair(s) || Has(path,"FOREX") || Has(path,"MAJOR") || Has(path,"MINOR")) return PROF_FX;
   return -1;
}

// Built-in presets. Hours are on the profile's own clock. These are STARTING
// HYPOTHESES to be confirmed by the per-symbol / per-regime journal, not facts.
void PresetProfile(int prof)
{
   // gold-like base (this is exactly v3.4's gold schedule on NY+7)
   g_p.name = ProfName(prof);
   g_p.clock = CLOCK_NY7;
   g_p.useSession = true; g_p.sessS = 7;  g_p.sessE = 21;
   g_p.blk1 = true;  g_p.b1S = 16; g_p.b1E = 18;       // NY 09:00-11:00 (open + US data)
   g_p.blk2 = true;  g_p.b2S = 19; g_p.b2E = 20;       // NY 12:00-13:00
   g_p.asiaS = 0;    g_p.asiaE = 7;
   g_p.flatWeekend = true; g_p.flatHour = 19;
   g_p.haltFrom = 0; g_p.haltUntil = 0;
   g_p.maxTradesDay = InpMaxTradesDay;
   g_p.maxSpreadATR = InpMaxSpreadATR; g_p.maxSpreadRPct = InpMaxSpreadRPct; g_p.maxSL_ATR = InpMaxSL_ATR;

   switch(prof)
   {
      case PROF_INDEX_US:        // NY cash session 09:00-16:00 NY = 16-23 on NY+7; overnight range = 17:00 -> 09:00 NY
         g_p.sessS = 16; g_p.sessE = 23;
         g_p.blk1 = false; g_p.blk2 = false;               // no blackout until the journal says the open bleeds
         g_p.asiaS = 0;  g_p.asiaE = 16;
         g_p.flatHour = 22;                                // Fri 15:00 NY
         break;
      case PROF_INDEX_EU:        // Frankfurt/London on the EU clock
         g_p.clock = CLOCK_EU;
         g_p.sessS = 9;  g_p.sessE = 17;
         g_p.blk1 = true; g_p.b1S = 14; g_p.b1E = 15;      // 14:30 CET US data
         g_p.blk2 = false;
         g_p.asiaS = 0;  g_p.asiaE = 9;
         g_p.flatHour = 16;
         break;
      case PROF_OIL:             // NYMEX pit hours 08:00-15:00 NY = 15-22 on NY+7
         g_p.sessS = 15; g_p.sessE = 22;
         g_p.blk1 = true; g_p.b1S = 17; g_p.b1E = 18;      // 10:00-11:00 NY (inventory / data)
         g_p.blk2 = false;
         g_p.asiaS = 0;  g_p.asiaE = 15;
         g_p.flatHour = 22;
         break;
      case PROF_CRYPTO:          // 24/7: no session, no blackout, no weekend flatten, UTC day
         g_p.clock = CLOCK_UTC;
         g_p.useSession = false; g_p.sessS = 0; g_p.sessE = 24;
         g_p.blk1 = false; g_p.blk2 = false;
         g_p.asiaS = 0;  g_p.asiaE = 7;
         g_p.flatWeekend = false;
         break;
      default: break;            // GOLD / SILVER / FX keep the gold schedule
   }
}

int ClampI(int v, int lo, int hi){ return (v < lo) ? lo : ((v > hi) ? hi : v); }
double ClampD(double v, double lo, double hi){ return (v < lo) ? lo : ((v > hi) ? hi : v); }

// "16-18" -> on, a, b.  "off" -> off.
bool ParseHours(string v, bool &on, int &a, int &b)
{
   StringTrimLeft(v); StringTrimRight(v); StringToLower(v);
   if(v == "off" || v == "none" || v == "") { on = false; return true; }
   int p = StringFind(v, "-");
   if(p < 1) return false;
   a = ClampI((int)StringToInteger(StringSubstr(v, 0, p)), 0, 24);
   b = ClampI((int)StringToInteger(StringSubstr(v, p+1)),  0, 24);
   on = true;
   return true;
}

string ProfilePath()
{
   return (InpProfileFile != "") ? InpProfileFile : ("MIDAS\\profile_" + _Symbol + ".ini");
}

// Returns true when a file was found and applied. Unknown keys are reported, not fatal.
bool ApplyProfileFile()
{
   string path = ProfilePath();
   if(!FileIsExist(path, FILE_COMMON)) return false;
   int h = FileOpen(path, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE){ PrintFormat("PROFILE file %s exists but cannot be opened (err %d)", path, GetLastError()); return false; }
   string keys[], vals[]; int n = 0;
   while(!FileIsEnding(h))
   {
      string ln = FileReadString(h);
      StringTrimLeft(ln); StringTrimRight(ln);
      if(ln == "" || StringGetCharacter(ln,0) == '#' || StringGetCharacter(ln,0) == ';') continue;
      int e = StringFind(ln, "=");
      if(e < 1) continue;
      string k = StringSubstr(ln, 0, e), v = StringSubstr(ln, e+1);
      StringTrimLeft(k); StringTrimRight(k); StringToLower(k);
      StringTrimLeft(v); StringTrimRight(v);
      ArrayResize(keys, n+1); ArrayResize(vals, n+1); keys[n] = k; vals[n] = v; n++;
   }
   g_profStamp = (datetime)FileGetInteger(h, FILE_MODIFY_DATE);
   FileClose(h);

   // 1st pass: an explicit base preset.
   for(int i=0;i<n;i++)
      if(keys[i] == "profile")
      {
         int p = ProfFromName(vals[i]);
         if(p > 0) PresetProfile(p); else PrintFormat("PROFILE file: unknown profile '%s' ignored", vals[i]);
      }
   // 2nd pass: overrides.
   for(int i=0;i<n;i++)
   {
      string k = keys[i], v = vals[i]; bool on = false; int a = 0, b = 0;
      if(k == "profile") continue;
      else if(k == "clock")
      {
         string u = v; StringToUpper(u);
         if(u == "NY7" || u == "NY+7") g_p.clock = CLOCK_NY7;
         else if(u == "UTC")           g_p.clock = CLOCK_UTC;
         else if(u == "EU")            g_p.clock = CLOCK_EU;
         else PrintFormat("PROFILE file: bad clock '%s'", v);
      }
      else if(k == "use_session")        g_p.useSession = ((int)StringToInteger(v) != 0);
      else if(k == "session")            { if(ParseHours(v, on, a, b)){ if(on){ g_p.useSession = true; g_p.sessS = a; g_p.sessE = b; } else g_p.useSession = false; } }
      else if(k == "blackout1")          { if(ParseHours(v, on, a, b)){ g_p.blk1 = on; if(on){ g_p.b1S = a; g_p.b1E = b; } } }
      else if(k == "blackout2")          { if(ParseHours(v, on, a, b)){ g_p.blk2 = on; if(on){ g_p.b2S = a; g_p.b2E = b; } } }
      else if(k == "asia")               { if(ParseHours(v, on, a, b) && on){ g_p.asiaS = a; g_p.asiaE = b; } }
      else if(k == "weekend_flat")       g_p.flatWeekend = ((int)StringToInteger(v) != 0);
      else if(k == "weekend_flat_hour")  g_p.flatHour = ClampI((int)StringToInteger(v), 0, 23);
      else if(k == "max_trades_day")     g_p.maxTradesDay = ClampI((int)StringToInteger(v), 1, 20);
      else if(k == "max_spread_atr")     g_p.maxSpreadATR  = ClampD(StringToDouble(v), 0.05, 1.0);
      else if(k == "max_spread_r_pct")   g_p.maxSpreadRPct = ClampD(StringToDouble(v), 3.0, 50.0);
      else if(k == "max_sl_atr")         g_p.maxSL_ATR     = ClampD(StringToDouble(v), 0.8, 4.0);
      else if(k == "halt_from_utc" || k == "halt_until_utc")
      {
         string t = v; StringReplace(t, "-", "."); datetime dt = StringToTime(t);
         if(dt > 0){ if(k == "halt_from_utc") g_p.haltFrom = dt; else g_p.haltUntil = dt; }
      }
      else PrintFormat("PROFILE file: key '%s' is not an allowed (safe) key - ignored", k);
   }
   // The halt window can only STOP trading, and only briefly: <= 6 h long and starting no later than 12 h ahead.
   if(g_p.haltUntil > 0)
   {
      datetime nowU = ServerToUTC(TimeCurrent());
      if(g_p.haltFrom <= 0 || g_p.haltUntil <= g_p.haltFrom || (g_p.haltUntil - g_p.haltFrom) > 6*3600 || g_p.haltFrom > nowU + 12*3600 || g_p.haltUntil < nowU)
      { g_p.haltFrom = 0; g_p.haltUntil = 0; }
   }
   return true;
}

string ProfileDesc()
{
   return StringFormat("%s clock=%s sess=%s%d-%d blk1=%s blk2=%s asia=%d-%d wkndFlat=%s@%d maxTr=%d spr=%.2fATR/%.0f%%R maxSL=%.2fATR halt=%s%s",
          g_p.name, ClockName(), (g_p.useSession ? "" : "off:"), g_p.sessS, g_p.sessE,
          (g_p.blk1 ? StringFormat("%d-%d", g_p.b1S, g_p.b1E) : "off"),
          (g_p.blk2 ? StringFormat("%d-%d", g_p.b2S, g_p.b2E) : "off"),
          g_p.asiaS, g_p.asiaE, (g_p.flatWeekend ? "on" : "off"), g_p.flatHour, g_p.maxTradesDay,
          g_p.maxSpreadATR, g_p.maxSpreadRPct, g_p.maxSL_ATR,
          (g_p.haltUntil > 0 ? TimeToString(g_p.haltFrom, TIME_DATE|TIME_MINUTES) + ">" + TimeToString(g_p.haltUntil, TIME_DATE|TIME_MINUTES) : "-"),
          (g_profFile ? " [file]" : ""));
}

void LoadProfile(bool initial)
{
   int base = (InpProfile == PROF_AUTO) ? DetectProfile() : (int)InpProfile;
   if(base < 0)
   {
      base = PROF_GOLD;
      PrintFormat("MIDAS v4 WARNING: %s matches no profile - using the GOLD schedule. Set InpProfile or write MIDAS\\profile_%s.ini.", _Symbol, _Symbol);
   }
   PresetProfile(base);
   g_profFile = false;
   if(InpUseProfileFile) g_profFile = ApplyProfileFile();
   if(initial || g_profFile) PrintFormat("PROFILE %s", ProfileDesc());
}

// Live: pick up a changed override file at a bar boundary (never mid-bar).
void ReloadProfileIfChanged()
{
   if(!InpUseProfileFile || MQLInfoInteger(MQL_TESTER)) return;
   if(InpProfileReloadBars <= 0 || (g_barCounter % InpProfileReloadBars) != 0) return;
   string path = ProfilePath();
   if(!FileIsExist(path, FILE_COMMON))
   {
      if(g_profFile){ LoadProfile(false); WriteStatus("profile_removed"); }
      return;
   }
   datetime mt = (datetime)FileGetInteger(path, FILE_MODIFY_DATE, true);
   if(mt != g_profStamp)
   {
      LoadProfile(false);
      WriteStatus("profile_applied");
   }
}


bool IsNewBar()
{
   datetime t = (datetime)iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != g_lastBarTime){ g_lastBarTime = t; return true; }
   return false;
}

bool RefreshATR()
{
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) < 1) return false;
   if(buf[0] <= 0) return false;
   g_atr = buf[0];
   return true;
}

int CountMyPositions()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(PositionSelectByTicket(tk))
         if(PositionGetInteger(POSITION_MAGIC)==InpMagic &&
            PositionGetString(POSITION_SYMBOL)==_Symbol) n++;
   }
   return n;
}

int CountMyPendings()
{
   int n = 0;
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk>0 && OrderGetInteger(ORDER_MAGIC)==InpMagic &&
         OrderGetString(ORDER_SYMBOL)==_Symbol) n++;
   }
   return n;
}

ulong GetPosByType(ENUM_POSITION_TYPE pt)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(PositionSelectByTicket(tk))
         if(PositionGetInteger(POSITION_MAGIC)==InpMagic &&
            PositionGetString(POSITION_SYMBOL)==_Symbol &&
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==pt) return tk;
   }
   return 0;
}
bool HasLong(){  return GetPosByType(POSITION_TYPE_BUY)  > 0; }
bool HasShort(){ return GetPosByType(POSITION_TYPE_SELL) > 0; }

//==================================================================//
//  PART 5 - DAY / SESSION / SPREAD                                  //
//==================================================================//
string GVN(string s){ return "MIDAS4_" + (string)AccountInfoInteger(ACCOUNT_LOGIN) + "_" + (string)InpMagic + "_" + _Symbol + "_" + s; }

void StoreDayState()
{
   GlobalVariableSet(GVN("dayKey"),  (double)g_dayKey);
   GlobalVariableSet(GVN("dayEq"),   g_dayStartEq);
   GlobalVariableSet(GVN("trades"),  (double)g_tradesToday);
   GlobalVariableSet(GVN("blocked"), g_blockedToday ? 1.0 : 0.0);
}

// The trading day rolls at midnight of InpClock (NY+7 = 17:00 New York) so both
// brokers roll together.
long TodayKey(){ return ClockDayKey(TimeCurrent()); }

void StartNewDay(long key)
{
   g_dayKey       = key;
   g_dayStartEq   = AccountInfoDouble(ACCOUNT_EQUITY);
   g_tradesToday  = 0;
   g_blockedToday = false;
   StoreDayState();
}

void RecordTrade(){ g_tradesToday++; StoreDayState(); }

void InitDayState()
{
   long key = TodayKey();
   bool restore = !MQLInfoInteger(MQL_TESTER)
               && !InpResetState
               && GlobalVariableCheck(GVN("dayKey"))
               && (long)GlobalVariableGet(GVN("dayKey")) == key;
   if(restore)
   {
      g_dayKey       = key;
      g_dayStartEq   = GlobalVariableGet(GVN("dayEq"));
      g_tradesToday  = (int)GlobalVariableGet(GVN("trades"));
      g_blockedToday = (GlobalVariableGet(GVN("blocked")) > 0.5);
      if(g_dayStartEq <= 0) g_dayStartEq = AccountInfoDouble(ACCOUNT_EQUITY);
      int openNow = CountMyPositions();
      if(g_tradesToday < openNow) g_tradesToday = openNow;
   }
   else
      StartNewDay(key);
}

void InitFundedState()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(InpResetState)
   {
      GlobalVariableDel(GVN("fStart"));
      GlobalVariableDel(GVN("ePeak"));
   }
   if(InpFundedStartBal > 0)
      g_fundedStart = InpFundedStartBal;
   else if(!MQLInfoInteger(MQL_TESTER) && !InpResetState && GlobalVariableCheck(GVN("fStart")))
      g_fundedStart = GlobalVariableGet(GVN("fStart"));

   if(g_fundedStart <= 0 || (bal > 0 && g_fundedStart > bal*1.5))
      g_fundedStart = (InpFundedStartBal > 0) ? InpFundedStartBal : bal;
   GlobalVariableSet(GVN("fStart"), g_fundedStart);

   if(!MQLInfoInteger(MQL_TESTER) && !InpResetState && GlobalVariableCheck(GVN("ePeak")))
      g_equityPeak = GlobalVariableGet(GVN("ePeak"));
   if(g_equityPeak < g_fundedStart) g_equityPeak = g_fundedStart;
   GlobalVariableSet(GVN("ePeak"), g_equityPeak);
}

void ResetDayIfNeeded()
{
   if(TodayKey() != g_dayKey)
   {
      StartNewDay(TodayKey());
      if(ServerClockIsMeasured()) ResolveServerClock();  // re-detect across DST
   }
}

bool InWindow(int h,int a,int b){ if(a<=b) return (h>=a && h<b); return (h>=a || h<b); }

bool SessionOK()
{
   if(!g_p.useSession) return true;
   return InWindow(ClockHour(TimeCurrent()), g_p.sessS, g_p.sessE);
}

// Shock guard + Agent halt window count as blackout: they cancel resting setups and block new ones.
bool HaltNow()
{
   if(g_p.haltUntil <= 0) return false;
   datetime u = ServerToUTC(TimeCurrent());
   return (u >= g_p.haltFrom && u < g_p.haltUntil);
}
bool SpikeNow(){ return g_barCounter < g_spikeUntilBar; }

bool BlackoutNow()
{
   if(HaltNow() || SpikeNow()) return true;
   int h = ClockHour(TimeCurrent());
   if(g_p.blk1 && InWindow(h, g_p.b1S, g_p.b1E)) return true;
   if(g_p.blk2 && InWindow(h, g_p.b2S, g_p.b2E)) return true;
   return false;
}

// Market-level gate: the spread against the volatility of the moment. It is
// broker-neutral (ATR units) and only blocks NEW arms - a resting setup is never
// cancelled for spread, so two accounts cannot drop different trades.
// The trade-level gate (spread as a % of THIS trade's R) lives in ArmSetup.
bool SpreadOK()
{
   double spr = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(spr <= 0) return true;
   if(g_p.maxSpreadATR > 0 && g_atr > 0 && spr > g_p.maxSpreadATR*g_atr) return false;
   return true;
}

void FlattenAll()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(PositionSelectByTicket(tk))
         if(PositionGetInteger(POSITION_MAGIC)==InpMagic && PositionGetString(POSITION_SYMBOL)==_Symbol)
            trade.PositionClose(tk);
   }
}

void CancelAllPendings()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong tk=OrderGetTicket(i);
      if(tk>0 && OrderGetInteger(ORDER_MAGIC)==InpMagic && OrderGetString(ORDER_SYMBOL)==_Symbol)
         trade.OrderDelete(tk);
   }
   ClearSetup(g_setL); ClearSetup(g_setS);
}

void UpdateFundedState()
{
   if(!InpFundedMode) return;
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(g_fundedStart <= 0){ g_fundedStart = (InpFundedStartBal>0) ? InpFundedStartBal : bal; GlobalVariableSet(GVN("fStart"), g_fundedStart); }
   if(g_equityPeak  < g_fundedStart) g_equityPeak = g_fundedStart;
   if(eq > g_equityPeak){ g_equityPeak = eq; GlobalVariableSet(GVN("ePeak"), g_equityPeak); }

   bool breach = false;
   if(InpStaticFloorPct>0 && eq <= g_fundedStart*(1.0 - InpStaticFloorPct/100.0)) breach = true;
   if(InpTrailingDDPct >0 && g_equityPeak>0 && eq <= g_equityPeak*(1.0 - InpTrailingDDPct/100.0)) breach = true;
   if(breach && !g_hardHalt)
   {
      g_hardHalt = true;
      CancelAllPendings();
      if(InpFlattenOnHalt) FlattenAll();
      Print("FUNDED HARD HALT: drawdown rule breached - trading stopped for this run.");
   }

   double dayDD = (g_dayStartEq>0) ? (g_dayStartEq-eq)/g_dayStartEq*100.0 : 0.0;
   if(InpDailyLossPct>0 && dayDD >= InpDailyLossPct && !g_blockedToday)
   {
      g_blockedToday = true;
      StoreDayState();
      CancelAllPendings();
      if(InpFlattenOnHalt) FlattenAll();
   }
}

bool MarginOK(bool isLong, double lot, double price)
{
   if(!InpFundedMode || InpMinMarginLevel<=0 || lot<=0) return true;
   double mreq=0;
   ENUM_ORDER_TYPE ot = isLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcMargin(ot, _Symbol, lot, price, mreq)) return true;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double proj = AccountInfoDouble(ACCOUNT_MARGIN) + mreq;
   double level = (proj>0) ? eq/proj*100.0 : 1e9;
   return level >= InpMinMarginLevel;
}

bool DailyLimitsOK()
{
   if(g_blockedToday) return false;
   if(g_tradesToday >= g_p.maxTradesDay) return false;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (g_dayStartEq>0) ? (g_dayStartEq-eq)/g_dayStartEq*100.0 : 0.0;
   if(dd >= InpDailyLossPct){ g_blockedToday = true; StoreDayState(); return false; }
   return true;
}

//==================================================================//
//  PART 5b - ACCOUNT RISK MANAGER                                   //
//==================================================================//
// Open risk = what the account loses if every MIDAS stop is hit right now:
// each position to its CURRENT stop (a stop at/over breakeven = 0) plus every
// resting limit to its stop. Counted over every magic in [Lo..Hi], on every
// symbol, so ten instances cannot quietly add up to a blown account.
bool IsMidasMagic(long m){ return (m >= InpRiskMagicLo && m <= InpRiskMagicHi); }

double RiskToStop(string sym, bool isLong, double vol, double open, double sl)
{
   if(sl <= 0 || vol <= 0 || open <= 0) return 0.0;
   if(isLong  && sl >= open) return 0.0;
   if(!isLong && sl <= open) return 0.0;
   double p = 0.0;
   if(!OrderCalcProfit(isLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, vol, open, sl, p)) return 0.0;
   return MathAbs(p);
}

double OpenRiskAll(int &n)
{
   double tot = 0.0; n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(!IsMidasMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      n++;
      bool isLong = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      tot += RiskToStop(PositionGetString(POSITION_SYMBOL), isLong, PositionGetDouble(POSITION_VOLUME),
                        PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL));
   }
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(!IsMidasMagic(OrderGetInteger(ORDER_MAGIC))) continue;
      ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool bl = (t == ORDER_TYPE_BUY_LIMIT  || t == ORDER_TYPE_BUY_STOP  || t == ORDER_TYPE_BUY_STOP_LIMIT);
      bool sh = (t == ORDER_TYPE_SELL_LIMIT || t == ORDER_TYPE_SELL_STOP || t == ORDER_TYPE_SELL_STOP_LIMIT);
      if(!bl && !sh) continue;
      n++;
      tot += RiskToStop(OrderGetString(ORDER_SYMBOL), bl, OrderGetDouble(ORDER_VOLUME_CURRENT),
                        OrderGetDouble(ORDER_PRICE_OPEN), OrderGetDouble(ORDER_SL));
   }
   return tot;
}

double g_openRiskPct = 0.0;      // cache for the panel (refreshed each M5 bar)
int    g_openRiskN   = 0;
void RefreshOpenRisk()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   int n; double r = OpenRiskAll(n);
   g_openRiskN = n;
   g_openRiskPct = (bal > 0) ? r / bal * 100.0 : 0.0;
}

bool RiskMgrOK(double newRisk)
{
   if(!InpUseRiskMgr) return true;
   int n; double open = OpenRiskAll(n);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   string why = "";
   if(InpMaxOpenPositions > 0 && n + 1 > InpMaxOpenPositions)
      why = StringFormat("%d positions/orders already open (max %d)", n, InpMaxOpenPositions);
   else if(InpMaxOpenRiskPct > 0 && bal > 0 && (open + newRisk)/bal*100.0 > InpMaxOpenRiskPct)
      why = StringFormat("open risk %.2f%% + new %.2f%% > cap %.2f%%", open/bal*100.0, newRisk/bal*100.0, InpMaxOpenRiskPct);
   if(why == "") return true;
   if(g_rmNotes < 30){ g_rmNotes++; PrintFormat("RISK MGR refused %s: %s", _Symbol, why); }
   return false;
}

//==================================================================//
//  PART 5c - TRADE JOURNAL + STATUS (read by Python / the Agent)     //
//==================================================================//
bool JrnEnabled(){ return InpJournal && (!MQLInfoInteger(MQL_TESTER) || InpJournalTester); }

string JrnFile()
{
   return InpJournalDir + "\\journal_" + _Symbol + "_" + (string)InpMagic + (MQLInfoInteger(MQL_TESTER) ? "_TEST" : "") + ".csv";
}

string UtcStr(datetime srv)
{
   string s = TimeToString(ServerToUTC(srv), TIME_DATE|TIME_SECONDS);
   StringReplace(s, ".", "-");
   return s;
}

void JournalInit()
{
   if(!JrnEnabled()) return;
   FolderCreate(InpJournalDir, FILE_COMMON);
   if(MQLInfoInteger(MQL_TESTER) && FileIsExist(JrnFile(), FILE_COMMON)) FileDelete(JrnFile(), FILE_COMMON);
}

// Volatility regime = ATR now vs its own last day (288 M5 bars).
string VolRegime()
{
   double b[];
   int n = CopyBuffer(g_atrHandle, 0, 1, 288, b);
   if(n < 60) return "NA";
   double s = 0; for(int i=0;i<n;i++) s += b[i];
   double avg = s / n;
   if(avg <= 0) return "NA";
   double r = g_atr / avg;
   return (r < 0.75) ? "LOW" : ((r > 1.35) ? "HIGH" : "NORM");
}

void JournalOpen(bool isLong, ulong tk, const SSetup &s)
{
   if(!JrnEnabled()) return;
   if(!PositionSelectByTicket(tk)) return;
   SJrn j; ClearJrn(j);
   j.on       = true;
   j.posId    = PositionGetInteger(POSITION_IDENTIFIER);
   j.tOpen    = (datetime)PositionGetInteger(POSITION_TIME);
   j.entry    = PositionGetDouble(POSITION_PRICE_OPEN);
   j.sl0      = PositionGetDouble(POSITION_SL);
   j.lot      = PositionGetDouble(POSITION_VOLUME);
   j.riskDist = MathAbs(j.entry - j.sl0);
   j.riskMoney= RiskToStop(_Symbol, isLong, j.lot, j.entry, j.sl0);
   j.atr      = g_atr;
   j.spread   = s.spread;
   j.tag      = s.tag;
   j.htf      = g_htfTrend;
   j.volReg   = VolRegime();
   int al     = (isLong ? 1 : -1) * g_htfTrend;
   j.trendReg = (al > 0) ? "WITH" : ((al < 0) ? "AGAINST" : "FLAT");
   j.hour     = ClockHour(j.tOpen);
   if(isLong) g_jL = j; else g_jS = j;
}

void JrnUpd(SJrn &j, bool isLong, double bid, double ask)
{
   if(!j.on) return;
   double fav = isLong ? (bid - j.entry) : (j.entry - ask);
   double adv = isLong ? (j.entry - bid) : (ask - j.entry);
   if(fav > j.mfe) j.mfe = fav;
   if(adv > j.mae) j.mae = adv;
}

void JrnWrite(SJrn &j, bool isLong, double pnl, string exitTxt)
{
   int h = FileOpen(JrnFile(), FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE){ PrintFormat("JOURNAL: cannot open %s (err %d)", JrnFile(), GetLastError()); return; }
   if(FileSize(h) == 0)
      FileWriteString(h, "close_utc,open_utc,symbol,profile,magic,tag,dir,lot,entry,sl,r_price,r_atr,atr,spread,spread_r_pct,"
                         "pnl_money,pnl_r,mfe_r,mae_r,hold_min,exit,tp1,htf,vol_regime,trend_regime,clock_hour,balance_after\r\n");
   FileSeek(h, 0, SEEK_END);
   double rd   = (j.riskDist > 0) ? j.riskDist : 1.0;
   double pr   = (j.riskMoney > 0) ? pnl / j.riskMoney : 0.0;
   long   hold = (long)((TimeCurrent() - j.tOpen) / 60);
   string line = UtcStr(TimeCurrent()) + "," + UtcStr(j.tOpen) + "," + _Symbol + "," + g_p.name + "," + (string)InpMagic + "," + j.tag + ","
               + (isLong ? "L" : "S") + "," + DoubleToString(j.lot, 2) + ","
               + DoubleToString(j.entry, g_digits) + "," + DoubleToString(j.sl0, g_digits) + ","
               + DoubleToString(j.riskDist, g_digits) + "," + DoubleToString((j.atr > 0 ? j.riskDist/j.atr : 0.0), 3) + ","
               + DoubleToString(j.atr, g_digits) + "," + DoubleToString(j.spread, g_digits) + ","
               + DoubleToString(j.spread/rd*100.0, 2) + "," + DoubleToString(pnl, 2) + "," + DoubleToString(pr, 3) + ","
               + DoubleToString(j.mfe/rd, 3) + "," + DoubleToString(j.mae/rd, 3) + "," + (string)hold + ","
               + exitTxt + "," + (j.tp1 ? "1" : "0") + "," + (string)j.htf + "," + j.volReg + "," + j.trendReg + ","
               + (string)j.hour + "," + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\r\n";
   FileWriteString(h, line);
   FileClose(h);
}

void JournalClose(long posId, double pnl, ENUM_DEAL_REASON rs)
{
   if(!JrnEnabled()) return;
   string ex = (rs == DEAL_REASON_SL) ? "SL" : ((rs == DEAL_REASON_TP) ? "TP" : ((rs == DEAL_REASON_SO) ? "STOPOUT" : "EA"));
   if(g_jL.on && g_jL.posId == posId){ JrnWrite(g_jL, true,  pnl, ex); ClearJrn(g_jL); }
   else if(g_jS.on && g_jS.posId == posId){ JrnWrite(g_jS, false, pnl, ex); ClearJrn(g_jS); }
}

// Acknowledgement for the Agent: what the EA is ACTUALLY running with right now.
void WriteStatus(string why)
{
   if(MQLInfoInteger(MQL_TESTER) || !InpJournal) return;
   FolderCreate(InpJournalDir, FILE_COMMON);
   string f = InpJournalDir + "\\status_" + _Symbol + "_" + (string)InpMagic + ".ini";
   int h = FileOpen(f, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ);
   if(h == INVALID_HANDLE) return;
   int n; double open = OpenRiskAll(n);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   FileWrite(h, "event=" + why);
   FileWrite(h, "updated_utc=" + UtcStr(TimeCurrent()));
   FileWrite(h, "symbol=" + _Symbol);
   FileWrite(h, "magic=" + (string)InpMagic);
   FileWrite(h, "version=4.00");
   FileWrite(h, "profile=" + g_p.name);
   FileWrite(h, "profile_file_active=" + (g_profFile ? "1" : "0"));
   FileWrite(h, "profile_desc=" + ProfileDesc());
   FileWrite(h, "balance=" + DoubleToString(bal, 2));
   FileWrite(h, "equity=" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   FileWrite(h, "open_risk_pct=" + DoubleToString((bal > 0 ? open/bal*100.0 : 0.0), 3));
   FileWrite(h, "open_items=" + (string)n);
   FileWrite(h, "halted=" + ((g_hardHalt || g_floorHalt) ? "1" : "0"));
   FileWrite(h, "blocked_today=" + (g_blockedToday ? "1" : "0"));
   FileWrite(h, "loss_streak=" + (string)g_lossStreak);
   FileClose(h);
}

//==================================================================//
//  PART 6 - SWINGS & STRUCTURE                                      //
//==================================================================//
bool FindSwingHigh(const MqlRates &r[], int w, int maxlook, int start, int &idx, double &price)
{
   int limit = MathMin(maxlook, ArraySize(r)-1) - w;
   for(int i = MathMax(start, 1+w); i <= limit; i++)
   {
      bool ok = true;
      for(int k = 1; k <= w; k++)
         if(!(H(r,i) > H(r,i-k)) || !(H(r,i) > H(r,i+k))){ ok=false; break; }
      if(ok){ idx=i; price=H(r,i); return true; }
   }
   return false;
}

bool FindSwingLow(const MqlRates &r[], int w, int maxlook, int start, int &idx, double &price)
{
   int limit = MathMin(maxlook, ArraySize(r)-1) - w;
   for(int i = MathMax(start, 1+w); i <= limit; i++)
   {
      bool ok = true;
      for(int k = 1; k <= w; k++)
         if(!(L(r,i) < L(r,i-k)) || !(L(r,i) < L(r,i+k))){ ok=false; break; }
      if(ok){ idx=i; price=L(r,i); return true; }
   }
   return false;
}

int TrendFromStructure(const MqlRates &r[], int w, int maxlook, double &lastH, double &lastL)
{
   int h1,h2,l1,l2; double ph1,ph2,pl1,pl2;
   bool gotH1 = FindSwingHigh(r,w,maxlook,1+w,h1,ph1);
   bool gotH2 = gotH1 ? FindSwingHigh(r,w,maxlook,h1+1,h2,ph2) : false;
   bool gotL1 = FindSwingLow (r,w,maxlook,1+w,l1,pl1);
   bool gotL2 = gotL1 ? FindSwingLow (r,w,maxlook,l1+1,l2,pl2) : false;

   lastH = gotH1 ? ph1 : 0;
   lastL = gotL1 ? pl1 : 0;
   if(!(gotH1 && gotH2 && gotL1 && gotL2)) return 0;
   if(ph1 > ph2 && pl1 > pl2) return +1;
   if(ph1 < ph2 && pl1 < pl2) return -1;
   return 0;
}

void UpdateM5Structure()
{
   int shi,sli; double sh,sl;
   bool haveSH = FindSwingHigh(g_m5, InpSwingStrength, InpStructLookback, 1+InpSwingStrength, shi, sh);
   bool haveSL = FindSwingLow (g_m5, InpSwingStrength, InpStructLookback, 1+InpSwingStrength, sli, sl);
   g_m5High = haveSH ? sh : 0;
   g_m5Low  = haveSL ? sl : 0;

   if(haveSH && C(g_m5,1) > sh && C(g_m5,2) <= sh)
   {
      g_lastBreakDir = +1;
      g_lastBreakTxt = (g_m5Trend <= 0) ? "CHoCH UP" : "BOS UP";
      g_m5Trend = +1;
   }
   else if(haveSL && C(g_m5,1) < sl && C(g_m5,2) >= sl)
   {
      g_lastBreakDir = -1;
      g_lastBreakTxt = (g_m5Trend >= 0) ? "CHoCH DOWN" : "BOS DOWN";
      g_m5Trend = -1;
   }
}

bool FreshBreakUp()
{
   int shi; double sh;
   if(!FindSwingHigh(g_m5, InpSwingStrength, InpStructLookback, 1+InpSwingStrength, shi, sh)) return false;
   return (C(g_m5,1) > sh && C(g_m5,2) <= sh);
}
bool FreshBreakDown()
{
   int sli; double sl;
   if(!FindSwingLow(g_m5, InpSwingStrength, InpStructLookback, 1+InpSwingStrength, sli, sl)) return false;
   return (C(g_m5,1) < sl && C(g_m5,2) >= sl);
}

void UpdateHTFBias()
{
   int need = InpHTFLookback + 10;
   int copied = CopyRates(_Symbol, InpHTF, 0, need, g_htf);
   if(copied < InpHTFSwing*3 + 5){ g_htfTrend = 0; return; }
   double hh,ll;
   g_htfTrend = TrendFromStructure(g_htf, InpHTFSwing, InpHTFLookback, hh, ll);
   g_htfHigh = hh; g_htfLow = ll;
}

bool HTFAllowsLong()
{
   if(!InpUseHTFBias) return true;
   return InpLongHTFStrict ? (g_htfTrend > 0) : (g_htfTrend >= 0);
}
bool HTFAllowsShort()
{
   if(!InpUseHTFBias) return true;
   return InpShortHTFStrict ? (g_htfTrend < 0) : (g_htfTrend <= 0);
}

bool HTFDiscount(){ if(g_htfHigh<=0||g_htfLow<=0) return false; return C(g_m5,1) < (g_htfHigh+g_htfLow)/2.0; }
bool HTFPremium (){ if(g_htfHigh<=0||g_htfLow<=0) return false; return C(g_m5,1) > (g_htfHigh+g_htfLow)/2.0; }

//==================================================================//
//  PART 7 - V3 POOL ENGINE                                          //
//==================================================================//
// A pool is LIVE while no BODY has closed beyond it. Bodies, not wicks: two
// brokers' wicks disagree on spikes, their closes almost never do. Rebuilt from
// bars every close, so two terminals cannot drift into different pool maps.
void AddPool(SPool &arr[], double price, int idx, int kind, double tol)
{
   for(int i=0;i<ArraySize(arr);i++)
      if(MathAbs(arr[i].price - price) <= tol)      // equal high/low -> merge, stronger pool
      {
         arr[i].hits++;
         if(idx < arr[i].idx) arr[i].idx = idx;     // keep the most recent touch
         return;
      }
   int n = ArraySize(arr);
   ArrayResize(arr, n+1);
   arr[n].price = price; arr[n].idx = idx; arr[n].hits = 1; arr[n].kind = kind;
}

// Prefix scans of the body extremes so "has a body closed beyond this level
// since it formed?" is O(1) instead of O(bars). Without this the pool rebuild
// is ~25k comparisons per M5 bar, which makes a multi-year test crawl.
void BuildBodyExtremes(int n)
{
   ArrayResize(g_bMaxTo, n+1);
   ArrayResize(g_bMinTo, n+1);
   if(n < 1) return;
   g_bMaxTo[0] = -DBL_MAX; g_bMinTo[0] = DBL_MAX;
   g_bMaxTo[1] = -DBL_MAX; g_bMinTo[1] = DBL_MAX;   // nothing newer than bar 1
   for(int i=2; i<=n; i++)
   {
      g_bMaxTo[i] = MathMax(g_bMaxTo[i-1], BodyHi(g_m5,i-1));
      g_bMinTo[i] = MathMin(g_bMinTo[i-1], BodyLo(g_m5,i-1));
   }
}
bool BodyBrokenAbove(double level, int fromIdx)
{
   if(fromIdx < 1 || fromIdx >= ArraySize(g_bMaxTo)) return false;
   return (g_bMaxTo[fromIdx] > level);
}
bool BodyBrokenBelow(double level, int fromIdx)
{
   if(fromIdx < 1 || fromIdx >= ArraySize(g_bMinTo)) return false;
   return (g_bMinTo[fromIdx] < level);
}

// Asia range + previous-day extremes, both measured on InpClock boundaries so
// the two brokers compute the SAME levels despite different server clocks.
void AddSessionPools(double tol)
{
   if(!InpUseSessionPools) return;
   long today = ClockDayKey(TimeCurrent());
   long yday  = -1;
   double aH=0, aL=0; int aHi=0, aLi=0;
   double pH=0, pL=0; int pHi=0, pLi=0;
   int n = MathMin(ArraySize(g_m5)-1, 620 * g_k);      // >2 UTC days, independent of InpPoolLookback

   for(int i=1;i<=n;i++)
   {
      long dk = ClockDayKey(g_m5[i].time);
      int  hr = ClockHour(g_m5[i].time);
      if(dk == today && InWindow(hr, g_p.asiaS, g_p.asiaE))
      {
         if(aH==0 || H(g_m5,i) > aH){ aH = H(g_m5,i); aHi = i; }
         if(aL==0 || L(g_m5,i) < aL){ aL = L(g_m5,i); aLi = i; }
      }
      if(dk != today)
      {
         if(yday < 0) yday = dk;
         if(dk == yday)
         {
            if(pH==0 || H(g_m5,i) > pH){ pH = H(g_m5,i); pHi = i; }
            if(pL==0 || L(g_m5,i) < pL){ pL = L(g_m5,i); pLi = i; }
         }
      }
   }
   if(aH>0 && aHi>1 && !BodyBrokenAbove(aH, aHi)) AddPool(g_bsl, aH, aHi, 1, tol);
   if(aL>0 && aLi>1 && !BodyBrokenBelow(aL, aLi)) AddPool(g_ssl, aL, aLi, 1, tol);
   if(pH>0 && pHi>1 && !BodyBrokenAbove(pH, pHi)) AddPool(g_bsl, pH, pHi, 2, tol);
   if(pL>0 && pLi>1 && !BodyBrokenBelow(pL, pLi)) AddPool(g_ssl, pL, pLi, 2, tol);
}

void BuildPools()
{
   ArrayResize(g_bsl, 0);
   ArrayResize(g_ssl, 0);
   if(g_atr <= 0) return;
   BuildBodyExtremes(MathMin(ArraySize(g_m5)-1, 620 * g_k));
   double tol = InpEqTolATR * g_atr;
   int w    = InpPoolPivot;
   int last = MathMin(InpPoolLookback, ArraySize(g_m5)-1) - w;

   for(int i = 1+w; i <= last; i++)
   {
      bool isHigh = true, isLow = true;
      for(int k=1;k<=w;k++)
      {
         if(!(H(g_m5,i) > H(g_m5,i-k)) || !(H(g_m5,i) > H(g_m5,i+k))) isHigh = false;
         if(!(L(g_m5,i) < L(g_m5,i-k)) || !(L(g_m5,i) < L(g_m5,i+k))) isLow  = false;
         if(!isHigh && !isLow) break;
      }
      if(isHigh && !BodyBrokenAbove(H(g_m5,i), i) && ArraySize(g_bsl) < InpMaxPools)
         AddPool(g_bsl, H(g_m5,i), i, 0, tol);
      if(isLow  && !BodyBrokenBelow(L(g_m5,i), i) && ArraySize(g_ssl) < InpMaxPools)
         AddPool(g_ssl, L(g_m5,i), i, 0, tol);
   }
   AddSessionPools(tol);
}

//==================================================================//
//  PART 8 - V3 GRAB DETECTION                                       //
//==================================================================//
// A grab on the just-closed bar: the wick clears a live pool by a real margin,
// and the BODY closes back inside. That is the fluxchart definition you already
// trust on the TradingView side, and it is the version that survives a feed swap.
bool DetectGrab(int dir, double &poolPrice, int &poolKind, double &sweepExt)
{
   if(ArraySize(g_m5) < 4 || g_atr <= 0) return false;
   double rng = H(g_m5,1) - L(g_m5,1);
   if(rng <= 0) return false;
   double poke = InpGrabMinPokeATR * g_atr;
   bool found = false;
   double best = 0; int bestKind = 0;

   if(dir > 0)   // sell-side grab -> long setup
   {
      double wick = BodyLo(g_m5,1) - L(g_m5,1);
      if(wick < InpGrabWickFrac*rng) return false;
      for(int i=0;i<ArraySize(g_ssl);i++)
      {
         double p = g_ssl[i].price;
         if(g_ssl[i].idx <= 1) continue;
         if(L(g_m5,1) < p - poke && BodyLo(g_m5,1) > p)      // ran it, closed back above
            if(!found || p < best){ best = p; bestKind = g_ssl[i].kind; found = true; }
      }
      if(found){ poolPrice = best; poolKind = bestKind; sweepExt = L(g_m5,1); }
   }
   else          // buy-side grab -> short setup
   {
      double wick = H(g_m5,1) - BodyHi(g_m5,1);
      if(wick < InpGrabWickFrac*rng) return false;
      for(int i=0;i<ArraySize(g_bsl);i++)
      {
         double p = g_bsl[i].price;
         if(g_bsl[i].idx <= 1) continue;
         if(H(g_m5,1) > p + poke && BodyHi(g_m5,1) < p)      // ran it, closed back below
            if(!found || p > best){ best = p; bestKind = g_bsl[i].kind; found = true; }
      }
      if(found){ poolPrice = best; poolKind = bestKind; sweepExt = H(g_m5,1); }
   }
   return found;
}

//==================================================================//
//  PART 9 - V3 DISPLACEMENT ZONE (FVG on the leg, OB fallback)      //
//==================================================================//
// Scan ONLY the bars of the impulse leg (from the grab to now) for a gap. v2.1
// accepted any FVG in a 4-bar window regardless of whether it belonged to the
// move - that is how unrelated gaps passed as "displacement".
bool ZoneFromLeg(int dir, int fromIdx, double sweepExt, double &lo, double &hi)
{
   double minGap = InpMinFVGATR * g_atr;
   int hiIdx = MathMin(fromIdx, ArraySize(g_m5)-3);
   bool got = false;

   if(dir > 0)
   {
      for(int k=1; k<=hiIdx; k++)                       // nearest-to-price first
      {
         if(k+2 > ArraySize(g_m5)-1) break;
         double gLo = H(g_m5,k+2), gHi = L(g_m5,k);
         if(gHi - gLo >= minGap && gLo > sweepExt)      // gap must sit above the swept low
         {
            lo = gLo; hi = gHi; got = true; break;
         }
      }
      if(!got && InpZoneFallbackOB)
      {
         // Scan from the ORIGIN outward: the bullish OB is the last down-close
         // candle BEFORE the impulse, not the most recent red candle in it.
         for(int j=hiIdx; j>=1; j--)
            if(C(g_m5,j) < O(g_m5,j)){ lo = L(g_m5,j); hi = H(g_m5,j); got = true; break; }
      }
   }
   else
   {
      for(int k=1; k<=hiIdx; k++)
      {
         if(k+2 > ArraySize(g_m5)-1) break;
         double gHi = L(g_m5,k+2), gLo = H(g_m5,k);
         if(gHi - gLo >= minGap && gHi < sweepExt)
         {
            lo = gLo; hi = gHi; got = true; break;
         }
      }
      if(!got && InpZoneFallbackOB)
      {
         for(int j=hiIdx; j>=1; j--)
            if(C(g_m5,j) > O(g_m5,j)){ lo = L(g_m5,j); hi = H(g_m5,j); got = true; break; }
      }
   }
   return got;
}

//==================================================================//
//  PART 11 - LIQUIDITY TARGETS (unchanged from v2.1)                //
//==================================================================//
int CollectSwingHighs(double &out[])
{
   int cnt=0; ArrayResize(out,0);
   int limit = MathMin(InpLiqLookback, ArraySize(g_m5)-1) - InpSwingStrength;
   for(int i=1+InpSwingStrength; i<=limit; i++)
   {
      bool ok=true;
      for(int k=1;k<=InpSwingStrength;k++)
         if(!(H(g_m5,i)>H(g_m5,i-k)) || !(H(g_m5,i)>H(g_m5,i+k))){ ok=false; break; }
      if(ok){ ArrayResize(out,cnt+1); out[cnt]=H(g_m5,i); cnt++; }
   }
   return cnt;
}
int CollectSwingLows(double &out[])
{
   int cnt=0; ArrayResize(out,0);
   int limit = MathMin(InpLiqLookback, ArraySize(g_m5)-1) - InpSwingStrength;
   for(int i=1+InpSwingStrength; i<=limit; i++)
   {
      bool ok=true;
      for(int k=1;k<=InpSwingStrength;k++)
         if(!(L(g_m5,i)<L(g_m5,i-k)) || !(L(g_m5,i)<L(g_m5,i+k))){ ok=false; break; }
      if(ok){ ArrayResize(out,cnt+1); out[cnt]=L(g_m5,i); cnt++; }
   }
   return cnt;
}

int LiquidityAbove(double price, double minDist, double &t1, double &t2)
{
   t1=0; t2=0;
   double hs[]; CollectSwingHighs(hs);
   double cand[]; int c=0;
   for(int i=0;i<ArraySize(hs);i++)
      if(hs[i] > price + minDist){ ArrayResize(cand,c+1); cand[c]=hs[i]; c++; }
   if(c==0) return 0;
   ArraySort(cand);
   t1 = cand[0];
   if(c>=2) t2 = cand[1];
   return c;
}
int LiquidityBelow(double price, double minDist, double &t1, double &t2)
{
   t1=0; t2=0;
   double ls[]; CollectSwingLows(ls);
   double cand[]; int c=0;
   for(int i=0;i<ArraySize(ls);i++)
      if(ls[i] < price - minDist){ ArrayResize(cand,c+1); cand[c]=ls[i]; c++; }
   if(c==0) return 0;
   ArraySort(cand);
   t1 = cand[c-1];
   if(c>=2) t2 = cand[c-2];
   return c;
}

void ResolveLongTargets(double entry, double R, double &tp1, double &tp2)
{
   double a,b;
   int n = LiquidityAbove(entry, InpMinTP1_R*R, a, b);
   tp1 = (n>=1) ? a : entry + InpFallbackTP1_R*R;
   tp2 = (n>=2) ? b : 0.0;
   if(tp2>0 && tp2 < tp1 + 0.5*R) tp2 = tp1 + R;
}
void ResolveShortTargets(double entry, double R, double &tp1, double &tp2)
{
   double a,b;
   int n = LiquidityBelow(entry, InpMinTP1_R*R, a, b);
   tp1 = (n>=1) ? a : entry - InpFallbackTP1_R*R;
   tp2 = (n>=2) ? b : 0.0;
   if(tp2>0 && tp2 > tp1 - 0.5*R) tp2 = tp1 - R;
}

int FindLadder(bool isLong, double entry, double minGap, double &out[])
{
   ArrayResize(out,0);
   double sw[];
   if(isLong) CollectSwingHighs(sw); else CollectSwingLows(sw);
   double cand[]; int c=0;
   for(int i=0;i<ArraySize(sw);i++)
   {
      bool ok = isLong ? (sw[i] > entry + minGap) : (sw[i] < entry - minGap);
      if(ok){ ArrayResize(cand,c+1); cand[c]=sw[i]; c++; }
   }
   if(c==0) return 0;
   ArraySort(cand);
   int n=0; double last=entry;
   if(isLong)
   {
      for(int i=0;i<c && n<InpMaxRungs;i++)
         if(cand[i] >= last + minGap){ ArrayResize(out,n+1); out[n]=cand[i]; last=cand[i]; n++; }
   }
   else
   {
      for(int i=c-1;i>=0 && n<InpMaxRungs;i--)
         if(cand[i] <= last - minGap){ ArrayResize(out,n+1); out[n]=cand[i]; last=cand[i]; n++; }
   }
   return n;
}

//==================================================================//
//  PART 12 - SIZING                                                 //
//==================================================================//
double NormalizeLot(double lot)
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st<=0) st = 0.01;
   lot = MathFloor(lot/st)*st;
   lot = MathMax(mn, MathMin(mx, lot));
   return NormalizeDouble(lot, 2);
}

//------------------------------------------------------------------//
//  v3.1 RISK LAYER                                                   //
//                                                                    //
//  The v2.2 hypergrowth run turned $5k into $1.23M with a 90.6%      //
//  drawdown. Bootstrapping its own 536 trades in 20,000 random       //
//  orders showed that drawdown was not bad luck: at 10% risk the     //
//  MEDIAN path draws down 92%, and 12.5% of paths lose 90%+. Full    //
//  Kelly on that trade distribution is 13.2%, so 10% was ~0.76       //
//  Kelly - sized as if the edge were known exactly, when its         //
//  yearly expectancy ranged from +0.02R to +0.50R.                   //
//                                                                    //
//  So the drawdown is a SIZING artifact, not a missing hedge. These  //
//  three multipliers attack it directly:                             //
//    - a ladder whose step scales WITH the account (v2.2's fixed     //
//      $100 step hit the 10% cap after only +16% growth)             //
//    - a throttle that cuts risk while equity is below its peak      //
//    - a brake that cuts risk during a losing streak                 //
//------------------------------------------------------------------//
void UpdatePeaks()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_startBal <= 0) g_startBal = (InpFundedStartBal > 0) ? InpFundedStartBal : bal;
   if(eq  > g_equityPeak) g_equityPeak = eq;
   if(bal > g_peakBal)    g_peakBal    = bal;
   // v3.2 milestone ratchet: banking a gain re-anchors the ladder, so risk drops
   // back to base instead of staying at the cap forever.
   if(InpUseRatchet && InpRatchetPct > 0 && g_startBal > 0 &&
      bal >= g_startBal * (1.0 + InpRatchetPct/100.0))
   {
      PrintFormat("RATCHET: milestone %.2f reached - ladder re-anchored (risk back to %.2f%%)",
                  bal, InpBaseRiskPct);
      g_startBal = bal;
   }

   // v3.2 capital floor. Independent of the funded shell so a personal account
   // gets the same protection.
   if(InpUseCapitalFloor && InpCapitalFloorDD > 0 && g_equityPeak > 0)
   {
      double ddPct = (g_equityPeak - eq)/g_equityPeak*100.0;
      if(ddPct >= InpCapitalFloorDD && InpFloorAction == FLOOR_HALT && !g_floorHalt)
      {
         g_floorHalt = true;
         PrintFormat("CAPITAL FLOOR BREACHED: equity %.2f is %.1f%% below the peak %.2f - trading stopped.",
                     eq, ddPct, g_equityPeak);
      }
   }

   if(InpUseVault && InpVaultPct > 0)
   {
      double prof = g_peakBal - g_startBal;
      g_vault = (prof > 0) ? prof * InpVaultPct/100.0 : 0.0;
   }
   else g_vault = 0.0;
}

// Balance the sizing math is allowed to compound on.
double TradeableBalance()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE) - g_vault;
   return MathMax(bal, 0.0);
}

// Risk ladder: one step per InpScaleStepPct % of the START balance gained.
double BaseRiskPct()
{
   if(!InpUseHyperGrowth) return InpRiskPercent;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(g_startBal <= 0 || InpScaleStepPct <= 0) return InpBaseRiskPct;
   double step  = g_startBal * InpScaleStepPct/100.0;
   double grown = bal - g_startBal;
   double rp    = InpBaseRiskPct;
   if(grown > 0) rp += MathFloor(grown/step) * InpScaleAddPct;
   return MathMin(rp, InpMaxRiskPct);
}

// 1.0 at the equity peak, sliding to InpThrottleMinMult at InpThrottleFullDD.
double DDThrottleMult()
{
   if(!InpUseDDThrottle || g_equityPeak <= 0) return 1.0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (g_equityPeak - eq)/g_equityPeak*100.0;
   if(dd <= InpThrottleStartDD) return 1.0;
   if(dd >= InpThrottleFullDD)  return InpThrottleMinMult;
   double frac = (dd - InpThrottleStartDD)/(InpThrottleFullDD - InpThrottleStartDD);
   return 1.0 - frac*(1.0 - InpThrottleMinMult);
}

// Compounds per loss beyond the trigger. A 7-loss streak at flat 10% risk
// costs 52% of the account; braking turns that into roughly 30%.
double StreakMult()
{
   if(!InpUseStreakBrake || g_lossStreak < InpStreakTrigger) return 1.0;
   double m = MathPow(InpStreakMult, (double)(g_lossStreak - InpStreakTrigger + 1));
   return MathMax(m, InpStreakFloor);
}

// THROTTLE mode keeps trading below the floor at reduced size.
double FloorMult()
{
   if(!InpUseCapitalFloor || InpFloorAction != FLOOR_THROTTLE || g_equityPeak <= 0) return 1.0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (g_equityPeak - eq)/g_equityPeak*100.0;
   return (dd >= InpCapitalFloorDD) ? InpFloorRiskMult : 1.0;
}

double RiskMult(){ return DDThrottleMult() * StreakMult() * FloorMult(); }

double CalcLot(bool isLong, double entry, double sl)
{
   if(InpUseFixedLot) return NormalizeLot(InpFixedLot);
   double slDist = MathAbs(entry - sl);
   if(slDist <= 0) return 0.0;

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double eqn       = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = balance * InpRiskPercent / 100.0;

   if(InpUseHyperGrowth)                       // personal-account ladder
      riskMoney = TradeableBalance() * BaseRiskPct() / 100.0;
   else if(InpFundedMode && InpGrowthMode && g_fundedStart > 0)
   {
      double refFloor;
      if(InpStaticFloorPct > 0)                          refFloor = g_fundedStart*(1.0 - InpStaticFloorPct/100.0);
      else if(InpTrailingDDPct > 0 && g_equityPeak > 0)  refFloor = g_equityPeak  *(1.0 - InpTrailingDDPct/100.0);
      else                                               refFloor = g_fundedStart*0.96;
      double headroom = eqn - refFloor;
      if(headroom <= 0) return 0.0;
      riskMoney = headroom * InpHeadroomRiskPct/100.0;
      double cap = balance * InpGrowthMaxRiskPct/100.0;
      if(riskMoney > cap) riskMoney = cap;
   }
   else if(InpFundedMode && InpDeriskInDD && g_fundedStart > 0)
   {
      double refTop = 0, refFloor = 0;
      if(InpStaticFloorPct > 0){ refTop = g_fundedStart; refFloor = g_fundedStart*(1.0 - InpStaticFloorPct/100.0); }
      else if(InpTrailingDDPct > 0 && g_equityPeak > 0){ refTop = g_equityPeak; refFloor = g_equityPeak*(1.0 - InpTrailingDDPct/100.0); }
      double span = refTop - refFloor;
      if(span > 0)
      {
         double frac = (eqn - refFloor) / span;
         frac = MathMax(0.0, MathMin(1.0, frac));
         double factor = InpDeriskMinFactor + (1.0 - InpDeriskMinFactor)*frac;
         riskMoney *= factor;
      }
   }

   riskMoney *= RiskMult();
   if(riskMoney <= 0) return 0.0;

   double lossPerLot = 0.0;
   ENUM_ORDER_TYPE ot = isLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(ot, _Symbol, 1.0, entry, sl, lossPerLot))
      return 0.0;
   lossPerLot = MathAbs(lossPerLot);
   if(lossPerLot <= 0) return 0.0;

   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   double lot = riskMoney / lossPerLot;

   // v4: the minimum lot is a floor on SIZE, not a licence to exceed the risk. If
   // even one minimum lot risks far more than configured, the account is too small
   // for this stop on this symbol - skip the trade instead of silently over-risking.
   if(InpMinLotRiskMult > 0 && lot < mn && mn*lossPerLot > riskMoney*InpMinLotRiskMult)
   {
      if(g_minLotNotes < 10)
      {
         g_minLotNotes++;
         PrintFormat("MIDAS v4 NOTE: %s min lot %.2f would risk %.2f vs configured %.2f (x%.1f > cap x%.1f) - trade skipped. "
                     "Account too small for this stop on this symbol.%s",
                     _Symbol, mn, mn*lossPerLot, riskMoney, mn*lossPerLot/riskMoney, InpMinLotRiskMult,
                     (g_minLotNotes==10 ? " (further notices suppressed)" : ""));
      }
      return 0.0;
   }
   double normalized = NormalizeLot(lot);

   // Notional cap (replaces the v3.4 ounce cap): lots x contract x price in account
   // currency <= InpMaxNotionalX x equity. Value per 1.0 of price per lot comes from
   // the same OrderCalcProfit used for risk, so it is right for gold, indices, FX,
   // JPY pairs and crypto alike.
   if(InpMaxNotionalX > 0 && eqn > 0)
   {
      double notionalPerLot = entry * (lossPerLot / slDist);
      if(notionalPerLot > 0)
      {
         double maxLots = InpMaxNotionalX * eqn / notionalPerLot;
         if(maxLots < mn)
         {
            if(g_ceilHits < 10)
            {
               g_ceilHits++;
               PrintFormat("MIDAS v4 NOTE: %s notional of the MIN lot (%.0f) exceeds %.1fx equity (%.0f) - trade skipped.",
                           _Symbol, mn*notionalPerLot, InpMaxNotionalX, InpMaxNotionalX*eqn);
            }
            return 0.0;
         }
         double ceiling = NormalizeLot(maxLots);
         if(normalized > ceiling)
         {
            if(g_ceilHits < 10)
            {
               g_ceilHits++;
               PrintFormat("MIDAS v4 NOTE: notional cap bound this trade (%.2f -> %.2f lots). Actual risk %.2f%% vs configured %.2f%%.",
                           normalized, ceiling, ceiling*lossPerLot/MathMax(balance,1.0)*100.0, BaseRiskPct()*RiskMult());
            }
            normalized = ceiling;
         }
      }
   }

   if(InpFundedMode && InpMinMarginLevel > 0)
   {
      for(int g=0; g<60 && normalized>0; g++)
      {
         if(MarginOK(isLong, normalized, entry)) break;
         normalized = NormalizeLot(normalized - step);
      }
      if(normalized < mn) return 0.0;
   }
   return normalized;
}

//==================================================================//
//  PART 13 - EXECUTION HELPERS                                      //
//==================================================================//
double MinStopDistance()
{
   long sl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return ((double)sl + 2) * g_point;
}

// v3.3. CTrade::PositionClosePartial() is HEDGING-ONLY: on a netting account it
// returns false without sending anything. That is why v3.2 never took a single
// partial (549 trades = 1098 deals) although 31 trades closed on the BE lock.
// Netting/exchange accounts are reduced by an opposite market deal of the same
// volume instead. Leaves the position re-selected for the caller.
bool ClosePartialSafe(ulong tk, bool isLong, double vol, string why)
{
   if(vol <= 0 || !PositionSelectByTicket(tk)) return false;
   double prevSL  = PositionGetDouble(POSITION_SL);
   double prevTP  = PositionGetDouble(POSITION_TP);
   double prevVol = PositionGetDouble(POSITION_VOLUME);
   bool   hedging = IsHedgingAccount();
   string route   = hedging ? "PositionClosePartial" : "opposite deal";

   bool sent;
   if(hedging)     sent = trade.PositionClosePartial(tk, vol);
   else if(isLong) sent = trade.Sell(vol, _Symbol, 0.0, 0.0, 0.0, InpComment + "|PART");
   else            sent = trade.Buy (vol, _Symbol, 0.0, 0.0, 0.0, InpComment + "|PART");

   // CTrade returns true once the request is accepted; the retcode says whether
   // the server actually executed it.
   uint rc = trade.ResultRetcode();
   bool ok = sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED);
   if(!ok)
   {
      PrintFormat("PART %s %s FAILED via %s: %.2f of %.2f lots | retcode=%u %s",
                  (isLong ? "LONG" : "SHORT"), why, route, vol, prevVol, rc, trade.ResultRetcodeDescription());
      PositionSelectByTicket(tk);
      return false;
   }

   // A reducing deal on a netting account may drop or move the position's stops.
   if(PositionSelectByTicket(tk))
   {
      double nowSL = PositionGetDouble(POSITION_SL);
      double nowTP = PositionGetDouble(POSITION_TP);
      double tol   = g_point * 0.5;
      bool slBad = (prevSL > 0 && (nowSL == 0 || MathAbs(nowSL - prevSL) > tol));
      bool tpBad = (prevTP > 0 && (nowTP == 0 || MathAbs(nowTP - prevTP) > tol));
      if(slBad || tpBad)
      {
         bool mod = trade.PositionModify(tk, prevSL, prevTP);
         uint mrc = trade.ResultRetcode();
         if(mod && mrc == TRADE_RETCODE_DONE)
            PrintFormat("PART %s: stops re-applied (sl %.2f -> %.2f, tp %.2f -> %.2f)",
                        why, nowSL, prevSL, nowTP, prevTP);
         else
            PrintFormat("PART %s: stop re-apply FAILED (sl now %.2f, wanted %.2f) | retcode=%u %s",
                        why, nowSL, prevSL, mrc, trade.ResultRetcodeDescription());
         PositionSelectByTicket(tk);
      }
   }
   PrintFormat("PART %s %s %.2f of %.2f lots via %s", (isLong ? "LONG" : "SHORT"), why, vol, prevVol, route);
   return true;
}

// v3.4. ManageOne decides WHEN to move the stop; this only refuses to send a
// request the server would reject or ignore, which v3.3 re-sent on every tick
// (200k-316k "failed modify" lines per backtest). It selects the position first,
// exactly as CTrade::PositionModify does, so the caller is left with the same
// position snapshot whether the request is sent or skipped.
bool SafeModifySL(ulong tk, bool isLong, double newSL, double tp)
{
   if(!PositionSelectByTicket(tk)) return false;
   newSL = NormalizeDouble(newSL, g_digits);

   // a. Same level after rounding -> "no changes".
   double curSL = PositionGetDouble(POSITION_SL);
   if(MathAbs(newSL - curSL) < _Point) return false;

   // b. Wrong side of the market by more than the stops level -> "invalid stops".
   //    Server rule exactly (Bid-SL >= level for a long, SL-Ask >= level for a
   //    short); the boundary itself is still sent and left to the server.
   double lvl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(isLong)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid > 0 && newSL > bid - lvl + 0.5*_Point) return false;
   }
   else
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask > 0 && newSL < ask + lvl - 0.5*_Point) return false;
   }

   // c. The last try met a closed market -> not again before the next M5 bar.
   datetime bar = iTime(_Symbol, PERIOD_M5, 0);
   if(g_modBlockBar != 0)
   {
      if(bar == g_modBlockBar) return false;
      g_modBlockBar = 0;
   }

   bool ok = trade.PositionModify(tk, newSL, tp);
   uint rc = trade.ResultRetcode();
   if(rc == TRADE_RETCODE_MARKET_CLOSED) g_modBlockBar = bar;
   return (ok && rc == TRADE_RETCODE_DONE);
}

void RegisterNewPosition(bool isLong, double riskPrice, double tp1Level)
{
   ulong tk = isLong ? GetPosByType(POSITION_TYPE_BUY) : GetPosByType(POSITION_TYPE_SELL);
   double entry = tp1Level;
   if(tk>0 && PositionSelectByTicket(tk)) entry = PositionGetDouble(POSITION_PRICE_OPEN);

   double lad[]; int n = FindLadder(isLong, entry, InpMinTP1_R*riskPrice, lad);
   if(n > 12) n = 12;
   double firstRung = (n>0) ? lad[0] : tp1Level;

   if(isLong)
   {
      g_tkLong=tk; g_riskLong=riskPrice; g_tp1Long=firstRung; g_doneLong=false;
      g_reachedL=0; g_nRungsL=n;
      for(int i=0;i<n;i++) g_ladderL[i]=lad[i];
   }
   else
   {
      g_tkShort=tk; g_riskShort=riskPrice; g_tp1Short=firstRung; g_doneShort=false;
      g_reachedS=0; g_nRungsS=n;
      for(int i=0;i<n;i++) g_ladderS[i]=lad[i];
   }
}

//==================================================================//
//  PART 14 - V3 ENTRY STATE MACHINE                                 //
//==================================================================//
// Step 3: the minor swing a close must break to confirm the reversal.
bool FindMSSLevel(int dir, double &level)
{
   int idx; double px;
   if(dir > 0)
   {
      if(!FindSwingHigh(g_m5, InpMSSPivot, InpMSSLookback, 1+InpMSSPivot, idx, px)) return false;
      level = px;
   }
   else
   {
      if(!FindSwingLow(g_m5, InpMSSPivot, InpMSSLookback, 1+InpMSSPivot, idx, px)) return false;
      level = px;
   }
   return true;
}


// Throttled rejection log: tells you WHY a confirmed setup did not become an order.
int g_rejNotes = 0;
void CountDrop(string why)
{
   for(int i=0;i<g_nDrop;i++) if(g_dropWhy[i] == why){ g_dropN[i]++; return; }
   if(g_nDrop < 40){ g_dropWhy[g_nDrop] = why; g_dropN[g_nDrop] = 1; g_nDrop++; }
}
void Reject(string cat, string why)
{
   CountDrop("arm:" + cat);
   if(g_rejNotes < 200){ g_rejNotes++; PrintFormat("REJECT %s: %s", _Symbol, why); }
}
// Printed when the EA stops (every backtest): where do setups die?
void PrintFunnel()
{
   string s = StringFormat("FUNNEL %s grabs=%d mss_confirmed=%d armed=%d filled=%d spikes=%d |", _Symbol, g_fGrab, g_fMSS, g_fArm, g_fFill, g_fSpikes);
   for(int i=0;i<g_nDrop;i++) s += StringFormat(" %s=%d", g_dropWhy[i], g_dropN[i]);
   Print(s);
}

// Optimisation score: edge x sqrt(trades) / drawdown. Rewards a real edge AND frequency; zero below 20 trades or without profit.
double OnTester()
{
   double n  = TesterStatistics(STAT_TRADES);
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   double dd = TesterStatistics(STAT_EQUITYDD_PERCENT);
   if(n < 20 || TesterStatistics(STAT_PROFIT) <= 0) return 0.0;
   return (pf - 1.0) * MathSqrt(n) / (1.0 + dd/20.0);
}

// Step 4: turn a confirmed setup into a resting limit order.
bool ArmSetup(SSetup &s)
{
   double lo, hi;
   if(!ZoneFromLeg(s.dir, s.age + 1, s.sweepExt, lo, hi)){ CountDrop("arm:no_zone"); return false; }
   if(hi <= lo) return false;

   double entry, sl;
   double buf = MathMax(InpSLBufferATR*g_atr, 3.0*g_point);

   if(s.dir > 0)
   {
      entry = hi - InpZoneEntryFrac*(hi-lo);
      sl    = MathMin(s.sweepExt, lo) - buf;
   }
   else
   {
      entry = lo + InpZoneEntryFrac*(hi-lo);
      sl    = MathMax(s.sweepExt, hi) + buf;
   }

   double R = MathAbs(entry - sl);
   if(R <= 0) return false;
   if(g_p.maxSL_ATR > 0 && R > g_p.maxSL_ATR*g_atr){ Reject("stop_too_wide", StringFormat("stop %.2f ATR > max %.2f", R/g_atr, g_p.maxSL_ATR)); return false; }

   // The limit must sit the correct side of the market, clear of the stops level.
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minD = MinStopDistance();
   if(s.dir > 0 && entry > ask - minD){ CountDrop("arm:price_past_zone"); return false; }   // price already past the zone
   if(s.dir < 0 && entry < bid + minD){ CountDrop("arm:price_past_zone"); return false; }

   // Trade-level spread gate: the spread is a cost paid in R. A stop this tight on
   // a market this wide is a bad trade however good the setup looks.
   double spr = ask - bid;
   if(g_p.maxSpreadRPct > 0 && spr > 0 && spr > g_p.maxSpreadRPct/100.0*R)
   {
      Reject("spread_vs_R", StringFormat("spread %.1f%% of R > max %.0f%%", spr/R*100.0, g_p.maxSpreadRPct));
      return false;
   }

   if(InpUseRangeFilter)
   {
      int span = MathMin(s.age + InpMSSLookback, ArraySize(g_m5)-1);
      double legHi = H(g_m5,1), legLo = L(g_m5,1);
      for(int i=1;i<=span;i++){ legHi = MathMax(legHi, H(g_m5,i)); legLo = MathMin(legLo, L(g_m5,i)); }
      double mid = (legHi + legLo) / 2.0;
      if(s.dir > 0 && InpLongUsePremDisc  && entry > legLo + InpLongDiscountPct*(legHi-legLo)){ CountDrop("arm:range_filter"); return false; }
      if(s.dir < 0 && InpShortUsePremDisc && entry < mid){ CountDrop("arm:range_filter"); return false; }
   }

   // A real pool must be within reach, otherwise there is nothing to target.
   double t1, t2;
   int nPools = (s.dir > 0) ? LiquidityAbove(entry, InpMinTP1_R*R, t1, t2)
                            : LiquidityBelow(entry, InpMinTP1_R*R, t1, t2);
   if(InpRequirePool && nPools < 1){ CountDrop("arm:no_pool_ahead"); return false; }

   double lot = CalcLot(s.dir > 0, entry, sl);
   if(lot <= 0){ CountDrop("arm:lot_zero"); return false; }

   entry = NormalizeDouble(entry, g_digits);
   sl    = NormalizeDouble(sl,    g_digits);

   // Account-wide gate (all MIDAS magics, all symbols).
   double newRisk = RiskToStop(_Symbol, s.dir > 0, lot, entry, sl);
   if(!RiskMgrOK(newRisk)){ CountDrop("arm:risk_mgr"); return false; }

   string kindTxt = (s.poolKind==1 ? "ASIA" : (s.poolKind==2 ? "PDHL" : "PIV"));
   s.tag = InpComment + "|SW" + kindTxt;                              // tag so reports can split by setup

   bool ok = (s.dir > 0)
           ? trade.BuyLimit (lot, entry, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, s.tag)
           : trade.SellLimit(lot, entry, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, s.tag);
   if(!ok)
   {
      PrintFormat("MIDAS v4: limit rejected %s dir=%d entry=%s sl=%s lot=%.2f err=%d",
                  _Symbol, s.dir, DoubleToString(entry,g_digits), DoubleToString(sl,g_digits), lot, trade.ResultRetcode());
      return false;
   }

   s.ticket   = trade.ResultOrder();
   s.zoneLo   = lo;  s.zoneHi = hi;
   s.entry    = entry; s.sl = sl; s.riskDist = R;
   s.lot      = lot; s.riskMoney = newRisk; s.spread = spr;
   s.state    = ST_ARMED;
   g_fArm++;
   PrintFormat("ARM %s %s pool=%s(%s) sweep=%s zone=%s-%s entry=%s sl=%s R=%.2fATR atr=%s lot=%.2f risk=%.2f",
               _Symbol, (s.dir>0?"LONG":"SHORT"), DoubleToString(s.poolPrice,g_digits), kindTxt, DoubleToString(s.sweepExt,g_digits),
               DoubleToString(lo,g_digits), DoubleToString(hi,g_digits), DoubleToString(entry,g_digits), DoubleToString(sl,g_digits),
               R/g_atr, DoubleToString(g_atr,g_digits), lot, newRisk);
   return true;
}

void CancelSetup(SSetup &s, string why)
{
   if(s.ticket > 0 && OrderSelect(s.ticket)) trade.OrderDelete(s.ticket);
   if(s.state != ST_NONE)
      { CountDrop("drop:" + why); PrintFormat("DROP %s setup (%s)", (s.dir>0?"LONG":"SHORT"), why); }
   ClearSetup(s);
}

// Called every tick: a resting limit that vanished either filled or was killed.
void SyncFills(SSetup &s, bool isLong)
{
   if(s.state != ST_ARMED || s.ticket == 0) return;
   if(OrderSelect(s.ticket)) return;                    // still resting

   ulong tk = GetPosByType(isLong ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
   ulong cur = isLong ? g_tkLong : g_tkShort;
   if(tk > 0 && tk != cur)
   {
      // Resolve the targets off the ACTUAL fill. Passing s.entry here would make
      // the fallback TP1 equal the entry, firing the partial + BE instantly.
      double fill = s.entry;
      if(PositionSelectByTicket(tk)) fill = PositionGetDouble(POSITION_PRICE_OPEN);
      double tp1, tp2;
      if(isLong) ResolveLongTargets (fill, s.riskDist, tp1, tp2);
      else       ResolveShortTargets(fill, s.riskDist, tp1, tp2);

      RecordTrade();
      g_fFill++;
      RegisterNewPosition(isLong, s.riskDist, tp1);
      JournalOpen(isLong, tk, s);
      PrintFormat("FILL %s %s @%s tp1=%s R=%s", _Symbol, (isLong?"LONG":"SHORT"), DoubleToString(fill,g_digits),
                  DoubleToString(tp1,g_digits), DoubleToString(s.riskDist,g_digits));
   }
   ClearSetup(s);
}

// One M5 close of work for one side. allowNew=false still ages and invalidates
// a live setup (so nothing is orphaned) but may not arm or hunt - otherwise a
// setup already in ST_SWEPT would arm straight through the position cap.
void ProcessSide(SSetup &s, int dir, bool allowNew)
{
   bool isLong = (dir > 0);
   if(isLong  && InpDirection == DIR_SHORT_ONLY) return;
   if(!isLong && InpDirection == DIR_LONG_ONLY)  return;

   // ---- age / invalidate an existing setup ----
   if(s.state != ST_NONE)
   {
      s.age++;
      bool htfOK = isLong ? HTFAllowsLong() : HTFAllowsShort();
      if(!htfOK){ CancelSetup(s, "HTF flipped"); }
      else if(isLong  && C(g_m5,1) < s.sweepExt){ CancelSetup(s, "closed below the swept low"); }
      else if(!isLong && C(g_m5,1) > s.sweepExt){ CancelSetup(s, "closed above the swept high"); }
      else if(s.state == ST_SWEPT && s.age > InpMSSMaxBars){ CancelSetup(s, "no MSS in time"); }
      else if(s.state == ST_ARMED && s.age > InpArmExpiryBars){ CancelSetup(s, "limit expired unfilled"); }
   }

   // ---- ST_SWEPT: wait for the close-confirmed structure shift ----
   if(s.state == ST_SWEPT)
   {
      if(!allowNew) return;
      bool shifted = isLong ? (C(g_m5,1) > s.mssLevel) : (C(g_m5,1) < s.mssLevel);
      if(shifted) g_fMSS++;
      if(shifted && !ArmSetup(s))
         CancelSetup(s, "MSS confirmed but no tradable zone");
      return;
   }
   if(s.state == ST_ARMED) return;
   if(!allowNew) return;

   // ---- ST_NONE: hunt for a fresh grab ----
   if(isLong  && HasLong())  return;
   if(!isLong && HasShort()) return;
   if(isLong  && !HTFAllowsLong())  return;
   if(!isLong && !HTFAllowsShort()) return;
   if(InpUseHTFZone && isLong  && !HTFDiscount()) return;
   if(InpUseHTFZone && !isLong && !HTFPremium())  return;

   int lastGrab = isLong ? g_lastGrabBarL : g_lastGrabBarS;
   if(g_barCounter - lastGrab <= InpGrabCooldown) return;

   double pool, ext; int kind;
   if(!DetectGrab(dir, pool, kind, ext)) return;

   double mss;
   if(!FindMSSLevel(dir, mss)) return;
   if(isLong  && mss <= ext) return;                    // nothing above to break
   if(!isLong && mss >= ext) return;

   g_fGrab++;
   s.state = ST_SWEPT; s.dir = dir; s.age = 0;
   s.poolPrice = pool; s.poolKind = kind; s.sweepExt = ext; s.mssLevel = mss;
   if(isLong) g_lastGrabBarL = g_barCounter; else g_lastGrabBarS = g_barCounter;
   PrintFormat("GRAB %s pool=%.2f ext=%.2f -> needs close %s %.2f",
               (isLong?"SELLSIDE":"BUYSIDE"), pool, ext, (isLong?">":"<"), mss);
}

//==================================================================//
//  PART 16 - TRADE MANAGEMENT                                       //
//==================================================================//
void ManageOne(ulong tk, bool isLong)
{
   if(!PositionSelectByTicket(tk)) return;

   ulong curTk = isLong ? g_tkLong : g_tkShort;
   if(tk != curTk)
   {
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      double cs = PositionGetDouble(POSITION_SL);
      double rk = MathAbs(op - cs);
      if(isLong){ g_tkLong=tk;  g_riskLong=rk;  g_tp1Long=0;  g_doneLong=true;  g_nRungsL=0; g_reachedL=0; }
      else      { g_tkShort=tk; g_riskShort=rk; g_tp1Short=0; g_doneShort=true; g_nRungsS=0; g_reachedS=0; }
   }

   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = PositionGetDouble(POSITION_TP);
   double vol  = PositionGetDouble(POSITION_VOLUME);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double tp1  = isLong ? g_tp1Long  : g_tp1Short;
   bool   done = isLong ? g_doneLong : g_doneShort;
   if(isLong) JrnUpd(g_jL, true, bid, ask); else JrnUpd(g_jS, false, bid, ask);

   // v3.1: bleed size off a trade that is already deeply offside, instead of
   // hedging it. Same effect on the loss, without a second position, a second
   // spread, or an unwind problem.
   if(InpCutLossAtR > 0 && !done)
   {
      double Rk  = isLong ? g_riskLong : g_riskShort;
      bool   cut = isLong ? g_cutLong  : g_cutShort;
      if(Rk > 0 && !cut)
      {
         double adverse = isLong ? (open - bid) : (ask - open);
         if(adverse >= InpCutLossAtR * Rk)
         {
            double cv = NormalizeLot(vol * InpCutLossPct/100.0);
            if(cv >= minLot && (vol - cv) >= minLot && ClosePartialSafe(tk, isLong, cv, "CUT"))
            {
               if(isLong) g_cutLong = true; else g_cutShort = true;
               PrintFormat("CUT %s %.2f lots at -%.2fR", (isLong?"LONG":"SHORT"), cv, InpCutLossAtR);
               vol -= cv;
            }
         }
      }
   }

   if(isLong)
   {
      bool tp1hit = (tp1>0 && bid >= tp1);
      if(!done && tp1hit)
      {
         if(InpUseRunner)
         {
            double closeVol = NormalizeLot(vol * InpPartialPct/100.0);
            if(closeVol >= minLot && (vol - closeVol) >= minLot)
               ClosePartialSafe(tk, true, closeVol, "TP1");
         }
         double be = open + (InpBE_LockATR*g_atr);
         if(be > sl) SafeModifySL(tk, true, be, tp);
         g_doneLong = true; done = true; g_jL.tp1 = true;
      }
      if(done)
      {
         double curSL = PositionGetDouble(POSITION_SL);
         double newSL = curSL;
         if(InpUseLadder && g_nRungsL > 0)
         {
            while(g_reachedL < g_nRungsL && bid >= g_ladderL[g_reachedL]) g_reachedL++;
            if(g_reachedL >= 2)
            {
               double lock = g_ladderL[g_reachedL-2];
               if(lock > newSL) newSL = lock;
            }
            if(g_reachedL >= g_nRungsL)
            {
               int sli; double slp;
               if(FindSwingLow(g_m5, InpSwingStrength, InpStructLookback, 1+InpSwingStrength, sli, slp))
               {
                  double cand = slp - (InpStructTrailATR*g_atr);
                  if(cand > newSL) newSL = cand;
               }
            }
         }
         else
         {
            int sli; double slp;
            if(FindSwingLow(g_m5, InpSwingStrength, InpStructLookback, 1+InpSwingStrength, sli, slp))
            {
               double cand = slp - (InpStructTrailATR*g_atr);
               if(cand > newSL) newSL = cand;
            }
         }
         if(newSL > curSL && newSL >= open) SafeModifySL(tk, true, newSL, tp);
      }
   }
   else
   {
      bool tp1hit = (tp1>0 && ask <= tp1);
      if(!done && tp1hit)
      {
         if(InpUseRunner)
         {
            double closeVol = NormalizeLot(vol * InpPartialPct/100.0);
            if(closeVol >= minLot && (vol - closeVol) >= minLot)
               ClosePartialSafe(tk, false, closeVol, "TP1");
         }
         double be = open - (InpBE_LockATR*g_atr);
         if(be < sl || sl==0) SafeModifySL(tk, false, be, tp);
         g_doneShort = true; done = true; g_jS.tp1 = true;
      }
      if(done)
      {
         double curSL = PositionGetDouble(POSITION_SL);
         double newSL = curSL;
         if(InpUseLadder && g_nRungsS > 0)
         {
            while(g_reachedS < g_nRungsS && ask <= g_ladderS[g_reachedS]) g_reachedS++;
            if(g_reachedS >= 2)
            {
               double lock = g_ladderS[g_reachedS-2];
               if(lock < newSL || newSL==0) newSL = lock;
            }
            if(g_reachedS >= g_nRungsS)
            {
               int shi; double shp;
               if(FindSwingHigh(g_m5, InpSwingStrength, InpStructLookback, 1+InpSwingStrength, shi, shp))
               {
                  double cand = shp + (InpStructTrailATR*g_atr);
                  if(cand < newSL || newSL==0) newSL = cand;
               }
            }
         }
         else
         {
            int shi; double shp;
            if(FindSwingHigh(g_m5, InpSwingStrength, InpStructLookback, 1+InpSwingStrength, shi, shp))
            {
               double cand = shp + (InpStructTrailATR*g_atr);
               if(cand < newSL || newSL==0) newSL = cand;
            }
         }
         if((newSL < curSL || (curSL==0 && newSL>0)) && newSL <= open)
            SafeModifySL(tk, false, newSL, tp);
      }
   }
}

void ManagePositions()
{
   ulong tkL = GetPosByType(POSITION_TYPE_BUY);
   ulong tkS = GetPosByType(POSITION_TYPE_SELL);
   if(tkL == 0){ g_tkLong = 0;  g_doneLong = false; g_cutLong  = false; }
   if(tkS == 0){ g_tkShort = 0; g_doneShort = false; g_cutShort = false; }
   if(tkL > 0) ManageOne(tkL, true);
   if(tkS > 0) ManageOne(tkS, false);
}

//==================================================================//
//  PART 17 - DASHBOARD                                              //
//==================================================================//
void PanelRect(string name,int x,int y,int w,int h,color bg,color brd)
{
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,name,OBJPROP_COLOR,brd);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}

void PanelText(string name,string txt,int x,int y,color clr,int fs=9,string font="Consolas",ENUM_ANCHOR_POINT anchor=ANCHOR_LEFT_UPPER)
{
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,anchor);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetString (0,name,OBJPROP_TEXT,txt);
   ObjectSetString (0,name,OBJPROP_FONT,font);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fs);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}

string SetupTxt(const SSetup &s)
{
   if(s.state == ST_NONE)  return "-";
   if(s.state == ST_SWEPT) return StringFormat("%s swept %s, need %s", (s.dir>0?"L":"S"), DoubleToString(s.poolPrice,g_digits), DoubleToString(s.mssLevel,g_digits));
   return StringFormat("%s limit %s  R %s", (s.dir>0?"L":"S"), DoubleToString(s.entry,g_digits), DoubleToString(s.riskDist,g_digits));
}

#define ROWS 16
void UpdatePanel()
{
   if(!InpShowPanel){ ObjectsDeleteAll(0, PFX); return; }

   int W = 320, marginR = InpPanelX, top = InpPanelY;
   int left = marginR + W;
   int padL = left - 14;
   int padV = left - 150;
   int rowH = 18;
   int bodyH = 30 + ROWS*rowH + 10;

   color cBg=C'18,22,30', cHdr=C'28,35,50', cBrd=C'60,70,90';
   color cLabel=C'150,160,178', cValue=C'225,230,238';
   color cGreen=C'80,210,140', cRed=C'235,95,95', cAmber=C'235,185,80';

   if(InpPanelBox)
   {
      PanelRect(PFX+"bg",  marginR, top, W, bodyH, cBg,  cBrd);
      PanelRect(PFX+"hdr", marginR, top, W, 26,    cHdr, cHdr);
   }
   else
   {
      ObjectDelete(0, PFX+"bg");
      ObjectDelete(0, PFX+"hdr");
   }

   PanelText(PFX+"title", "M I D A S   v4.0   " + _Symbol, padL, top+6, C'120,170,255', 10, "Consolas");

   double spr = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dpnl= eq - g_dayStartEq;
   double dpct= (g_dayStartEq>0) ? dpnl/g_dayStartEq*100.0 : 0.0;

   string htfTxt = (g_htfTrend>0?"BULLISH":(g_htfTrend<0?"BEARISH":"-"));
   color  htfClr = (g_htfTrend>0?cGreen:(g_htfTrend<0?cRed:cAmber));
   string m5Txt  = (g_m5Trend>0?"BULLISH":(g_m5Trend<0?"BEARISH":"-"));
   color  m5Clr  = (g_m5Trend>0?cGreen:(g_m5Trend<0?cRed:cAmber));

   int y = top + 34;
   string lbl[ROWS]; string val[ROWS]; color vc[ROWS];

   lbl[0]="Profile";    val[0]=StringFormat("%s%s | %s", g_p.name, (g_profFile?" [file]":""), ClockName()); vc[0]=cValue;
   lbl[1]="Clock";      val[1]=StringFormat("%s %02d:00 | srv UTC%+d", ClockName(), ClockHour(TimeCurrent()), SrvOffsetNow()); vc[1]=cValue;
   lbl[2]="HTF bias";   val[2]=htfTxt;                             vc[2]=htfClr;
   lbl[3]="M5 struct";  val[3]=m5Txt;                              vc[3]=m5Clr;
   lbl[4]="ATR(M5)";    val[4]=StringFormat("%s (%.3f%%)", DoubleToString(g_atr,g_digits), (SymbolInfoDouble(_Symbol,SYMBOL_BID)>0 ? g_atr/SymbolInfoDouble(_Symbol,SYMBOL_BID)*100.0 : 0.0)); vc[4]=cValue;
   lbl[5]="Pools B/S";  val[5]=StringFormat("%d / %d", ArraySize(g_bsl), ArraySize(g_ssl)); vc[5]=cValue;
   lbl[6]="Spread";     val[6]=StringFormat("%s = %.2f ATR", DoubleToString(spr,g_digits), (g_atr>0 ? spr/g_atr : 0.0)); vc[6]=(SpreadOK()?cValue:cRed);
   lbl[7]="Session";    val[7]=(BlackoutNow()?"BLACKOUT":(SessionOK()?"OPEN":"closed")); vc[7]=(BlackoutNow()?cAmber:(SessionOK()?cGreen:cAmber));
   lbl[8]="Long setup"; val[8]=SetupTxt(g_setL);                   vc[8]=(g_setL.state==ST_ARMED?cGreen:(g_setL.state==ST_SWEPT?cAmber:cLabel));
   lbl[9]="Short setup";val[9]=SetupTxt(g_setS);                   vc[9]=(g_setS.state==ST_ARMED?cRed:(g_setS.state==ST_SWEPT?cAmber:cLabel));
   lbl[10]="Position";  val[10]=StringFormat("%d / %d  (%d pend) %s",CountMyPositions(),InpMaxPositions,CountMyPendings(),((g_doneLong||g_doneShort)?"[runner]":"")); vc[10]=cValue;
   lbl[11]="Trades day";val[11]=StringFormat("%d / %d",g_tradesToday,g_p.maxTradesDay); vc[11]=cValue;
   lbl[12]="Day P&L";   val[12]=StringFormat("%.2f (%.2f%%)",dpnl,dpct); vc[12]=(dpnl>=0?cGreen:cRed);
   double ddNow = (g_equityPeak>0) ? (g_equityPeak-eq)/g_equityPeak*100.0 : 0.0;
   lbl[13]="Risk/trade"; val[13]=StringFormat("%.2f%% x%.2f = %.2f%%", BaseRiskPct(), RiskMult(), BaseRiskPct()*RiskMult());
   vc[13]=(RiskMult()<0.99?cAmber:cGreen);
   lbl[14]="DD / streak"; val[14]=StringFormat("%.1f%% peak / %d loss", ddNow, g_lossStreak);
   vc[14]=(ddNow>=InpThrottleStartDD?cRed:cValue);
   lbl[15]="Acct open risk"; val[15]=StringFormat("%.2f%% / %.1f%% (%d items)", g_openRiskPct, InpMaxOpenRiskPct, g_openRiskN);
   vc[15]=(g_openRiskPct>=InpMaxOpenRiskPct*0.9?cAmber:cValue);

   for(int i=0;i<ROWS;i++)
   {
      PanelText(PFX+"l"+(string)i, lbl[i], padL, y+i*rowH, cLabel, 9);
      PanelText(PFX+"v"+(string)i, val[i], padV, y+i*rowH, vc[i], 9);
   }

   if(g_floorHalt)
      PanelText(PFX+"blk", "CAPITAL FLOOR HIT - STOPPED", padL, y+ROWS*rowH, cRed, 9);
   else if(g_hardHalt)
      PanelText(PFX+"blk", "FUNDED HALT - DD RULE HIT", padL, y+ROWS*rowH, cRed, 9);
   else if(g_blockedToday)
      PanelText(PFX+"blk", "DAILY LIMIT HIT", padL, y+ROWS*rowH, cRed, 9);
   else if(InpFundedMode && g_fundedStart>0)
   {
      double eqn = AccountInfoDouble(ACCOUNT_EQUITY);
      double floorPx = (eqn - g_fundedStart*(1.0-InpStaticFloorPct/100.0)) / g_fundedStart * 100.0;
      PanelText(PFX+"blk", StringFormat("FUNDED: %.2f%% above floor", floorPx), padL, y+ROWS*rowH, C'120,200,120', 9);
   }
   else
      ObjectDelete(0, PFX+"blk");
}

//==================================================================//
//  PART 17b - v3.1 CLOSED-TRADE TRACKING (feeds the streak brake)    //
//==================================================================//
// Partial closes emit several DEAL_ENTRY_OUT deals for one position, so a
// naive per-deal streak counter would count one trade several times. We
// accumulate by position id and only finalise once the position is gone.
int AccSlot(long posid)
{
   for(int i=0;i<8;i++) if(g_accId[i]==posid) return i;
   for(int i=0;i<8;i++) if(g_accId[i]==0){ g_accId[i]=posid; g_accPnl[i]=0.0; return i; }
   return -1;
}

void FinaliseTrade(double pnl)
{
   if(pnl > 0) g_lossStreak = 0;
   else        g_lossStreak++;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal > g_peakBal) g_peakBal = bal;
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest    &request,
                        const MqlTradeResult     &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC)  != InpMagic) return;
   if(HistoryDealGetString (trans.deal, DEAL_SYMBOL) != _Symbol)  return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

   long posid = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   double p   = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
              + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   ENUM_DEAL_REASON rs = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
   int sl = AccSlot(posid);
   if(sl < 0){ JournalClose(posid, p, rs); FinaliseTrade(p); return; }   // table full - degrade gracefully
   g_accPnl[sl] += p;
   if(PositionSelectByTicket(posid)) return;         // partial: still open
   double total = g_accPnl[sl];
   JournalClose(posid, total, rs);
   FinaliseTrade(total);
   g_accId[sl] = 0; g_accPnl[sl] = 0.0;
}

// A stop cannot protect a gap. Flatten before the weekend - on the profile's own
// clock and only for markets that actually close (crypto does not).
bool WeekendFlatTime()
{
   if(!InpFlatBeforeWeekend || !g_p.flatWeekend) return false;
   MqlDateTime d; TimeToStruct(ToClock(TimeCurrent()), d);
   return (d.day_of_week == FRIDAY && d.hour >= g_p.flatHour);
}


//==================================================================//
//  PART 17b - PULLBACK ENGINE (trend scalper)                       //
//==================================================================//
// Evaluated once per closed M5 bar. Trend = EMA(fast) vs EMA(slow) with price on the right side, ADX above a floor and
// the H1 EMA slope agreeing. Trigger = the bar that just closed touched the fast EMA (pullback to value) and closed back
// in the trend direction with a real body. Market entry, stop beyond the pullback extreme, TP1 in R, then the same
// BE-lock + structural trail as the sweep engine.
void TryPullback()
{
   if(InpDirection == DIR_BOTH || InpDirection == DIR_LONG_ONLY || InpDirection == DIR_SHORT_ONLY) {}
   if(CountMyPositions() > 0 || CountMyPendings() > 0) return;
   if(g_barCounter - g_pbLastBar < InpPbCooldownBars) return;
   if(ArraySize(g_m5) < 10 || g_atr <= 0) return;

   if(InpPbRandomPct > 0)
   {
      if(MathRand() / 32767.0 * 100.0 >= InpPbRandomPct) return;
      int rd = (MathRand() % 2 == 0) ? +1 : -1;
      double bidr = SymbolInfoDouble(_Symbol, SYMBOL_BID), askr = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double er = (rd > 0) ? askr : bidr, Rr = InpPbRandSL_ATR * g_atr, slr = (rd > 0) ? er - Rr : er + Rr;
      double lotr = CalcLot(rd > 0, er, slr);
      if(lotr <= 0 || !RiskMgrOK(RiskToStop(_Symbol, rd > 0, lotr, er, slr))) return;
      slr = NormalizeDouble(slr, g_digits);
      bool okr = (rd > 0) ? trade.Buy(lotr, _Symbol, 0.0, slr, 0.0, InpComment + "|RND") : trade.Sell(lotr, _Symbol, 0.0, slr, 0.0, InpComment + "|RND");
      ulong tkr = okr ? GetPosByType(rd > 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL) : 0;
      if(tkr == 0) return;
      g_fFill++; g_pbLastBar = g_barCounter; RecordTrade();
      double tpr = (rd > 0) ? er + InpPbTP1_R*Rr : er - InpPbTP1_R*Rr;
      RegisterNewPosition(rd > 0, Rr, tpr);
      if(rd > 0){ g_tp1Long = tpr; g_nRungsL = 0; g_reachedL = 0; } else { g_tp1Short = tpr; g_nRungsS = 0; g_reachedS = 0; }
      SSetup jr; ClearSetup(jr); jr.tag = InpComment + "|RND"; jr.spread = askr - bidr; JournalOpen(rd > 0, tkr, jr);
      return;
   }
   double ef[], es[], ad[], eh[];
   if(CopyBuffer(g_hEmaF, 0, 1, 3, ef) < 3 || CopyBuffer(g_hEmaS, 0, 1, 3, es) < 3) return;
   double f1 = ef[2], s1 = es[2];
   if(InpPbAdxMin > 0 && !InpPbNoTrend)
   {
      if(CopyBuffer(g_hAdx, 0, 1, 1, ad) < 1) return;
      if(ad[0] < InpPbAdxMin) return;
   }
   int dir = 0;
   if(InpPbNoTrend)
   {
      // pullback trigger only: side follows the candle (bullish rejection of the fast EMA = long)
      dir = (C(g_m5,1) > O(g_m5,1)) ? +1 : -1;
   }
   else if(f1 > s1 && C(g_m5,1) > s1) dir = +1;
   else if(f1 < s1 && C(g_m5,1) < s1) dir = -1;
   else return;
   if(dir > 0 && InpDirection == DIR_SHORT_ONLY) return;
   if(dir < 0 && InpDirection == DIR_LONG_ONLY)  return;
   if(InpPbHTFEma > 0 && !InpPbNoTrend)
   {
      if(CopyBuffer(g_hEmaH, 0, 1, 4, eh) < 4) return;
      double slope = eh[3] - eh[0];
      if(dir > 0 && slope <= 0) return;
      if(dir < 0 && slope >= 0) return;
   }

   double atr = g_atr, o1 = O(g_m5,1), c1 = C(g_m5,1);
   if(MathAbs(c1 - o1) < InpPbMinBodyATR*atr) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry, sl;
   if(dir > 0)
   {
      if(!(c1 > o1 && c1 > f1)) return;
      if(L(g_m5,1) > f1 + InpPbTouchATR*atr) return;                // did not pull back to value
      double ext = MathMin(L(g_m5,1), MathMin(L(g_m5,2), L(g_m5,3)));
      entry = ask; sl = ext - InpPbSLBufATR*atr;
   }
   else
   {
      if(!(c1 < o1 && c1 < f1)) return;
      if(H(g_m5,1) < f1 - InpPbTouchATR*atr) return;
      double ext = MathMax(H(g_m5,1), MathMax(H(g_m5,2), H(g_m5,3)));
      entry = bid; sl = ext + InpPbSLBufATR*atr;
   }
   double minD = MinStopDistance();
   if(dir > 0 && entry - sl < minD) sl = entry - minD;
   if(dir < 0 && sl - entry < minD) sl = entry + minD;
   double R = MathAbs(entry - sl);
   if(R < InpPbMinSL_ATR*atr){ CountDrop("pb:stop_too_tight"); return; }
   if(R > InpPbMaxSL_ATR*atr){ CountDrop("pb:stop_too_wide"); return; }
   double spr = ask - bid;
   if(g_p.maxSpreadRPct > 0 && spr > g_p.maxSpreadRPct/100.0*R){ CountDrop("pb:spread_vs_R"); return; }

   double lot = CalcLot(dir > 0, entry, sl);
   if(lot <= 0){ CountDrop("pb:lot_zero"); return; }
   sl = NormalizeDouble(sl, g_digits);
   double newRisk = RiskToStop(_Symbol, dir > 0, lot, entry, sl);
   if(!RiskMgrOK(newRisk)){ CountDrop("pb:risk_mgr"); return; }

   string tag = InpComment + "|PB";
   double tp1 = (dir > 0) ? entry + InpPbTP1_R*R : entry - InpPbTP1_R*R;
   bool ok = (dir > 0) ? trade.Buy(lot, _Symbol, 0.0, sl, 0.0, tag) : trade.Sell(lot, _Symbol, 0.0, sl, 0.0, tag);
   if(!ok){ CountDrop("pb:order_failed"); return; }
   g_fArm++;
   ulong tk = GetPosByType(dir > 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
   if(tk == 0) return;
   g_fFill++; g_pbLastBar = g_barCounter;
   RecordTrade();
   RegisterNewPosition(dir > 0, R, tp1);
   if(dir > 0){ g_tp1Long = tp1; g_nRungsL = 0; g_reachedL = 0; } else { g_tp1Short = tp1; g_nRungsS = 0; g_reachedS = 0; }
   SSetup js; ClearSetup(js); js.tag = tag; js.spread = spr;
   JournalOpen(dir > 0, tk, js);
}


//==================================================================//
//  PART 17c - ORB ENGINE (range breakout)                           //
//==================================================================//
bool TodayAsiaRange(long today, double &hi, double &lo)
{
   hi = 0; lo = 0; int cnt = 0, seen = 0;
   int n = MathMin(ArraySize(g_m5) - 1, 620 * g_k);
   for(int i = 1; i <= n; i++)
   {
      if(ClockDayKey(g_m5[i].time) != today){ if(seen > 0) break; continue; }
      seen++;
      if(!InWindow(ClockHour(g_m5[i].time), g_p.asiaS, g_p.asiaE)) continue;
      if(cnt == 0 || H(g_m5,i) > hi) hi = H(g_m5,i);
      if(cnt == 0 || L(g_m5,i) < lo) lo = L(g_m5,i);
      cnt++;
   }
   return (cnt >= 6 && hi > lo);
}

void TryORB()
{
   if(CountMyPositions() > 0 || CountMyPendings() > 0) return;
   if(ArraySize(g_m5) < 50 || g_atr <= 0) return;
   long today = ClockDayKey(TimeCurrent());
   if(g_orbDay != today){ g_orbDay = today; g_orbCount = 0; }
   if(g_orbCount >= InpOrbMaxPerDay) return;
   if(InWindow(ClockHour(TimeCurrent()), g_p.asiaS, g_p.asiaE)) return;          // the range is still forming
   double hi, lo;
   if(!TodayAsiaRange(today, hi, lo)){ CountDrop("orb:no_range"); return; }
   double rATR = (hi - lo) / g_atr;
   if(rATR < InpOrbMinRangeATR || rATR > InpOrbMaxRangeATR){ CountDrop("orb:range_size"); return; }

   double buf = InpOrbBufATR * g_atr, c1 = C(g_m5,1), c2 = C(g_m5,2);
   int dir = 0;
   if(c1 > hi + buf && c2 <= hi + buf) dir = +1;                                  // first close beyond the range
   else if(c1 < lo - buf && c2 >= lo - buf) dir = -1;
   else return;
   if(dir > 0 && InpDirection == DIR_SHORT_ONLY) return;
   if(dir < 0 && InpDirection == DIR_LONG_ONLY)  return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry = (dir > 0) ? ask : bid;
   double mid = (hi + lo) / 2.0;
   double sl = (InpOrbSLMode == 0) ? ((dir > 0) ? lo : hi) : mid;
   double minD = MinStopDistance();
   if(dir > 0 && entry - sl < minD) sl = entry - minD;
   if(dir < 0 && sl - entry < minD) sl = entry + minD;
   double R = MathAbs(entry - sl);
   if(R < InpOrbMinSL_ATR*g_atr){ CountDrop("orb:stop_too_tight"); return; }
   if(R > InpOrbMaxSL_ATR*g_atr){ CountDrop("orb:stop_too_wide"); return; }
   double spr = ask - bid;
   if(g_p.maxSpreadRPct > 0 && spr > g_p.maxSpreadRPct/100.0*R){ CountDrop("orb:spread_vs_R"); return; }
   double lot = CalcLot(dir > 0, entry, sl);
   if(lot <= 0){ CountDrop("orb:lot_zero"); return; }
   sl = NormalizeDouble(sl, g_digits);
   if(!RiskMgrOK(RiskToStop(_Symbol, dir > 0, lot, entry, sl))){ CountDrop("orb:risk_mgr"); return; }

   string tag = InpComment + "|ORB";
   double tp1 = (dir > 0) ? entry + InpOrbTP1_R*R : entry - InpOrbTP1_R*R;
   bool ok = (dir > 0) ? trade.Buy(lot, _Symbol, 0.0, sl, 0.0, tag) : trade.Sell(lot, _Symbol, 0.0, sl, 0.0, tag);
   if(!ok){ CountDrop("orb:order_failed"); return; }
   ulong tk = GetPosByType(dir > 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
   if(tk == 0) return;
   g_fArm++; g_fFill++; g_orbCount++;
   RecordTrade();
   RegisterNewPosition(dir > 0, R, tp1);
   if(dir > 0){ g_tp1Long = tp1; g_nRungsL = 0; g_reachedL = 0; } else { g_tp1Short = tp1; g_nRungsS = 0; g_reachedS = 0; }
   SSetup js; ClearSetup(js); js.tag = tag; js.spread = spr;
   JournalOpen(dir > 0, tk, js);
}

//==================================================================//
//  PART 18 - MAIN TICK ORCHESTRATION                                //
//==================================================================//
void OnTick()
{
   ResetDayIfNeeded();
   UpdatePeaks();

   // SyncFills MUST run before ManagePositions. A limit fill produces a ticket
   // that ManagePositions does not recognise, and its restart-recovery branch
   // would mark the position done=true - skipping the TP1 partial entirely.
   SyncFills(g_setL, true);
   SyncFills(g_setS, false);
   ManagePositions();
   UpdateFundedState();
   UpdatePanel();

   if(!IsNewBar()) return;
   g_barCounter++;

   // 620 bars covers >2 days so PDH/PDL and the overnight range are always available.
   int need = MathMax(MathMax(InpStructLookback, InpPoolLookback) + 10, 620 * g_k);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, need, g_m5) < 50) return;
   if(!RefreshATR()) return;

   // Shock guard: a closed bar this violent (news, flash move) means price discovery, not a clean sweep.
   if(InpSpikeRangeATR > 0 && (H(g_m5,1) - L(g_m5,1)) >= InpSpikeRangeATR*g_atr)
   {
      if(!SpikeNow()) g_fSpikes++;
      g_spikeUntilBar = g_barCounter + MathMax(1, InpSpikeCooldownBars);
   }
   ReloadProfileIfChanged();
   UpdateM5Structure();
   UpdateHTFBias();
   if(InpEntryEngine == ENGINE_SWEEP) BuildPools();
   RefreshOpenRisk();
   if(!MQLInfoInteger(MQL_TESTER) && (g_barCounter % 12) == 0) WriteStatus("heartbeat");

   // Hard stops: kill anything resting, then stand down.
   if(g_floorHalt && CountMyPositions() > 0){ CancelAllPendings(); FlattenAll(); return; }
   if(g_hardHalt || g_blockedToday || g_floorHalt)
   {
      if(CountMyPendings() > 0) CancelAllPendings();
      return;
   }

   // Go flat into the weekend gap.
   if(WeekendFlatTime())
   {
      if(CountMyPendings()  > 0) CancelAllPendings();
      if(CountMyPositions() > 0){ FlattenAll(); Print("MIDAS v4: flat for the weekend"); }
      return;
   }

   // Two different gates on purpose. The window is structural, so it kills a
   // resting setup. Spread is a momentary, per-broker condition - it only blocks
   // new arms.
   bool windowOK = SessionOK() && !BlackoutNow();
   bool armOK    = windowOK && SpreadOK() && DailyLimitsOK();

   if(!windowOK)
   {
      if(g_setL.state != ST_NONE) CancelSetup(g_setL, "outside the trading window");
      if(g_setS.state != ST_NONE) CancelSetup(g_setS, "outside the trading window");
      return;
   }
   bool room = (CountMyPositions() + CountMyPendings()) < InpMaxPositions;
   if(InpEntryEngine == ENGINE_PULLBACK)
   {
      if(armOK && room) TryPullback();
      return;
   }
   if(InpEntryEngine == ENGINE_ORB)
   {
      if(armOK && room) TryORB();
      return;
   }
   ProcessSide(g_setL, +1, armOK && room);
   ProcessSide(g_setS, -1, armOK && room);
}
//+------------------------------------------------------------------+


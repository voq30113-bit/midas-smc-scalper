//+------------------------------------------------------------------+
//|                                      MIDAS_Gold_SMC_v3.4.mq5      |
//|   M I D A S  v3.4  -  Gold Scalper + CAPITAL FLOOR                |
//|                                                                  |
//|  v3.4 CHANGELOG  (no trade decision changed; item 2 defaults OFF) |
//|  -------------------------------------------------------------   |
//|  1. NO MORE PositionModify SPAM.  v3.3 backtests logged 200k-316k |
//|     "failed modify ... [Invalid stops] / [Market closed]" lines:  |
//|     ManageOne re-sent the same rejected request on every tick.    |
//|     -> SafeModifySL() skips a modify that cannot change anything: |
//|        a. the SL equals the current one after NormalizeDouble     |
//|           (the server would answer "no changes");                 |
//|        b. the SL is on the wrong side of bid/ask by more than the |
//|           stops level (the server would answer "invalid stops") - |
//|           exact server rule, no extra margin, so nothing the      |
//|           server would accept is skipped;                         |
//|        c. the previous try got MARKET_CLOSED -> wait for the next |
//|           M5 bar instead of retrying on every tick.               |
//|        Used for the 4 modifies in ManageOne (BE + trail, L + S).  |
//|        The comparisons that decide WHEN to move the stop are      |
//|        untouched, so the trade list stays the same.               |
//|  2. InpUseSweepLong / InpUseSweepShort: the LEGACY sweep setup    |
//|     per side (both true = v3.3 behaviour).                        |
//|                                                                  |
//|  v3.3 CHANGELOG  (entry / exit / sizing logic NOT changed)        |
//|  -------------------------------------------------------------   |
//|  Evidence = v3.2 backtest: MetaQuotes-Demo, XAUUSD M5, real       |
//|  ticks, 2021.01.01-2026.10.14, $5,000, LEGACY engine:             |
//|  549 trades, 1098 deals, net +27,108.19.                          |
//|                                                                  |
//|  A. PARTIAL CLOSE NOW WORKS ON NETTING ACCOUNTS                   |
//|     549 trades = exactly 1098 deals (one in, one out, same        |
//|     volume) - not a single partial - yet 31 trades closed at      |
//|     entry +/-$0.20, i.e. on the BE lock that is only set once     |
//|     TP1 is hit. So TP1 fired and the 50% partial silently did     |
//|     nothing: CTrade::PositionClosePartial() is HEDGING-ONLY and   |
//|     returns false on a netting account, which the tester was.     |
//|     -> ClosePartialSafe(): hedging = PositionClosePartial();      |
//|        netting/exchange = opposite market deal of that volume     |
//|        (same magic, comment "<InpComment>|PART"). Failures print  |
//|        retcode + description. Afterwards the SL (and TP) is       |
//|        re-applied if the reducing deal removed or moved it.       |
//|        Used by the TP1 partial and by InpCutLossAtR.              |
//|     -> The v3.2 results are therefore InpUseRunner=false results. |
//|        With the runner ON v3.3 trades DIFFERENTLY from v3.2.      |
//|                                                                  |
//|  B. MARKET CLOCK ANCHORED TO NEW YORK (DST-aware)                 |
//|     The MetaQuotes-Demo server is GMT+2, GMT+3 while the US is    |
//|     on DST = New York + 7 - not UTC. v3.2 was tested with         |
//|     InpServerGMT=0, so every hour input (session, blackouts,      |
//|     Asia, weekend flat, day roll) was really tuned on NY+7.       |
//|     -> InpClock: the clock all hour inputs are written in         |
//|        (NY7 = New York + 7, day rolls at 17:00 New York; or UTC). |
//|     -> InpServerClock: how server time becomes UTC (AUTO measures |
//|        it live and falls back to NYCLOSE in the tester; NYCLOSE = |
//|        UTC+2 / UTC+3 in US DST; FIXED = InpServerGMT as before).  |
//|     -> Input NAMES unchanged (the *UTC suffix stays) so old .set  |
//|        files still load; only their meaning follows InpClock.     |
//|     -> NY7 + NYCLOSE on MetaQuotes data gives ToClock(t)==t for   |
//|        every bar = identical to v3.2 run with InpServerGMT=0.     |
//|                                                                  |
//|  C. BOS SETUP SWITCHABLE PER SIDE + 2 TEST FILTERS (default OFF)  |
//|     SBOS (short BOS) in v3.2: 202 trades, +0.04R/trade, PF 1.07,  |
//|     in 2021-23 AND in 2024-26 - no edge, and the main DD source.  |
//|     -> InpUseBOSLong / InpUseBOSShort (both true = v3.2).         |
//|     -> Test 1 InpBOSRequireZone: LBOS only when the close is in   |
//|        the lower half of the last InpBOSRangeBars range, SBOS     |
//|        only in the upper half.                                    |
//|     -> Test 2 InpBOSD1Filter: LBOS only when D1 close[1] > EMA[1] |
//|        and EMA[1] > EMA[6]; SBOS the mirror image.                |
//|     LEGACY BOS branch only - sweep setups and V3 engine as v3.2.  |
//|                                                                  |
//|  (v3.0 - v3.2 notes follow)                                       |
//|                                                                  |
//|  XAUUSD / M5.  v3 rebuilds the ENTRY half of v2.1 and adds a      |
//|  broker-normalisation layer so ONE .set file behaves identically  |
//|  on several brokers at once (personal + funded).                  |
//|                                                                  |
//|  WHAT CHANGED FROM v2.1 (entry only - exits/shell untouched)      |
//|  -------------------------------------------------------------   |
//|  1. REAL liquidity grabs.  v2.1's SweptSellside() only compared a |
//|     bar to the TWO OLDER bars, so it fired on ~75% of windows -   |
//|     the sweep filter was effectively off.  v3 tracks actual pools |
//|     (pivots, equal highs/lows, Asia range, PDH/PDL) and needs the |
//|     wick THROUGH the pool with the BODY CLOSING BACK INSIDE.      |
//|  2. SEQUENCE, not a bag of flags.  v2.1 ANDed sweep/FVG/CHoCH     |
//|     over overlapping windows with no ordering.  v3 is a state     |
//|     machine: grab -> market-structure shift -> arm -> fill.       |
//|  3. LIMIT ENTRY AT THE ZONE.  v2.1 bought at market on the close  |
//|     of the displacement bar (worst price in the leg) with the     |
//|     stop at LowestLow(10) - measured median stop $4.81 = 481pts.  |
//|     v3 rests a limit in the displacement FVG/OB with the stop     |
//|     just beyond the swept extreme.  Same targets, ~1/3 the R.     |
//|  4. NO point-based inputs.  Every distance is in DOLLARS of gold  |
//|     price or in ATR.  A 2-digit and a 3-digit gold feed disagree  |
//|     on "points" by 10x - that silently broke multi-broker runs.   |
//|  5. UTC SESSIONS.  Server-hour windows meant each broker traded   |
//|     a different part of the day.  v3 converts to UTC first.       |
//|     (v3.3: hours are now read on InpClock - see B above.)         |
//|                                                                  |
//|  MULTI-BROKER CONSISTENCY (why v3 places the same order twice)    |
//|  -------------------------------------------------------------   |
//|   * decisions only on CLOSED M5 bars (bar grid is UTC-aligned, so |
//|     every broker closes M5/H1 bars at the same instant)           |
//|   * pool map REBUILT from bars each bar - no path-dependent state |
//|     that could drift apart between two terminals                  |
//|   * levels confirmed by BODY CLOSES; wicks are where feeds differ |
//|   * all tolerances ATR-relative, so a $0.30 feed offset cannot    |
//|     change which pool is "hit"                                    |
//|   * entries are LIMIT orders: both terminals rest the same price  |
//|     instead of taking two different market fills                  |
//|                                                                  |
//|  InpEntryEngine lets the SAME binary run v2.1 logic (ENGINE_      |
//|  LEGACY) or v3 (ENGINE_V3) so you can A/B on identical data.      |
//+------------------------------------------------------------------+
#property copyright "Built with Claude for Bean"
#property version   "3.40"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================//
//  PART 1 - INPUTS                                                  //
//==================================================================//
input group "=== General ==="
input long   InpMagic          = 580518;           // Magic number
input string InpComment        = "MIDAS_v3";       // Order comment prefix (setup tag is appended)

enum ENUM_DIR { DIR_BOTH=0, DIR_LONG_ONLY=1, DIR_SHORT_ONLY=2 };
input ENUM_DIR InpDirection    = DIR_BOTH;         // Which side(s) may trade

enum ENUM_ENGINE { ENGINE_V3=0, ENGINE_LEGACY=1 };
input ENUM_ENGINE InpEntryEngine = ENGINE_V3;      // V3 = grab->MSS->limit at zone. LEGACY = exact v2.1 entry (for A/B)

input group "=== Broker normalisation (SET THIS PER BROKER) ==="
// v3.3 - two separate questions:
//   InpClock       = which clock ALL hour inputs below (the *UTC ones) are written in
//   InpServerClock = how this broker's server time converts to UTC
enum ENUM_CLOCK
{
   CLOCK_NY7 = 0,     // NY+7 (= MetaQuotes server clock, day rolls 17:00 New York)
   CLOCK_UTC = 1      // UTC
};
input ENUM_CLOCK InpClock      = CLOCK_NY7;        // Clock that every hour input (*UTC names kept) is read in
enum ENUM_SRVCLOCK
{
   SRV_AUTO    = 0,   // AUTO (live: measured; tester: NYCLOSE)
   SRV_NYCLOSE = 1,   // NYCLOSE (UTC+2, UTC+3 in US DST - MetaQuotes)
   SRV_FIXED   = 2    // FIXED (InpServerGMT, e.g. 0 for Exness data)
};
input ENUM_SRVCLOCK InpServerClock = SRV_AUTO;     // Broker server clock -> UTC
input int    InpServerGMT      = 99;               // SRV_FIXED only: server offset from UTC in hours (99 = auto-detect live; SET IT for the tester)
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

input group "=== V3 STEP 1 - Liquidity pools (what counts as liquidity) ==="
input int    InpPoolPivot      = 10;               // Pivot half-width for a pool (v2.1 used 2 = noise). 8-15
input int    InpPoolLookback   = 400;              // M5 bars scanned for pools
input int    InpMaxPools       = 14;               // Max live pools kept per side
input double InpEqTolATR       = 0.15;             // Equal-high/low merge tolerance (x ATR)
input bool   InpUseSessionPools= true;             // Add Asia-range H/L and PDH/PDL as pools
input int    InpAsiaStartUTC   = 0;                // Asia range start (hour on InpClock)
input int    InpAsiaEndUTC     = 7;                // Asia range end (hour on InpClock, exclusive)

input group "=== V3 STEP 2 - The grab (sweep that actually swept) ==="
input double InpGrabWickFrac   = 0.35;             // Min wick / candle-range on the grab bar
input double InpGrabMinPokeATR = 0.05;             // Wick must clear the pool by this x ATR (feed-noise guard)
input int    InpGrabCooldown   = 3;                // Bars before the same side may grab again

input group "=== V3 STEP 3 - Market-structure shift (the trigger) ==="
input int    InpMSSPivot       = 2;                // Fractal half-width of the minor swing the MSS must break
input int    InpMSSLookback    = 15;               // Bars searched for that minor swing
input int    InpMSSMaxBars     = 5;                // MSS must arrive within N bars of the grab, else drop the setup
input double InpMinFVGATR      = 0.35;             // Displacement FVG must be >= this x ATR (replaces fixed 30 points)

input group "=== V3 STEP 4 - The entry (limit order in the zone) ==="
input double InpZoneEntryFrac  = 0.30;             // 0 = proximal edge (fills most), 0.5 = FVG midpoint (better price)
input bool   InpZoneFallbackOB = true;             // If the leg left no qualifying FVG, use the order block
input double InpSLBufferUSD    = 0.30;             // Stop beyond the swept extreme, in DOLLARS ($0.30 = 30 old points)
input double InpSLBufferATR    = 0.25;             // ...or this x ATR, whichever is larger
input double InpMaxSL_ATR      = 2.20;             // Reject the setup if the stop is wider than this x ATR
input double InpMaxSL_USD      = 6.00;             // ...or wider than this many dollars
input int    InpArmExpiryBars  = 10;               // Cancel the resting limit after N M5 bars
input bool   InpRequirePool    = true;             // Reject unless a real pool sits >= InpMinTP1_R away
input bool   InpUseRangeFilter = true;             // Entry must sit in the discount/premium half of the swept leg

input group "=== v3.1 GROWTH ladder (personal account) ==="
input bool   InpUseHyperGrowth = true;             // v2.2 plan, fixed: step risk up as REALIZED balance grows
input double InpBaseRiskPct    = 2.0;              // Starting risk % per trade
input double InpScaleStepPct   = 10.0;             // One risk step per this % of START balance gained (v2.2 used a fixed $100 - it maxed out after +16%)
input double InpScaleAddPct    = 1.0;              // Risk % added per step
input double InpMaxRiskPct     = 4.0;              // Hard cap on risk % per trade. Swept: 3%=44%DD/18x, 4%=53%DD/31x, 8%=77%DD/69x, 10%=84%DD/48x (past growth-optimal)

input group "=== v3.2 CAPITAL FLOOR (the preservation feature) ==="
// The ONE mechanism that survived testing. Everything else here re-parameterises
// risk; this changes the outcome when the EDGE ITSELF fails, which is what a
// preservation feature is actually for. Stress-tested at flat 2% risk:
//                        edge holds            edge gone (0R)
//   no floor        6.68x  p10 2.38x  34%DD    0.71x  p10 0.25x  65%DD
//   floor 50%       6.59x  p10 2.02x  34%DD    0.69x  p10 0.51x  50%DD
//   floor 40%       5.92x  p10 1.05x  34%DD    0.77x  p10 0.60x  41%DD
// 50% costs 1.3% of median return while DOUBLING the bad-case outcome if the
// edge dies. 40% is too tight - normal median DD is 34%, so it fires on healthy
// drawdowns and costs 11%. RULE: set the floor at ~1.5x your expected normal DD.
input bool   InpUseCapitalFloor = true;            // Act when equity falls this far below its PEAK (works with FundedMode off)
input double InpCapitalFloorDD  = 50.0;            // % below the equity peak
enum ENUM_FLOOR_ACT { FLOOR_HALT=0, FLOOR_THROTTLE=1 };
input ENUM_FLOOR_ACT InpFloorAction = FLOOR_HALT;  // HALT = stop for the run. THROTTLE = keep trading at reduced size
input double InpFloorRiskMult   = 0.25;            // Risk multiplier when THROTTLE is chosen

input group "=== v3.2 Milestone ratchet (RETURN-NEUTRAL - see note) ==="
// Your idea: re-anchor the risk ladder each time the balance makes a new
// milestone, so risk drops back to base after banking a gain. Implemented and
// tested - it is neutral, not harmful. Over 20,000 bootstrapped orderings it
// lands ON the flat-risk curve, not above it:
//   cap4% + ratchet+25% -> 7.15x at 35.6% DD ; flat risk at 35.6% DD -> 7.20x  (-0.6%)
// It also gave no protection when the edge was halved, zeroed or made adverse.
// It is a re-parameterisation of risk LEVEL, not a source of edge - the capital
// floor above is what actually preserves capital. Left switchable; default OFF.
input bool   InpUseRatchet      = false;           // Re-anchor the ladder at each milestone
input double InpRatchetPct      = 25.0;            // Re-anchor after this % gain over the anchor

input group "=== v3.1 DRAWDOWN CONTROL ==="
// MEASURED ON YOUR OWN 536 TRADES - read before switching these on:
//   lag-1..5 autocorrelation of R: -0.08..+0.04, runs test z=+1.19.
//   The win/loss sequence is statistically indistinguishable from random, so
//   losses do NOT cluster and there is nothing for a throttle to predict.
//   Worse, expectancy AFTER losses was higher, not lower:
//     0 prior losses +0.203R | 3+ prior losses +0.385R
//     near equity peak +0.208R | >20% below peak +0.388R
//   Bootstrapped, throttling is strictly dominated: cap10%+throttle+brake gave
//   8.3x median at 44% DD, while a plain 3% cap gave 18.3x at 44% DD - same
//   drawdown, double the return. Both default OFF. Enable only if live data
//   ever shows genuine loss clustering.
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
input bool   InpFlatBeforeWeekend = true;          // Flatten + cancel before the weekend gap (stops cannot protect a gap)
input int    InpWeekendFlatUTC = 19;               // Friday hour to flatten (on InpClock)
input double InpCutLossAtR     = 0.0;              // Partial-close when a trade is this far offside in R (0 = off)
input double InpCutLossPct     = 50.0;             // % of the position closed at that point

input group "=== Risk & Sizing ==="
input bool   InpUseFixedLot    = false;            // Fixed lot instead of % risk
input double InpFixedLot       = 0.01;             // Fixed lot
input double InpRiskPercent    = 0.15;             // Base risk % of balance (used when GrowthMode OFF)
input double InpMaxOzPer5k     = 100.0;            // BACKSTOP ONLY: max ounces per $5k. Keep it non-binding so InpMaxRiskPct governs sizing. 5.0 caps a $5k account at 0.05 lots = ~0.6% risk, whatever you set the risk to.
input bool   InpGrowthMode     = true;             // Risk a fixed fraction of drawdown headroom (grows with profit)
input double InpHeadroomRiskPct= 10.0;             // GrowthMode: risk this % of (equity - floor) per trade
input double InpGrowthMaxRiskPct= 1.00;            // GrowthMode: hard cap, % of balance per trade

input group "=== SMC Exits (unchanged from v2.1) ==="
input bool   InpUseRunner      = true;             // Partial at TP1 + let a runner go
input double InpPartialPct     = 50.0;             // % closed at TP1 (first pool)
input double InpBE_LockUSD     = 0.20;             // Dollars locked at BE after TP1
input double InpMinTP1_R       = 1.5;              // First pool must be >= this many R away
input int    InpLiqLookback    = 180;              // Bars scanned for target pools
input double InpStructTrailUSD = 0.30;             // Structural trail buffer, in dollars
input double InpFallbackTP1_R  = 1.5;              // Fallback TP1 (R) when no pool ahead
input bool   InpUseLadder      = true;             // Liquidity-ladder stop (SL climbs pool rungs)
input int    InpMaxRungs       = 4;                // Max pool rungs in the ladder

input group "=== LEGACY engine only (v2.1 entry, kept for A/B) ==="
input bool   InpRequireSweep   = true;             // LEGACY: require the old sweep test
input double InpWickRatio      = 0.50;             // LEGACY: min wick/range
input int    InpSweepLookback  = 8;                // LEGACY: sweep window
input bool   InpRequireFVG     = true;             // LEGACY: require an FVG
input double InpMinFVGUSD      = 0.30;             // LEGACY: min FVG size in dollars
input int    InpFVGFreshness   = 2;                // LEGACY: FVG age
input bool   InpRequireCHoCH   = false;            // LEGACY: require an M5 break
input bool   InpUseSweepSetup  = true;             // LEGACY: setup 1
input bool   InpUseSweepLong   = true;             // v3.4 LEGACY: allow the long sweep setup (LSW)
input bool   InpUseSweepShort  = true;             // v3.4 LEGACY: allow the short sweep setup (SSW)
input bool   InpUseBOSSetup    = true;             // LEGACY: setup 2 (no location filter - the leak)
input bool   InpUseBOSLong     = true;             // v3.3 LEGACY: allow the long BOS setup (LBOS)
input bool   InpUseBOSShort    = true;             // v3.3 LEGACY: allow the short BOS setup (SBOS: 202 tr, +0.04R, PF 1.07 in v3.2)
input bool   InpBOSRequireFVG  = true;             // LEGACY: BOS also needs an FVG
input bool   InpBOSRequireZone = false;            // v3.3 TEST 1: LBOS only in the lower half / SBOS only in the upper half of the range
input int    InpBOSRangeBars   = 48;               // v3.3 TEST 1: M5 bars that define that range
input bool   InpBOSD1Filter    = false;            // v3.3 TEST 2: LBOS needs D1 close>EMA and EMA rising over 5 days; SBOS the mirror
input int    InpD1EMA          = 50;               // v3.3 TEST 2: D1 EMA period
input double InpLegacySLBufUSD = 0.50;             // LEGACY: buffer beyond LowestLow(10), dollars
input bool   InpUseLTF         = true;             // LEGACY: M1 candle-count confirmation
input ENUM_TIMEFRAMES InpLTF   = PERIOD_M1;        // LEGACY: confirmation timeframe
input int    InpLongLTFBars    = 2;                // LEGACY: M1 confirms for longs
input int    InpShortLTFBars   = 2;                // LEGACY: M1 confirms for shorts

input group "=== Side tunes (both engines) ==="
input bool   InpLongHTFStrict  = true;             // Longs require a real H1 uptrend
input bool   InpLongUsePremDisc= true;             // Longs only in discount
input double InpLongDiscountPct= 0.50;             // How low in the range a long is allowed
input bool   InpShortHTFStrict = true;             // Shorts require an H1 downtrend
input bool   InpShortUsePremDisc= true;            // Shorts only in premium

input group "=== Filters ==="
input double InpMaxSpreadUSD   = 0.35;             // EXECUTION gate: skip if spread > this many dollars (per-broker)
input double InpMaxSpreadATR   = 0.25;             // ...and skip if spread > this x ATR (broker-neutral)
input bool   InpUseSession     = true;             // Restrict to a session
input int    InpSessionStartUTC= 7;                // Session start (hour on InpClock)
input int    InpSessionEndUTC  = 21;               // Session end (hour on InpClock, exclusive)
input bool   InpUseBlackout    = true;             // Blackout A (NY open / US data)
input int    InpBlackoutStartUTC= 16;              // Blackout A start (hour on InpClock)
input int    InpBlackoutEndUTC = 18;               // Blackout A end (hour on InpClock, exclusive)
input bool   InpUseBlackout2   = true;             // Blackout B (evening)
input int    InpBlackout2StartUTC= 19;             // Blackout B start (hour on InpClock)
input int    InpBlackout2EndUTC= 20;               // Blackout B end (hour on InpClock, exclusive)
input int    InpMaxTradesDay   = 3;                // Max FILLS per day
input double InpDailyLossPct   = 2.0;              // Flatten + block for the day at this DD %

input group "=== Funded-account shell (match YOUR firm) ==="
input bool   InpFundedMode     = true;             // Prop guardrails ON
input double InpFundedStartBal = 0;                // Funded starting balance (0 = auto-detect)
input double InpStaticFloorPct = 3.0;              // HALT this % below the initial balance
input double InpTrailingDDPct  = 0;                // HALT this % from the equity peak (0 = off)
input double InpMinMarginLevel = 200.0;            // Refuse/shrink a trade below this margin level %
input bool   InpFlattenOnHalt  = true;             // Close open trades on a hard halt
input bool   InpDeriskInDD     = true;             // Shrink risk near the floor (ignored when GrowthMode ON)
input double InpDeriskMinFactor= 0.35;             // Risk multiplier AT the floor
input int    InpMaxPositions   = 1;                // Max concurrent positions (pendings count as exposure)
input bool   InpResetState     = false;            // ON once to wipe saved day/floor state

input group "=== Dashboard ==="
input bool   InpShowPanel      = true;             // Top-right info panel
input bool   InpPanelBox       = false;            // Background box behind the panel
input int    InpPanelX         = 80;               // Right margin (px)
input int    InpPanelY         = 22;               // Top margin (px)

//==================================================================//
//  PART 2 - GLOBALS                                                 //
//==================================================================//
MqlRates  g_m5[];               // M5 series, [0] = forming bar
MqlRates  g_htf[];              // HTF series
MqlRates  g_ltf[];              // LTF series (legacy engine only)
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
double    g_contract   = 100.0;  // ounces per lot (read from the symbol)
int       g_srvGMT     = 0;      // resolved server->UTC offset in hours (SRV_AUTO live / SRV_FIXED)
ENUM_SRVCLOCK g_srvMode = SRV_FIXED;   // v3.3 effective server-clock mode (AUTO -> NYCLOSE in the tester)
int       g_dstYear    = 0;      // v3.3 IsUSDST() cache: year whose DST window is held below
datetime  g_dstYrLo    = 0, g_dstYrHi = 0;   // [1 Jan, next 1 Jan) of that year
datetime  g_dstOn      = 0, g_dstOff  = 0;   // US DST window of that year, in UTC
int       g_d1EmaHandle = INVALID_HANDLE;    // v3.3 BOS D1 filter (created only when InpBOSD1Filter)
datetime  g_modBlockBar = 0;     // v3.4 M5 bar of the last MARKET_CLOSED modify reply (0 = none)
int       g_atrHandle  = INVALID_HANDLE;
double    g_atr        = 0;      // ATR(14) on M5, in price dollars

// per-direction runner tracking
ulong     g_tkLong=0,   g_tkShort=0;
double    g_riskLong=0, g_riskShort=0;
double    g_tp1Long=0,  g_tp1Short=0;
bool      g_doneLong=false, g_doneShort=false;
double    g_ladderL[12], g_ladderS[12];
int       g_nRungsL=0,  g_nRungsS=0;
int       g_reachedL=0, g_reachedS=0;

// ---- v3 pool map (rebuilt from bars every M5 close - stateless by design) ----
struct SPool
{
   double price;      // the level
   int    idx;        // bar index where it formed
   int    hits;       // how many pivots merged into it (equal highs/lows = stronger)
   int    kind;       // 0 pivot, 1 Asia range, 2 previous day
};
SPool  g_bsl[];       // buy-side pools (highs) - live only
SPool  g_ssl[];       // sell-side pools (lows) - live only
double g_bMaxTo[];    // running max BodyHi over bars 1..i-1 (pool invalidation, O(1))
double g_bMinTo[];    // running min BodyLo over bars 1..i-1

// ---- v3 setup state machine (one live setup per side) ----
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
   ulong  ticket;        // resting limit order
   string tag;
};
SSetup g_setL, g_setS;

// ---- v3.1 risk-layer state ----
bool   g_floorHalt   = false;  // v3.2 capital floor breached (personal-account kill switch)
int    g_ceilHits    = 0;      // times the lot ceiling overrode the risk setting
double g_startBal    = 0;      // actual starting balance - the ladder anchor
double g_peakBal     = 0;      // realized balance high-water (vault basis)
double g_vault       = 0;      // profit locked out of the sizing base
int    g_lossStreak  = 0;      // consecutive full-trade losses
bool   g_cutLong=false, g_cutShort=false;   // InpCutLossAtR already fired this trade
long   g_accId[8];             // per-position P&L accumulator (partial closes)
double g_accPnl[8];
int    g_lastGrabBarL = -999, g_lastGrabBarS = -999;
int    g_barCounter   = 0;      // monotonic M5 bar counter for cooldowns

string PFX = "midas3_";

//==================================================================//
//  PART 3 - INIT / DEINIT                                           //
//==================================================================//
void ClearSetup(SSetup &s)
{
   s.state=ST_NONE; s.dir=0; s.age=0; s.poolPrice=0; s.poolKind=0;
   s.sweepExt=0; s.mssLevel=0; s.zoneLo=0; s.zoneHi=0;
   s.entry=0; s.sl=0; s.riskDist=0; s.ticket=0; s.tag="";
}

int OnInit()
{
   g_point  = _Point;
   g_digits = _Digits;
   g_contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(g_contract <= 0) g_contract = 100.0;

   ArraySetAsSeries(g_m5,  true);
   ArraySetAsSeries(g_htf, true);
   ArraySetAsSeries(g_ltf, true);

   ClearSetup(g_setL); ClearSetup(g_setS);
   ArrayInitialize(g_accId, 0);
   ArrayInitialize(g_accPnl, 0.0);
   g_startBal = (InpFundedStartBal > 0) ? InpFundedStartBal : AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakBal  = AccountInfoDouble(ACCOUNT_BALANCE);

   // The v2.2 hypergrowth run left InpFundedStartBal at 200 on a $5,000 deposit.
   // grown = 5000-200 = 4800 -> the ladder jumped straight to its cap, so every
   // trade risked the 10% maximum from the very first one. Refuse to repeat it
   // silently: that setting is the difference between a 2% ramp and a 92% DD.
   {
      double liveBal = AccountInfoDouble(ACCOUNT_BALANCE);
      if(InpFundedStartBal > 0 && liveBal > 0 &&
         (InpFundedStartBal > liveBal*1.5 || InpFundedStartBal < liveBal*0.67))
         PrintFormat("MIDAS v3.1 WARNING: InpFundedStartBal=%.2f but the balance is %.2f. "
                     "The risk ladder anchors on that number - set it to the real starting "
                     "balance or leave it 0 to auto-detect. Risk would start at %.2f%%.",
                     InpFundedStartBal, liveBal, BaseRiskPct());
   }

   g_atrHandle = iATR(_Symbol, PERIOD_M5, 14);
   if(g_atrHandle == INVALID_HANDLE){ Print("MIDAS v3: ATR handle failed"); return(INIT_FAILED); }

   // v3.3 BOS test 2. Only built when the filter is on, so a run with it off
   // loads nothing extra and stays identical to v3.2.
   if(InpBOSD1Filter)
   {
      g_d1EmaHandle = iMA(_Symbol, PERIOD_D1, InpD1EMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_d1EmaHandle == INVALID_HANDLE){ Print("MIDAS v3.3: D1 EMA handle failed"); return(INIT_FAILED); }
   }

   ResolveServerClock();

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   InitDayState();
   InitFundedState();

   // v3.3: the partial-close route depends on this (see ClosePartialSafe).
   PrintFormat("MIDAS v3.3 margin mode: %s -> partial closes via %s",
               MarginModeName(), (IsHedgingAccount() ? "PositionClosePartial()" : "opposite market deal"));

   if(InpLogNormalise)
   {
      PrintFormat("MIDAS v3 init | %s digits=%d point=%.5f contract=%.0f oz | server=%s UTC%+d | clock=%s | engine=%s",
                  _Symbol, g_digits, g_point, g_contract, SrvModeName(), SrvOffsetNow(), ClockName(),
                  (InpEntryEngine==ENGINE_V3 ? "V3" : "LEGACY"));
      ClockSelfTest();
   }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, PFX);
   Comment("");
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_d1EmaHandle != INVALID_HANDLE){ IndicatorRelease(g_d1EmaHandle); g_d1EmaHandle = INVALID_HANDLE; }
}

// v3.3. Server clocks differ per broker (Exness GMT+0, MetaQuotes and most props
// GMT+2/+3 = New York + 7) and shift with DST. This resolves HOW server time
// becomes UTC; InpClock then decides which clock the hour inputs are read in.
// Live AUTO measures the offset. In the tester TimeGMT()==TimeTradeServer(), so
// AUTO cannot measure anything there and falls back to NYCLOSE.
void ResolveServerClock()
{
   bool tester = (MQLInfoInteger(MQL_TESTER) != 0);
   g_srvMode = InpServerClock;
   if(g_srvMode == SRV_AUTO)
   {
      if(tester)
      {
         g_srvMode = SRV_NYCLOSE;
         Print("MIDAS v3.3 WARNING: InpServerClock=AUTO cannot measure the server offset in the tester - "
               "using SRV_NYCLOSE (UTC+2, UTC+3 in US DST = MetaQuotes). "
               "For a GMT+0 broker's own data use SRV_FIXED with InpServerGMT=0.");
         return;
      }
      g_srvGMT = (int)MathRound((double)((long)TimeTradeServer() - (long)TimeGMT()) / 3600.0);
      return;
   }
   if(g_srvMode == SRV_NYCLOSE) return;

   // SRV_FIXED = the v3.2 InpServerGMT behaviour, unchanged.
   if(InpServerGMT != 99){ g_srvGMT = InpServerGMT; return; }
   if(tester)
   {
      g_srvGMT = 0;
      Print("MIDAS v3 WARNING: InpServerGMT=99 (auto) has no meaning in the tester - "
            "assuming server=UTC+0. Set it explicitly to match the broker you are testing.");
      return;
   }
   g_srvGMT = (int)MathRound((double)((long)TimeTradeServer() - (long)TimeGMT()) / 3600.0);
}

// True when the offset was measured from the live clock and must be re-measured
// across a DST change.
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
//  v3.3 MARKET CLOCK                                                 //
//  server time --ServerToUTC()--> UTC --> InpClock (NY+7 or UTC).    //
//  NY+7 = New York + 7 = UTC+2, UTC+3 while the US is on DST - the   //
//  MetaQuotes server clock, so on its data ToClock(t)==t for every   //
//  bar and the hour inputs mean exactly what they meant in v3.2.     //
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

// Explicit-mode versions so the init self-test can check NYCLOSE/NY7 whatever
// this run's inputs are.
datetime SrvToUTCMode(datetime srv, ENUM_SRVCLOCK mode, int fixedOff)
{
   if(mode == SRV_NYCLOSE)
   {
      // srv-2h is on the correct side of the DST switch for every server time
      // that exists (only the skipped 09:00-10:00 of the March switch Sunday is
      // ambiguous, and the market is shut then).
      int off = IsUSDST((datetime)((long)srv - 7200)) ? 3 : 2;
      return (datetime)((long)srv - (long)off*3600);
   }
   return (datetime)((long)srv - (long)fixedOff*3600);
}
datetime UTCToClockMode(datetime utc, ENUM_CLOCK clk)
{
   if(clk == CLOCK_UTC) return utc;
   return (datetime)((long)utc + (long)(IsUSDST(utc) ? 3 : 2)*3600);
}

datetime ServerToUTC(datetime srv){ return SrvToUTCMode(srv, g_srvMode, g_srvGMT); }
datetime ToClock(datetime srv)    { return UTCToClockMode(ServerToUTC(srv), InpClock); }
int      ClockHour(datetime srv){ MqlDateTime d; TimeToStruct(ToClock(srv), d); return d.hour; }
long     ClockDayKey(datetime srv)
{
   MqlDateTime d; TimeToStruct(ToClock(srv), d);
   return (long)d.year*10000 + (long)d.mon*100 + (long)d.day;
}

// Current server offset from UTC, for the panel / log.
int    SrvOffsetNow(){ datetime s = TimeCurrent(); return (int)(((long)s - (long)ServerToUTC(s)) / 3600); }
string ClockName()   { return (InpClock == CLOCK_NY7) ? "NY+7" : "UTC"; }
string SrvModeName()
{
   if(g_srvMode == SRV_NYCLOSE) return "NYCLOSE";
   if(g_srvMode == SRV_AUTO)    return "AUTO";
   return "FIXED";
}

// Printed at init when InpLogNormalise. Expected values are for a NY-close
// server (MetaQuotes) read on the NY+7 clock, so those modes are forced here.
void ClockSelfTest()
{
   datetime srv[6] = { D'2024.01.15 10:00', D'2024.07.15 10:00',
                       D'2024.03.10 08:00', D'2024.03.10 10:00',
                       D'2024.11.03 07:00', D'2024.11.03 10:00' };
   datetime exU[6] = { D'2024.01.15 08:00', D'2024.07.15 07:00',
                       D'2024.03.10 06:00', D'2024.03.10 07:00',
                       D'2024.11.03 04:00', D'2024.11.03 08:00' };
   string   what[6]= { "winter", "summer", "DST start, before", "DST start, after",
                       "DST end, before", "DST end, after" };
   int fails = 0;
   for(int i=0;i<6;i++)
   {
      datetime u = SrvToUTCMode(srv[i], SRV_NYCLOSE, 0);
      datetime c = UTCToClockMode(u, CLOCK_NY7);
      bool ok = (u == exU[i] && c == srv[i]);
      if(!ok) fails++;
      PrintFormat("CLOCK TEST %s srv %s -> UTC %s (exp %s) -> NY+7 %s (exp %s) %s",
                  what[i], TimeToString(srv[i], TIME_DATE|TIME_MINUTES),
                  TimeToString(u, TIME_MINUTES), TimeToString(exU[i], TIME_MINUTES),
                  TimeToString(c, TIME_MINUTES), TimeToString(srv[i], TIME_MINUTES),
                  (ok ? "OK" : "FAIL"));
   }
   // The DST edges themselves.
   bool e1 = !IsUSDST(D'2024.03.10 06:59') &&  IsUSDST(D'2024.03.10 07:00');
   bool e2 =  IsUSDST(D'2024.11.03 05:59') && !IsUSDST(D'2024.11.03 06:00');
   if(!e1) fails++;
   if(!e2) fails++;
   PrintFormat("CLOCK TEST US DST edges: 2024.03.10 07:00 UTC %s | 2024.11.03 06:00 UTC %s",
               (e1 ? "OK" : "FAIL"), (e2 ? "OK" : "FAIL"));
   PrintFormat("CLOCK TEST %s (%d failure%s)", (fails==0 ? "PASSED" : "FAILED"), fails, (fails==1 ? "" : "s"));

   datetime now = TimeCurrent();
   PrintFormat("CLOCK active: server=%s clock=%s | srv %s -> UTC %s -> %s %s",
               SrvModeName(), ClockName(), TimeToString(now, TIME_DATE|TIME_MINUTES),
               TimeToString(ServerToUTC(now), TIME_DATE|TIME_MINUTES),
               ClockName(), TimeToString(ToClock(now), TIME_DATE|TIME_MINUTES));
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
string GVN(string s){ return "MIDAS3_" + (string)AccountInfoInteger(ACCOUNT_LOGIN) + "_" + (string)InpMagic + "_" + _Symbol + "_" + s; }

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
   if(!InpUseSession) return true;
   return InWindow(ClockHour(TimeCurrent()), InpSessionStartUTC, InpSessionEndUTC);
}

bool BlackoutNow()
{
   int h = ClockHour(TimeCurrent());
   if(InpUseBlackout  && InWindow(h, InpBlackoutStartUTC,  InpBlackoutEndUTC))  return true;
   if(InpUseBlackout2 && InWindow(h, InpBlackout2StartUTC, InpBlackout2EndUTC)) return true;
   return false;
}

// Two gates. The USD one is the per-broker execution cost gate; the ATR one is
// broker-neutral so a volatility spike is skipped identically on both accounts.
bool SpreadOK()
{
   double spr = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(spr <= 0) return true;
   if(InpMaxSpreadUSD > 0 && spr > InpMaxSpreadUSD) return false;
   if(InpMaxSpreadATR > 0 && g_atr > 0 && spr > InpMaxSpreadATR*g_atr) return false;
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
   if(g_tradesToday >= InpMaxTradesDay) return false;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (g_dayStartEq>0) ? (g_dayStartEq-eq)/g_dayStartEq*100.0 : 0.0;
   if(dd >= InpDailyLossPct){ g_blockedToday = true; StoreDayState(); return false; }
   return true;
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
   int n = MathMin(ArraySize(g_m5)-1, 620);      // >2 UTC days, independent of InpPoolLookback

   for(int i=1;i<=n;i++)
   {
      long dk = ClockDayKey(g_m5[i].time);
      int  hr = ClockHour(g_m5[i].time);
      if(dk == today && InWindow(hr, InpAsiaStartUTC, InpAsiaEndUTC))
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
   BuildBodyExtremes(MathMin(ArraySize(g_m5)-1, 620));
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
//  PART 10 - LEGACY DETECTORS (v2.1 engine, kept verbatim for A/B)  //
//==================================================================//
bool RefreshLTF()
{
   int need = MathMax(InpLongLTFBars, InpShortLTFBars) + 3;
   return (CopyRates(_Symbol, InpLTF, 1, need, g_ltf) >= need);
}
bool LTFBullish()
{
   if(!InpUseLTF) return true;
   if(ArraySize(g_ltf) < InpLongLTFBars) return false;
   for(int i = 0; i < InpLongLTFBars; i++)
      if(g_ltf[i].close <= g_ltf[i].open) return false;
   return true;
}
bool LTFBearish()
{
   if(!InpUseLTF) return true;
   if(ArraySize(g_ltf) < InpShortLTFBars) return false;
   for(int i = 0; i < InpShortLTFBars; i++)
      if(g_ltf[i].close >= g_ltf[i].open) return false;
   return true;
}

bool SweptSellside(int maxBars)
{
   int hi = MathMin(maxBars, ArraySize(g_m5)-3);
   for(int j = 1; j <= hi; j++)
   {
      double range = H(g_m5,j) - L(g_m5,j);
      if(range <= 0) continue;
      double lowerWick = BodyLo(g_m5,j) - L(g_m5,j);
      if(L(g_m5,j) < L(g_m5,j+1) && L(g_m5,j) < L(g_m5,j+2) &&
         lowerWick >= InpWickRatio*range) return true;
   }
   return false;
}
bool SweptBuyside(int maxBars)
{
   int hi = MathMin(maxBars, ArraySize(g_m5)-3);
   for(int j = 1; j <= hi; j++)
   {
      double range = H(g_m5,j) - L(g_m5,j);
      if(range <= 0) continue;
      double upperWick = H(g_m5,j) - BodyHi(g_m5,j);
      if(H(g_m5,j) > H(g_m5,j+1) && H(g_m5,j) > H(g_m5,j+2) &&
         upperWick >= InpWickRatio*range) return true;
   }
   return false;
}
bool FindBullishFVG()
{
   for(int k = 1; k <= InpFVGFreshness; k++)
   {
      if(k+2 > ArraySize(g_m5)-1) break;
      if(L(g_m5,k) - H(g_m5,k+2) >= InpMinFVGUSD) return true;
   }
   return false;
}
bool FindBearishFVG()
{
   for(int k = 1; k <= InpFVGFreshness; k++)
   {
      if(k+2 > ArraySize(g_m5)-1) break;
      if(L(g_m5,k+2) - H(g_m5,k) >= InpMinFVGUSD) return true;
   }
   return false;
}
bool M5Discount(){ if(g_m5High<=0||g_m5Low<=0) return false; return C(g_m5,1) < g_m5Low + InpLongDiscountPct*(g_m5High-g_m5Low); }
bool M5Premium (){ if(g_m5High<=0||g_m5Low<=0) return false; return C(g_m5,1) > (g_m5High+g_m5Low)/2.0; }

double LowestLow(int bars)
{
   double m = L(g_m5,1); int hi = MathMin(bars, ArraySize(g_m5)-1);
   for(int i=1;i<=hi;i++) m = MathMin(m, L(g_m5,i));
   return m;
}
double HighestHigh(int bars)
{
   double m = H(g_m5,1); int hi = MathMin(bars, ArraySize(g_m5)-1);
   for(int i=1;i<=hi;i++) m = MathMax(m, H(g_m5,i));
   return m;
}

// v3.3 BOS TEST 1 - location. LBOS only when the close sits in the lower half
// of the last InpBOSRangeBars range, SBOS only in the upper half.
bool BOSZoneOK(bool isLong)
{
   double lo = LowestLow(InpBOSRangeBars);
   double hi = HighestHigh(InpBOSRangeBars);
   if(hi <= lo) return false;
   double mid = (hi + lo) / 2.0;
   return isLong ? (C(g_m5,1) < mid) : (C(g_m5,1) > mid);
}

// v3.3 BOS TEST 2 - daily trend. [1] = last closed D1 bar. Any copy failure
// means no BOS trade.
bool BOSD1OK(bool isLong)
{
   if(g_d1EmaHandle == INVALID_HANDLE) return false;
   double e1[], e6[], c1[];
   if(CopyBuffer(g_d1EmaHandle, 0, 1, 1, e1) < 1) return false;
   if(CopyBuffer(g_d1EmaHandle, 0, 6, 1, e6) < 1) return false;
   if(CopyClose(_Symbol, PERIOD_D1, 1, 1, c1) < 1) return false;
   if(e1[0] <= 0 || e6[0] <= 0 || e1[0] == EMPTY_VALUE || e6[0] == EMPTY_VALUE) return false;
   return isLong ? (c1[0] > e1[0] && e1[0] > e6[0])
                 : (c1[0] < e1[0] && e1[0] < e6[0]);
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

   if(InpUseHyperGrowth)                       // v3.1 personal-account ladder
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

   // Drawdown throttle and streak brake apply to EVERY sizing path.
   riskMoney *= RiskMult();
   if(riskMoney <= 0) return 0.0;

   double lossPerLot = 0.0;
   ENUM_ORDER_TYPE ot = isLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(ot, _Symbol, 1.0, entry, sl, lossPerLot))
      return 0.0;
   lossPerLot = MathAbs(lossPerLot);
   if(lossPerLot <= 0) return 0.0;

   double lot = riskMoney / lossPerLot;

   double normalized = NormalizeLot(lot);
   if(normalized * lossPerLot > riskMoney * 1.05)
      normalized = NormalizeLot(normalized - SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));

   // Ceiling in OUNCES, not lots: brokers using a 10oz or 1oz contract would
   // otherwise get 10x/100x the intended exposure from the same .set file.
   double maxLots = (balance/5000.0) * InpMaxOzPer5k / g_contract;
   double ceiling = NormalizeLot(maxLots);
   if(ceiling > 0 && normalized > ceiling)
   {
      // Silent-misconfiguration detector. The first v3.1 backtest ran with
      // InpMaxOzPer5k=5.0 carried over from the funded profile: the ceiling
      // bound EVERY trade, so a configured 2->4% ladder actually traded at
      // 0.56%, and the result read as a weak edge rather than a capped one.
      if(g_ceilHits < 5)
      {
         g_ceilHits++;
         PrintFormat("MIDAS v3.1 NOTE: lot ceiling bound this trade (%.2f -> %.2f lots). "
                     "Actual risk %.2f%% vs configured %.2f%%. Raise InpMaxOzPer5k so "
                     "InpMaxRiskPct governs sizing.%s",
                     normalized, ceiling,
                     ceiling*lossPerLot/MathMax(balance,1.0)*100.0, BaseRiskPct()*RiskMult(),
                     (g_ceilHits==5 ? " (further notices suppressed)" : ""));
      }
      normalized = ceiling;
   }

   if(InpFundedMode && InpMinMarginLevel > 0)
   {
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
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

// Step 4: turn a confirmed setup into a resting limit order.
bool ArmSetup(SSetup &s)
{
   double lo, hi;
   if(!ZoneFromLeg(s.dir, s.age + 1, s.sweepExt, lo, hi)) return false;
   if(hi <= lo) return false;

   double entry, sl;
   double buf = MathMax(InpSLBufferUSD, InpSLBufferATR*g_atr);

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
   if(InpMaxSL_ATR > 0 && R > InpMaxSL_ATR*g_atr) return false;      // too wide -> not a scalp
   if(InpMaxSL_USD > 0 && R > InpMaxSL_USD)       return false;

   // The limit must sit the correct side of the market, clear of the stops level.
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minD = MinStopDistance();
   if(s.dir > 0 && entry > ask - minD) return false;                  // price already past the zone
   if(s.dir < 0 && entry < bid + minD) return false;

   // Location: the entry must be in the discount (longs) / premium (shorts) half
   // of the leg that the grab created - a real dealing range, not two adjacent
   // 5-bar fractals like v2.1 used.
   if(InpUseRangeFilter)
   {
      int span = MathMin(s.age + InpMSSLookback, ArraySize(g_m5)-1);
      double legHi = H(g_m5,1), legLo = L(g_m5,1);
      for(int i=1;i<=span;i++){ legHi = MathMax(legHi, H(g_m5,i)); legLo = MathMin(legLo, L(g_m5,i)); }
      double mid = (legHi + legLo) / 2.0;
      if(s.dir > 0 && InpLongUsePremDisc  && entry > legLo + InpLongDiscountPct*(legHi-legLo)) return false;
      if(s.dir < 0 && InpShortUsePremDisc && entry < mid) return false;
   }

   // A real pool must be within reach, otherwise there is nothing to target.
   double t1, t2;
   int nPools = (s.dir > 0) ? LiquidityAbove(entry, InpMinTP1_R*R, t1, t2)
                            : LiquidityBelow(entry, InpMinTP1_R*R, t1, t2);
   if(InpRequirePool && nPools < 1) return false;

   double lot = CalcLot(s.dir > 0, entry, sl);
   if(lot <= 0) return false;

   entry = NormalizeDouble(entry, g_digits);
   sl    = NormalizeDouble(sl,    g_digits);

   string kindTxt = (s.poolKind==1 ? "ASIA" : (s.poolKind==2 ? "PDHL" : "PIV"));
   s.tag = InpComment + "|SW" + kindTxt;                              // tag so reports can split by setup

   bool ok = (s.dir > 0)
           ? trade.BuyLimit (lot, entry, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, s.tag)
           : trade.SellLimit(lot, entry, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, s.tag);
   if(!ok)
   {
      PrintFormat("MIDAS v3: limit rejected dir=%d entry=%.2f sl=%.2f lot=%.2f err=%d",
                  s.dir, entry, sl, lot, trade.ResultRetcode());
      return false;
   }

   s.ticket   = trade.ResultOrder();
   s.zoneLo   = lo;  s.zoneHi = hi;
   s.entry    = entry; s.sl = sl; s.riskDist = R;
   s.state    = ST_ARMED;
   PrintFormat("ARM %s pool=%.2f(%s) sweep=%.2f zone=%.2f-%.2f entry=%.2f sl=%.2f R=%.2f atr=%.2f lot=%.2f",
               (s.dir>0?"LONG":"SHORT"), s.poolPrice, kindTxt, s.sweepExt, lo, hi, entry, sl, R, g_atr, lot);
   return true;
}

void CancelSetup(SSetup &s, string why)
{
   if(s.ticket > 0 && OrderSelect(s.ticket)) trade.OrderDelete(s.ticket);
   if(s.state != ST_NONE)
      PrintFormat("DROP %s setup (%s)", (s.dir>0?"LONG":"SHORT"), why);
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
      RegisterNewPosition(isLong, s.riskDist, tp1);
      PrintFormat("FILL %s @%.2f tp1=%.2f R=%.2f", (isLong?"LONG":"SHORT"), fill, tp1, s.riskDist);
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

   s.state = ST_SWEPT; s.dir = dir; s.age = 0;
   s.poolPrice = pool; s.poolKind = kind; s.sweepExt = ext; s.mssLevel = mss;
   if(isLong) g_lastGrabBarL = g_barCounter; else g_lastGrabBarS = g_barCounter;
   PrintFormat("GRAB %s pool=%.2f ext=%.2f -> needs close %s %.2f",
               (isLong?"SELLSIDE":"BUYSIDE"), pool, ext, (isLong?">":"<"), mss);
}

//==================================================================//
//  PART 15 - LEGACY ENTRY (v2.1 verbatim, for A/B only)             //
//==================================================================//
void TryEnterLong()
{
   if(InpDirection == DIR_SHORT_ONLY) return;
   if(HasLong()) return;
   if(!HTFAllowsLong()) return;
   if(InpUseHTFZone && !HTFDiscount()) return;
   if(!LTFBullish()) return;

   bool sweepSetup=false, bosSetup=false;
   if(InpUseSweepSetup && InpUseSweepLong)
   {
      bool ok=true;
      if(InpRequireFVG   && !FindBullishFVG()) ok=false;
      if(InpRequireSweep && !SweptSellside(InpSweepLookback + InpFVGFreshness)) ok=false;
      if(InpRequireCHoCH && g_lastBreakDir != +1) ok=false;
      if(InpLongUsePremDisc && !M5Discount()) ok=false;
      sweepSetup=ok;
   }
   if(InpUseBOSSetup && InpUseBOSLong)
   {
      bool ok=FreshBreakUp();
      if(InpBOSRequireFVG && !FindBullishFVG()) ok=false;
      if(ok && InpBOSRequireZone && !BOSZoneOK(true)) ok=false;   // v3.3 test 1
      if(ok && InpBOSD1Filter    && !BOSD1OK(true))   ok=false;   // v3.3 test 2
      bosSetup=ok;
   }
   if(!sweepSetup && !bosSetup) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl  = LowestLow(InpSweepLookback + InpFVGFreshness) - InpLegacySLBufUSD;
   double minDist = MinStopDistance();
   if(ask - sl < minDist) sl = ask - minDist;
   double slDist = ask - sl;
   if(slDist <= 0) return;

   double tp1, tp2;
   ResolveLongTargets(ask, slDist, tp1, tp2);
   double tp = InpUseLadder ? 0.0 : (InpUseRunner ? tp2 : tp1);
   sl  = NormalizeDouble(sl, g_digits);
   tp  = NormalizeDouble(tp, g_digits);
   tp1 = NormalizeDouble(tp1, g_digits);
   double lot = CalcLot(true, ask, sl);
   if(lot <= 0) return;

   string tag = InpComment + (sweepSetup ? "|LSW" : "|LBOS");
   if(trade.Buy(lot, _Symbol, 0.0, sl, tp, tag))
   {
      RecordTrade();
      RegisterNewPosition(true, slDist, tp1);
      PrintFormat("LONG(legacy) lot=%.2f sl=%.2f tp1=%.2f R=%.2f", lot, sl, tp1, slDist);
   }
}

void TryEnterShort()
{
   if(InpDirection == DIR_LONG_ONLY) return;
   if(HasShort()) return;
   if(!HTFAllowsShort()) return;
   if(InpUseHTFZone && !HTFPremium()) return;
   if(!LTFBearish()) return;

   bool sweepSetup=false, bosSetup=false;
   if(InpUseSweepSetup && InpUseSweepShort)
   {
      bool ok=true;
      if(InpRequireFVG   && !FindBearishFVG()) ok=false;
      if(InpRequireSweep && !SweptBuyside(InpSweepLookback + InpFVGFreshness)) ok=false;
      if(InpRequireCHoCH && g_lastBreakDir != -1) ok=false;
      if(InpShortUsePremDisc && !M5Premium()) ok=false;
      sweepSetup=ok;
   }
   if(InpUseBOSSetup && InpUseBOSShort)
   {
      bool ok=FreshBreakDown();
      if(InpBOSRequireFVG && !FindBearishFVG()) ok=false;
      if(ok && InpBOSRequireZone && !BOSZoneOK(false)) ok=false;  // v3.3 test 1
      if(ok && InpBOSD1Filter    && !BOSD1OK(false))   ok=false;  // v3.3 test 2
      bosSetup=ok;
   }
   if(!sweepSetup && !bosSetup) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl  = HighestHigh(InpSweepLookback + InpFVGFreshness) + InpLegacySLBufUSD;
   double minDist = MinStopDistance();
   if(sl - bid < minDist) sl = bid + minDist;
   double slDist = sl - bid;
   if(slDist <= 0) return;

   double tp1, tp2;
   ResolveShortTargets(bid, slDist, tp1, tp2);
   double tp = InpUseLadder ? 0.0 : (InpUseRunner ? tp2 : tp1);
   sl  = NormalizeDouble(sl, g_digits);
   tp  = NormalizeDouble(tp, g_digits);
   tp1 = NormalizeDouble(tp1, g_digits);
   double lot = CalcLot(false, bid, sl);
   if(lot <= 0) return;

   string tag = InpComment + (sweepSetup ? "|SSW" : "|SBOS");
   if(trade.Sell(lot, _Symbol, 0.0, sl, tp, tag))
   {
      RecordTrade();
      RegisterNewPosition(false, slDist, tp1);
      PrintFormat("SHORT(legacy) lot=%.2f sl=%.2f tp1=%.2f R=%.2f", lot, sl, tp1, slDist);
   }
}

//==================================================================//
//  PART 16 - TRADE MANAGEMENT (v2.1 + v2.2 stop fix, unchanged)     //
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
         double be = open + InpBE_LockUSD;
         if(be > sl) SafeModifySL(tk, true, be, tp);
         g_doneLong = true; done = true;
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
                  double cand = slp - InpStructTrailUSD;
                  if(cand > newSL) newSL = cand;
               }
            }
         }
         else
         {
            int sli; double slp;
            if(FindSwingLow(g_m5, InpSwingStrength, InpStructLookback, 1+InpSwingStrength, sli, slp))
            {
               double cand = slp - InpStructTrailUSD;
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
         double be = open - InpBE_LockUSD;
         if(be < sl || sl==0) SafeModifySL(tk, false, be, tp);
         g_doneShort = true; done = true;
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
                  double cand = shp + InpStructTrailUSD;
                  if(cand < newSL || newSL==0) newSL = cand;
               }
            }
         }
         else
         {
            int shi; double shp;
            if(FindSwingHigh(g_m5, InpSwingStrength, InpStructLookback, 1+InpSwingStrength, shi, shp))
            {
               double cand = shp + InpStructTrailUSD;
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
   if(s.state == ST_SWEPT) return StringFormat("%s swept %.2f, need %.2f", (s.dir>0?"L":"S"), s.poolPrice, s.mssLevel);
   return StringFormat("%s limit %.2f  R %.2f", (s.dir>0?"L":"S"), s.entry, s.riskDist);
}

void UpdatePanel()
{
   if(!InpShowPanel){ ObjectsDeleteAll(0, PFX); return; }

   int W = 300, marginR = InpPanelX, top = InpPanelY;
   int left = marginR + W;
   int padL = left - 14;
   int padV = left - 150;
   int rowH = 18;
   int rows = 15;
   int bodyH = 30 + rows*rowH + 10;

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

   PanelText(PFX+"title", "M I D A S   v3.4", padL, top+6, C'120,170,255', 10, "Consolas");

   double spr = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dpnl= eq - g_dayStartEq;
   double dpct= (g_dayStartEq>0) ? dpnl/g_dayStartEq*100.0 : 0.0;

   string htfTxt = (g_htfTrend>0?"BULLISH":(g_htfTrend<0?"BEARISH":"-"));
   color  htfClr = (g_htfTrend>0?cGreen:(g_htfTrend<0?cRed:cAmber));
   string m5Txt  = (g_m5Trend>0?"BULLISH":(g_m5Trend<0?"BEARISH":"-"));
   color  m5Clr  = (g_m5Trend>0?cGreen:(g_m5Trend<0?cRed:cAmber));

   int y = top + 34;
   string lbl[15]; string val[15]; color vc[15];

   lbl[0]="Engine";     val[0]=(InpEntryEngine==ENGINE_V3?"V3 grab->MSS->limit":"LEGACY v2.1"); vc[0]=cValue;
   lbl[1]="Clock";      val[1]=StringFormat("%s %02d:00 | srv UTC%+d", ClockName(), ClockHour(TimeCurrent()), SrvOffsetNow()); vc[1]=cValue;
   lbl[2]="HTF bias";   val[2]=htfTxt;                             vc[2]=htfClr;
   lbl[3]="M5 struct";  val[3]=m5Txt;                              vc[3]=m5Clr;
   lbl[4]="ATR(M5)";    val[4]=StringFormat("$%.2f", g_atr);       vc[4]=cValue;
   lbl[5]="Pools B/S";  val[5]=StringFormat("%d / %d", ArraySize(g_bsl), ArraySize(g_ssl)); vc[5]=cValue;
   lbl[6]="Spread";     val[6]=StringFormat("$%.2f", spr);         vc[6]=(SpreadOK()?cValue:cRed);
   lbl[7]="Session";    val[7]=(BlackoutNow()?"BLACKOUT":(SessionOK()?"OPEN":"closed")); vc[7]=(BlackoutNow()?cAmber:(SessionOK()?cGreen:cAmber));
   lbl[8]="Long setup"; val[8]=SetupTxt(g_setL);                   vc[8]=(g_setL.state==ST_ARMED?cGreen:(g_setL.state==ST_SWEPT?cAmber:cLabel));
   lbl[9]="Short setup";val[9]=SetupTxt(g_setS);                   vc[9]=(g_setS.state==ST_ARMED?cRed:(g_setS.state==ST_SWEPT?cAmber:cLabel));
   lbl[10]="Position";  val[10]=StringFormat("%d / %d  (%d pend) %s",CountMyPositions(),InpMaxPositions,CountMyPendings(),((g_doneLong||g_doneShort)?"[runner]":"")); vc[10]=cValue;
   lbl[11]="Trades day";val[11]=StringFormat("%d / %d",g_tradesToday,InpMaxTradesDay); vc[11]=cValue;
   lbl[12]="Day P&L";   val[12]=StringFormat("%.2f (%.2f%%)",dpnl,dpct); vc[12]=(dpnl>=0?cGreen:cRed);
   double ddNow = (g_equityPeak>0) ? (g_equityPeak-eq)/g_equityPeak*100.0 : 0.0;
   lbl[13]="Risk/trade"; val[13]=StringFormat("%.2f%% x%.2f = %.2f%%", BaseRiskPct(), RiskMult(), BaseRiskPct()*RiskMult());
   vc[13]=(RiskMult()<0.99?cAmber:cGreen);
   lbl[14]="DD / streak"; val[14]=StringFormat("%.1f%% peak / %d loss", ddNow, g_lossStreak);
   vc[14]=(ddNow>=InpThrottleStartDD?cRed:cValue);

   for(int i=0;i<15;i++)
   {
      PanelText(PFX+"l"+(string)i, lbl[i], padL, y+i*rowH, cLabel, 9);
      PanelText(PFX+"v"+(string)i, val[i], padV, y+i*rowH, vc[i], 9);
   }

   if(g_floorHalt)
      PanelText(PFX+"blk", "CAPITAL FLOOR HIT - STOPPED", padL, y+15*rowH, cRed, 9);
   else if(g_hardHalt)
      PanelText(PFX+"blk", "FUNDED HALT - DD RULE HIT", padL, y+15*rowH, cRed, 9);
   else if(g_blockedToday)
      PanelText(PFX+"blk", "DAILY LIMIT HIT", padL, y+15*rowH, cRed, 9);
   else if(InpFundedMode && g_fundedStart>0)
   {
      double eqn = AccountInfoDouble(ACCOUNT_EQUITY);
      double floorPx = (eqn - g_fundedStart*(1.0-InpStaticFloorPct/100.0)) / g_fundedStart * 100.0;
      PanelText(PFX+"blk", StringFormat("FUNDED: %.2f%% above floor", floorPx), padL, y+15*rowH, C'120,200,120', 9);
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
   int sl = AccSlot(posid);
   if(sl < 0){ FinaliseTrade(p); return; }          // table full - degrade gracefully
   g_accPnl[sl] += p;
   if(PositionSelectByTicket(posid)) return;         // partial: still open
   FinaliseTrade(g_accPnl[sl]);
   g_accId[sl] = 0; g_accPnl[sl] = 0.0;
}

// Gold gaps over the weekend and a stop cannot protect a gap. This is the one
// genuine gap-risk control - unlike a same-symbol hedge, which just locks the
// loss in and pays the spread twice.
bool WeekendFlatTime()
{
   if(!InpFlatBeforeWeekend) return false;
   MqlDateTime d; TimeToStruct(ToClock(TimeCurrent()), d);
   return (d.day_of_week == FRIDAY && d.hour >= InpWeekendFlatUTC);
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
   // would mark the position done=true - skipping the TP1 partial entirely and
   // trailing from the first bar. Claim the fill first, then manage it.
   if(InpEntryEngine == ENGINE_V3)
   {
      SyncFills(g_setL, true);
      SyncFills(g_setS, false);
   }
   ManagePositions();
   UpdateFundedState();
   UpdatePanel();

   if(InpEntryEngine == ENGINE_LEGACY) RefreshLTF();

   if(!IsNewBar()) return;
   g_barCounter++;

   // 620 bars covers >2 UTC days so PDH/PDL and the Asia range are always available.
   int need = MathMax(MathMax(InpStructLookback, InpPoolLookback) + 10, 620);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, need, g_m5) < 50) return;
   if(!RefreshATR()) return;

   UpdateM5Structure();
   UpdateHTFBias();
   if(InpEntryEngine == ENGINE_V3) BuildPools();

   // Hard stops: kill anything resting, then stand down.
   if(g_floorHalt && CountMyPositions() > 0){ CancelAllPendings(); FlattenAll(); return; }
   if(g_hardHalt || g_blockedToday || g_floorHalt)
   {
      if(CountMyPendings() > 0) CancelAllPendings();
      return;
   }

   // v3.1: go flat into the weekend gap.
   if(WeekendFlatTime())
   {
      if(CountMyPendings()  > 0) CancelAllPendings();
      if(CountMyPositions() > 0){ FlattenAll(); Print("v3.1: flat for the weekend"); }
      return;
   }

   // Two different gates on purpose. The window is structural, so it kills a
   // resting setup. Spread is a momentary, PER-BROKER condition - letting it
   // cancel setups would make the two accounts drop different trades, which is
   // exactly the divergence this build exists to remove. It only blocks new arms.
   bool windowOK = SessionOK() && !BlackoutNow();
   bool armOK    = windowOK && SpreadOK() && DailyLimitsOK();

   if(InpEntryEngine == ENGINE_V3)
   {
      if(!windowOK)
      {
         if(g_setL.state != ST_NONE) CancelSetup(g_setL, "outside the trading window");
         if(g_setS.state != ST_NONE) CancelSetup(g_setS, "outside the trading window");
         return;
      }
      bool room = (CountMyPositions() + CountMyPendings()) < InpMaxPositions;
      ProcessSide(g_setL, +1, armOK && room);
      ProcessSide(g_setS, -1, armOK && room);
   }
   else
   {
      if(!armOK) return;
      if(CountMyPositions() >= InpMaxPositions) return;
      TryEnterLong();
      TryEnterShort();
   }
}
//+------------------------------------------------------------------+

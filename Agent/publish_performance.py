"""Publish performance to the control page.

Collects every journal CSV the EA writes (live: <Common>\\Files\\MIDAS, backtests: backtests/*_journal.csv) plus the
tester reports, writes docs/data/performance.json and (optionally) commits + pushes it so the GitHub Pages
report refreshes by itself.

    python publish_performance.py                 # build the JSON only
    python publish_performance.py --push          # build, commit, push
    python publish_performance.py --watch 30 --push   # repeat every 30 minutes (the Agent's 'observe' loop)

Read-only with respect to trading: it never writes a profile and never touches MT5.
"""
import csv, glob, json, os, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
# The page is public, the DATA is not: performance.json is encrypted (AES-256-GCM, key = PBKDF2(password)) into
# docs/data/performance.enc.json and the browser decrypts it only after you type the password.
OUT = os.path.join(ROOT, "docs", "data", "performance.enc.json")
PWFILE = os.path.join(os.path.dirname(__file__), ".midas_pw")        # local only: never committed (.gitignore whitelist)
ITER = 600000
COMMON = os.path.join(os.environ.get("APPDATA", ""), "MetaQuotes", "Terminal", "Common", "Files", "MIDAS")
NUM = ("lot", "entry", "sl", "r_price", "r_atr", "atr", "spread", "spread_r_pct", "pnl_money", "pnl_r", "mfe_r",
       "mae_r", "hold_min", "balance_after")
REPORT_KEYS = ("profit", "gross_profit", "gross_loss", "profit_factor", "expected_payoff", "recovery_factor", "sharpe_ratio",
               "drawdown_percent_balance", "drawdown_percent_equity", "max_drawdown_equity", "trades", "profit_trades",
               "loss_trades", "long_trades", "short_trades", "max_consecutive_loss_trades", "initial_deposit")


KEEP = ("close_utc", "open_utc", "symbol", "magic", "tag", "dir", "pnl_money", "pnl_r", "mfe_r", "mae_r", "hold_min", "exit",
        "vol_regime", "trend_regime", "clock_hour", "balance_after", "lot", "r_atr", "spread_r_pct", "run")   # fields the page uses: keeps the payload small


def read_journal(path, run):
    rows = []
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        for r in csv.DictReader(f):
            try:
                for k in NUM:
                    r[k] = float(r[k])
            except (KeyError, ValueError):
                continue
            r["run"] = run
            r["clock_hour"] = int(float(r.get("clock_hour", 0)))
            rows.append({k: r[k] for k in KEEP if k in r})
    return rows


def collect():
    trades, runs = [], []
    for p in sorted(glob.glob(os.path.join(COMMON, "journal_*.csv"))):
        name = os.path.basename(p)[len("journal_"):-4]
        trades += read_journal(p, ("test:" if name.endswith("_TEST") else "live:") + name)
    for p in sorted(glob.glob(os.path.join(ROOT, "backtests", "*_journal.csv"))):
        if os.path.basename(p).startswith("x2_"):          # exploratory sweeps stay local: they would bloat the published payload
            continue
        trades += read_journal(p, "bt:" + os.path.basename(p)[:-len("_journal.csv")])
    for p in sorted(glob.glob(os.path.join(ROOT, "backtests", "*_report.json"))):
        name = os.path.basename(p)[:-len("_report.json")]
        try:
            rep = json.loads(open(p, encoding="utf-8").read())
        except ValueError:
            continue
        runs.append({"name": name, "symbol": rep.get("symbol"), "report": {k: rep[k] for k in REPORT_KEYS if k in rep}})
    ref = os.path.join(ROOT, "backtests", "reference_runs.json")          # hand-entered older runs (e.g. v3.2 on MetaQuotes)
    if os.path.exists(ref):
        runs += json.load(open(ref, encoding="utf-8"))
    trades.sort(key=lambda r: r["close_utc"])
    status = []
    for p in sorted(glob.glob(os.path.join(COMMON, "status_*.ini"))):      # EA heartbeat / acknowledgement files
        d = {}
        for ln in open(p, encoding="utf-8", errors="replace"):
            if "=" in ln:
                k, v = ln.strip().split("=", 1); d[k] = v
        status.append(d)
    agent = {}
    sp = os.path.join(os.path.dirname(__file__), "agent_state.json")
    if os.path.exists(sp):
        agent = json.load(open(sp, encoding="utf-8"))
        lp = os.path.join(os.path.dirname(__file__), "decisions.jsonl")
        agent["decisions"] = [json.loads(l) for l in open(lp, encoding="utf-8")][-200:] if os.path.exists(lp) else []
    return {"generated_utc": time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime()), "trades": trades, "runs": runs, "status": status, "agent": agent}


def password():
    pw = os.environ.get("MIDAS_PASSWORD")
    if not pw and os.path.exists(PWFILE):
        pw = open(PWFILE, encoding="utf-8-sig").read().strip()
    if not pw:
        sys.exit("No password set. Run once:  python publish_performance.py --set-password")
    return pw


def encrypt(obj, pw):
    import base64
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
    salt, iv = os.urandom(16), os.urandom(12)
    key = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=ITER).derive(pw.encode("utf-8"))
    import gzip
    ct = AESGCM(key).encrypt(iv, gzip.compress(json.dumps(obj, separators=(",", ":")).encode("utf-8"), 9), None)
    b = lambda x: base64.b64encode(x).decode()
    return {"v": 1, "z": 1, "iter": ITER, "salt": b(salt), "iv": b(iv), "ct": b(ct)}


def fingerprint(data):
    """Hash of the content without volatile timestamps, so an unchanged state is not re-encrypted and re-pushed."""
    d = json.loads(json.dumps(data))
    d.pop("generated_utc", None)
    d.get("agent", {}).pop("updated_utc", None)
    for v in d.get("agent", {}).get("regimes", {}).values():
        v.pop("updated_utc", None)
    for s_ in d.get("status", []):
        s_.pop("updated_utc", None)
    import hashlib
    return hashlib.sha256(json.dumps(d, sort_keys=True).encode()).hexdigest()


def build():
    data = collect()
    fp, fpf = fingerprint(data), os.path.join(os.path.dirname(__file__), ".last_fingerprint")
    if os.path.exists(OUT) and os.path.exists(fpf) and open(fpf).read() == fp:
        print("unchanged - nothing to publish"); return data
    open(fpf, "w").write(fp)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(encrypt(data, password()), f, separators=(",", ":"))
    print("wrote (encrypted)", OUT, len(data["trades"]), "trades,", len(data["runs"]), "runs")
    return data


def push():
    def git(*a):
        return subprocess.run(["git", "-C", ROOT, *a], capture_output=True, text=True)
    lp = os.path.join(os.path.dirname(__file__), ".last_push")
    if os.path.exists(lp) and time.time() - os.path.getmtime(lp) < 20 * 60:
        print("pushed recently - waiting"); return
    git("add", "docs/data/performance.enc.json", "backtests")
    if git("diff", "--cached", "--quiet").returncode == 0:
        print("nothing new to publish"); return
    msg = "Agent: update performance data " + time.strftime("%Y-%m-%d %H:%M", time.gmtime()) + " UTC"
    c = git("commit", "-m", msg)
    p = git("push")
    open(lp, "w").write(str(time.time()))
    print((c.stdout + c.stderr + p.stdout + p.stderr).strip()[-300:])


if __name__ == "__main__":
    if "--set-password" in sys.argv:
        import getpass
        a, b = getpass.getpass("New dashboard password (12+ chars): "), getpass.getpass("Repeat: ")
        if a != b or len(a) < 12:
            sys.exit("Passwords differ or are shorter than 12 characters.")
        open(PWFILE, "w", encoding="utf-8").write(a)
        print("saved to", PWFILE, "(local only)")
    watch = int(sys.argv[sys.argv.index("--watch") + 1]) if "--watch" in sys.argv else 0
    while True:
        if "--agent" in sys.argv:
            try:
                import agent; agent.cycle()
            except Exception as e:
                print("agent cycle failed:", e)
        build()
        if "--push" in sys.argv:
            push()
        if not watch:
            break
        time.sleep(watch * 60)

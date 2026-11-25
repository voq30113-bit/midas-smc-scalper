/* MIDAS performance report: KPIs, per-bot table, SVG charts. No libraries. */
(function () {
  const $ = s => document.querySelector(s);
  const css = k => getComputedStyle(document.documentElement).getPropertyValue(k).trim();
  const f2 = (x, d = 2) => (isFinite(x) ? Number(x).toFixed(d) : "∞");
  let DATA = { trades: [], runs: [], generated_utc: "" }, VIEW = { bot: "ALL", run: "ALL" };

  /* ---------- statistics ---------- */
  function dayKey(t) { return t.slice(0, 10); }
  function stats(tr) {
    const n = tr.length; if (!n) return null;
    let w = 0, gp = 0, gl = 0, R = 0, money = 0, sw = 0, sl = 0, streak = 0, maxLoss = 0, hold = 0, mfe = 0, mae = 0;
    const days = {};
    tr.forEach(t => {
      R += t.pnl_r; money += t.pnl_money; hold += t.hold_min; mfe += t.mfe_r; mae += t.mae_r;
      if (t.pnl_r > 0) { w++; sw += t.pnl_r; streak = 0; } else { sl += t.pnl_r; streak++; maxLoss = Math.max(maxLoss, streak); }
      if (t.pnl_money > 0) gp += t.pnl_money; else gl -= t.pnl_money;
      days[dayKey(t.close_utc)] = (days[dayKey(t.close_utc)] || 0) + t.pnl_r;
    });
    const losses = n - w;
    // equity / drawdown in R and money
    let eq = 0, pk = 0, dd = 0, mEq = 0, mPk = 0, mDd = 0;
    tr.forEach(t => { eq += t.pnl_r; pk = Math.max(pk, eq); dd = Math.max(dd, pk - eq); mEq += t.pnl_money; mPk = Math.max(mPk, mEq); mDd = Math.max(mDd, mPk - mEq); });
    const dv = Object.values(days), mean = dv.reduce((a, b) => a + b, 0) / dv.length;
    const sd = Math.sqrt(dv.reduce((a, b) => a + (b - mean) ** 2, 0) / Math.max(1, dv.length - 1));
    const dn = Math.sqrt(dv.reduce((a, b) => a + Math.min(0, b) ** 2, 0) / Math.max(1, dv.length));
    const span = (new Date(tr[n - 1].close_utc) - new Date(tr[0].close_utc)) / 864e5 || 1;
    const avgW = w ? sw / w : 0, avgL = losses ? sl / losses : 0;
    return {
      n, wr: w / n * 100, R, money, exp: R / n, pf: gl > 0 ? gp / gl : Infinity, avgW, avgL,
      payoff: avgL ? Math.abs(avgW / avgL) : Infinity, maxDdR: dd, maxDdMoney: mDd,
      sharpe: sd ? mean / sd * Math.sqrt(252) : 0, sortino: dn ? mean / dn * Math.sqrt(252) : 0,
      recovery: dd ? R / dd : Infinity, perYear: n / span * 365, maxLossStreak: maxLoss,
      hold: hold / n, mfe: mfe / n, mae: mae / n, days: span
    };
  }
  const group = (rows, f) => { const g = {}; rows.forEach(r => { const k = f(r); (g[k] = g[k] || []).push(r); }); return g; };
  const botOf = t => t.symbol + " #" + t.magic;

  /* ---------- svg helpers ---------- */
  function svgWrap(w, h, inner) { return `<svg viewBox="0 0 ${w} ${h}" width="100%" style="max-width:${w}px;background:var(--card);border:1px solid var(--bd);border-radius:8px">${inner}</svg>`; }
  function axes(w, h, p, x0, x1, y0, y1, fmtY) {
    let s = ""; const m = css("--m"), bd = css("--bd");
    for (let i = 0; i <= 4; i++) {
      const v = y0 + (y1 - y0) * i / 4, y = p.t + (h - p.t - p.b) * (1 - i / 4);
      s += `<line x1="${p.l}" x2="${w - p.r}" y1="${y}" y2="${y}" stroke="${bd}"/><text x="${p.l - 4}" y="${y + 4}" font-size="10" text-anchor="end" fill="${m}">${(fmtY || (v => v.toFixed(1)))(v)}</text>`;
    }
    return s;
  }
  function lineChart(title, series, opts = {}) {
    const w = 560, h = 230, p = { l: 48, r: 10, t: 24, b: 22 };
    const all = series.flatMap(s => s.pts); if (all.length < 2) return card(title, "<p class=m>Chưa đủ dữ liệu</p>");
    let y0 = Math.min(0, ...all.map(a => a[1])), y1 = Math.max(0, ...all.map(a => a[1])); if (y0 === y1) y1 = y0 + 1;
    const n = Math.max(...series.map(s => s.pts.length)) - 1 || 1;
    const X = i => p.l + (w - p.l - p.r) * i / n, Y = v => p.t + (h - p.t - p.b) * (1 - (v - y0) / (y1 - y0));
    let s = axes(w, h, p, 0, n, y0, y1, opts.fmt);
    series.forEach(se => {
      const d = se.pts.map((a, i) => (i ? "L" : "M") + X(i).toFixed(1) + "," + Y(a[1]).toFixed(1)).join("");
      if (se.fill) s += `<path d="${d}L${X(se.pts.length - 1)},${Y(0)}L${X(0)},${Y(0)}Z" fill="${se.color}" opacity=".18"/>`;
      s += `<path d="${d}" fill="none" stroke="${se.color}" stroke-width="1.6"/>`;
    });
    s += `<text x="${p.l}" y="14" font-size="12" fill="${css("--fg")}">${title}</text>`;
    const lbl = series[0].pts; if (lbl.length) s += `<text x="${p.l}" y="${h - 6}" font-size="10" fill="${css("--m")}">${lbl[0][0].slice(0, 10)}</text><text x="${w - p.r}" y="${h - 6}" font-size="10" text-anchor="end" fill="${css("--m")}">${lbl[lbl.length - 1][0].slice(0, 10)}</text>`;
    return svgWrap(w, h, s);
  }
  function barChart(title, items, opts = {}) { // items: [label, value, color?]
    const w = 560, rowH = 20, h = 30 + items.length * rowH, p = { l: 150, r: 50 };
    if (!items.length) return card(title, "<p class=m>Không có dữ liệu</p>");
    const mx = Math.max(...items.map(i => Math.abs(i[1])), 1e-9), mid = p.l + (w - p.l - p.r) / 2, half = (w - p.l - p.r) / 2;
    let s = `<text x="10" y="16" font-size="12" fill="${css("--fg")}">${title}</text><line x1="${mid}" x2="${mid}" y1="22" y2="${h - 4}" stroke="${css("--bd")}"/>`;
    items.forEach((it, i) => {
      const y = 28 + i * rowH, len = Math.abs(it[1]) / mx * half * 0.95, pos = it[1] >= 0;
      s += `<text x="${p.l - 6}" y="${y + 12}" font-size="11" text-anchor="end" fill="${css("--m")}">${String(it[0]).slice(0, 22)}</text><rect x="${pos ? mid : mid - len}" y="${y + 2}" width="${len}" height="13" fill="${it[2] || (pos ? css("--g") : css("--r"))}" rx="2"/><text x="${pos ? mid + len + 4 : mid - len - 4}" y="${y + 12}" font-size="10" text-anchor="${pos ? "start" : "end"}" fill="${css("--fg")}">${(opts.fmt || (v => v.toFixed(2)))(it[1])}${it[3] ? " (" + it[3] + ")" : ""}</text>`;
    });
    return svgWrap(w, h, s);
  }
  function histogram(title, vals, lo, hi, bins) {
    const w = 560, h = 210, p = { l: 36, r: 10, t: 24, b: 24 };
    if (!vals.length) return card(title, "<p class=m>Không có dữ liệu</p>");
    const c = new Array(bins).fill(0), step = (hi - lo) / bins;
    vals.forEach(v => { c[Math.max(0, Math.min(bins - 1, Math.floor((v - lo) / step)))]++; });
    const mx = Math.max(...c), bw = (w - p.l - p.r) / bins;
    let s = `<text x="${p.l}" y="14" font-size="12" fill="${css("--fg")}">${title}</text>`;
    c.forEach((k, i) => {
      const mid = lo + step * (i + .5), bh = (h - p.t - p.b) * k / mx;
      s += `<rect x="${p.l + i * bw + 1}" y="${h - p.b - bh}" width="${bw - 2}" height="${bh}" fill="${mid >= 0 ? css("--g") : css("--r")}" opacity=".85"/>`;
      if (i % Math.ceil(bins / 8) === 0) s += `<text x="${p.l + i * bw}" y="${h - 8}" font-size="10" fill="${css("--m")}">${(lo + step * i).toFixed(1)}</text>`;
    });
    s += `<text x="${p.l - 4}" y="${p.t + 6}" font-size="10" text-anchor="end" fill="${css("--m")}">${mx}</text>`;
    return svgWrap(w, h, s);
  }
  function scatter(title, pts) { // x = mae, y = mfe (both R), colour by win
    const w = 560, h = 260, p = { l: 40, r: 10, t: 24, b: 28 };
    if (!pts.length) return card(title, "<p class=m>Không có dữ liệu</p>");
    const mx = Math.min(8, Math.max(2, ...pts.map(a => a[0]))), my = Math.min(12, Math.max(2, ...pts.map(a => a[1])));
    const X = v => p.l + (w - p.l - p.r) * Math.min(v, mx) / mx, Y = v => h - p.b - (h - p.t - p.b) * Math.min(v, my) / my;
    let s = `<text x="${p.l}" y="14" font-size="12" fill="${css("--fg")}">${title}</text><line x1="${X(1)}" x2="${X(1)}" y1="${p.t}" y2="${h - p.b}" stroke="${css("--bd")}" stroke-dasharray="3"/><text x="${X(1) + 3}" y="${p.t + 10}" font-size="10" fill="${css("--m")}">MAE = 1R (chạm SL)</text>`;
    pts.forEach(a => { s += `<circle cx="${X(a[0])}" cy="${Y(a[1])}" r="3" fill="${a[2] > 0 ? css("--g") : css("--r")}" opacity=".7"/>`; });
    s += `<text x="${w / 2}" y="${h - 6}" font-size="10" text-anchor="middle" fill="${css("--m")}">MAE (R, bất lợi tối đa)</text><text x="12" y="${h / 2}" font-size="10" fill="${css("--m")}" transform="rotate(-90 12 ${h / 2})">MFE (R, thuận lợi tối đa)</text>`;
    return svgWrap(w, h, s);
  }
  function heat(title, rows) { // monthly R table
    const g = group(rows, t => t.close_utc.slice(0, 7)), months = Object.keys(g).sort();
    if (!months.length) return card(title, "<p class=m>Không có dữ liệu</p>");
    const years = [...new Set(months.map(m => m.slice(0, 4)))], mx = Math.max(...months.map(m => Math.abs(g[m].reduce((a, t) => a + t.pnl_r, 0))), 1);
    let h = `<table><tr><th>${title}<th>${[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12].map(m => "<th class=n>T" + m).join("")}<th class=n>Năm</tr>`;
    years.forEach(y => {
      let tot = 0; h += `<tr><td>${y}`;
      for (let m = 1; m <= 12; m++) {
        const k = y + "-" + String(m).padStart(2, "0"), v = g[k] ? g[k].reduce((a, t) => a + t.pnl_r, 0) : null;
        if (v === null) { h += "<td>"; continue; } tot += v;
        const a = Math.min(.75, Math.abs(v) / mx * .75 + .08);
        h += `<td class=n style="background:${v >= 0 ? `rgba(26,143,90,${a})` : `rgba(200,64,63,${a})`}" title="${g[k].length} lệnh">${v.toFixed(1)}`;
      }
      h += `<td class=n><b>${tot.toFixed(1)}</b></tr>`;
    });
    return `<div class=wrap>${h}</table></div>`;
  }
  const card = (t, b) => `<div class=card><b>${t}</b>${b}</div>`;


  /* ---------- per-symbol small multiples ---------- */
  function miniCurve(pts, dd, w = 300, h = 120) {
    const p = { l: 34, r: 6, t: 8, b: 16 };
    const all = pts.map(a => a[1]).concat(dd.map(a => a[1]), [0]);
    let y0 = Math.min(...all), y1 = Math.max(...all); if (y0 === y1) y1 = y0 + 1;
    const n = Math.max(1, pts.length - 1);
    const X = i => p.l + (w - p.l - p.r) * i / n, Y = v => p.t + (h - p.t - p.b) * (1 - (v - y0) / (y1 - y0));
    const line = a => a.map((q, i) => (i ? "L" : "M") + X(i).toFixed(1) + "," + Y(q[1]).toFixed(1)).join("");
    let s = `<line x1="${p.l}" x2="${w - p.r}" y1="${Y(0)}" y2="${Y(0)}" stroke="${css("--bd")}"/>`;
    s += `<path d="${line(dd)}L${X(dd.length - 1)},${Y(0)}L${X(0)},${Y(0)}Z" fill="${css("--r")}" opacity=".2"/>`;
    s += `<path d="${line(pts)}" fill="none" stroke="${css("--ac")}" stroke-width="1.5"/>`;
    s += `<text x="${p.l - 3}" y="${p.t + 8}" font-size="9" text-anchor="end" fill="${css("--m")}">${y1.toFixed(0)}R</text><text x="${p.l - 3}" y="${h - p.b}" font-size="9" text-anchor="end" fill="${css("--m")}">${y0.toFixed(0)}R</text>`;
    s += `<text x="${p.l}" y="${h - 3}" font-size="9" fill="${css("--m")}">${pts[0][0].slice(0, 7)}</text><text x="${w - p.r}" y="${h - 3}" font-size="9" text-anchor="end" fill="${css("--m")}">${pts[pts.length - 1][0].slice(0, 7)}</text>`;
    return `<svg viewBox="0 0 ${w} ${h}" width="100%">${s}</svg>`;
  }
  function yearBars(rows) {
    const g = group(rows, t => t.close_utc.slice(0, 4)), ys = Object.keys(g).sort();
    return ys.map(y => { const r = g[y].reduce((a, t) => a + t.pnl_r, 0); return `<span class="tag ${r >= 0 ? "s" : "c"}" title="${g[y].length} lệnh">${y.slice(2)}: ${r >= 0 ? "+" : ""}${r.toFixed(1)}R</span>`; }).join(" ");
  }
  function symbolCards(rows) {
    const key = t => (VIEW.run === "ALL" ? t.run + " · " : "") + t.symbol;
    const g = group(rows, key);
    const items = Object.entries(g).filter(([, r]) => r.length >= 3).map(([k, r]) => [k, r, stats(r)]).sort((a, b) => b[2].R - a[2].R);
    if (!items.length) return "<p class=m>Chưa có mã nào đủ 3 lệnh.</p>";
    const shown = items.slice(0, 30);
    return `<div class="grid3">${shown.map(([k, r, x]) => {
      let c = 0, pk = 0; const pts = [], dd = [];
      r.forEach(t => { c += t.pnl_r; pk = Math.max(pk, c); pts.push([t.close_utc, c]); dd.push([t.close_utc, c - pk]); });
      return `<div class=card style="margin:0"><div style="display:flex;justify-content:space-between;gap:8px"><b style="font-size:13px;word-break:break-all">${k}</b><span class="${x.R >= 0 ? "pos" : "neg"} mono">${f2(x.R, 1)}R</span></div>
      ${miniCurve(pts, dd)}
      <div class=m style="font:11px ui-monospace,Consolas,monospace">${x.n} lệnh · thắng ${f2(x.wr, 0)}% · PF ${f2(x.pf)} · kỳ vọng ${f2(x.exp)}R · DD ${f2(x.maxDdR, 1)}R · Sharpe ${f2(x.sharpe, 1)}</div>
      <div style="margin-top:4px">${yearBars(r)}</div></div>`;
    }).join("")}</div>${items.length > 30 ? `<p class=m>Hiển thị 30/${items.length} nhóm có R cao nhất; lọc theo lần chạy để xem các nhóm còn lại.</p>` : ""}`;
  }

  /* ---------- rendering ---------- */
  function kpi(label, val, cls, hint) { return `<div class="kpi"><div class="m" style="font-size:12px">${label}</div><div class="${cls || ""}" style="font-size:20px;font-weight:600">${val}</div>${hint ? `<div class=m style="font-size:11px">${hint}</div>` : ""}</div>`; }
  function render() {
    const root = $("#pout"); if (!root) return;
    let rows = DATA.trades.filter(t => (VIEW.run === "ALL" || t.run === VIEW.run) && (VIEW.bot === "ALL" || botOf(t) === VIEW.bot));
    rows.sort((a, b) => a.close_utc < b.close_utc ? -1 : 1);
    const s = stats(rows);
    const runs = [...new Set(DATA.trades.map(t => t.run))].sort(), bots = [...new Set(DATA.trades.filter(t => VIEW.run === "ALL" || t.run === VIEW.run).map(botOf))].sort();
    let h = `<div class=row><div><label>Nguồn / lần chạy</label><select id=vrun><option value=ALL>Tất cả${runs.map(r => `<option ${r === VIEW.run ? "selected" : ""}>${r}`).join("")}</select></div><div><label>Bot</label><select id=vbot><option value=ALL>Tất cả${bots.map(b => `<option ${b === VIEW.bot ? "selected" : ""}>${b}`).join("")}</select></div><div class=m style="flex:2">Dữ liệu cập nhật: ${DATA.generated_utc || "—"} UTC · ${DATA.trades.length} lệnh trong file</div></div>`;
    if (!s) { root.innerHTML = h + "<p class=m>Không có lệnh nào với bộ lọc này. Agent đẩy dữ liệu bằng <code>Agent/publish_performance.py</code>, hoặc kéo thả CSV ở trên.</p>" + runsTable(); bind(); return; }
    const c = (v, good) => v >= good ? "pos" : "neg";
    h += `<div class="kpis">${kpi("Tổng R", f2(s.R, 1), s.R >= 0 ? "pos" : "neg")}${kpi("Lãi/lỗ", f2(s.money, 0), s.money >= 0 ? "pos" : "neg", "tiền tệ tài khoản")}${kpi("Số lệnh", s.n, "", f2(s.perYear, 0) + " lệnh/năm")}${kpi("Tỉ lệ thắng", f2(s.wr, 1) + "%")}${kpi("Profit factor", f2(s.pf), c(s.pf, 1))}${kpi("Kỳ vọng / lệnh", f2(s.exp) + "R", s.exp >= 0 ? "pos" : "neg")}${kpi("Payoff (thắng/thua)", f2(s.payoff), "", f2(s.avgW) + "R / " + f2(s.avgL) + "R")}${kpi("Max DD", f2(s.maxDdR, 1) + "R", "neg", f2(s.maxDdMoney, 0) + " tiền")}${kpi("Sharpe (ngày)", f2(s.sharpe), c(s.sharpe, 1))}${kpi("Sortino", f2(s.sortino), c(s.sortino, 1))}${kpi("Recovery (R/DD)", f2(s.recovery), c(s.recovery, 1))}${kpi("Chuỗi thua dài nhất", s.maxLossStreak)}${kpi("Giữ lệnh TB", f2(s.hold / 60, 1) + " giờ")}${kpi("MFE / MAE TB", f2(s.mfe) + " / " + f2(s.mae), "", "R")}</div>`;
    // curves
    let cr = 0, cm = 0, pk = 0; const eqR = [], eqM = [], ddS = [];
    rows.forEach(t => { cr += t.pnl_r; cm += t.pnl_money; pk = Math.max(pk, cr); eqR.push([t.close_utc, cr]); eqM.push([t.close_utc, cm]); ddS.push([t.close_utc, cr - pk]); });
    h += `<h3>Đường vốn</h3><div class=grid2>${lineChart("Đường vốn tích lũy (R) và drawdown", [{ pts: ddS, color: css("--r"), fill: true }, { pts: eqR, color: css("--ac") }])}${lineChart("Lãi/lỗ tích lũy (tiền)", [{ pts: eqM, color: css("--g"), fill: true }], { fmt: v => v.toFixed(0) })}</div>`;
    // per bot
    const gb = group(rows, botOf), botS = Object.keys(gb).sort().map(k => [k, stats(gb[k])]);
    h += `<h3>Theo từng bot</h3><div class=grid2>${barChart("Tổng R theo bot", botS.map(([k, x]) => [k, x.R, null, x.n + " lệnh"]), { fmt: v => v.toFixed(1) })}${barChart("Kỳ vọng R / lệnh theo bot", botS.map(([k, x]) => [k, x.exp]))}</div>`;
    h += `<div class=wrap><table><tr><th>Bot<th class=n>Lệnh<th class=n>Thắng %<th class=n>Kỳ vọng R<th class=n>Tổng R<th class=n>PF<th class=n>Payoff<th class=n>Max DD R<th class=n>Sharpe<th class=n>Recovery<th class=n>Chuỗi thua<th class=n>MFE<th class=n>MAE</tr>${botS.map(([k, x]) => `<tr><td>${k}<td class=n>${x.n}<td class=n>${f2(x.wr, 1)}<td class="n ${x.exp >= 0 ? "pos" : "neg"}">${f2(x.exp)}<td class=n>${f2(x.R, 1)}<td class=n>${f2(x.pf)}<td class=n>${f2(x.payoff)}<td class=n>${f2(x.maxDdR, 1)}<td class=n>${f2(x.sharpe)}<td class=n>${f2(x.recovery)}<td class=n>${x.maxLossStreak}<td class=n>${f2(x.mfe)}<td class=n>${f2(x.mae)}</tr>`).join("")}</table></div>`;
    h += `<h3>Hiệu suất từng mã (đường vốn R, vùng đỏ = drawdown, thẻ = R theo năm)</h3>${symbolCards(rows)}`;
    // distributions
    h += `<h3>Phân bố</h3><div class=grid2>${histogram("Phân bố kết quả mỗi lệnh (R)", rows.map(t => t.pnl_r), -2, 8, 20)}${scatter("MFE so với MAE (hiệu quả thoát lệnh)", rows.map(t => [t.mae_r, t.mfe_r, t.pnl_r]))}</div>`;
    const by = (f, min = 1) => Object.entries(group(rows, f)).sort().filter(([, r]) => r.length >= min).map(([k, r]) => [k, r.reduce((a, t) => a + t.pnl_r, 0), null, r.length]);
    h += `<div class=grid2>${barChart("Tổng R theo giờ (clock của profile)", by(t => String(t.clock_hour).padStart(2, "0") + "h"), { fmt: v => v.toFixed(1) })}${barChart("Tổng R theo regime biến động", by(t => t.vol_regime), { fmt: v => v.toFixed(1) })}${barChart("Tổng R theo quan hệ với xu hướng HTF", by(t => t.trend_regime), { fmt: v => v.toFixed(1) })}${barChart("Tổng R theo setup", by(t => (t.tag || "").split("|").pop()), { fmt: v => v.toFixed(1) })}${barChart("Tổng R theo hướng", by(t => t.dir === "L" ? "Mua" : "Bán"), { fmt: v => v.toFixed(1) })}${barChart("Tổng R theo cách thoát", by(t => t.exit + (t.tp1 == 1 ? " +TP1" : "")), { fmt: v => v.toFixed(1) })}</div>`;
    h += `<h3>R theo tháng</h3>${heat("Năm", rows)}`;
    root.innerHTML = h + runsTable(); bind();
  }
  function runsTable() {
    if (!DATA.runs.length) return "";
    const rs = DATA.runs;
    return `<h3>So sánh các lần backtest (báo cáo của Strategy Tester)</h3><div class=wrap><table><tr><th>Lần chạy<th>Symbol<th class=n>Lãi<th class=n>PF<th class=n>Lệnh<th class=n>Thắng %<th class=n>DD equity %<th class=n>Sharpe<th class=n>Recovery<th class=n>Kỳ vọng</tr>${rs.map(r => { const x = r.report || {}; return `<tr><td>${r.name}<td>${r.symbol || ""}<td class="n ${x.profit >= 0 ? "pos" : "neg"}">${f2(x.profit, 0)}<td class=n>${f2(x.profit_factor)}<td class=n>${x.trades ?? ""}<td class=n>${x.trades ? f2(x.profit_trades / x.trades * 100, 1) : ""}<td class=n>${f2(x.drawdown_percent_equity, 1)}<td class=n>${f2(x.sharpe_ratio)}<td class=n>${f2(x.recovery_factor)}<td class=n>${f2(x.expected_payoff, 1)}</tr>`; }).join("")}</table></div>`;
  }
  function bind() {
    const a = $("#vrun"), b = $("#vbot");
    if (a) a.onchange = () => { VIEW.run = a.value; VIEW.bot = "ALL"; render(); };
    if (b) b.onchange = () => { VIEW.bot = b.value; render(); };
  }

  /* ---------- data in ---------- */
  function parseCsv(txt, run) {
    const L = txt.trim().split(/\r?\n/), h = L.shift().split(",");
    return L.map(l => { const c = l.split(","), o = {}; h.forEach((k, i) => o[k] = c[i]); ["lot", "pnl_money", "pnl_r", "mfe_r", "mae_r", "hold_min", "r_atr", "spread_r_pct"].forEach(k => o[k] = +o[k]); o.clock_hour = +o.clock_hour; o.run = run; return o; });
  }
  window.perfLoadFiles = async function (files) {
    for (const f of files) DATA.trades = DATA.trades.concat(parseCsv(await f.text(), "upload:" + f.name));
    document.dispatchEvent(new Event("midas-data")); render();
  };
  window.perfData = () => DATA;
  window.perfSet = d => { DATA = Object.assign({ trades: [], runs: [], status: [], generated_utc: "" }, d); document.dispatchEvent(new Event("midas-data")); render(); };
  window.perfRender = render;
  render();
})();

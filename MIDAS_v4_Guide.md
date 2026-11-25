# MIDAS v4 — hướng dẫn và kết quả đánh giá

## 1. Kết nối MT5 (đã làm)
- Terminal `C:\Program Files\MetaTrader 5`, tài khoản **demo Exness-MT5Trial6**, $100, hedging, build 6306, **giờ server = UTC+0** (đã đối chiếu `get_time_information`).
- Hai MCP của thư mục `MT5/.mcp.json`: terminal (22346, chạy sẵn) và MetaEditor (22345, phải mở MetaEditor mới có). Qua đó đã đọc 359 symbol, nạp lịch sử, biên dịch và chạy tester.
- Vàng Exness có **3 chữ số thập phân** (point 0.001) — v3.4 đã dùng USD/ATR nên không bị lệch, nhưng tham số tính bằng "point" sẽ lệch 10×.

## 2. Ý tưởng Agent → engine cần gì
| Yêu cầu từ tài liệu Agent | v3.4 | V4 |
|---|---|---|
| Phân loại tham số Safe / Sensitive / Critical | không có | Profile file chỉ nhận khóa an toàn, mọi giá trị bị chặn; rủi ro %, floor, magic là Critical, không đổi qua file |
| Bot xác nhận đã áp dụng thay đổi | không | `status_<SYMBOL>_<magic>.ini` ghi lại profile đang chạy |
| Risk Manager cấp portfolio | không | Trần rủi ro mở toàn tài khoản (mọi magic MIDAS) ngay trong EA |
| Hiệu suất theo Regime × Config | không | Nhật ký CSV: R, MFE/MAE, regime biến động, quan hệ HTF, giờ, cách thoát |
| Tham số theo loại tài sản | USD/ounce cho vàng | ATR, notional, profile theo mã |

## 3. Chọn tài sản (snapshot 25/11/2026, `tools/asset_scan_2026-11-25.csv`)
- **Lõi:** XAUUSD (spread/ATR 0,03), USTEC (0,02), BTCUSD (0,03, 24/7).
- **Phụ:** DE30 (phiên châu Âu, 0,02), USOIL (0,06), XAGUSD (0,16 — cùng nhóm vàng, đừng chạy cả hai cùng rủi ro đầy).
- **Theo dõi:** EURUSD, USDJPY (spread/ATR 0,15–0,21; stop M5 chặt nên cổng spread/R sẽ từ chối nhiều lệnh).
- **USTEC thay vì US500:** cùng phiên, tương quan cao, USTEC có ATR lớn hơn (18,8 bp so với 11,1 bp); chạy cả hai là nhân đôi rủi ro. Có sẵn set cho US500 nếu muốn đổi.
- **Loại:** XNGUSD (spread ≈ ATR), UK100 (biến động quá nhỏ), cổ phiếu CFD (chỉ một phiên, gap/earnings, cần profile riêng), exotic.
- Mẫu giá chỉ ~30 ngày và một phần dữ liệu M5 trong cache, nên đây là sàng lọc, không phải kết luận.

**Tài khoản $100:** lot nhỏ nhất của vàng rủi ro ~$8,4 với SL 1,5 ATR (8%). V4 từ chối lệnh nếu lot tối thiểu rủi ro quá 1,5× mức cấu hình (v3.4 âm thầm làm tròn lên). Số dư tối thiểu cho 1% rủi ro: vàng ~$840, USTEC ~$360, BTC ~$230, DE30 ~$220, USOIL ~$260, EURUSD ~$44. Với $100 chỉ forex, ETH, UK100 vừa đủ.

## 4. V4 làm gì
1. **Bỏ LEGACY**, chỉ còn engine V3 (pools → grab → MSS → limit tại zone). A/B vẫn dùng binary v3.4.
2. **Không còn tham số USD:** buffer SL, trần SL, BE lock, trail đều theo ATR. Spread có hai cổng: `InpMaxSpreadATR` (thị trường) và `InpMaxSpreadRPct` (spread tính theo % R của lệnh).
3. **Trần notional** `InpMaxNotionalX` × equity thay trần ounce; đúng cho mọi kích thước hợp đồng.
4. **Profile theo mã** (tự nhận từ tên symbol): giờ phiên, blackout, khoảng Asia/qua đêm, flat cuối tuần, cách xác định ngày (NY+7 / UTC / EU). Ghi đè bằng `Common\Files\MIDAS\profile_<SYMBOL>.ini`, EA tự đọc lại khi live.
5. **Risk Manager:** tổng rủi ro-tới-SL của mọi vị thế + lệnh limit chờ thuộc magic 580000–589999 không vượt `InpMaxOpenRiskPct` (4%) và `InpMaxOpenPositions` (4).
6. **Nhật ký CSV** `journal_<SYMBOL>_<magic>.csv`; đọc bằng `tools/analyze_journal.py` hoặc kéo vào trang quản lý.
7. Tester: `InpServerClock=AUTO` giờ nghĩa là FIXED `InpServerGMT` (Exness = 0), không đoán kiểu MetaQuotes.

Preset giờ là **giả thuyết khởi đầu**, nhất là chỉ số (không blackout), dầu, DE30. Phải kiểm bằng nhật ký theo giờ.

## 5. Triển khai
1. Chép `MIDAS_SMC_v4.mq5` vào `MQL5\Experts\MIDAS\`, biên dịch (đã biên dịch 0 lỗi, 0 cảnh báo).
2. Mỗi symbol một chart **M5**, nạp `sets\midas_v4_<SYMBOL>.set` (magic riêng 580001–580009).
3. Bật Algo Trading. Bắt đầu bằng demo.

## 6. Backtest cần chạy (tick thực, M5, ký quỹ $5.000)
Dữ liệu tick Exness chỉ có từ 01/03/2026.
1. V4 vàng 03→11/2026 (cơ sở) — đang chạy nền, kết quả vào `backtests/`.
2. v3.4 LEGACY vàng cùng kỳ; 3. v3.4 V3 vàng cùng kỳ (quyết định A/B).
4. V4 USTEC, BTCUSD, DE30, USOIL, XAGUSD cùng kỳ (mỗi mã một lần).
5. V4 EURUSD/USDJPY để xem tỉ lệ lệnh bị từ chối.
6. Blackout bật/tắt cho vàng và chỉ số, đọc theo giờ trong nhật ký.

**Chưa kiểm chứng:** hiệu suất của V4 (backtest chưa xong khi viết tài liệu này), trần rủi ro đa mã (tester chỉ chạy một symbol, chỉ kiểm được live/đa chart), và việc EA tự đọc lại profile (chỉ chạy live).

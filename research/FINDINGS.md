# Nghiên cứu engine động lượng (27/11/2026)

## Engine (EA v4.6, `InpEntryEngine = 3`)
Nến M5 đóng có thân > 2×ATR, ATR ≥ trung bình dài, giờ 07–20 UTC → vào theo hướng nến, stop 3×ATR, không chốt lời,
đóng trước khi hết ngày. Mỗi chiều tối đa 1 tín hiệu/ngày.

## Kết quả EA (0,5% rủi ro mỗi lệnh; R = khoảng cách stop)
| Bộ dữ liệu (US30, US500, USTEC, DE30) | Lệnh | R/lệnh | PF | DD gộp |
|---|---|---|---|---|
| Exness M1, 07/2025–11/2026 (đã dùng để chọn) | 1001 | +0,17 | 1,28 | 50R |
| Exness M1, 01–07/2025 (chưa dùng) | 241 | +0,22 | 1,33 | 20R |
| Exness tick thật, 03–11/2026 (trùng giai đoạn chọn) | 584 | +0,10 | 1,15 | 54R |
| Dukascopy USTEC + DE30, 2021 – 06/2025 | 1664 | −0,02 | 0,97 | 140R |

Dukascopy theo năm (USTEC / DE30, R mỗi lệnh): 2021 −0,20 / −0,07; 2022 −0,04 / +0,05; 2023 −0,23 / −0,16;
2024 +0,10 / +0,15; nửa đầu 2025 +0,23 / +0,19.

## Kết luận
- **Không đạt.** Lợi thế chỉ xuất hiện từ 2024; 2021–2023 hòa hoặc lỗ. Đây là hiệu ứng theo giai đoạn thị trường.
- Dữ liệu Dukascopy cho chỉ số có spread thấp hơn Exness, nên kết quả thật 2021–2023 khó khá hơn. Số lệnh USTEC.D
  năm 2025 ít hơn Exness nhiều (29 so với 73): dữ liệu hai nguồn không tương đương.
- US30 và US500 dương ở cả ba bộ Exness, nhưng đó là chọn sau khi xem kết quả, hai mã tương quan cao và không có
  dữ liệu dài để kiểm.

## Lỗi đã sửa
Trung bình ATR dài khởi tạo từ ô chưa tính (EMPTY_VALUE) khi lịch sử bắt đầu đúng ngày test → mọi tín hiệu bị loại.

## Tệp
`profile_assets.py` (đặc điểm tài sản), `analyze_trades.py` (lệnh của engine quét thanh khoản), `engines.py` /
`rank.py` (sàng lọc engine), `robust_mom.py` (độ nhạy tham số). Dữ liệu nến xuất bằng `tools/MIDAS_ExportBars.mq5`.

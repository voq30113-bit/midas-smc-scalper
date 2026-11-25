# Agent (khung, chưa có Agent thật)

Bám theo `Agent_Internal_Org_and_Bots.docx` và `Agent_Layer_Trading_Bot_Knowledge.docx`.

| Module | File | Trạng thái |
|---|---|---|
| Regime Detector | `regime_detector.py` | rule-based + hysteresis, chưa nối dữ liệu MT5 |
| Performance Analyzer | `performance_analyzer.py` | đọc journal CSV của EA v4 |
| Experience Store | `experience_store.py` | JSONL, trọng số giảm theo thời gian |
| Decision Engine | `decision_engine.py` | chỉ hold/alert, logic thật là giai đoạn 3 |
| Parameter Manager | `parameter_manager.py` | Safe/Sensitive/Critical, biên độ, cooldown |
| Vòng lặp | `agent.py` | chỉ quan sát (giai đoạn 1), không ghi profile |

Agent không đặt lệnh. Kênh ghi duy nhất là `tools/profile_gateway.py` (khóa an toàn, giá trị bị chặn).

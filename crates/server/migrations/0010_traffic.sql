-- 流量统计:累计收/发字节(由上报速率 × 时间估算,非精抓包计费级别精度);
-- 可选按月清零,清零日(1~28,避开短月边界问题)。
ALTER TABLE nodes ADD COLUMN traffic_rx_total INTEGER NOT NULL DEFAULT 0;
ALTER TABLE nodes ADD COLUMN traffic_tx_total INTEGER NOT NULL DEFAULT 0;
ALTER TABLE nodes ADD COLUMN traffic_period_start INTEGER NOT NULL DEFAULT 0;
ALTER TABLE nodes ADD COLUMN traffic_last_ts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE nodes ADD COLUMN traffic_reset_enabled INTEGER NOT NULL DEFAULT 0;
ALTER TABLE nodes ADD COLUMN traffic_reset_day INTEGER NOT NULL DEFAULT 1;

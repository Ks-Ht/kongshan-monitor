//! 节点流量统计:按上报速率(bps)× 时间估算累计收/发字节(不是精确抓包计费,
//! 是监控面板常见的估算口径),可选按月清零。
//!
//! 月份边界计算用纯整数日历算法(Howard Hinnant 的 civil_from_days / days_from_civil,
//! 公有领域算法),不引入 chrono/time 等日期库依赖。清零日限定 1~28,避开"某月没有第
//! 29/30/31 天"的边界问题,不做月末截断。全程按 UTC 天边界计算,不做时区换算。

use crate::state::AppState;
use crate::util::unix_now;

/// 清零日合法范围(避开短月边界问题)。
#[must_use]
pub fn valid_reset_day(d: i64) -> bool {
    (1..=28).contains(&d)
}

/// 单次报告的最大计入时长(秒):断线重连后避免用"离线期间的全部秒数"乘以瞬时速率,
/// 造成流量暴涨的假象;超过则按此上限计入(与"在线判定"用的 interval*3 同量级)。
fn capped_elapsed(elapsed: i64, interval_secs: i64) -> i64 {
    elapsed.clamp(0, interval_secs.saturating_mul(3).max(30))
}

/// Unix 天数(自 1970-01-01 起,可为负)→ (年, 月[1..=12], 日[1..=31])。
#[allow(clippy::cast_possible_wrap, clippy::cast_possible_truncation)]
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    let year = if m <= 2 { y + 1 } else { y };
    (year, m, d)
}

/// (年, 月[1..=12], 日[1..=31]) → Unix 天数。
#[allow(clippy::cast_possible_wrap, clippy::cast_possible_truncation)]
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u64; // [0, 399]
    let mp = u64::from(if m > 2 { m - 3 } else { m + 9 }); // [0, 11]
    let doy = (153 * mp + 2) / 5 + u64::from(d) - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146_097 + doe as i64 - 719_468
}

/// 给定当前时刻与"每月第几天清零",计算当前所在统计周期的起始时刻(UTC 当天 00:00:00)。
#[must_use]
pub fn current_period_start(now: i64, reset_day: i64) -> i64 {
    let reset_day = reset_day.clamp(1, 28) as u32;
    let days = now.div_euclid(86400);
    let (y, m, d) = civil_from_days(days);
    let start_days = if d >= reset_day {
        days_from_civil(y, m, reset_day)
    } else {
        let (py, pm) = if m == 1 { (y - 1, 12) } else { (y, m - 1) };
        days_from_civil(py, pm, reset_day)
    };
    start_days * 86400
}

/// 按本次上报的速率估算这段时间的流量,累加进节点的周期计数器。静默失败(不影响主流程)。
pub async fn accumulate(st: &AppState, node_id: i64, now: i64, rx_bps: i64, tx_bps: i64) {
    let interval_secs = crate::db::setting_i64(&st.db, "report_interval_secs", 5, 1, 3600).await;
    let Ok(Some(row)) = sqlx::query!(
        r#"SELECT traffic_last_ts as "last_ts!" FROM nodes WHERE id = ?1"#,
        node_id
    )
    .fetch_optional(&st.db)
    .await
    else {
        return;
    };
    let elapsed = if row.last_ts > 0 { capped_elapsed(now - row.last_ts, interval_secs) } else { 0 };
    if elapsed <= 0 {
        let _ = sqlx::query!("UPDATE nodes SET traffic_last_ts = ?1 WHERE id = ?2", now, node_id)
            .execute(&st.db)
            .await;
        return;
    }
    let rx_add = rx_bps.max(0).saturating_mul(elapsed);
    let tx_add = tx_bps.max(0).saturating_mul(elapsed);
    let _ = sqlx::query!(
        "UPDATE nodes SET traffic_rx_total = traffic_rx_total + ?1,
                           traffic_tx_total = traffic_tx_total + ?2,
                           traffic_last_ts = ?3
         WHERE id = ?4",
        rx_add,
        tx_add,
        now,
        node_id
    )
    .execute(&st.db)
    .await;
}

/// 周期性(每小时)巡检:对开启按月清零的节点,若已跨过当前统计周期边界则清零。
pub async fn sweep_resets(st: &AppState) {
    let now = unix_now();
    let rows = sqlx::query!(
        r#"SELECT id as "id!", traffic_reset_day as "reset_day!", traffic_period_start as "period_start!"
           FROM nodes WHERE traffic_reset_enabled = 1"#
    )
    .fetch_all(&st.db)
    .await
    .unwrap_or_default();
    for r in rows {
        let expected = current_period_start(now, r.reset_day);
        if expected != r.period_start {
            let _ = sqlx::query!(
                "UPDATE nodes SET traffic_rx_total = 0, traffic_tx_total = 0, traffic_period_start = ?1
                 WHERE id = ?2",
                expected,
                r.id
            )
            .execute(&st.db)
            .await;
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn civil_roundtrip_known_dates() {
        // (unix_days, y, m, d)
        // 天数与日期对照(与 Python `(date - date(1970,1,1)).days` 核对一致)
        let cases: &[(i64, i64, u32, u32)] = &[
            (0, 1970, 1, 1),
            (-1, 1969, 12, 31),
            (19722, 2023, 12, 31),
            (19723, 2024, 1, 1),
            (19781, 2024, 2, 28),
            (19782, 2024, 2, 29), // 闰年(能被 4 整除、不能被 100 整除)
            (19783, 2024, 3, 1),
        ];
        for &(days, y, m, d) in cases {
            assert_eq!(civil_from_days(days), (y, m, d), "civil_from_days({days})");
            assert_eq!(days_from_civil(y, m, d), days, "days_from_civil({y},{m},{d})");
        }
    }

    #[test]
    fn century_leap_rule() {
        // 1900 不是闰年(能被 100 整除但不能被 400 整除);2000 是闰年
        let d1900 = days_from_civil(1900, 2, 28);
        let d1900_mar1 = days_from_civil(1900, 3, 1);
        assert_eq!(d1900_mar1 - d1900, 1); // 1900 年 2 月只有 28 天
        let d2000 = days_from_civil(2000, 2, 28);
        let d2000_mar1 = days_from_civil(2000, 3, 1);
        assert_eq!(d2000_mar1 - d2000, 2); // 2000 年 2 月有 29 天
    }

    #[test]
    fn period_start_same_month_and_rollover() {
        // 2026-07-05,清零日=1 → 本期起点 2026-07-01
        let ts_20260705 = days_from_civil(2026, 7, 5) * 86400 + 12 * 3600;
        assert_eq!(current_period_start(ts_20260705, 1), days_from_civil(2026, 7, 1) * 86400);

        // 2026-07-05,清零日=10 → 还没到本月 10 号,应回退到上月(6 月)10 号
        assert_eq!(current_period_start(ts_20260705, 10), days_from_civil(2026, 6, 10) * 86400);

        // 跨年:2026-01-05,清零日=10 → 上月是 2025-12-10
        let ts_20260105 = days_from_civil(2026, 1, 5) * 86400;
        assert_eq!(current_period_start(ts_20260105, 10), days_from_civil(2025, 12, 10) * 86400);
    }

    #[test]
    fn reset_day_validation() {
        assert!(valid_reset_day(1) && valid_reset_day(28));
        assert!(!valid_reset_day(0) && !valid_reset_day(29) && !valid_reset_day(31));
    }

    #[test]
    fn elapsed_capping_avoids_reconnect_spike() {
        assert_eq!(capped_elapsed(5, 5), 5);
        assert_eq!(capped_elapsed(100_000, 5), 30); // 断线很久重连:按上限(至少 30s)计入,不放大
        assert_eq!(capped_elapsed(-3, 5), 0); // 时钟异常/重复上报,不倒扣
    }
}

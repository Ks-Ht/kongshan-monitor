-- 性能与去重:补 ts 单列索引 + 将 (node_id, ts) 升为唯一索引。
-- 背景:此前只有非唯一复合索引 idx_metrics_node_ts(node_id, ts),凡"只按 ts 过滤"的
-- 查询(保留清理 / rollup 聚合 / 趋势)都用不上它(首列是 node_id)→ 全表扫描;每小时
-- 的保留任务因此长时间独占 SQLite 唯一写锁,把 agent 上报的写入饿死(表现为写卡 3-5s)。

-- 先去除历史 (node_id, ts) 重复行(保留最小 id),为唯一索引铺路。
DELETE FROM metrics
WHERE id NOT IN (SELECT MIN(id) FROM metrics GROUP BY node_id, ts);

-- (node_id, ts) 升级为唯一索引:配合 live 写入路径的 INSERT OR IGNORE 去重"同一秒"重复行。
DROP INDEX IF EXISTS idx_metrics_node_ts;
CREATE UNIQUE INDEX idx_metrics_node_ts ON metrics(node_id, ts);

-- ts 单列索引:让"只按 ts"的范围查询走 B 树 seek 而非全表扫描。ts 近乎单调递增,
-- 追加成本低,INSERT 多维护一个索引的代价远小于收益。
CREATE INDEX idx_metrics_ts ON metrics(ts);

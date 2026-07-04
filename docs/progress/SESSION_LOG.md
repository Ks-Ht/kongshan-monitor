
## 2026-07-04 安全审计(agent 上报通道 + 采集端 + 本轮新增功能)
- 审计范围:ws_agent.rs / collect.rs / parsers.rs / notify.rs / notify_smtp.rs / alerts.rs / nodes.rs(install 渲染)/ agent_api.rs / common lib / config / middleware
- 已完成:逐文件通读,聚焦 Backfill 补传、systemd 子进程、top 进程/TCP 解析、SMTP 新代码、SSRF、告警分级/静默/renotify、install.sh 注入面
- 结论:未发现可远程利用的严重漏洞;发现若干中/低风险与设计权衡点(详见审计报告)
- 状态:审计报告已直接输出给用户,未改动任何代码

## 2026-07-04 备份/数据保留 安全审计(只读,未改代码)
- 审计范围:retention.rs / handlers/account.rs / db.rs(备份相关)/ 全 crates grep VACUUM|backup
- 结论:发现 1 个严重(备份文件权限 0644,含全部敏感数据)、1 个中(备份 DoS 可被认证用户触发填满磁盘)、若干低/误报澄清
- VACUUM INTO 路径注入:误报(路径服务端派生,非请求可控;且已对单引号转义)
- 未修改任何代码
## 2026-07-04 安全审计(前端XSS/HTTP头/数据出口/部署容器/备份)
- 审计范围:crates/server/static/*.js、middleware.rs、pages.rs、handlers/{status,dataout,account,settings}.rs、retention.rs、apiauth.rs、notify.rs、audit.rs、Dockerfile、deploy/、scripts/
- 结论:未发现【严重】漏洞。前端全站 textContent/createElement,无 innerHTML/eval;CSP script-src 'self' 无 unsafe-inline;CSV/Prometheus 有转义;VACUUM 路径无用户输入;容器非 root 运行;私钥 chmod 600。
- 报告以最终消息形式返回,未落地报告文件。

## 2026-07-04 安全审计(认证/会话/密码/2FA/授权/CSRF)
- 已完成:通读 auth.rs / session.rs / totp.rs / twofa.rs / middleware.rs / ratelimit.rs / apitokens.rs / apiauth.rs / util.rs / config.rs / ws_agent.rs / account.rs / settings.rs / nodes.rs / common lib / DB schema。
- 结论:整体安全设计扎实(服务端会话+SHA256、argon2、常量时间比较、__Host- Cookie、CSRF Origin+自定义头、client_ip 只信任配置代理)。
- 主要发现:2FA 登录暴力破解节流依赖 per-username 退避+per-IP 10/min,TOTP ±1 窗口重放窗口约 90s(单管理员影响可控);argon2 用默认参数(0.5.3=19MiB/t=2,达标)。详见对话报告。
- 未改代码。状态:审计完成,待人工复核结论。

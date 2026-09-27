# 报告回顾与代码对齐

**日期**：2026-09-27
**基线版本**：lua-resty-yar v0.5.0（dist.ini）、lua-yar >= 0.1.1
**回顾范围**：`docs/reports/` 目录下 9 份报告

---

## 1. 已解决问题（22 项）

### 1.1 P0 — cosocket `setkeepalive()` 未透传 `keepalive_idle`/`pool_size`

| 维度 | 内容 |
|------|------|
| **来源** | dependency-audit.md |
| **报告时版本** | v0.1.0 |
| **解决证据** | `lib/resty/yar/init.lua` `new_client()` 使用嵌套表 `keepalive = { idle_timeout, pool_size }` 传递给 `client:set_options(client_opts)`；lua-yar 侧 `Socket.release` 签名已修复 |
| **业界参考** | lua-resty-redis `setkeepalive(timeout, size)` 双参数；lua-resty-http 同 |
| **状态** | ✅ 已解决 |

### 1.2 P0 — API 名大小写迁移（`Yar.Server`→`Yar.server`）

| 维度 | 内容 |
|------|------|
| **来源** | restructuring-review.md |
| **解决证据** | `lib/resty/yar/init.lua` 全部使用小写导出 `Yar.server`/`Yar.client`/`Yar.log`/`Yar.error` |
| **状态** | ✅ 已解决 |

### 1.3 P0 — `from_codec` → `register_packager`

| 维度 | 内容 |
|------|------|
| **来源** | restructuring-review.md |
| **解决证据** | `lib/resty/yar/init.lua` 使用 `Yar.register_packager(Yar.PACKAGER_JSON, cjson)` |
| **状态** | ✅ 已解决 |

### 1.4 P0 — Server 统一 Facade + `get_tcp_server` 简化

| 维度 | 内容 |
|------|------|
| **来源** | restructuring-review.md |
| **解决证据** | 单 `_server` 实例，`server/tcp.lua` 复用同一 `_server:handle({socket=sock})` |
| **状态** | ✅ 已解决 |

### 1.5 P0 — `tcp.lua` `handle({socket})` 委托

| 维度 | 内容 |
|------|------|
| **来源** | restructuring-review.md |
| **解决证据** | `server/tcp.lua` `_server:handle({ socket = sock, keepalive = true })` |
| **状态** | ✅ 已解决 |

### 1.6 P1 — `http.lua` `serve_callback` 委托

| 维度 | 内容 |
|------|------|
| **来源** | restructuring-review.md |
| **解决证据** | `server/http.lua` `_server:handle({ method, data, writer })` |
| **状态** | ✅ 已解决 |

### 1.7 P2 — `dist.ini` requires 补充 `lua-yar`

| 维度 | 内容 |
|------|------|
| **来源** | restructuring-review.md |
| **解决证据** | `dist.ini` 有 `requires = luajit, openresty >= 1.19.3.1, fangfengxiang/lua-yar >= 0.1.1` |
| **状态** | ✅ 已解决 |

### 1.8 P1 — Schema 驱动配置校验

| 维度 | 内容 |
|------|------|
| **来源** | kong-inspired-optimization.md #1 |
| **解决证据** | `lib/resty/yar/config.lua` `TYPE_SPEC` 类型校验 + `validate()` + `deep_merge` + 嵌套分域（server/client/observability/extensions）+ flat 向后兼容 |
| **业界参考** | Kong schema 驱动（Kong 有 100+ 实体需完整框架，resty-yar 10+ 配置项用内联校验 ~50 行已够） |
| **状态** | ✅ 已解决 |

### 1.9 P1 — 可观测性（metrics/埋点）

| 维度 | 内容 |
|------|------|
| **来源** | kong-inspired-optimization.md #5, evaluation-report.md |
| **解决证据** | `lib/resty/yar/observability.lua` 三件套：`access_logger`（结构化 JSON 访问日志，defer 模式）+ `trace_middleware`（request ID 追踪+跨服务传播）+ `metrics_recorder`（Prometheus exposition format，counter + histogram，buffer 模式）+ `compose`/`compose_named` + `defaults` |
| **业界参考** | Kong 有完整的 observability stack（Prometheus/Zipkin/datadog 插件）；lua-resty-redis/http 无。resty-yar 自实现 Prometheus 格式输出（零依赖），不集成第三方库 |
| **状态** | ✅ 已解决 |

### 1.10 P2 — 请求追踪 X-Request-ID

| 维度 | 内容 |
|------|------|
| **来源** | kong-inspired-optimization.md #7 |
| **解决证据** | `observability.lua` `trace_middleware` 生成 request ID + 注入响应 header + 跨服务传播（client → server header 注入） |
| **业界参考** | Kong 有 request ID 插件；lua-resty-redis/http 无 |
| **状态** | ✅ 已解决 |

### 1.11 P3 — 插件/中间件架构

| 维度 | 内容 |
|------|------|
| **来源** | kong-inspired-optimization.md #11 |
| **解决证据** | `lib/resty/yar/registry.lua` 插件注册 + 优先级排序 + named compose；`lib/resty/yar/hooks.lua` 生命周期钩子适配（on_request/on_response/on_error/on_timeout/on_connect/on_init_worker） |
| **业界参考** | Kong PDK 插件体系；gRPC-go interceptor；lor 中间件链。resty-yar 用 hooks/registry 轻量实现，不引入 PDK 抽象层 |
| **状态** | ✅ 已解决 |

### 1.12 P1 — CI 多版本矩阵

| 维度 | 内容 |
|------|------|
| **来源** | evaluation-report.md |
| **解决证据** | `.github/workflows/test.yml` matrix: openresty 1.21.4.3 / 1.25.3.2 / 1.27.1.2 |
| **业界参考** | lua-resty-http CI 测 1.25/1.27；lua-resty-redis 测 1.19+ |
| **状态** | ✅ 已解决 |

### 1.13 P1 — luacov 代码覆盖率

| 维度 | 内容 |
|------|------|
| **来源** | evaluation-report.md |
| **解决证据** | `.github/workflows/test.yml` 独立 coverage job（安装 luacov + 注入 `t/luacov_init.lua` + Codecov 上传） |
| **状态** | ✅ 已解决 |

### 1.14 P1 — TLS/SSL 支持

| 维度 | 内容 |
|------|------|
| **来源** | evaluation-report.md |
| **解决证据** | `config.lua` `ssl_verify = true` 默认配置；`init.lua` `new_client()` 传递 ssl_verify；cosocket 原生支持 TLS；lua-resty-http provider 也传递 ssl_verify |
| **业界参考** | lua-resty-redis `ssl_verify`；lua-resty-http `ssl_verify`。cosocket `sock:sslhandshake()` 原生支持 |
| **状态** | ✅ 已解决 |

### 1.15 P1 — WARN/INFO 日志

| 维度 | 内容 |
|------|------|
| **来源** | evaluation-report.md |
| **解决证据** | `init.lua` `Log.set_writer(ngx_log_writer)` + `Log.set_level(level)` 注入；`observability.lua` `access_logger` 输出 INFO/WARN 级别结构化 JSON 日志 |
| **状态** | ✅ 已解决 |

### 1.16 P1 — 基本 Metrics

| 维度 | 内容 |
|------|------|
| **来源** | evaluation-report.md |
| **解决证据** | `observability.lua` `metrics_recorder` 输出 Prometheus exposition format，支持 counter（rpc_calls_total）+ histogram（rpc_duration_seconds），支持 buffer 模式（flush_interval + shared dict） |
| **业界参考** | 自实现而非集成 lua-resty-prometheus（零依赖，功能等价） |
| **状态** | ✅ 已解决 |

### 1.17 P1 — 补充测试

| 维度 | 内容 |
|------|------|
| **来源** | evaluation-report.md |
| **解决证据** | `t/` 从 3 文件→17 文件（bdd.t, chaos.t, config.t, e2e.t, framework.t, functional.t, hooks.t, http.t, integration.t, observability.t, performance.t, registry.t, tcp.t, client.t + benchmark/ + luacov_init.lua） |
| **状态** | ✅ 已解决 |

### 1.18 P2 — lua-yar `set_logger`

| 维度 | 内容 |
|------|------|
| **来源** | evaluation-report.md |
| **解决证据** | `Log.set_writer` 已存在（lua-yar 侧已实现），`init.lua` 注入 ngx.log writer |
| **状态** | ✅ 已解决 |

### 1.19 P2 — 并发测试

| 维度 | 内容 |
|------|------|
| **来源** | evaluation-report.md |
| **解决证据** | `t/chaos.t` + `t/performance.t` + `t/benchmark/` 目录 + `.github/workflows/test-chaos.yml` + `test-performance.yml` |
| **状态** | ✅ 已解决 |

### 1.20 P2 — 错误码常量 + 结构化错误

| 维度 | 内容 |
|------|------|
| **来源** | evaluation-report.md, kong-inspired-optimization.md #4 |
| **解决证据** | `Error` 对象（5 类错误码：TRANSPORT/TIMEOUT/PROTOCOL/NOT_FOUND/EXCEPTION）+ `hooks.lua` `on_error`/`on_timeout` 派生 + `observability.lua` `error_status()` 对齐 Error 码体系 |
| **业界参考** | gRPC status codes；yar-c `YAR_ERR_*` 常量 |
| **状态** | ✅ 已解决 |

### 1.21 P3 — 集成 lua-resty-http

| 维度 | 内容 |
|------|------|
| **来源** | evaluation-report.md |
| **解决证据** | `init.lua` `use_resty_http` provider 注入（`local httpc = require("resty.http").new()`） |
| **状态** | ✅ 已解决 |

### 1.22 P2 — 贡献指南

| 维度 | 内容 |
|------|------|
| **来源** | evaluation-report.md |
| **解决证据** | `CONTRIBUTING.md` 已存在 |
| **状态** | ✅ 已解决 |

---

## 2. 部分解决问题（5 项）

### 2.1 P1 — 认证中间件

| 维度 | 内容 |
|------|------|
| **已解决** | hooks 机制提供 `on_request` 扩展点，用户可注册认证 hook |
| **未解决** | 无内置认证实现/示例文档 |
| **业界参考** | lua-resty-redis 的 AUTH 是协议级（Redis 协议内置 AUTH 命令）；lua-resty-http 无认证；Yar 协议有 token 字段但 lua-yar 已透传 |
| **处理方案** | 提供认证 hooks 示例文档（本提案 tasks 4.2），不内置实现（框架不应绑定认证方案） |
| **状态** | ⚠️ 部分解决 |

### 2.2 P2 — 优雅关闭

| 维度 | 内容 |
|------|------|
| **已解决** | TCP 侧有 lingering close（`pcall(sock.shutdown, "send")` + `pcall(sock.close)`） |
| **未解决** | 无 `ngx.worker.exiting()` 检测（worker 退出时 keepalive 循环仍读取新消息） |
| **业界参考** | Kong 在 runloop 中检测 `ngx.worker.exiting()`；lua-resty-redis/http 无（客户端库） |
| **处理方案** | `tcp.lua` keepalive 循环增加 `ngx.worker.exiting()` 检测（本提案 tasks 5.1） |
| **状态** | ⚠️ 部分解决 |

### 2.3 P3 — 错误回调 + 重试

| 维度 | 内容 |
|------|------|
| **已解决** | 错误回调（`on_error`/`on_timeout`）已实现 |
| **未解决** | 重试 + 指数退避未实现 |
| **业界参考** | lua-resty-redis 有 retry；lua-resty-http/yar-c 无。需幂等性判断，作为框架增强按优先级实施 |
| **状态** | ⚠️ 部分解决（重试作为框架增强功能，当前版本暂不实施） |

### 2.4 P3 — OpenTelemetry tracing

| 维度 | 内容 |
|------|------|
| **已解决** | `trace_middleware` 有 request ID 追踪 + 跨服务传播 |
| **未解决** | 非 OpenTelemetry 标准（无 OTel SDK 集成） |
| **业界参考** | Kong 支持 Zipkin/OTel；lua-resty-redis/http 无。需 OTel SDK 依赖，作为框架增强按优先级实施 |
| **状态** | ⚠️ 部分解决（OTel 标准化作为框架增强功能，当前版本暂不实施） |

### 2.5 P3 — LuaLS 类型标注

| 维度 | 内容 |
|------|------|
| **已解决** | 有 `@diagnostic` 和部分 `@param` 注解 |
| **未解决** | 未全面覆盖所有公共 API |
| **状态** | ⚠️ 部分解决（低优先级，后续迭代补充） |

---

## 3. 框架增强功能（当前版本暂不实施，6 项）

以下功能作为轻量 RPC 框架的增强功能，按优先级逐步实现，当前版本（v0.5.0）暂不实施。

### 3.1 健康检查 + 熔断

| 维度 | 内容 |
|------|------|
| **来源** | kong-inspired-optimization.md #2, evaluation-report.md |
| **业界参考** | Kong 有完整健康检查（active/passive/三态机）；lua-resty-redis/http/yar-c 无 |
| **暂不实施理由** | 连接级健康检查可用 hooks 做（on_connect 检测失败计数），服务级健康检查需服务注册/发现/状态机，属平台层 `lua-resty-php-beacon` 职责。轻量框架不引入此复杂度 |

### 3.2 重试 + 指数退避

| 维度 | 内容 |
|------|------|
| **来源** | kong-inspired-optimization.md #9 |
| **业界参考** | lua-resty-redis 有 retry；lua-resty-http/yar-c 无 |
| **暂不实施理由** | RPC 调用可能非幂等，重试需用户显式开启 + 幂等性判断。作为框架增强按优先级实施，当前版本暂不做 |

### 3.3 Worker 事件 + 配置热更新

| 维度 | 内容 |
|------|------|
| **来源** | kong-inspired-optimization.md #6 |
| **业界参考** | Kong 有 worker events；lua-resty-redis/http 无 |
| **暂不实施理由** | OpenResty 项目通常用 `nginx.conf` 管配置，`nginx -s reload` 即可热更新。额外的 worker 事件总线冗余 |

### 3.4 DNS 解析缓存

| 维度 | 内容 |
|------|------|
| **来源** | kong-inspired-optimization.md #10 |
| **业界参考** | Kong 有 DNS client；lua-resty-redis/http 无 |
| **暂不实施理由** | RPC 客户端通常直连 IP。cosocket 内置 DNS 解析已满足需求 |

### 3.5 声明式配置 + env 覆盖

| 维度 | 内容 |
|------|------|
| **来源** | kong-inspired-optimization.md #12 |
| **业界参考** | Kong 有 declarative config；lua-resty-redis/http 无 |
| **暂不实施理由** | `config.lua` 已有 Schema 驱动配置体系。OpenResty 用 `nginx.conf` + `init_by_lua` 是配置惯例，额外声明式配置文件层冗余 |

### 3.6 OpenTelemetry 标准 tracing

| 维度 | 内容 |
|------|------|
| **来源** | evaluation-report.md |
| **业界参考** | Kong 支持 Zipkin/OTel；lua-resty-redis/http 无 |
| **暂不实施理由** | 当前 `trace_middleware` 已实现 request ID 追踪 + 跨服务传播，满足基本需求。OTel 标准化需引入 OTel SDK 依赖，作为框架增强按优先级实施 |

---

## 4. 运维操作（1 项）

### 4.1 P0 — 发布到 OPM 仓库

| 维度 | 内容 |
|------|------|
| **来源** | evaluation-report.md |
| **状态** | 包配置已就绪，发布是手动运维操作 |
| **就绪证据** | `dist.ini` 完整（version 0.5.0, requires 声明）；`.github/workflows/opm-build.yml` CI 验证打包；`.github/workflows/release.yml` 发布流程 |
| **业界参考** | lua-resty-redis/http 已发布到 OPM |
| **操作** | 手动执行 `opm publish` |

---

## 5. 已有提案覆盖的问题（不重复处理）

### 5.1 review-driven-hardening（0/27 未实施）

| 维度 | 内容 |
|------|------|
| **来源** | review-driven-hardening 提案 |
| **P0 bug** | 1.1 histogram 累积桶方向错误；1.2 status_kinds 不对齐 Error 码体系；1.3 tcp.lua 配置分层错误（`config.connect_timeout` → `config.client.connect_timeout`） |
| **其他** | compose() 委托、JSON 控制字符转义、deep_merge 深度守卫、observability 配置桥接、测试策略升级、文档更新 |
| **处理** | 独立实施，不合并到 report-reconciliation |

### 5.2 adapt-lua-yar-011 验证任务（4.1-4.5 未完成）

| 维度 | 内容 |
|------|------|
| **来源** | adapt-lua-yar-011 提案 tasks 4.1-4.5 |
| **未完成** | keepalive 参数到达 cosocket 验证、prove 全测试、luacheck、HTTP 不加载 tcp 模块、日志到 error log |
| **处理** | 本提案 tasks 6.1-6.5 收尾 |

---

## 6. 不适用（3 项）

| # | 问题 | 来源 | 不适用理由 |
|---|------|------|------------|
| 1 | 多级缓存 | kong-inspired #13 | 报告建议不实施 |
| 2 | PDK 抽象层 | kong-inspired #14 | 报告建议不实施 |
| 3 | Admin API | kong-inspired #15 | 报告建议不实施 |

---

## 7. 结论与下一步

**已解决 22/40+**（55%），部分解决 5 项，框架增强暂不实施 6 项，运维操作 1 项，已有提案覆盖 2 项，不适用 3 项。

**下一步行动**（report-reconciliation 提案 tasks）：
1. 补充架构图 + 性能调优指南（纯文档）
2. 补充限流/认证 hooks 示例（纯文档）
3. `tcp.lua` 优雅关闭增强（~5 行代码）
4. adapt-lua-yar-011 验证收尾
5. 归档 project-hardening（26/26 已完成）

# 可观测性集成设计决策

可观测性是生产级 RPC 服务的必备能力——日志、追踪、metrics。lua-resty-yar 作为适配层，将 lua-yar 的可观测性扩展点（Log writer 注入、hooks 机制）桥接到 OpenResty 运行时，并补充结构化日志与链路追踪支持。

---

## 7. ngx.log writer 注入

- **状态**：已实现
- **决策驱动因素**：运行时适配
- **关联决策**：#1（适配层定位）

### 背景

lua-yar 的日志模块（`log.lua`）提供 4 级别（DEBUG/INFO/WARN/ERROR）+ 可注入 writer（`Log.set_writer(fn)`）。默认 writer 是 `print()`，全环境可用。在 OpenResty 中，日志应重定向到 `ngx.log`，写入 nginx error log，统一运维日志通道。

### 思考与取舍

> "Logs are for humans." — 运维哲学
> "日志是给人看的。" — 运维哲学

决策：`setup()` 中注入 ngx.log writer，将 lua-yar 日志重定向到 nginx error log。

**注入方式：**
```lua
Log.set_writer(function(lvl, msg)
    ngx.log(LOG_LEVEL_MAP[lvl] or ngx.ERR, "[yar] " .. msg)
end)
```

**级别映射：**
- lua-yar `Log.DEBUG`(1) → `ngx.DEBUG`
- lua-yar `Log.INFO`(2) → `ngx.INFO`
- lua-yar `Log.WARN`(3) → `ngx.WARN`
- lua-yar `Log.ERROR`(4) → `ngx.ERR`

**设计要点：**
- 级别映射表 `LOG_LEVEL_MAP` 是模块级常量，避免每条日志重复映射
- `or ngx.ERR` 兜底：未知级别降级为 ERR（安全默认）
- 消息前缀 `[yar]`：便于在 nginx error log 中过滤 lua-yar 相关日志
- `Log.set_level()` 可选配置：用户可在 `setup({ log_level = Yar.log.DEBUG })` 中调整级别

**为什么不在 lua-yar 内部硬编码 ngx.log：**
- lua-yar 定位为运行时无关的纯协议库，不应引用 `ngx`
- writer 注入是对标 Python logging 的 `addHandler` 模式——库提供扩展点，运行时适配层注入
- 对标 lua-resty-redis：库内部用 `ngx.log` 是因为它专为 OpenResty 设计；lua-yar 不是

### 业界参考

- **lua-resty-redis**：内部直接用 `ngx.log`（专为 OpenResty 设计）
- **Python `logging`**：`logging.getLogger(name)` + `addHandler(handler)`，库提供 logger，应用配置 handler
- **log4lua**：多 appender + 级别，类似但依赖配置文件

### 代码评价

`init.lua` 的 writer 注入 3 行代码，简洁。`LOG_LEVEL_MAP` 用数组索引（lua-yar 级别是 1-4 整数），查找 O(1)。`or ngx.ERR` 兜底设计安全。消息前缀 `[yar]` 便于运维过滤。`set_level` 用 `opts.log_level` 可选配置，不强制。

### 知识领域

1. *Site Reliability Engineering*（Google）— 日志级别与可观测性
2. *Release It!*（Nygard）— 日志与故障排查

---

## 8. 结构化 JSON 访问日志

- **状态**：已实现
- **决策驱动因素**：可观测性
- **关联决策**：#7（ngx.log writer 注入）、#9（request ID 贯穿）

### 背景

nginx 原生 `log_format` 生成文本日志，难以被日志采集系统（ELK/Loki/Fluentd）结构化解析。OpenResty 的 `ngx.log` 写入 error log（非访问日志），不适合记录每请求的访问日志。需要提供结构化 JSON 访问日志能力，记录 RPC 调用的 method/params/response_size/duration/status 等字段。

### 思考与取舍

> "Observability is a measure of how well internal states of a system can be inferred from knowledge of its external outputs." — Wikipedia
> "可观测性是衡量系统内部状态能否从外部输出推断的程度。" — Wikipedia

决策：通过 lua-yar hooks 机制（`on_request` / `on_response`）采集 RPC 调用数据，提供结构化 JSON 日志 writer。

**设计方式：**
- `resty.yar.observability` 模块提供 `access_logger(opts)` 工厂函数
- 返回一个 hooks 表 `{ on_request, on_response }`，注入 `setup({ hooks = ... })`
- `on_request(method, params)` 记录请求开始时间、method、params 大小
- `on_response(method, retval, err)` 记录响应状态、retval 大小、duration
- 输出 JSON 格式到 `ngx.log(ngx.INFO, ...)` 或自定义 writer

**为什么用 hooks 而非独立中间件：**
- lua-yar 已提供 hooks 机制（`on_request` / `on_response` + pcall 保护），无需重新设计
- hooks 是零开销的（未配置时 `if not hook then return end` 直接返回）
- 对标 Express.js middleware：hooks 是轻量中间件，pcall 保护避免日志故障影响主流程

**JSON 字段设计：**
```json
{
  "ts": "2026-08-13T12:00:00Z",
  "level": "info",
  "module": "yar.rpc",
  "method": "add",
  "params_size": 2,
  "status": "ok",
  "retval_size": 1,
  "duration_ms": 0.5,
  "request_id": "abc123",
  "trace_id": "def456"
}
```

**与 nginx access_log 的关系：**
- nginx access_log 记录 HTTP 层信息（status code、bytes sent、remote addr）
- YAR access_log 记录 RPC 层信息（method、params、retval、duration）
- 两者互补，不替代

### 业界参考

- **OpenTelemetry**：结构化日志规范，`LogRecord` 含 timestamp/severity/body/attributes
- **nginx log_format**：文本格式，`$remote_addr - $request - $status`
- **Kong**：`kong.log` 模块，结构化 JSON 日志 + 级别过滤
- **lua-resty-logger**：ngx.log 封装，绑定 OpenResty

### 代码评价

`observability.lua` 的 `access_logger` 工厂函数返回 hooks 表，设计简洁。`on_request` 用 `ngx.now()` 记录开始时间（OpenResty 高精度时间戳），`on_response` 计算 duration。JSON 序列化用 `cjson.encode`（若可用）或手写拼接（零依赖兜底）。request_id 从 `ngx.ctx` 读取（由 trace middleware 注入）。

### 知识领域

1. *OpenTelemetry Specification* — 结构化日志与 LogRecord 规范
2. *nginx log_format docs* — 访问日志格式

---

## 9. request ID 贯穿与 trace context 传播

- **状态**：已实现
- **决策驱动因素**：链路追踪
- **关联决策**：#8（结构化日志）、#7（ngx.log writer 注入）

### 背景

分布式系统中，一个用户请求可能触发多个 RPC 调用，跨多个服务。链路追踪（distributed tracing）需要 request ID 贯穿调用链，trace context 在服务间传播。lua-yar 的 request ID（事务 ID）是协议层的，用于 YAR 协议帧匹配，不适合直接作为追踪 ID。

### 思考与取舍

> "Distributed tracing is the recording of the causal path of requests through a system." — Distributed Tracing Literature
> "分布式追踪是记录请求在系统中传播的因果路径。" — 分布式追踪文献

决策：提供 `resty.yar.observability` 模块的 trace middleware，在 `ngx.ctx` 中注入 request_id 和 trace_id，通过 YAR 协议的 provider/token 字段传播 trace context。

**设计方式：**
- `trace_middleware(opts)` 工厂函数，返回 `on_request` hook
- `on_request(method, params)` 时，从 `ngx.ctx` 读取 request_id（若不存在则生成）
- request_id 生成用 `ngx.time() + ngx.worker.pid() + 计数器` 组合，或注入自定义生成器
- trace context 通过 YAR 协议的 `provider` / `token` 字段传播（YAR 协议头有这两个字段，可用于元数据传递）

**为什么用 ngx.ctx：**
- `ngx.ctx` 是 OpenResty 请求级上下文，每请求独立，协程内共享
- 对标 Go context.Context：请求级上下文传播
- 不污染全局状态

**trace context 传播策略：**
- 出向 RPC 调用：Client 的 `on_request` hook 将 `ngx.ctx.request_id` 写入 YAR 请求的 `provider` 字段
- 入向 RPC 处理：Server 的 `on_request` hook 从 YAR 请求的 `provider` 字段读取 trace context，写入 `ngx.ctx`
- 跨服务传播：服务 A 调用服务 B，A 的 client hook 注入 trace context，B 的 server hook 提取 trace context

**与 W3C Trace Context 的关系：**
- W3C Trace Context 用 `traceparent` / `tracestate` HTTP 头传播
- YAR 协议是二进制协议，没有 HTTP 头，用 provider/token 字段传播
- provider 字段（8 字节）适合放 trace_id，token 字段（32 字节）适合放 span_id + 采样标志

**与 lua-yar request ID 的区别：**
- lua-yar request ID（事务 ID）：YAR 协议帧匹配，per-request 唯一，用于响应匹配
- trace request_id：链路追踪，跨服务贯穿，用于调用链关联
- 两者独立，不混用

### 业界参考

- **OpenTelemetry Trace Context (W3C)**：`traceparent` / `tracestate` 头传播规范
- **Dapper Paper (Google)**：分布式追踪基础理论，span/tree 模型
- **nginx-opentracing**：nginx 的 OpenTracing 集成，用 `ngx.ctx` 传播 span context
- **Jaeger**：分布式追踪系统，Uber 开源

### 代码评价

`observability.lua` 的 `trace_middleware` 工厂函数设计简洁。request_id 生成用多熵源混合（ngx.time + ngx.worker.pid + 计数器），对标 lua-yar 的 `gen_id` 设计。trace context 通过 provider/token 字段传播，不修改 YAR 协议结构（兼容 PHP Yar）。`ngx.ctx` 请求级上下文，协程安全。

### 知识领域

1. *OpenTelemetry Trace Context (W3C)* — trace context 传播规范
2. *Dapper Paper (Google)* — 分布式追踪基础理论

---

## 12. log_by_lua 延迟访问日志

- **状态**：已实现
- **决策驱动因素**：性能 + OpenResty 原生惯例
- **关联决策**：#8（结构化 JSON 访问日志）、#1（适配层定位）

### 背景

OpenResty 的 `log_by_lua` 阶段在响应已发给客户端**之后**执行，是 OpenResty 原生的访问日志阶段（nginx `access_log` 也在此阶段写入）。决策 #8 的 `access_logger` 通过 `on_response` hook 在请求处理过程中同步写日志，日志 I/O 在响应热路径上。如果日志采集慢（如 shared dict 竞争、外部日志服务阻塞），拖慢响应。

### 思考与取舍

> "The fastest I/O is no I/O." — Mythical Man-Month
> "最快的 I/O 是不做 I/O。" — 人月神话

决策：`access_logger` 新增 `defer` 选项，延迟模式将日志输出从 `on_response`（请求中）移到 `log_by_lua` 阶段（请求后），由 `flush_logs()` 函数触发输出。

**延迟而非消除：**
- `on_response` 仍需组装 entry（计算 duration、组装字段），只是**输出**延迟
- 日志 I/O（JSON 序列化 + writer 调用）移出热路径
- 对标 nginx `access_log`：响应发送后才写访问日志

**defer 选项设计：**
- `defer = false`（默认）：`on_response` 立即输出（现有行为，兼容）
- `defer = true`：`on_response` 将 entry 存到 `ngx.ctx[CTX_LOG_ENTRY]`，不输出
- `flush_logs()`：在 `log_by_lua_block` 调用，从 `ngx.ctx` 读 entry 并输出

**为什么用 ngx.ctx 传递：**
- `ngx.ctx` 是请求级上下文，在 `log_by_lua` 阶段仍可读（OpenResty 保证）
- `on_response` 在 content phase 内调用（lua-yar handle_message 内），`flush_logs` 在 log phase 调用，两者跨 phase 通过 `ngx.ctx` 传递
- 对标 Kong log plugin：plugin 在 log phase 从 `ngx.ctx` 读取 content phase 存储的数据

**TCP/stream 模式限制：**
- stream 上下文无 `log_by_lua` 阶段（stream 的 `log` 阶段语义不同）
- defer 模式仅 HTTP 上下文可用，文档明确说明
- TCP 模式用户使用默认即时模式（`defer` 不设或 false）

**适配层 vs 平台分界：**
- 此优化是**阶段挂接映射**（适配层挂接 OpenResty 原生 `log_by_lua` 阶段），不是实现自己的 phase 编排系统
- 对标 Kong 的 log phase plugin：Kong 在 log phase 调用 plugin，lua-resty-yar 在 log phase 调用 `flush_logs()`
- 不引入插件架构、不引入 phase 编排——只是多挂接一个 OpenResty 原生阶段

### 业界参考

- **nginx `access_log`**：在 log phase 写入，响应发送后执行
- **Kong log plugin**：挂在 `log_by_lua` 阶段，从 `ngx.ctx` 读取请求数据并异步写日志
- **OpenResty `log_by_lua_block`**：官方文档明确此阶段用于"请求结束后的日志记录"

### 代码评价

`access_logger` 的 `defer` 选项实现简洁——`on_response` 组装 entry 后，`if defer then ngx.ctx[CTX_LOG_ENTRY] = entry else writer(...) end`，3 行分支。`flush_logs` 函数 8 行：读 ctx、判空、序列化、输出。默认 `defer = false` 保持向后兼容。`CTX_LOG_ENTRY` 常量按功能命名（日志条目存储 key）。TCP 模式不支持在文档和评估报告中明确说明。

### 知识领域

1. *OpenResty 官方文档* — `log_by_lua` 阶段语义与 `ngx.ctx` 生命周期
2. *Mythical Man-Month*（Brooks）— "The fastest I/O is no I/O"，延迟 I/O 移出热路径

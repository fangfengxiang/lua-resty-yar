# lua-resty-yar 设计文档

本目录记录 lua-resty-yar 框架开发过程中做出的全部架构与实现决策。每个决策遵循 ADR（Architecture Decision Record）骨架，并辅以业界名言与经典文献，便于读者理解决策的背景、取舍与知识脉络。

## 设计哲学三原则

lua-resty-yar 是 lua-yar（纯 Lua Yar RPC 协议库）的 **OpenResty 开发框架**。三条原则贯穿全部决策：

1. **委托而非重造** — 协议逻辑全部委托 lua-yar，框架层只做运行时桥接（cosocket 注入、ngx.log 桥接、handler 入口、配置映射）和框架能力（插件注册、配置体系、生命周期钩子、可观测性仪表化）。不重复实现协议解析、编解码、帧处理。

2. **OpenResty 原生优先** — 优先使用 OpenResty 原生能力（cosocket 非阻塞 I/O、ngx.log 日志、ngx.req 请求处理、lua_package_path 模块加载），而非引入第三方依赖。C 扩展加速（cjson/cmsgpack）为可选增强，非硬依赖。

3. **进程级复用，请求级无状态** — Server Facade 实例在 `init_by_lua` 创建、worker 内复用；handler 函数无模块级可变状态（除 Server 实例缓存），每请求/连接独立协程，天然并发安全。

## 模块大纲

17 个设计决策，按 5 个模块组织。每个决策列出驱动因素、名言（中英文对照）、经典文献/标准。看完此大纲即可掌握全貌，无需逐个阅读设计文件。

### 框架定位（[adaptation-layer.md](adaptation-layer.md)，3 个决策）

| # | 决策 | 驱动因素 | 名言 | 文献 |
|---|------|---------|------|------|
| 1 | 框架定位：委托协议库而非独立实现 | 不重复造轮子 | "Don't repeat yourself." — Hunt & Thomas | The Pragmatic Programmer (Hunt & Thomas); The Art of Unix Programming (Raymond) |
| 2 | OPM 目录结构：lib/resty/yar/ 层级 | 社区惯例 | "Convention over configuration." — Rails 哲学 | OPM Documentation; lua-resty-core 源码 |
| 3 | 进程级 Server 实例复用 | 性能 | "The fastest I/O is no I/O." — Mythical Man-Month | Release It! (Nygard); Programming in Lua (Ierusalimschy) |

### Handler 委托策略（[handler-delegation.md](handler-delegation.md)，4 个决策）

| # | 决策 | 驱动因素 | 名言 | 文献 |
|---|------|---------|------|------|
| 4 | HTTP handler 委托 serve_callback | 消除重复逻辑 | "Don't repeat yourself." — Hunt & Thomas | WSGI (PEP 333); lua-resty-http 源码 |
| 5 | TCP handler 委托 handle({socket}) | 统一 Server 实例 | "Favor object composition over class inheritance." — Gang of Four | Design Patterns (GoF); Programming in Lua (Ierusalimschy) |
| 6 | 自动检测 HTTP/stream 上下文 | 易用性 | "Make the common case fast." — 计算机体系结构原则 | The Art of Unix Programming (Raymond); nginx stream module docs |
| 17 | TCP handler worker exiting 优雅关闭检测 | 优雅关闭 / 资源清理 | "Fail fast." — 工程原则 | nginx documentation; OpenResty documentation |

### 可观测性集成（[observability-integration.md](observability-integration.md)，5 个决策）

| # | 决策 | 驱动因素 | 名言 | 文献 |
|---|------|---------|------|------|
| 7 | ngx.log writer 注入 | 运行时适配 | "Logs are for humans." — 运维哲学 | Site Reliability Engineering (Google); Release It! (Nygard) |
| 8 | 结构化 JSON 访问日志 | 可观测性 | "Observability is a measure of how well internal states of a system can be inferred from knowledge of its external outputs." — Wikipedia | OpenTelemetry Specification; nginx log_format docs |
| 9 | request ID 贯穿与 trace context 传播 | 链路追踪 | "Distributed tracing is the recording of the causal path of requests." — Distributed Tracing Literature | OpenTelemetry Trace Context (W3C); Dapper Paper (Google) |
| 12 | log_by_lua 延迟访问日志 | 性能 + OpenResty 原生惯例 | "The fastest I/O is no I/O." — Mythical Man-Month | OpenResty 官方文档; Mythical Man-Month (Brooks) |
| 16 | Worker-local metrics buffer + timer flush | 性能优化 / 高吞吐场景 | "Batching is the universal optimization." — 数据库工程经验 | Designing Data-Intensive Applications (Kleppmann); nginx access_log buffer |

### 配置桥接（[configuration-bridge.md](configuration-bridge.md)，3 个决策）

| # | 决策 | 驱动因素 | 名言 | 文献 |
|---|------|---------|------|------|
| 10 | 嵌套选项结构桥接 lua-yar | 配置一致性 | "Convention over configuration." — Rails 哲学 | The Pragmatic Programmer (Hunt & Thomas); YAR PHP Extension Spec |
| 11 | yar-c 参数映射 | 兼容性 | "Be liberal in what you accept, conservative in what you send." — Jon Postel | yar-c source code; RFC 7230 HTTP/1.1 Message Syntax |
| 13 | 嵌套分域配置 Schema + flat 向后兼容 | 配置可扩展性 / 框架演进 | "Make the common case fast." — 计算机体系结构原则 | The Pragmatic Programmer (Hunt & Thomas); nginx documentation |

### 插件与生命周期（[plugin-lifecycle.md](plugin-lifecycle.md)，2 个决策）

| # | 决策 | 驱动因素 | 名言 | 文献 |
|---|------|---------|------|------|
| 14 | 插件注册体系 register + priority + named compose | 框架特征 / 调试友好性 | "Make the common case fast." — 计算机体系结构原则 | Programming in Lua (Ierusalimschy); Design Patterns (GoF) |
| 15 | 框架生命周期钩子适配 on_error/on_timeout 派生 | 框架特征 / 生命周期完整性 | "The best way to predict the future is to invent it." — Alan Kay | Distributed Systems (Tanenbaum); gRPC-go interceptor 设计 |

## 阅读指南

- **按模块阅读**：从你最关心的模块开始，每个文档自成体系。
- **按决策追踪**：每个决策有"关联决策"字段，可顺藤摸瓜理解决策间的依赖关系。
- **按知识脉络阅读**：每个决策末尾列出 2-3 篇经典文献或标准，供深入理解该领域的理论基础。
- **名言双语对照**：每个决策的"思考与取舍"节首引一句业界名言，中英文对照，标注署名。
- **与 lua-yar ADR 互补**：lua-yar 的 41 个 ADR 记录协议层决策（docs/design/），lua-resty-yar 的 17 个 ADR 记录框架层决策，两者互补不重叠。

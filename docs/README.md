# lua-resty-yar 文档目录

本目录包含 lua-resty-yar（OpenResty 轻量 Yar RPC 框架）的全部文档：API 参考、设计决策（ADR）、工程报告。

## 文档清单

### 顶层文档

| 文档 | 语言 | 内容 |
|------|------|------|
| [index.md](index.md) | EN | 项目首页：Features、Installation、Quick Start（HTTP / TCP） |
| [api.md](api.md) | EN | 完整 API 参考：`setup()`、`get_server()`、`get_tcp_server()`、配置选项 |
| [positioning.md](positioning.md) | ZH | 项目定位：轻量 RPC 框架 vs 平台、与 lua-yar / yar-c / yar-php 的生态关系、架构概览 |

### design/ — 设计决策（ADR）

记录开发过程中做出的架构与实现决策，遵循 ADR（Architecture Decision Record）骨架。

| 文档 | 决策数 | 内容 |
|------|--------|------|
| [decisions.md](design/decisions.md) | 16 | ADR 总索引：设计哲学三原则 + 5 模块大纲表 + 阅读指南 |
| [adaptation-layer.md](design/adaptation-layer.md) | 3 | 框架定位、OPM 目录结构、进程级 Server 实例复用 |
| [handler-delegation.md](design/handler-delegation.md) | 3 | HTTP/TCP handler 委托策略、自动检测上下文 |
| [observability-integration.md](design/observability-integration.md) | 5 | ngx.log 注入、结构化访问日志、request ID 贯穿、trace context、worker-local metrics buffer |
| [configuration-bridge.md](design/configuration-bridge.md) | 3 | 配置桥接、yar-c 参数映射、嵌套分域配置 Schema + flat 向后兼容 |
| [plugin-lifecycle.md](design/plugin-lifecycle.md) | 2 | 插件注册体系 register + priority、框架生命周期钩子适配 on_error/on_timeout 派生 |
| [framework-evolution-plan.md](design/framework-evolution-plan.md) | — | 框架化改造方案：插件体系、配置 schema、生命周期钩子、性能优化、工程卫生（已实现 v0.5.0） |

### reports/ — 工程报告

测评、优化分析、依赖审计、代码审查等工程化文档。

| 文档 | 时间 | 内容 |
|------|------|------|
| [evaluation-report.md](reports/evaluation-report.md) | 2026-07-10 | 工程化测评报告（v0.1.0，对标 lua-resty-redis/http/mysql/websocket） |
| [dependency-audit.md](reports/dependency-audit.md) | 2026-07-15 | 对 lua-yar 依赖审计（逐文件逐行对照） |
| [kong-inspired-optimization.md](reports/kong-inspired-optimization.md) | 2026-07-15 | Kong Gateway 工程思想启发下的优化分析 |
| [optimization-plan-0.1.0.md](reports/optimization-plan-0.1.0.md) | 2026-07-16 | 适配 lua-yar 0.1.0 + OpenResty 分段加载优化计划 |
| [reevaluation-0.1.0.md](reports/reevaluation-0.1.0.md) | 2026-07-17 | 基于 lua-yar 0.1.0 最新代码的提案重新评测 |
| [restructuring-review.md](reports/restructuring-review.md) | — | Facade API 统一架构改造回顾 |
| [multi-stage-evaluation.md](reports/multi-stage-evaluation.md) | 2026-08-17 | OpenResty 多阶段特性利用空间评估 |
| [code-review-2026-07-10.md](reports/code-review-2026-07-10.md) | 2026-07-10 | 代码审查报告（优化后二次 Review，12 维度） |
| [lua-yar-pool-param-refactor.md](reports/lua-yar-pool-param-refactor.md) | — | 从 resty-yar 反向审视 lua-yar（定位参照 yar-c / yar-php） |

## 阅读路径

**快速上手**：`index.md` → `api.md`

**理解设计**：`positioning.md` → `design/decisions.md`（总览）→ 按模块深入

**了解演进**：`reports/evaluation-report.md`（初始测评）→ `reports/optimization-plan-0.1.0.md` → `reports/reevaluation-0.1.0.md` → `reports/multi-stage-evaluation.md`

## 相关文档

- 项目根 [README.md](../README.md) / [README.zh.md](../README.zh.md) — 安装、用法、FAQ
- 底层协议库 [lua-yar](https://github.com/fangfengxiang/lua-yar) — Yar RPC 协议的纯 Lua 实现

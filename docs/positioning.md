# lua-resty-yar 项目定位

> lua-resty-yar 是 lua-yar（纯 Lua Yar RPC 协议库）的 OpenResty OPM 适配层。

---

## 一、是什么

lua-resty-yar 将 lua-yar 纯协议库接入 OpenResty 运行时，提供：

- **cosocket 注入** — 出向 RPC 调用走 OpenResty 非阻塞 I/O（替代 luasocket 阻塞 I/O），配合连接池实现 keepalive
- **ngx.log 桥接** — lua-yar 日志重定向到 nginx error log，统一运维日志通道
- **进程级实例管理** — Server Facade 实例在 `init_by_lua` 创建、worker 内复用
- **OpenResty handler 入口** — `content_by_lua_block` 直接调用的 HTTP / TCP stream handler
- **配置桥接** — nginx 配置参数 → lua-yar 嵌套选项结构
- **C 扩展加速** — cjson / cmsgpack 自动注册（替代纯 Lua 编解码，可选）
- **lua-resty-http 注入** — 可选的 HTTP 传输 provider（替代默认 cosocket 手动 HTTP 实现）
- **可观测性支持** — 结构化 JSON 访问日志、request ID 贯穿、trace context 传播

## 二、不是什么

- **不是独立协议实现** — 协议逻辑（帧解析、header 校验、编解码、packager registry、hooks、Error 分类）全部委托 lua-yar
- **不是运行时框架** — 不管理连接生命周期（nginx 管理）、不调度协程（OpenResty 调度）、不提供进程管理
- **不是 PHP Yar / yar-c 的替代品** — 是 Yar 协议生态的 Lua/OpenResty 实现，与 PHP Yar / yar-c 互操作

## 三、生态关系

### 3.1 与 lua-yar 的关系

| 维度 | lua-yar | lua-resty-yar |
|------|---------|---------------|
| 定位 | 纯协议库 / SDK（运行时无关） | OpenResty OPM 适配层 |
| 运行时 | 任意（luasocket / cosocket / 其他） | OpenResty 专属 |
| I/O 模型 | luasocket（阻塞）/ cosocket（注入后非阻塞） | cosocket（OpenResty 原生） |
| 分发方式 | `Server:handle(spec)` / `listen()` + `loop()` | `content_by_lua_block` handler |
| 日志 | `Log.set_writer(fn)` 注入式 | `ngx.log` writer 注入 |
| 安装方式 | LuaRocks | OPM |
| 依赖 | 零外部依赖（纯 Lua） | 依赖 lua-yar + OpenResty |

### 3.2 与 yar-c / yar-php 的对标

| 实现 | 语言 | I/O 模型 | 定位 |
|------|------|---------|------|
| yar-php | PHP | PHP stream / curl | PHP 原生实现 |
| yar-c | C | libcurl（同步阻塞） | C 语言参考实现 |
| lua-yar | Lua | luasocket / cosocket（注入） | 纯协议库 / SDK |
| lua-resty-yar | Lua | cosocket（OpenResty 原生） | OpenResty 适配层 |

所有实现遵循同一 Yar RPC 协议，可互操作。

## 四、架构概览

```
┌─────────────────────────────────────────────────────────┐
│                    OpenResty (nginx + LuaJIT)            │
│  ┌─────────────────────────────────────────────────────┐ │
│  │              lua-resty-yar (适配层)                 │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │ │
│  │  │ init.lua │  │ client   │  │ server/          │  │ │
│  │  │ setup()  │  │ new/get  │  │ http/tcp/init    │  │ │
│  │  │ cosocket │  │ 薄封装   │  │ handler 入口     │  │ │
│  │  │ ngx.log  │  │          │  │                  │  │ │
│  │  │ 配置桥接 │  │          │  │                  │  │ │
│  │  └────┬─────┘  └────┬─────┘  └────────┬─────────┘  │ │
│  │       │             │                 │            │ │
│  │       └─────────────┴─────────────────┘            │ │
│  │                     │ 委托                          │ │
│  └─────────────────────┼───────────────────────────────┘ │
│                        ▼                                  │
│  ┌─────────────────────────────────────────────────────┐ │
│  │                 lua-yar (协议库)                    │ │
│  │  Server Facade / Dispatcher / Transport /          │ │
│  │  Protocol / Framing / Packager / Message /          │ │
│  │  Client / Error / Log                               │ │
│  └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

**适配层职责（薄而清晰）：**
1. cosocket 注入 — `Client.set_socket(ngx.socket)`
2. ngx.log writer 注入 — `Log.set_writer(fn)`
3. Server Facade 实例管理 — `init_by_lua` 创建，worker 内复用
4. handler 入口 — `content_by_lua_block` → `server:handle(spec)`
5. 配置桥接 — 扁平配置 → lua-yar 嵌套选项结构
6. C 扩展注册 — cjson / cmsgpack（可选加速）

**协议库职责（lua-yar，不重造）：**
1. YAR 协议解析与渲染（Protocol.parse / Protocol.render）
2. 帧处理（Framing.receive_exact / receive_message）
3. JSON / Msgpack 编解码（纯 Lua 实现，cjson/cmsgpack 可替换）
4. Server Facade 分发（handle(spec) → TcpTransport / HttpTransport）
5. 结构化 Error 对象（5 错误码 + .code 字段）
6. hooks 机制（on_request / on_response + pcall 保护）

## 五、设计原则

1. **适配而非重造** — 协议逻辑全部委托 lua-yar，适配层只做运行时桥接。不重复实现协议解析、编解码、帧处理。

2. **OpenResty 原生优先** — 优先使用 OpenResty 原生能力（cosocket、ngx.log、ngx.req、lua_package_path），而非引入第三方依赖。C 扩展加速为可选增强，非硬依赖。

3. **进程级复用，请求级无状态** — Server Facade 实例 worker 内复用；handler 函数无模块级可变状态，每请求/连接独立协程，天然并发安全。

## 六、阅读指南

- [README.md](../README.md) — 快速上手与 API 参考（英文）
- [API 参考](api.md) — 完整方法签名与选项
- [docs/design/decisions.md](design/decisions.md) — ADR 设计文档索引
- [docs/design/adaptation-layer.md](design/adaptation-layer.md) — 适配层定位与分层设计
- [docs/design/handler-delegation.md](design/handler-delegation.md) — HTTP/TCP handler 委托策略
- [docs/design/observability-integration.md](design/observability-integration.md) — 可观测性集成设计
- [docs/design/configuration-bridge.md](design/configuration-bridge.md) — 配置桥接与参数映射
- [docs/reports/restructuring-review.md](reports/restructuring-review.md) — Facade API 迁移改造回顾

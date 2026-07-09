# 架构概览

lua-resty-yar 是 OpenResty 轻量 Yar RPC 框架，委托 lua-yar 协议库，在其上构建 OpenResty 集成与基础设施。

## 三层架构

```
┌─────────────────────────────────────────────────────────────┐
│                      用户业务层                               │
│    nginx.conf → init_by_lua → setup() → content_by_lua       │
└──────────────────────────┬──────────────────────────────────┘
                           │ require("resty.yar")
┌──────────────────────────▼──────────────────────────────────┐
│                lua-resty-yar（轻量 RPC 框架）                  │
│                                                              │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────┐│
│  │  init.lua  │  │config.lua │  │registry   │  │  hooks    ││
│  │  setup()   │  │ Schema    │  │  .lua     │  │  .lua     ││
│  │  工厂函数   │  │ 校验+合并  │  │ 插件注册   │  │ 生命周期   ││
│  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘│
│        │              │              │              │       │
│  ┌─────▼──────────────▼──────────────▼──────────────▼─────┐ │
│  │                observability.lua                        │ │
│  │    access_logger  |  trace_middleware  |  metrics       │ │
│  └─────────────────────────────────────────────────────────┘ │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │  server/http    │  │  server/tcp     │                   │
│  │  HTTP handler   │  │  TCP handler    │                   │
│  └────────┬────────┘  └────────┬────────┘                   │
└───────────┼────────────────────┼───────────────────────────┘
            │                    │
            │ cosocket 注入       │
            │ Client.set_socket(ngx.socket)
            │                    │
┌───────────▼────────────────────▼───────────────────────────┐
│                    lua-yar（协议库）                         │
│                                                            │
│  Protocol     │  Packager    │  Transport   │  Error       │
│  帧解析/header │ JSON/Msgpack │  socket 抽象  │  5类错误码   │
│  handle_msg   │  encode/decode│  serve       │  hooks       │
└────────────────────────────────────────────────────────────┘
```

## cosocket 注入路径

```
nginx worker 启动
  │
  ▼
init_by_lua_block
  │  require("resty.yar").setup({
  │      server = { service = MyApp, packager = "json" },
  │      client = { packager = "json", keepalive = { ... } },
  │      observability = { ... },
  │  })
  │
  │  setup() 内部：
  │  1. config.lua → deep_merge(DEFAULTS, opts) → validate()
  │  2. Yar.client.set_socket(ngx.socket)       ← cosocket 注入
  │  3. Yar.log.set_writer(ngx_log_writer)       ← ngx.log 注入
  │  4. Server.new(service, server_opts)         ← 协议库实例化
  │  5. registry.register(...) / hooks.adapt(...) ← 插件/钩子
  │  6. observability.defaults() / use_cjson()   ← 可选增强
  ▼
worker 就绪，content_by_lua_block 可调用 get_server():handle(spec)
```

## hooks 调用链路

```
RPC 请求到达
  │
  ▼
on_request ──→ Protocol.handle_message ──→ on_response
  │                  │                         │
  │           用户 RPC 方法 pcall             │
  │                  │                    成功路径│
  │                  ├──→ 正常返回 ──────────→│
  │                  ├──→ error()   ──→ on_error
  │                  └──→ 超时       ──→ on_timeout
  │
  ▼
响应编码 + 发送
```

`hooks.lua` 从 `on_response` 自动派生 `on_error`/`on_timeout`，框架层管理 `on_connect`/`on_init_worker`。

## observability 数据流

```
                      ┌───────────────────────────┐
                      │     RPC 请求生命周期        │
                      └─────────────┬─────────────┘
                                    │
           ┌────────────────────────┼────────────────────────┐
           ▼                        ▼                        ▼
 ┌──────────────────┐  ┌─────────────────────┐  ┌──────────────────┐
 │  access_logger    │  │  trace_middleware    │  │ metrics_recorder  │
 │                   │  │                     │  │                  │
 │ 结构化 JSON 日志   │  │ X-Request-ID 生成   │  │ counter+histogram │
 │ defer 模式         │  │ header 注入+传播    │  │ buffer 模式       │
 └────────┬──────────┘  └─────────┬───────────┘  └────────┬─────────┘
          │                       │                       │
          ▼                       ▼                       ▼
    ngx.log(error log)     X-Request-ID header     ngx.shared.dict
    或自定义 writer         跨服务传播到下游          → Prometheus
                                                    endpoint
```

## 配置层次

```
用户传入 opts
  │
  ▼
config.lua
  │  DEFAULTS（嵌套分域）
  │  ├── server: { service, packager, max_body_len, timeout, keepalive, hooks, ... }
  │  ├── client: { packager, timeout, keepalive, hooks, ... }
  │  ├── observability: { access_log, trace, metrics, metrics_buffer, ... }
  │  └── extensions: { use_cjson, use_cmsgpack, use_resty_http, ... }
  │
  │  deep_merge(DEFAULTS, opts)  →  validate(merged, TYPE_SPEC)
  │
  ├──→ server 配置 → Server.new(service, server_opts)
  ├──→ client 配置 → client:set_options(client_opts)
  ├──→ observability 配置 → hooks.adapt() + registry.register()
  └──→ extensions 配置 → use_cjson() / use_cmsgpack() / use_resty_http()
```

## 与 lua-resty-php-beacon 的关系

```
lua-yar              纯协议库/SDK（对标 dkjson/MessagePack）
  │
  ▼
lua-resty-yar        轻量 RPC 框架（对标 lor/gRPC-go，开发者代码集成）
  │                    ↑ 可基于 lua-resty-yar 构建
  ▼
lua-resty-php-beacon  PHP 微服务平台（对标 Kong/APISIX，运维+开发者，服务治理/网关）
```

lua-resty-yar 管单个 RPC 调用生命周期（协议编解码、连接管理、钩子、可观测性、配置管理）。
lua-resty-php-beacon 管服务治理层面（服务注册/发现/LB/故障转移、健康保活、声明式配置、协议转化）。

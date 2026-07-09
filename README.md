# lua-resty-yar

[English](README.md) | [简体中文](README.zh.md)

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![OPM](https://img.shields.io/badge/OPM-lua--resty--yar-blue.svg)](https://opm.openresty.org/package/fangfengxiang/lua-resty-yar/)
[![Test](https://github.com/fangfengxiang/lua-resty-yar/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/fangfengxiang/lua-resty-yar/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/fangfengxiang/lua-resty-yar/graph/badge.svg?branch=main)](https://codecov.io/gh/fangfengxiang/lua-resty-yar)
[![Release](https://img.shields.io/github/v/release/fangfengxiang/lua-resty-yar)](https://github.com/fangfengxiang/lua-resty-yar/releases)

> **Yar RPC framework for OpenResty.**
> Built on [lua-yar](https://github.com/fangfengxiang/lua-yar) — provides cosocket I/O, structured config, plugin registry, lifecycle hooks, and observability for running Yar services at scale. See [Project Positioning](docs/positioning.md), [Architecture](docs/architecture.md), and [Performance Guide](docs/performance-guide.md).

[Yar](https://github.com/laruence/yar) (Yet Another RPC Framework) is a lightweight concurrent RPC framework from the PHP ecosystem. This project is the **OpenResty development framework** for Yar — not the protocol library itself. The pure-Lua protocol implementation lives in [lua-yar](https://github.com/fangfengxiang/lua-yar); lua-resty-yar wraps it with everything OpenResty needs to run Yar in production: non-blocking cosocket I/O, connection pooling, a nested config schema, a priority-ordered plugin registry, lifecycle hook adaptation, and a built-in observability suite (access logging, request tracing, Prometheus metrics).

Compared to HTTP+JSON microservices, Yar's binary protocol stream removes text codec overhead; compared to gRPC/Thrift, it needs no IDL or heavy runtime — a pragmatic middle ground for lightweight RPC.

---


## Features

- **Unified server facade** — one Server instance serves both HTTP and TCP, created in init_by_lua and shared across all worker coroutines
- **Cosocket client** — non-blocking I/O with connection pooling, keepalive, and optional persistent TCP
- **Nested config schema** — four-domain config (server / client / observability / extensions) with flat-format backward compatibility
- **Plugin registry** — `register(name, factory, opts)` with priority-based ordering and named error logs
- **Lifecycle hooks** — `on_error` / `on_timeout` derived from `on_response`, plus `on_connect` / `on_init_worker` framework hooks
- **Observability suite** — structured JSON access logging, cross-service request ID tracing, Prometheus RPC metrics
- **Metrics buffer mode** — worker-local buffer + `ngx.timer.every` flush, eliminates shared-dict lock contention in high-throughput scenarios
- **yar-c parameter mapping** — `READ_TIMEOUT` → three-stage cosocket timeouts, `CHILD_INIT` → `on_worker_init` hook
- **Optional C acceleration** — cjson / cmsgpack auto-replace pure-Lua codecs; lua-resty-http transport provider injection
- **Structured error objects** — 5 codes (TRANSPORT / TIMEOUT / PROTOCOL / NOT_FOUND / EXCEPTION), match via `err.code`

## Requirements

- **OpenResty** >= 1.19.3.1 (cosocket, `ngx.timer`, shared dict)
- **[lua-yar](https://github.com/fangfengxiang/lua-yar)** >= 0.1.0 (auto-installed via OPM)
- **Perl** (for [test-nginx](https://github.com/openresty/test-nginx) test suite)

## Installation

### OPM (Recommended)

```bash
opm get fangfengxiang/lua-resty-yar
```

[lua-yar](https://github.com/fangfengxiang/lua-yar) is declared in `dist.ini` and installed automatically.

### Source

Add `lib/` to `lua_package_path` (and point at a local lua-yar checkout during development):

```nginx
lua_package_path "/path/to/lua-resty-yar/lib/?.lua;/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";
```

## Quick Start

### HTTP Server

```nginx
http {
    lua_package_path "/path/to/lua-resty-yar/lib/?.lua;/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";

    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
                sub = function(a, b) return a - b end,
            },
        }
    }

    server {
        listen 8888;
        location /api {
            content_by_lua_block { require("resty.yar.server").serve() }
        }
    }
}
```

### TCP Stream Server

```nginx
stream {
    lua_package_path "/path/to/lua-resty-yar/lib/?.lua;/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";

    init_by_lua_block {
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end },
        }
    }

    server {
        listen 9999;
        content_by_lua_block { require("resty.yar.server").serve() }
    }
}
```

> `server.serve()` auto-detects the HTTP/stream context (a tiny pcall overhead). For the production hot path, call `require("resty.yar.server.http").serve()` or `require("resty.yar.server.tcp").serve()` directly.

### Client

```nginx
location /t {
    content_by_lua_block {
        local yar = require("resty.yar")
        local client = yar.new_client("http://127.0.0.1:8888/api")
        local result = client:call("add", { 1, 2 })   -- => 3
    }
}
```

Persistent TCP client — same `uri` returns the same instance within a worker, enabling socket reuse across calls:

```nginx
local client = require("resty.yar").get_client("tcp://127.0.0.1:9999")
local r1 = client:call("add", { 1, 2 })   -- persistent, socket reused
local r2 = client:call("add", { 3, 4 })   -- same connection
```

### Error Handling

```lua
local ret, err = client:call("add", { 1, 2 })
if not ret then
    -- err is a structured Error object; match via .code
    if err.code == require("resty.yar").Error.TIMEOUT then
        -- handle timeout
    end
end
```

> More examples: the `t/` directory contains complete test-nginx suites (`http.t`, `tcp.t`, `client.t`, `observability.t`, ...).

## Configuration

`require("resty.yar").setup(opts)` is called once in `init_by_lua_block`. It merges config, injects the cosocket, and creates the unified Server Facade instance.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `service` | table | — | RPC service object (function fields = RPC methods) |
| `packager` | string | "JSON" | Response encoding: "JSON" or "Msgpack" |
| `connect_timeout` | number | 1000 | Connect timeout (ms) |
| `send_timeout` | number | 5000 | Send timeout (ms) |
| `read_timeout` | number | 5000 | Read timeout (ms) |
| `keepalive_idle` | number | 60000 | Pool idle timeout (ms) |
| `pool_size` | number | 30 | Cosocket pool size |
| `max_body_len` | number | 10485760 | Max request body (bytes) |
| `on_worker_init` | function | nil | Worker init callback (maps yar-c CHILD_INIT) |
| `hooks` | table | nil | `{on_request=fn, on_response=fn}` interception |
| `use_cjson` | boolean | false | Register cjson C extension for JSON encoding |
| `use_cmsgpack` | boolean | false | Register cmsgpack C extension for Msgpack encoding |
| `use_resty_http` | boolean | false | Inject lua-resty-http as HTTP transport provider |
| `log_level` | number | INFO | Log level (1=DEBUG ~ 4=ERROR) |

→ Full option list (client-level params, DNS, proxy, depth limits): [API Reference](docs/api.md)

## Observability

The observability module provides structured access logging, cross-service request ID tracing, and RPC metrics via hooks injection — no protocol-layer changes, zero overhead when unused.

### Access Logging

```lua
local obs = require("resty.yar.observability")

require("resty.yar").setup {
    service = { add = function(a, b) return a + b end },
    hooks = obs.access_logger({ writer = function(level, msg) ngx.log(level, msg) end }),
}
```

Outputs structured JSON with `ts`, `level`, `module`, `method`, `status`, `duration_ms`, `request_id`. Use `defer = true` + `obs.flush_logs()` in `log_by_lua_block` to move log I/O out of the response hot path.

### Request ID Tracing

```lua
require("resty.yar").setup {
    service = { add = function(a, b) return a + b end },
    hooks = obs.trace_middleware(),
}
```

Generates a per-request ID in `ngx.ctx.request_id` and propagates it to outgoing RPC calls via the `X-Request-Id` header. Read it in business code with `obs.get_request_id()`.

### RPC Metrics

```nginx
http {
    lua_shared_dict yar_metrics 1m;

    init_by_lua_block {
        local obs = require("resty.yar.observability")
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end },
            hooks = obs.metrics_recorder({ dict_name = "yar_metrics" }),
        }
    }
}
```

Exports in standard Prometheus exposition format (`# HELP` / `# TYPE`, sorted counters, latency histogram buckets 1/5/10/50/100/500/1000/5000ms + +Inf).

### One-Click Observability

```lua
local obs = require("resty.yar.observability")

require("resty.yar").setup {
    service = { add = function(a, b) return a + b end },
    hooks = obs.defaults(),  -- trace + access-log + metrics, one line
}
```

`defaults()` returns a priority-ordered composition. Pass per-hook opts: `obs.defaults({ metrics = { buffer_enabled = true } })`.

> High-throughput: enable `buffer_enabled = true` on the metrics recorder for a worker-local buffer flushed by `ngx.timer.every`, removing `dict:incr` lock contention. Same crash-loss semantics as nginx `access_log buffer`. See [Extensibility](docs/extensibility.md).

## Plugin Registry

Register plugins with priority-based ordering instead of manual `compose()`:

```lua
local yar = require("resty.yar")
local obs = require("resty.yar.observability")

yar.register("trace", function() return obs.trace_middleware() end, { priority = 50 })
yar.register("access-log", function() return obs.access_logger() end, { priority = 100 })
yar.register("metrics", function() return obs.metrics_recorder() end, { priority = 200 })

yar.setup {
    service = { add = function(a, b) return a + b end },
    -- hooks auto-collected from registry, no manual compose needed
}
```

- **Priority** — ascending order (lower executes first); same priority sorted by name
- **Named compose** — error logs show the plugin name (e.g., `on_response hook 'metrics' error: ...`)
- **Backward compatible** — inline `hooks = { on_request = fn }` still works (anonymous plugin, priority=50)

## Lifecycle Hooks

Framework-layer hooks beyond lua-yar's `on_request` / `on_response`:

| Hook | Derived From | When |
|------|---------------|------|
| `on_error(method, err_obj)` | `on_response` | `err_obj` is not nil |
| `on_timeout(method)` | `on_error` | `err_obj.code == TIMEOUT` |
| `on_connect(uri)` | Framework | After `new_client()` creates client |
| `on_init_worker()` | Framework | In `init_worker()`, after `on_worker_init` |

`on_error` / `on_timeout` are derived from `on_response` by the framework's `hooks.adapt()` — no protocol-layer changes.

## yar-c Parameter Mapping

| yar-c Parameter | OpenResty Equivalent | How |
|----------------|----------------------|-----|
| `READ_TIMEOUT` | `setup({connect_timeout, send_timeout, read_timeout})` | Three-stage cosocket timeouts via `sock:settimeouts()` |
| `CHILD_INIT` | `setup({on_worker_init = fn})` + `init_worker()` | Called in `init_worker_by_lua_block` |
| `PARENT_INIT` | `setup()` itself | Called in `init_by_lua_block` |
| `CUSTOM_DATA` | `service` object closure | Pass via `setup({service = {...}})` |
| `MAX_CHILDREN` | `worker_processes` | nginx.conf directive |
| `PID_FILE` | `pid` | nginx.conf directive |
| `LOG_FILE` / `LOG_LEVEL` | `error_log` | nginx.conf directive |
| `CHILD_USER` / `CHILD_GROUP` | `user` | nginx.conf directive |

## Architecture

```
+---------------------------------------------------------+
|              OpenResty (nginx + LuaJIT)                 |
|                                                         |
|  +---------------------------------------------------+ |
|  |        lua-resty-yar (framework layer)            | |
|  |                                                   | |
|  |  init.lua    client     server/    config          | |
|  |  setup()     new/get    http/tcp   schema          | |
|  |                                                   | |
|  |  registry    hooks      observability             | |
|  |  (plugins)   (adapt)    (metrics/trace/log)        | |
|  +-------------------+-------------------------------+ |
|                      | delegates                       |
|  +-------------------v-------------------------------+ |
|  |          lua-yar (protocol library)              | |
|  |  Server / Dispatcher / Transport /               | |
|  |  Protocol / Framing / Packager / Client          | |
|  +---------------------------------------------------+ |
+---------------------------------------------------------+
```

The framework layer delegates all protocol logic (frame parsing, header validation, encoding/decoding, packager registry, hooks, Error classification) to lua-yar. Beyond protocol bridging, it provides framework-level capabilities: structured config schema (`config`), plugin registry with priority-based ordering (`registry`), lifecycle hook adaptation (`hooks`), and observability instrumentation (`observability`).

## Testing

| Type | Command | Description |
|------|---------|-------------|
| Test suite | `make test` | Full test-nginx suite (14 files: http, tcp, client, observability, ...) |
| Linter | `make lint` | luacheck static analysis |
| Format | `make stylua-check` | stylua format check |
| Coverage | `make coverage` | luacov coverage report (requires `luarocks install luacov`) |
| Build | `opm build` | OPM package build |

## Module Overview

| Module | Description |
|--------|-------------|
| **init.lua** | Entry: `setup()`, `get_server()`, `get_config()`, `init_worker()`, `new_server()`, `new_client()`, `get_client()`, `register()` |
| **client.lua** | Client wrapper: `new(uri, opts)`, `get(uri, opts)` |
| **server/** | Handler entry: `serve()` in `init.lua` (auto-detect), `http.lua` / `tcp.lua` (direct) |
| **config.lua** | Nested config schema + flat backward compat + deprecation warnings |
| **registry.lua** | Plugin registry: `register(name, factory, opts)`, priority ordering |
| **hooks.lua** | Lifecycle hook adaptation: `on_error` / `on_timeout` / `on_connect` / `on_init_worker` |
| **observability.lua** | `access_logger` / `trace_middleware` / `metrics_recorder` / `compose` / `defaults` |

## Directory Structure

```
lua-resty-yar/
├── README.md / README.zh.md
├── LICENSE
├── Makefile
├── dist.ini                     # OPM packaging config
├── docs/
│   ├── api.md                   # API reference
│   ├── quick-start.md
│   ├── positioning.md          # What lua-resty-yar is and isn't
│   ├── design-philosophy.md
│   ├── extensibility.md
│   ├── design/                  # Architecture decision records (ADR)
│   └── reports/                 # Engineering assessments
├── lib/resty/yar/
│   ├── init.lua                 # Main entry
│   ├── client.lua
│   ├── config.lua
│   ├── hooks.lua
│   ├── observability.lua
│   ├── registry.lua
│   └── server/
│       ├── init.lua             # serve() auto-detect
│       ├── http.lua
│       └── tcp.lua
└── t/                           # test-nginx suites
```

## Documentation

- [API Reference](docs/api.md) — Full method signatures and options
- [Quick Start](docs/quick-start.md) — Step-by-step guide
- [Project Positioning](docs/positioning.md) — What lua-resty-yar is and isn't
- [Design Philosophy](docs/design-philosophy.md) — Framework design principles
- [Extensibility](docs/extensibility.md) — Plugins, hooks, observability
- [Design Decisions](docs/design/decisions.md) — Architecture decision records (ADR)
- [Engineering Reports](docs/reports/) — Evaluation, dependency audit, optimization plans

## License

[Apache License 2.0](LICENSE)

# lua-resty-yar

[English](README.md) | [简体中文](README.zh.md)

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![OPM](https://img.shields.io/badge/OPM-lua--resty--yar-blue.svg)](https://opm.openresty.org/package/fangfengxiang/lua-resty-yar/)
[![Test](https://github.com/fangfengxiang/lua-resty-yar/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/fangfengxiang/lua-resty-yar/actions/workflows/test.yml)
[![Release](https://img.shields.io/github/v/release/fangfengxiang/lua-resty-yar)](https://github.com/fangfengxiang/lua-resty-yar/releases)

High-performance Yar RPC server for OpenResty, built on [lua-yar](https://github.com/fangfengxiang/lua-yar).

## Features

- **Unified Server Facade** — single `Server` instance handles both HTTP and TCP, created in `init_by_lua`, shared across all coroutines in a worker
- **HTTP server handler** — `content_by_lua` entry, one coroutine per request, protocol dispatch via `serve_callback` delegation
- **TCP stream server handler** — stream `content_by_lua` entry, one coroutine per connection, keepalive loop via `handle({socket})` delegation
- **Cosocket injection** — outbound RPC calls use OpenResty non-blocking I/O with connection pooling and keepalive
- **yar-c parameter mapping** — `READ_TIMEOUT` → three-stage cosocket timeouts, `CHILD_INIT` → `on_worker_init` hook
- **Optional C extension acceleration** — cjson / cmsgpack auto-registration replaces pure-Lua codecs
- **lua-resty-http provider** — optional HTTP transport provider injection (replaces default cosocket HTTP implementation)
- **Structured error objects** — 5 error codes (TRANSPORT / TIMEOUT / PROTOCOL / NOT_FOUND / EXCEPTION), match via `err.code`
- **Hooks mechanism** — request/response interception (pcall-protected, zero overhead when unused)
- **Observability suite** — structured JSON access logging, cross-service request ID tracing, RPC metrics with Prometheus export

## Installation

```bash
opm get fangfengxiang/lua-resty-yar
```

The dependency [lua-yar](https://github.com/fangfengxiang/lua-yar) is declared in `dist.ini` and installed automatically by OPM.

## Quick Start

### HTTP Server

```nginx
http {
    lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";

    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
                sub = function(a, b) return a - b end,
            }
        }
    }

    server {
        listen 8888;
        location /api {
            content_by_lua_block {
                require("resty.yar.server").serve()
            }
        }
    }
}
```

### TCP Stream Server

```nginx
stream {
    lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";

    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
            }
        }
    }

    server {
        listen 9999;
        content_by_lua_block {
            require("resty.yar.server").serve()
        }
    }
}
```

> **More examples:** The `t/` directory contains complete test-nginx test suites (`http.t`, `tcp.t`, `client.t`, `observability.t`) covering HTTP server, TCP stream server, client usage, and observability patterns.

## API

### `require("resty.yar").setup(opts)`

Call once in `init_by_lua_block`. Merges config, injects cosocket, creates the unified Server Facade instance.

**Parameters:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `service` | table | `{add, sub, greet}` | RPC service object (function fields = RPC methods) |
| `packager` | string | `"JSON"` | Response encoding: `"JSON"` or `"Msgpack"` |
| `connect_timeout` | number | `1000` | Connection timeout (ms) |
| `send_timeout` | number | `5000` | Send timeout (ms) |
| `read_timeout` | number | `5000` | Read timeout (ms) |
| `keepalive_idle` | number | `60000` | TCP keepalive idle timeout (ms) |
| `timeout` | number | `5000` | Per-message timeout for standalone `run()` mode (ms) |
| `client_timeout` | number | `3000` | Outbound RPC default timeout (ms) |
| `pool_size` | number | `30` | Cosocket connection pool size |
| `max_body_len` | number | `10485760` | Maximum request body length (bytes, 10MB) |
| `ssl_verify` | boolean | `true` | HTTPS certificate verification |
| `resolve` | string | `""` | Custom DNS resolution (host:ip format) |
| `proxy` | string | `""` | HTTP proxy address |
| `on_worker_init` | function | `nil` | Worker init callback (CHILD_INIT mapping) |
| `log_level` | number | `INFO` | Log level (1=DEBUG ~ 4=ERROR) |
| `hooks` | table | `nil` | `{on_request=fn, on_response=fn}` interception |
| `use_cjson` | boolean | `false` | Register cjson C extension for JSON encoding |
| `use_cmsgpack` | boolean | `false` | Register cmsgpack C extension for Msgpack encoding |
| `use_resty_http` | boolean | `false` | Inject lua-resty-http as HTTP transport provider |
| `json_max_depth` | number | `512` | JSON max nesting depth (built-in codec) |
| `msgpack_max_depth` | number | `512` | Msgpack max nesting depth (built-in codec) |

### Server API

```lua
local yar = require("resty.yar")

-- Process-level Server Facade instance (created by setup())
local server = yar.get_server()

-- Worker initialization hook (call in init_worker_by_lua_block)
yar.init_worker()

-- Merged config table (handlers read connection-level params from here)
local config = yar.get_config()

-- Create a custom Server instance with options
local custom = yar.new_server(my_service, { packager = "Msgpack", hooks = my_hooks })
```

**Handler entry points** (call in `content_by_lua_block`):

```lua
-- Auto-detect HTTP/stream context (convenience entry, tiny pcall overhead)
require("resty.yar.server").serve()

-- Direct calls (production hot path, no detection overhead)
require("resty.yar.server.http").serve()  -- HTTP context
require("resty.yar.server.tcp").serve()   -- stream context
```

### Client API

#### `yar.new_client(uri, opts)`

Creates a new `Yar.Client` instance with connection-level params pre-injected from `setup()` config.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `uri` | string | — | Service URL: `http://host/api` or `tcp://host:port` |
| `opts.timeout` | number | `client_timeout` | Per-call timeout (ms) |
| `opts.packager` | string | `"JSON"` | Request encoding |
| `opts.connect_timeout` | number | `connect_timeout` | Connection timeout (ms) |
| `opts.keepalive_idle` | number | `keepalive_idle` | Pool idle timeout (ms) |
| `opts.pool_size` | number | `pool_size` | Connection pool size |
| `opts.ssl_verify` | boolean | `true` | HTTPS certificate verification |
| `opts.headers` | table | `nil` | Custom HTTP headers (merged with trace headers from `ngx.ctx`) |
| `opts.resolve` | string | `""` | Custom DNS (host:ip) |
| `opts.proxy` | string | `""` | HTTP proxy address |
| `opts.persistent` | boolean | `false` | Persistent TCP connection (socket reuse across calls) |
| `opts.hooks` | table | `nil` | `{on_request=fn, on_response=fn}` |

```nginx
location /t {
    content_by_lua_block {
        local yar = require("resty.yar")
        local client = yar.new_client("http://127.0.0.1:8888/api")
        local result = client:call("add", { 1, 2 })  -- returns 3
    }
}
```

#### `yar.get_client(uri, opts)`

Returns a memoized persistent Client instance by `uri`. Same `uri` returns the same instance within a worker, enabling socket reuse across calls.

```nginx
location /t {
    content_by_lua_block {
        local yar = require("resty.yar")
        local client = yar.get_client("tcp://127.0.0.1:9999")
        local r1 = client:call("add", { 1, 2 })     -- persistent, socket reused
        local r2 = client:call("add", { 3, 4 })     -- same connection
    }
}
```

#### Error handling

```lua
local ret, err = client:call("add", { 1, 2 })
if not ret then
    -- err is a structured Error object, match via .code
    if err.code == require("resty.yar").Error.TIMEOUT then
        -- handle timeout
    end
end
```

### `require("resty.yar.client")` module

Thin wrapper providing `new(uri, opts)` and `get(uri, opts)`:

```lua
local client = require("resty.yar.client").new("http://host/api")
local pclient = require("resty.yar.client").get("tcp://host:9999")
```

## Observability

The observability module provides structured access logging, cross-service request ID tracing, and RPC metrics via hooks injection — no protocol-layer changes, zero overhead when unused.

### Access logging

```lua
local obs = require("resty.yar.observability")

require("resty.yar").setup {
    service = { add = function(a, b) return a + b end },
    hooks = obs.access_logger({
        writer = function(level, msg) ngx.log(level, msg) end,
    }),
}
```

Outputs structured JSON logs with fields: `ts`, `level`, `module`, `method`, `params_size`, `status`, `duration_ms`, `request_id`, `retval_size`/`error`.

**Deferred mode** — move log I/O out of the response hot path:

```nginx
init_by_lua_block {
    require("resty.yar").setup {
        service = { ... },
        hooks = obs.access_logger({ defer = true }),
    }
}
log_by_lua_block {
    require("resty.yar.observability").flush_logs()
}
```

### Request ID tracing

```lua
require("resty.yar").setup {
    service = { ... },
    hooks = obs.trace_middleware(),
}
```

Generates a per-request ID in `ngx.ctx.request_id` and propagates it to outgoing RPC calls via the `X-Request-Id` HTTP header. Access the current request ID in business code:

```lua
local request_id = require("resty.yar.observability").get_request_id()
```

### RPC metrics

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

    # Prometheus scrape endpoint
    server {
        location /metrics {
            content_by_lua_block {
                -- Access the recorder's export function via your own module
                -- or store a reference during setup()
                ngx.print(your_metrics_export_fn())
            }
        }
    }
}
```

Exports in standard Prometheus exposition format with `# HELP` / `# TYPE` metadata, sorted counters, and latency histogram buckets (`1/5/10/50/100/500/1000/5000ms` + `+Inf`).

### Composing hooks

```lua
local obs = require("resty.yar.observability")

require("resty.yar").setup {
    service = { add = function(a, b) return a + b end },
    hooks = obs.compose(
        obs.trace_middleware(),
        obs.access_logger(),
        obs.metrics_recorder({ dict_name = "yar_metrics" })
    ),
}
```

Each hook is pcall-isolated; a failure in one hook does not affect others.

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
|              OpenResty (nginx + LuaJIT)                  |
|  +-----------------------------------------------------+|
|  |           lua-resty-yar (adaptation layer)           ||
|  |  +----------+  +----------+  +------------------+   ||
|  |  | init.lua |  | client   |  | server/          |   ||
|  |  | setup()  |  | new/get  |  | http/tcp/init    |   ||
|  |  | cosocket |  | wrapper  |  | handler entry    |   ||
|  |  | ngx.log  |  |          |  |                  |   ||
|  |  +----+-----+  +----+-----+  +--------+--------+   ||
|  |       |             |               |              ||
|  |       +-------------+---------------+             ||
|  |                     | delegates                    ||
|  +---------------------+------------------------------+|
|                        v                              |
|  +-----------------------------------------------------+|
|  |              lua-yar (protocol library)             ||
|  |  Server Facade / Dispatcher / Transport /           ||
|  |  Protocol / Framing / Packager / Message /          ||
|  |  Client / Error / Log                               ||
|  +-----------------------------------------------------+|
+---------------------------------------------------------+
```

The adaptation layer is thin and clear: cosocket injection, `ngx.log` writer, handler entry points, config bridging. All protocol logic (frame parsing, header validation, encoding/decoding, packager registry, hooks, Error classification) is delegated to lua-yar.

## Documentation

- [API Reference](docs/api.md) — Full method signatures and options
- [Project Positioning](docs/positioning.md) — What lua-resty-yar is and isn't
- [Design Decisions (ADR)](docs/design/decisions.md) — Architecture decision records
- [Evaluation Reports](docs/reports/) — Engineering assessments, dependency audits, optimization plans

## Development

### Prerequisites

- OpenResty >= 1.19.3.1
- lua-yar (auto-installed via OPM)
- Perl (for test-nginx)
- luacheck (for linting)

### Run Tests

```bash
make test
```

### Run Linter

```bash
make lint
```

### OPM Build

```bash
opm build
```

## License

[Apache License 2.0](LICENSE)

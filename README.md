# lua-resty-yar

High-performance Yar RPC server for OpenResty, built on [lua-yar](https://github.com/fangfengxiang/lua-yar).

## Features

- **HTTP server handler** — `content_by_lua` entry, one coroutine per request, pure protocol dispatch via `handle_message`
- **TCP stream server handler** — stream `content_by_lua` entry, one coroutine per connection, keepalive loop via `handle_connection`
- **Cosocket injection** — outbound RPC calls use OpenResty non-blocking I/O with connection pooling
- **yar-c parameter mapping** — `READ_TIMEOUT` → three-stage cosocket timeouts, `CHILD_INIT` → `on_worker_init` hook
- **Process-level instance reuse** — Server/TcpServer instances created in `init_by_lua`, shared by all coroutines in worker

## Installation

### Step 1: Install lua-yar (LuaRocks)

```bash
luarocks install lua-yar
```

### Step 2: Install lua-resty-yar (OPM)

```bash
opm get fangfengxiang/lua-resty-yar
```

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

> **More examples:** The `t/` directory contains complete, runnable test-nginx test suites (`http.t`, `tcp.t`, `client.t`) that cover HTTP server, TCP stream server, and client usage patterns. These serve as additional working references.

## API

### `require("resty.yar").setup(opts)`

Call once in `init_by_lua_block`. Merges config, injects cosocket, creates Server/TcpServer instances.

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
| `on_worker_init` | function | `nil` | Worker init callback (CHILD_INIT mapping) |

### `require("resty.yar").get_http_server()`

Returns the process-level Server instance (HTTP scenario). Error if `setup()` not called.

### `require("resty.yar").get_tcp_server()`

Returns the process-level TcpServer instance (TCP stream scenario). Error if `setup()` not called.

### `require("resty.yar").get_config()`

Returns the merged config table. Handlers use this to read connection-level parameters.

### `require("resty.yar").init_worker()`

Call in `init_worker_by_lua_block`. Executes the `on_worker_init` callback if provided.

### `require("resty.yar.server").serve()`

Unified entry point for `content_by_lua_block`. Auto-detects HTTP/stream context and dispatches to the appropriate handler.

You can also call handlers directly:
- `require("resty.yar.server.http").serve()`
- `require("resty.yar.server.tcp").serve()`

## Client API

### `require("resty.yar").new_client(uri, opts)`

Creates a `Yar.Client` instance with connection-level params pre-injected from `setup()` config. Each call creates a new instance.

**Parameters:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `uri` | string | — | Service URL: `http://host/api` or `tcp://host:port` |
| `opts.timeout` | number | `client_timeout` | Per-call timeout (ms) |
| `opts.packager` | string | `"JSON"` | Request encoding |
| `opts.connect_timeout` | number | `connect_timeout` | Connection timeout (ms) |
| `opts.keepalive_idle` | number | `keepalive_idle` | Pool idle timeout (ms) |
| `opts.pool_size` | number | `pool_size` | Connection pool size |

**Usage:**

```nginx
location /t {
    content_by_lua_block {
        local yar = require("resty.yar")
        local client = yar.new_client("http://127.0.0.1:8888/api")
        local result = client:call("add", { 1, 2 })  -- returns 3
    }
}
```

### `require("resty.yar").get_client(uri, opts)`

Returns a memoized persistent Client instance by `uri`. Same `uri` returns the same instance within a worker. Enables socket reuse across calls (persistent mode).

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

### `require("resty.yar.client")`

Thin wrapper module providing `new(uri, opts)` and `get(uri, opts)` functions, delegating to `init.new_client` / `init.get_client`.

```lua
local client = require("resty.yar.client").new("http://host/api")
local pclient = require("resty.yar.client").get("tcp://host:9999")
```

## yar-c Parameter Mapping

| yar-c Parameter | OpenResty Equivalent | How |
|-----------------|----------------------|-----|
| `READ_TIMEOUT` | `setup({connect_timeout, send_timeout, read_timeout})` | Three-stage cosocket timeouts via `sock:settimeouts()` |
| `CHILD_INIT` | `setup({on_worker_init = fn})` + `init_worker()` | Called in `init_worker_by_lua_block` |
| `PARENT_INIT` | `setup()` itself | Called in `init_by_lua_block` |
| `CUSTOM_DATA` | `service` object closure | Pass via `setup({service = {...}})` |
| `MAX_CHILDREN` | `worker_processes` | nginx.conf directive |
| `PID_FILE` | `pid` | nginx.conf directive |
| `LOG_FILE` / `LOG_LEVEL` | `error_log` | nginx.conf directive |
| `CHILD_USER` / `CHILD_GROUP` | `user` | nginx.conf directive |

## Development

### Prerequisites

- OpenResty >= 1.19.3.1
- lua-yar (installed via LuaRocks)
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

## License

Apache License 2.0

## Author

fangfengxiang

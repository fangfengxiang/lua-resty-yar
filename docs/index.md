# lua-resty-yar

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![OPM](https://img.shields.io/badge/OPM-lua--resty--yar-blue.svg)](https://opm.openresty.org/package/fangfengxiang/lua-resty-yar/)
[![Test](https://github.com/fangfengxiang/lua-resty-yar/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/fangfengxiang/lua-resty-yar/actions/workflows/test.yml)
[![Release](https://img.shields.io/github/v/release/fangfengxiang/lua-resty-yar)](https://github.com/fangfengxiang/lua-resty-yar/releases)

High-performance Yar RPC server for OpenResty, built on [lua-yar](https://github.com/fangfengxiang/lua-yar).

## Features

- **HTTP server handler** — `content_by_lua` entry, one coroutine per request, pure protocol dispatch via `handle_message`
- **TCP stream server handler** — stream `content_by_lua` entry, one coroutine per connection, keepalive loop via `handle_connection`
- **Cosocket injection** — outbound RPC calls use OpenResty non-blocking I/O with connection pooling
- **yar-c parameter mapping** — `READ_TIMEOUT` → three-stage cosocket timeouts, `CHILD_INIT` → `on_worker_init` hook
- **Process-level instance reuse** — Server/TcpServer instances created in `init_by_lua`, shared by all coroutines in worker

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
            },
        }
    }

    server {
        listen 8080;
        location /api {
            content_by_lua_block {
                require("resty.yar").get_server():handle()
            }
        }
    }
}
```

### TCP Server

```nginx
stream {
    lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";

    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
            },
        }
    }

    server {
        listen 9500;
        content_by_lua_block {
            require("resty.yar").get_tcp_server():loop()
        }
    }
}
```

## Documentation

- [API Reference](api.md) — full API documentation
- [Positioning](positioning.md) — adaptation layer vs platform, design philosophy
- [Design Decisions](design/decisions.md) — ADR index and module breakdown
- [Reports](reports/evaluation-report.md) — evaluation, optimization plans, and reviews

# Quick Start

> lua-resty-yar — get a Yar RPC service running in 5 minutes.

## Prerequisites

- [OpenResty](https://openresty.org/) 1.21.4.1+
- [lua-yar](https://github.com/fangfengxiang/lua-yar) (installed as a sibling directory or via OPM)

## Installation

### Option A: OPM (recommended)

```bash
opm get fangfengxiang/lua-resty-yar
```

### Option B: From source

```bash
git clone https://github.com/fangfengxiang/lua-resty-yar.git
cd lua-resty-yar
# lua-yar must be at ../lua-yar/src/ or installed via luarocks
git clone https://github.com/fangfengxiang/lua-yar.git ../lua-yar
```

## 1. HTTP Server (3 minutes)

### nginx.conf

```nginx
worker_processes 1;
events { worker_connections 1024; }
http {
    lua_package_path "/path/to/lua-resty-yar/lib/?.lua;/path/to/lua-yar/src/?.lua;;";

    init_by_lua_block {
        local yar = require("resty.yar")
        yar.setup {
            server = {
                service = {
                    add = function(a, b) return a + b end,
                    greet = function(name) return "Hello, " .. name end,
                },
            },
        }
    }

    server {
        listen 8080;
        location /rpc {
            content_by_lua_block {
                require("resty.yar").get_server():serve()
            }
        }
    }
}
```

### Call from PHP

```php
<?php
$client = new Yar_Client("http://127.0.0.1:8080/rpc");
echo $client->add(1, 2);       // 3
echo $client->greet("World");  // Hello, World
```

### Call from Lua

```lua
local yar = require("resty.yar")
local client = yar.new_client("http://127.0.0.1:8080/rpc")
local result = client:call("add", { 1, 2 })  -- 3
```

## 2. TCP Stream Server

```nginx
worker_processes 1;
events { worker_connections 1024; }
http {
    lua_package_path "/path/to/lua-resty-yar/lib/?.lua;/path/to/lua-yar/src/?.lua;;";

    init_by_lua_block {
        local yar = require("resty.yar")
        yar.setup {
            server = {
                service = {
                    add = function(a, b) return a + b end,
                },
            },
        }
    }

    server {
        listen 9999;  # No "location" block needed — pure TCP stream
        content_by_lua_block {
            require("resty.yar").server.tcp.serve()
        }
    }
}
```

The framework auto-detects HTTP vs TCP from the listen address:
- `location` block → HTTP mode (parse HTTP body, write HTTP response)
- No `location` → TCP stream mode (raw Yar protocol frames)

## 3. Adding Observability

```nginx
http {
    lua_shared_dict yar_metrics 1m;

    init_by_lua_block {
        local yar = require("resty.yar")
        local obs = require("resty.yar.observability")

        yar.setup {
            server = {
                service = {
                    add = function(a, b) return a + b end,
                },
            },
            -- One-click: trace + access-log + metrics
            hooks = obs.defaults({
                metrics = { dict_name = "yar_metrics", buffer_enabled = true },
            }),
        }
    }

    server {
        listen 8080;

        location /rpc {
            content_by_lua_block { yar.get_server():serve() }
        }

        # Prometheus metrics endpoint
        location /metrics {
            content_by_lua_block {
                local obs = require("resty.yar.observability")
                ngx.print(obs.get_export())
            }
        }
    }

    # Deferred access log flushing
    log_by_lua_block {
        require("resty.yar.observability").flush_logs()
    }
}
```

## 4. Writing a Plugin

```lua
-- rate_limit.lua
local yar = require("resty.yar")

yar.register("rate-limit", function()
    return {
        on_request = function(method, params)
            local dict = ngx.shared.rate_limit_dict
            local count = dict:incr(method, 1, 0)
            if count > 100 then
                error("rate limit exceeded for " .. method)
            end
        end,
    }
end, { priority = 75 })
```

```nginx
http {
    lua_shared_dict rate_limit_dict 1m;

    init_by_lua_block {
        require("rate_limit")  -- Register the plugin
        local yar = require("resty.yar")
        yar.setup {
            server = { service = { ... } },
        }
    }
}
```

## 5. Client with Keepalive

```lua
local yar = require("resty.yar")

-- Get a persistent client (socket reused across calls)
local client = yar.get_client("tcp://127.0.0.1:9999")

local r1 = client:call("add", { 1, 2 })  -- Connection established
local r2 = client:call("add", { 3, 4 })  -- Same connection (keepalive)

-- Error handling
local result, err = client:call("divide", { 1, 0 })
if err then
    ngx.log(ngx.ERR, "RPC failed: " .. err.code .. " — " .. tostring(err))
end
```

## Next Steps

- [API Reference](api.md) — Complete API documentation
- [Design Philosophy](design-philosophy.md) — Architecture and principles
- [Extensibility Guide](extensibility.md) — Plugins, transports, packagers
- [Examples](https://github.com/fangfengxiang/lua-resty-yar/tree/main/examples) — Complete runnable examples

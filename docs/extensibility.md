# Extensibility Guide

> lua-resty-yar — extension points and customization APIs.

## Overview

The framework provides five extension points, from least to most invasive:

| Extension Point | API | Use Case |
|----------------|-----|----------|
| Plugin Registry | `yar.register()` | Add lifecycle hooks (logging, tracing, metrics) |
| Inline Hooks | `setup({ server = { hooks = ... } })` | One-off hooks without registration |
| Transport Provider | `extensions.use_resty_http` | Replace cosocket with lua-resty-http |
| Packager Extension | `Yar.register_packager()` | Custom serialization format |
| C Extension | `extensions.use_cjson` / `use_cmsgpack` | Accelerate JSON/MsgPack encoding |

---

## 1. Plugin Registration

### Register a Named Plugin

```lua
local yar = require("resty.yar")
local obs = require("resty.yar.observability")

-- Register plugins (order doesn't matter — priority determines execution order)
yar.register("trace", function()
    return obs.trace_middleware({ header = "X-Request-Id" })
end, { priority = 50 })

yar.register("access-log", function()
    return obs.access_logger({ defer = true })
end, { priority = 100 })

yar.register("metrics", function()
    return obs.metrics_recorder({ dict_name = "yar_metrics", buffer_enabled = true })
end, { priority = 200 })

-- setup() instantiates all registered plugins (delayed instantiation)
yar.setup {
    server = {
        service = {
            add = function(a, b) return a + b end,
            echo = function(msg) return msg end,
        },
    },
}
```

### Priority Ordering

Hooks execute in ascending priority order (lower number = earlier):

```
trace (50) → access-log (100) → metrics (200)
```

Within the same priority, ties are broken by name (alphabetical). The recommended priority ranges:

| Range | Purpose | Examples |
|-------|---------|---------|
| 0–49 | Pre-processing | Request ID generation, authentication |
| 50–99 | Instrumentation | Tracing, access logging |
| 100–199 | Business logic | Rate limiting, caching |
| 200+ | Post-processing | Metrics, audit logging |

### Write a Custom Plugin

```lua
local yar = require("resty.yar")

-- A simple audit-log plugin that records all RPC calls
yar.register("audit-log", function()
    return {
        on_request = function(method, params)
            ngx.log(ngx.INFO, "[audit] RPC call: " .. method)
        end,
        on_response = function(method, retval, err_obj)
            if err_obj then
                ngx.log(ngx.WARN, "[audit] RPC failed: " .. method .. " — " .. tostring(err_obj))
            else
                ngx.log(ngx.INFO, "[audit] RPC ok: " .. method)
            end
        end,
        -- on_error and on_timeout are derived from on_response by hooks.adapt()
        -- But you can also define them explicitly:
        on_timeout = function(method)
            ngx.log(ngx.ERR, "[audit] RPC timeout: " .. method)
        end,
    }
end, { priority = 150 })

yar.setup { server = { service = { ... } } }
```

### Plugin Lifecycle

| Phase | Hook | When |
|-------|------|------|
| `init_by_lua` | `on_request` / `on_response` / `on_error` / `on_timeout` | Registered at `setup()`, composed by `registry.get_hooks()` |
| `init_worker_by_lua` | `on_init_worker` | Called by `yar.init_worker()` — once per worker |
| Connection | `on_connect` | Called by lua-yar when a new cosocket connection is established |

---

## 2. Inline Hooks

For one-off hooks without the registration ceremony:

```lua
yar.setup {
    server = {
        service = { add = function(a, b) return a + b end },
        hooks = {
            on_request = function(method, params)
                ngx.log(ngx.INFO, "calling: " .. method)
            end,
        },
    },
}
```

Inline hooks are treated as an anonymous plugin with priority 50. They are composed with any registered plugins.

### Hook Derivation

The framework derives `on_error` and `on_timeout` from `on_response`:

1. Call original `on_response(method, retval, err_obj)`
2. If `err_obj` is not nil → call `on_error(method, err_obj)`
3. If `err_obj.code == Error.TIMEOUT` → call `on_timeout(method)`

This means you only need to implement `on_response` for most use cases. The framework handles the derivation.

---

## 3. Transport Provider

By default, the framework uses OpenResty's built-in cosocket (`ngx.socket`) for network I/O. For advanced use cases (custom DNS resolution, SOCKS proxy, HTTP/2), you can switch to [lua-resty-http](https://github.com/ledgetech/lua-resty-http) as the transport layer.

### Enable lua-resty-http Transport

```lua
yar.setup {
    server = { service = { ... } },
    extensions = { use_resty_http = true },
    -- Requires: opm get ledgetech/lua-resty-http
}
```

When enabled, the framework injects `require("resty.http")` as the socket provider into lua-yar's `Client.set_socket()`. The cosocket API remains the same — lua-resty-http is API-compatible with `ngx.socket`.

### Custom Transport Provider

For fully custom transport, bypass the framework and inject directly into lua-yar:

```lua
local Yar = require("yar")
local yar = require("resty.yar")

-- Define a custom socket provider (must implement connect/send/receive/settimeout/close)
local custom_socket = {
    connect = function(self, host, port) ... end,
    send = function(self, data) ... end,
    receive = function(self, size) ... end,
    settimeout = function(self, ms) ... end,
    close = function(self) ... end,
}

-- Inject into lua-yar before framework setup
Yar.client.set_socket(function() return custom_socket end)

yar.setup { server = { service = { ... } } }
```

---

## 4. Packager Extension

The Yar protocol supports pluggable serialization formats. The framework defaults to JSON (pure-Lua implementation). You can register custom packagers via lua-yar's API.

### Register a Custom Packager

```lua
local Yar = require("yar")

-- Implement the packager interface: { pack(data) -> string, unpack(str) -> data }
local my_packager = {
    pack = function(data)
        -- Serialize to your custom format
        return ...
    end,
    unpack = function(str)
        -- Deserialize from your custom format
        return ...
    end,
}

-- Register with lua-yar
Yar.register_packager("MYFORMAT", my_packager)

-- Use in the framework
require("resty.yar").setup {
    server = { service = { ... }, packager = "MYFORMAT" },
}
```

---

## 5. C Extension Acceleration

For production workloads, replace the pure-Lua JSON/MsgPack implementations with C extensions for 5–20x encoding speedup.

### Enable cjson (JSON acceleration)

```lua
yar.setup {
    server = { service = { ... } },
    extensions = { use_cjson = true },
}
```

When enabled, the framework sets `Yar.use_cjson(true)` in lua-yar, which routes `Json.pack` / `Json.unpack` to `cjson.encode` / `cjson.decode`. The pure-Lua implementation remains as fallback.

### Enable cmsgpack (MsgPack acceleration)

```lua
yar.setup {
    server = { service = { ... }, packager = "MSGPACK" },
    extensions = { use_cmsgpack = true },
}
```

### Depth Protection

The pure-Lua implementations have configurable recursion depth limits (default 512) to prevent stack overflow on maliciously deep input:

```lua
yar.setup {
    extensions = {
        use_cjson = true,
        json_max_depth = 256,    -- Reduce for stricter security
        msgpack_max_depth = 256,
    },
}
```

---

## 6. Hook Composition Patterns

### Composing Multiple Observability Hooks

```lua
local obs = require("resty.yar.observability")

-- Manual composition (no registry)
yar.setup {
    server = { service = { ... } },
    hooks = obs.compose(
        obs.trace_middleware(),
        obs.access_logger({ defer = true }),
        obs.metrics_recorder({ dict_name = "yar_metrics" })
    ),
}
```

### One-Click Observability

```lua
local obs = require("resty.yar.observability")

yar.setup {
    server = { service = { ... } },
    hooks = obs.defaults({
        metrics = { buffer_enabled = true },
    }),
}
```

`defaults()` returns a priority-ordered composition of trace (50) + access-log (100) + metrics (200).

### Custom Hook with Registry

```lua
-- Register custom plugin alongside observability defaults
yar.register("rate-limit", function()
    return {
        on_request = function(method, params)
            local dict = ngx.shared.rate_limit
            local count = dict:incr(method, 1, 0)
            if count > 100 then
                error("rate limit exceeded for " .. method)
            end
        end,
    }
end, { priority = 75 })  -- Between trace (50) and access-log (100)

yar.setup {
    server = { service = { ... } },
    hooks = obs.defaults(),  -- Inline hooks compose with registered plugins
}
```

---

## 7. Client-Side Extensions

### Custom Client Options

```lua
local yar = require("resty.yar")

-- Per-URI client with custom options
local client = yar.new_client("tcp://10.0.0.1:9999", {
    timeout = 5000,
    connect_timeout = 2000,
    ssl_verify = false,           -- Skip TLS verification (not recommended for prod)
    persistent = true,             -- Enable keepalive connection pool
    keepalive_idle = 30000,       -- 30s idle timeout
    pool_size = 50,               -- 50 connections in pool
    resolve = "10.0.0.1",         -- Custom DNS resolution
    proxy = "http://proxy:8080",  -- Connect via proxy
    headers = {                    -- Base headers for all calls
        Authorization = "Bearer token",
    },
    packager = "JSON",             -- Override server packager
})

local result = client:call("add", { 1, 2 })
```

### Trace Header Propagation

When using `trace_middleware()`, outgoing RPC calls automatically receive the request ID header:

```lua
-- Server side: trace middleware sets ngx.ctx.request_id
yar.setup {
    server = { service = { ... } },
    hooks = obs.trace_middleware(),
}

-- Client side: get_client automatically propagates trace headers
local client = yar.get_client("tcp://backend:9999")
client:call("process", { data })
-- → backend receives "X-Request-Id: <id>" header
```

---

## Summary

| Extension Point | Complexity | When to Use |
|----------------|------------|-------------|
| Inline hooks | Low | Quick one-off logging or validation |
| Plugin registry | Medium | Reusable, composable hooks across services |
| Transport provider | Medium | Custom DNS, proxy, or HTTP/2 transport |
| Packager extension | High | Non-standard serialization format |
| C extension | Low (toggle) | Production performance optimization |

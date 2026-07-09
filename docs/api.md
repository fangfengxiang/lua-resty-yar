# API Reference

> lua-resty-yar — OpenResty Yar RPC framework API reference.
> Underlying protocol API: [lua-yar API Reference](https://github.com/fangfengxiang/lua-yar/blob/main/docs/api.md).

---

## Module: `resty.yar`

Main entry point. Call `setup()` once in `init_by_lua_block`.

### `yar.setup(opts)`

Initializes the adapter: injects cosocket, injects `ngx.log` writer, creates Server Facade instance, merges config.

**Parameters:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `service` | `table` | `{add, sub, greet}` | RPC service object. Function fields are exposed as RPC methods. |
| `packager` | `string` | `"JSON"` | Response packager name: `"JSON"` or `"Msgpack"` |
| `connect_timeout` | `number` | `1000` | Connection timeout (ms) |
| `send_timeout` | `number` | `5000` | Send timeout (ms) |
| `read_timeout` | `number` | `5000` | Read timeout (ms) |
| `keepalive_idle` | `number` | `60000` | TCP keepalive idle timeout (ms) |
| `timeout` | `number` | `5000` | Per-message timeout for standalone `run()` mode (ms) |
| `client_timeout` | `number` | `3000` | Outbound RPC default timeout (ms) |
| `pool_size` | `number` | `30` | Cosocket connection pool size |
| `max_body_len` | `number` | `10485760` | Max request body length (bytes, 10MB) |
| `ssl_verify` | `boolean` | `true` | HTTPS certificate verification |
| `on_worker_init` | `function\|nil` | `nil` | Worker init callback (CHILD_INIT mapping). Called via `init_worker()`. |
| `log_level` | `number` | `INFO` | Log level: `1`=DEBUG, `2`=INFO, `3`=WARN, `4`=ERROR |
| `hooks` | `table\|nil` | `nil` | `{on_request=fn, on_response=fn}` — request/response interception |
| `use_cjson` | `boolean` | `false` | Register cjson C extension for JSON acceleration |
| `use_cmsgpack` | `boolean` | `false` | Register cmsgpack C extension for Msgpack acceleration |
| `use_resty_http` | `boolean` | `false` | Inject lua-resty-http as HTTP transport provider |
| `json_max_depth` | `number` | `512` | Max JSON nesting depth (built-in codec only) |
| `msgpack_max_depth` | `number` | `512` | Max Msgpack nesting depth (built-in codec only) |

**Returns:** `self` (the module table, for chaining)

**Example:**

```lua
require("resty.yar").setup {
    service = {
        add = function(a, b) return a + b end,
        sub = function(a, b) return a - b end,
    },
    packager = "JSON",
    connect_timeout = 2000,
    read_timeout = 10000,
    pool_size = 50,
    on_worker_init = function()
        -- worker-level initialization (CHILD_INIT mapping)
    end,
    hooks = {
        on_request = function(method, params)
            ngx.log(ngx.INFO, "RPC call: " .. method)
        end,
        on_response = function(method, retval, err)
            -- response interception
        end,
    },
    use_cjson = true,  -- accelerate JSON with C extension
}
```

### `yar.get_server()`

Returns the process-level Server Facade instance (created by `setup()`).

**Returns:** `Yar.Server` instance

**Raises:** `error()` if `setup()` not called.

### `yar.get_config()`

Returns the merged config table. Handlers use this to read connection-level parameters.

**Returns:** `table` — merged configuration

### `yar.init_worker()`

Call in `init_worker_by_lua_block`. Executes the `on_worker_init` callback if provided.

### `yar.new_server(service)`

Creates a new Server Facade instance with a custom service (bypasses the process-level instance).

**Parameters:**
- `service` (`table`) — RPC service object

**Returns:** `Yar.Server` instance

### `yar.new_client(uri, opts)`

Creates a new `Yar.Client` instance with connection-level params pre-injected from `setup()` config. Each call creates a new instance.

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `uri` | `string` | — | Service URL: `http://host/api`, `https://host/api`, `tcp://host:port` |
| `opts.timeout` | `number` | `client_timeout` | Per-call timeout (ms) |
| `opts.packager` | `string` | `"JSON"` | Request encoding |
| `opts.connect_timeout` | `number` | `connect_timeout` | Connection timeout (ms) |
| `opts.keepalive_idle` | `number` | `keepalive_idle` | Pool idle timeout (ms) |
| `opts.pool_size` | `number` | `pool_size` | Connection pool size |
| `opts.max_body_len` | `number` | `max_body_len` | Max body length (bytes) |
| `opts.ssl_verify` | `boolean` | `true` | HTTPS certificate verification |
| `opts.headers` | `table\|nil` | `nil` | Custom HTTP headers |
| `opts.resolve` | `string` | `""` | Custom DNS (curl-style `host:port:ip` or PHP-style `host:ip`) |
| `opts.proxy` | `string` | `""` | HTTP proxy address |
| `opts.persistent` | `boolean` | `false` | Persistent TCP connection (reused across calls) |
| `opts.hooks` | `table\|nil` | `nil` | `{on_request=fn, on_response=fn}` |

**Returns:** `Yar.Client` instance

**Raises:** `error()` if `setup()` not called.

### `yar.get_client(uri, opts)`

Returns a memoized persistent Client instance by `uri`. Same `uri` returns the same instance within a worker. Enables socket reuse across calls.

**Parameters:** Same as `new_client()`. Options only apply on first creation per `uri`.

**Returns:** `Yar.Client` instance (persistent mode, socket reused)

### Exported Symbols

| Symbol | Type | Description |
|--------|------|-------------|
| `yar.VERSION` | `string` | Package version (e.g. `"0.1.0"`) |
| `yar.Error` | `table` | Error code constants: `.TRANSPORT`, `.TIMEOUT`, `.PROTOCOL`, `.NOT_FOUND`, `.EXCEPTION` |
| `yar.PACKAGER_JSON` | `string` | `"JSON"` |
| `yar.PACKAGER_MSGPACK` | `string` | `"Msgpack"` |

---

## Module: `resty.yar.server`

Unified server entry point. Auto-detects HTTP/stream context.

### `server.serve()`

Call in `content_by_lua_block`. Detects HTTP vs stream context by checking `ngx.req.get_method()` availability, then delegates to the appropriate handler.

> **Production tip:** For hot paths, call the specific handler directly to avoid the per-request `pcall` detection overhead:
> - HTTP: `require("resty.yar.server.http").serve()`
> - TCP: `require("resty.yar.server.tcp").serve()`

---

## Module: `resty.yar.server.http`

HTTP server handler. Delegates to lua-yar's `serve_callback` mode via `server:handle({method, data, writer})`.

### `http.serve()`

Call in `content_by_lua_block` within an HTTP `server` / `location` block. Reads request body, delegates to Server Facade, writes response via `ngx.status` / `ngx.header` / `ngx.print`.

---

## Module: `resty.yar.server.tcp`

TCP stream server handler. Delegates to lua-yar's socket mode via `server:handle({socket, keepalive})`.

### `tcp.serve()`

Call in `content_by_lua_block` within a `stream` / `server` block. Obtains downstream socket via `ngx.req.socket()`, sets three-stage timeouts from config, delegates to Server Facade with keepalive loop, performs graceful lingering close.

---

## Module: `resty.yar.client`

Thin wrapper module providing `new()` and `get()` functions.

### `client.new(uri, opts)`

Delegates to `yar.new_client(uri, opts)`.

### `client.get(uri, opts)`

Delegates to `yar.get_client(uri, opts)`.

---

## Client Usage

### Basic RPC Call

```lua
local yar = require("resty.yar")
local client = yar.new_client("http://127.0.0.1:8888/api")
local result, err = client:call("add", { 1, 2 })
if not result then
    -- err is a structured Error object
    if err.code == yar.Error.TIMEOUT then
        ngx.log(ngx.ERR, "RPC timeout")
    elseif err.code == yar.Error.TRANSPORT then
        ngx.log(ngx.ERR, "transport error: ", err.message)
    end
    return
end
ngx.say("result: ", result)  -- => 3
```

### Persistent Client (Socket Reuse)

```lua
local yar = require("resty.yar")
local client = yar.get_client("tcp://127.0.0.1:9999")
local r1 = client:call("add", { 1, 2 })   -- persistent, socket reused
local r2 = client:call("add", { 3, 4 })   -- same connection
```

---

## Module: `resty.yar.observability`

Observability instrumentation: structured access logging, cross-service request ID tracing, and RPC metrics with Prometheus export. All hooks are pcall-protected — a failure in one hook does not affect others.

### `observability.access_logger(opts)`

Factory returning a hooks table with `on_request` / `on_response`. Logs structured JSON entries with fields: `ts`, `level`, `module`, `method`, `params_size`, `status`, `duration_ms`, `request_id`, `retval_size` / `error`.

**Parameters:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `writer` | `function(level, msg)` | `ngx.log` | Custom log writer |
| `defer` | `boolean` | `false` | Defer log I/O to `log_by_lua` phase (call `flush_logs()` there) |

**Example:**

```lua
local obs = require("resty.yar.observability")
require("resty.yar").setup {
    service = { add = function(a, b) return a + b end },
    hooks = obs.access_logger({ defer = true }),
}
-- log_by_lua_block { obs.flush_logs() }
```

### `observability.trace_middleware(opts)`

Factory returning hooks table. Generates per-request ID in `ngx.ctx.request_id`, propagates to outgoing RPC calls via HTTP header.

**Parameters:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `header` | `string` | `"X-Request-Id"` | Header name for trace propagation |

### `observability.metrics_recorder(opts)`

Factory returning hooks table with `on_request` / `on_response` plus an `export()` function. Records RPC call counts and latency histograms in an `ngx.shared.dict`.

**Parameters:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `dict_name` | `string` | `"yar_metrics"` | Shared dict name (must be declared with `lua_shared_dict`) |
| `prefix` | `string` | `"yar"` | Metric name prefix |
| `buffer_enabled` | `boolean` | `false` | Worker-local buffer + `ngx.timer.every` flush (eliminates lock contention) |
| `flush_interval` | `number` | `1` | Buffer flush interval in seconds |

**Returns:** hooks table with `export()` method returning Prometheus exposition format string.

**Example:**

```nginx
http {
    lua_shared_dict yar_metrics 1m;
    init_by_lua_block {
        local obs = require("resty.yar.observability")
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end },
            hooks = obs.metrics_recorder({ dict_name = "yar_metrics" }),
        }
        -- Store export fn for /metrics endpoint
        _G.export_metrics = obs.get_export()
    }
    server {
        location /metrics {
            content_by_lua_block { ngx.print(_G.export_metrics()) }
        }
    }
}
```

### `observability.compose(...)`

Compose multiple hooks tables into one. Each hook is pcall-isolated.

```lua
local hooks = obs.compose(
    obs.trace_middleware(),
    obs.access_logger(),
    obs.metrics_recorder({ dict_name = "yar_metrics" })
)
```

### `observability.compose_named(list)`

Compose named hooks list (used by `registry`). Error logs show plugin name, not index.

**Parameters:**

| Option | Type | Description |
|--------|------|-------------|
| `list` | `table` | Array of `{ name=string, priority=number, hooks=table }` — must be pre-sorted by priority |

### `observability.defaults(opts)`

One-click observability: returns `compose_named` result with trace + access-log + metrics, priority-ordered.

**Parameters:**

| Option | Type | Description |
|--------|------|-------------|
| `opts.trace` | `table` | Options passed to `trace_middleware()` |
| `opts.access_log` | `table` | Options passed to `access_logger()` |
| `opts.metrics` | `table` | Options passed to `metrics_recorder()` |

```lua
require("resty.yar").setup {
    service = { ... },
    hooks = obs.defaults({ metrics = { buffer_enabled = true } }),
}
```

### `observability.get_request_id()`

Returns the current request ID from `ngx.ctx.request_id`. Returns `""` if not set (trace middleware not active).

### `observability.flush_logs()`

Flushes deferred access logs. Call in `log_by_lua_block` when using `access_logger({ defer = true })`.

### `observability.gen_request_id()`

Generate a new request ID (multi-entropy-source: timestamp + worker PID + monotonic counter). Public for testing — production code should use `trace_middleware()` which manages ID lifecycle automatically.

---

## Module: `resty.yar.registry`

Plugin registry with priority-based ordering and named composition.

### `registry.register(name, factory, opts)`

Register a plugin. Chainable. Factory is a zero-arg function returning a hooks table (called at `setup()` time, not at registration time — delayed instantiation).

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `string` | Plugin name (unique, overwrites on duplicate) |
| `factory` | `function` | Zero-arg function returning `{ on_request=fn, on_response=fn, ... }` |
| `opts.priority` | `number` | Execution priority (ascending: lower = first, default 50) |

```lua
local yar = require("resty.yar")
yar.register("trace", function() return obs.trace_middleware() end, { priority = 50 })
yar.register("metrics", function() return obs.metrics_recorder() end, { priority = 200 })
```

### `registry.get_hooks(user_hooks)`

Collect and compose all registered plugins. Called internally by `setup()`. If `user_hooks` is provided (inline hooks), it's treated as an anonymous plugin with priority 50.

**Returns:** composed hooks table (or `nil` if no plugins registered and no inline hooks)

### `registry.clear()`

Clear all registered plugins. For testing and reconfiguration.

### `registry.list()`

List registered plugins for introspection.

**Returns:** array of `{ name=string, priority=number }` sorted by priority then name.

---

## Module: `resty.yar.hooks`

Lifecycle hook adaptation: derives `on_error` / `on_timeout` from `on_response`, passes through `on_connect` / `on_init_worker`.

### `hooks.adapt(framework_hooks)`

Adapt framework hooks to lua-yar's `on_request` / `on_response` protocol format. Derivation logic:

1. Call original `on_response(method, retval, err_obj)`
2. If `err_obj` is not nil → derive `on_error(method, err_obj)`
3. If `err_obj.code == Error.TIMEOUT` → derive `on_timeout(method)`

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `framework_hooks` | `table\|nil` | Composed hooks table (from `registry.get_hooks()` or `obs.compose()`) |

**Returns:** adapted hooks table with `on_request` / `on_response` (lua-yar format) + `on_connect` / `on_init_worker` (passthrough), or `nil` if input is nil.

---

## Config Schema Reference

The config system supports both nested four-domain format and flat-format backward compatibility.

### Nested Format (recommended)

```lua
require("resty.yar").setup {
    server = {
        service = { add = function(a, b) return a + b end },
        packager = "JSON",
        timeout = 5000,
        max_body_len = 10485760,
        hooks = { on_request = function() end },
    },
    client = {
        timeout = 3000,
        connect_timeout = 1000,
        keepalive_idle = 60000,
        pool_size = 30,
        max_body_len = 10485760,
        ssl_verify = true,
        resolve = "",
        proxy = "",
    },
    observability = {
        metrics_dict = "yar_metrics",
        metrics_prefix = "yar",
        metrics_buffer = { enabled = false, flush_interval = 1 },
        access_log = { defer = false },
        trace = { header = "X-Request-Id" },
    },
    extensions = {
        use_cjson = false,
        use_cmsgpack = false,
        use_resty_http = false,
        json_max_depth = 512,
        msgpack_max_depth = 512,
    },
    log_level = 2,  -- 1=DEBUG, 2=INFO, 3=WARN, 4=ERROR
    on_worker_init = function() end,
}
```

### Flat Format (backward compatible)

Top-level keys are automatically routed to the correct domain:

```lua
require("resty.yar").setup {
    service = { add = function(a, b) return a + b end },  -- → server
    packager = "JSON",                                      -- → server
    timeout = 5000,                                         -- → server
    client_timeout = 3000,                                 -- → client.timeout
    connect_timeout = 1000,                                -- → client.connect_timeout
    pool_size = 30,                                         -- → client.pool_size
    use_cjson = true,                                      -- → extensions.use_cjson
    on_worker_init = function() end,                       -- top-level
}
```

### Config Domains

| Domain | Keys | Description |
|--------|------|-------------|
| `server` | `service`, `packager`, `timeout`, `max_body_len`, `hooks` | Server-side RPC service and protocol config |
| `client` | `timeout`, `connect_timeout`, `keepalive_idle`, `pool_size`, `max_body_len`, `ssl_verify`, `resolve`, `proxy` | Outbound RPC client defaults |
| `observability` | `metrics_dict`, `metrics_prefix`, `metrics_buffer`, `access_log`, `trace` | Observability configuration (hooks still need manual wiring) |
| `extensions` | `use_cjson`, `use_cmsgpack`, `use_resty_http`, `json_max_depth`, `msgpack_max_depth` | C extension and transport provider toggles |

### Type Validation

Config values are validated against type specs at `setup()` time. Type mismatches trigger `error()` (fail-fast, programming error).

| Key | Expected Type | Default |
|-----|--------------|---------|
| `server.packager` | `string` | `"JSON"` |
| `server.timeout` | `number` | `5000` |
| `server.max_body_len` | `number` | `10485760` |
| `client.timeout` | `number` | `3000` |
| `client.connect_timeout` | `number` | `1000` |
| `client.pool_size` | `number` | `30` |
| `client.ssl_verify` | `boolean` | `true` |
| `extensions.use_cjson` | `boolean` | `false` |
| `extensions.use_resty_http` | `boolean` | `false` |
| `log_level` | `number` | `2` (INFO) |

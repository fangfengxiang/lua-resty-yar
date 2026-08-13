# API Reference

> lua-resty-yar — OpenResty Yar RPC adapter layer API reference.
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

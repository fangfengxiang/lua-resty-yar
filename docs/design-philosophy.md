# Design Philosophy

> lua-resty-yar — the design principles and architectural decisions behind the framework.

## Overview

lua-resty-yar is an **OpenResty-native Yar RPC framework**, not a protocol library or an adapter layer. It builds on [lua-yar](https://github.com/fangfengxiang/lua-yar) (the pure-protocol Lua implementation of the Yar binary RPC protocol) and adds the infrastructure that production RPC systems need: configuration management, plugin registry, observability instrumentation, and lifecycle hooks.

**Key distinction:**

| Layer | Project | Role |
|-------|----------|------|
| Protocol | lua-yar | Yar protocol (framing, header, packager, transport) — runtime-agnostic SDK |
| Framework | lua-resty-yar | OpenResty integration, config, hooks, observability |
| Platform | (future) | Operational config-driven gateway (Kong/APISIX tier) |

---

## 1. Three-Layer Architecture

The framework is organized in three clean layers with a strict dependency DAG (no cycles):

```
┌─────────────────────────────────────────────────────────┐
│  Handler Layer                                          │
│  server/http.lua · server/tcp.lua · client.lua         │
│  OpenResty phase entry points (content_by_lua, etc.)   │
├─────────────────────────────────────────────────────────┤
│  Framework Layer                                        │
│  init.lua · config.lua · registry.lua                  │
│  hooks.lua · observability.lua · server/init.lua       │
│  Configuration · plugin registry · hook adaptation    │
├─────────────────────────────────────────────────────────┤
│  Protocol Layer                                         │
│  lua-yar (external dependency)                         │
│  Server · Client · Transport · Protocol · Packager     │
└─────────────────────────────────────────────────────────┘
```

**Dependency direction:** Handler → Framework → Protocol. No upward dependencies. The framework layer never imports handler-layer modules; the protocol layer never imports framework-layer modules.

**Why three layers?**

- **Separation of concerns**: protocol correctness (lua-yar) is independent of OpenResty integration (lua-resty-yar). Changes to nginx directives or OpenResty APIs never touch protocol code.
- **Testability**: lua-yar can be unit-tested without nginx. lua-resty-yar can be integration-tested with Test::Nginx.
- **Reusability**: lua-yar serves any Lua runtime (standalone LuaJIT, embedded). lua-resty-yar is OpenResty-specific.

---

## 2. Adaptation Over Reimplementation

The framework does **not** reimplement any protocol logic. Every protocol operation delegates to lua-yar:

- `Server.new()` / `Client.new()` → `Yar.Server.new()` / `Yar.Client.new()`
- Request/response handling → `server:handle_message()`
- Outbound RPC → `client:call()`
- Transport I/O → `Yar.client.set_socket(ngx.socket)` (cosocket injection)

**What the framework adds (non-protocol concerns):**

- Configuration schema with defaults, type validation, and flat-format backward compatibility
- Plugin registry with priority-based ordering and named composition
- Lifecycle hook adaptation (deriving `on_error` / `on_timeout` from `on_response`)
- Observability: structured access logging, request ID tracing, Prometheus metrics
- Connection management (client caching with weak-value table, trace header propagation)
- Auto-detection of HTTP vs TCP stream server from the listen address

---

## 3. OpenResty-Native First

The framework leverages OpenResty's async I/O model at every level:

### cosocket

All network I/O uses OpenResty cosockets (`ngx.socket`), not Lua's blocking `io.*`. The cosocket is injected into lua-yar via `Client.set_socket(ngx.socket)`, enabling non-blocking RPC calls that yield to the nginx event loop.

### Shared Dictionary (shdict)

Metrics are stored in `ngx.shared.dict` with atomic `incr()` operations. No locks needed — the shdict API is atomic by design. Optional worker-local buffering via `ngx.timer.every` eliminates lock contention for high-throughput scenarios.

### Timer

The metrics buffer flush uses `ngx.timer.every(flush_interval, fn)`, a standard OpenResty periodic timer. The timer callback runs in a light thread (coroutine), cooperatively scheduled — safe with the request-handling coroutine as long as neither yields during buffer mutation.

### Phase Awareness

| Phase | Framework Activity |
|-------|-------------------|
| `init_by_lua` | `setup()` — config merge, validate, plugin instantiation, Server/Client creation |
| `init_worker_by_lua` | `init_worker()` — worker-specific timers, plugin `on_init_worker` hooks |
| `content_by_lua` | `server.serve()` — HTTP/TCP request handling |
| `log_by_lua` | `flush_logs()` — deferred access log I/O |

---

## 4. Process-Level Reuse, Request-Level Stateless

**Server instances are created once** in `init_by_lua` and reused across all requests in the worker process. This is OpenResty's process model: each nginx worker is a separate process with its own Lua VM. The Server object is shared by all coroutines in that worker.

**Client instances are cached** per-URI in a weak-value table. The cosocket connection pool is managed by OpenResty's `lua_socket_pool_size` directive. Per-request state (trace headers, request ID) is stored in `ngx.ctx`, which is per-request and auto-cleaned.

**No global mutable state** beyond:
- `_merged` config table (written once in `setup()`, read-only after)
- `_plugins` registry (written in `register()`, read-only after `setup()`)
- `_client_cache` (weak-value table, entries GC'd when caller releases reference)
- `_request_seq` counter (monotonic, per-worker, no synchronization needed)
- Lazy-init caches (`_server` in http.lua, `_ctx_type` in server/init.lua): written once on first request, read-only after. Write-once pattern — no per-request mutation, no concurrency risk under cooperative scheduling.

---

## 5. Configuration-Driven Development

The config system is the framework's foundation. It supports:

### Nested Four-Domain Format (recommended)

```lua
setup {
    server = { service = ..., packager = "JSON", timeout = 5000 },
    client = { timeout = 3000, connect_timeout = 1000 },
    observability = { metrics_dict = "yar_metrics" },
    extensions = { use_cjson = true },
}
```

### Flat Format (deprecated, scheduled for removal in 1.0)

> **Deprecated.** Use nested four-domain format instead. Flat compatibility adds ~30% maintenance overhead to `config.lua` with no significant user benefit for a new framework. Will be removed before 1.0.

Top-level keys are automatically routed to the correct domain via `FLAT_MAP`:

```lua
setup { service = ..., packager = "JSON", client_timeout = 3000 }
```

### Deep Merge

User config is deep-merged with defaults — only specify what you want to change. A depth protection (100 levels) prevents infinite recursion on circular table references.

### Type Validation

All config values are validated against type specs at `setup()` time. Mismatches trigger `error()` (fail-fast) — programming errors should surface immediately, not in production at 3 AM.

---

## 6. Plugin Mechanism

The plugin registry enables extensibility without modifying core code.

### Registration

```lua
yar.register("trace", function() return obs.trace_middleware() end, { priority = 50 })
```

- **Delayed instantiation**: the factory function is called at `setup()` time, not at registration time. This allows plugins to be registered in any order (e.g., in different `require`'d files) before `setup()` runs.
- **Priority-based ordering**: plugins are sorted by ascending priority (lower = earlier in the hook chain). Ties are broken by name.
- **Named composition**: error logs show the plugin name, not an index — critical for debugging in multi-plugin setups.

### Hook Composition

All registered plugins' hooks are composed into a single hooks table via `compose_named()`. Each hook is pcall-protected — a failure in one plugin's hook does not affect others.

### Inline Hooks

User can also pass hooks directly to `setup({ server = { hooks = ... } })`. Inline hooks are treated as an anonymous plugin with priority 50.

---

## 7. Observability Instrumentation

Three observability dimensions, composable and independent:

### Access Logging

Structured JSON entries with fields: timestamp, log level, module, method, params size, status (ok/error), duration, request ID, retval/error. Supports deferred I/O to `log_by_lua` phase to minimize request latency impact.

### Request ID Tracing

Each request gets a multi-entropy-source ID (timestamp + worker PID + monotonic counter). The ID is propagated to outgoing RPC calls via an HTTP header, enabling cross-service trace correlation.

### Prometheus Metrics

RPC call counts and latency histograms, stored in `ngx.shared.dict`. Exportable via the standard Prometheus exposition format. Optional worker-local buffering eliminates shdict lock contention for high-throughput scenarios.

**Design choice**: observability is instrumentation, not infrastructure. Hooks are pcall-protected — a metrics failure never breaks an RPC call.

---

## 8. Error Handling Classification

The framework follows a three-tier error handling model (aligned with lua-yar's error classification):

| Error Type | Handling | Example |
|-----------|----------|---------|
| **Runtime** (unpredictable external conditions) | `return nil, err` | Network timeout, malformed data, shdict full |
| **Programming** (caller wrote wrong code) | `error(msg, 2)` | Wrong argument type, not initialized, config validation |
| **Third-party** (uncontrollable external code) | `pcall` isolation | User RPC method panic, hook callback error, packager encoding |

**Key principle**: runtime errors never `error()`. Programming errors never `return nil, err` (fail fast). Third-party code is always pcall-wrapped.

---

## 9. Yar Protocol Compatibility

The framework is compatible with [PHP Yar](https://www.php.net/manual/en/book.yar.php) and [yar-c](https://github.com/laruence/yar). Any protocol-level behavior (framing, header fields, packager names, error codes) is handled by lua-yar, which ensures interoperability with PHP Yar servers and clients. The framework layer never touches protocol-level concerns.

---

## Further Reading

- [API Reference](api.md) — Complete API documentation
- [Extensibility Guide](extensibility.md) — Plugin, transport, and packager extension points
- [Quick Start](quick-start.md) — Get running in 5 minutes
- [Design Decisions](design/) — Architecture Decision Records (ADRs)
- [Positioning](positioning.md) — Framework vs. library vs. platform distinction

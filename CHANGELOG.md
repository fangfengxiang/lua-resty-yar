# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-02

### Overview

lua-resty-yar — the OpenResty development framework for the Yar binary RPC protocol. Built on [lua-yar](https://github.com/fangfengxiang/lua-yar) (the pure-Lua protocol SDK), it wraps the protocol with everything OpenResty needs to run Yar in production: non-blocking cosocket I/O, a nested config schema, a priority-ordered plugin registry, lifecycle hook adaptation, and a built-in observability suite.

Compared to HTTP+JSON microservices, Yar's binary protocol stream removes text codec overhead; compared to gRPC/Thrift, it needs no IDL or heavy runtime — a pragmatic middle ground for lightweight RPC.

### Added

#### Core Framework

- **Unified server facade** — one Server instance serves both HTTP and TCP, created in `init_by_lua` and shared across all worker coroutines (process-level reuse, request-level stateless)
- **Cosocket client** — non-blocking I/O with connection pooling, keepalive, and optional persistent TCP; persistent client instances cached per-URI in a weak-value table
- **Nested config schema** — four-domain config (`server` / `client` / `observability` / `extensions`) with `deep_merge` defaults, type validation, and fail-fast `error()` on mismatches
- **Plugin registry** — `register(name, factory, opts)` with priority-based ordering, named error logs, and delayed factory instantiation
- **Lifecycle hooks** — `on_request` / `on_response` / `on_error` / `on_timeout` / `on_connect` / `on_init_worker`; `on_error` and `on_timeout` auto-derived from `on_response`; all hooks pcall-protected
- **yar-c parameter mapping** — `READ_TIMEOUT` → three-stage cosocket timeouts, `CHILD_INIT` → `on_init_worker` hook

#### Server Handlers

- HTTP server handler (`resty.yar.server.http`) — `content_by_lua` entry, delegates to lua-yar `serve_callback` mode, rejects oversized bodies with 413 (no blocking I/O on hot path)
- TCP stream server handler (`resty.yar.server.tcp`) — stream `content_by_lua` entry, keepalive loop via `handle({socket})`, graceful lingering close
- Unified server entry (`resty.yar.server`) — auto-detects HTTP/stream context, caches detection result per-worker

#### Observability

- **Structured JSON access logging** — deferred to `log_by_lua` phase for non-blocking I/O
- **Cross-service request ID tracing** — multi-entropy-source ID (timestamp + worker PID + monotonic counter), propagated via HTTP header to outgoing RPC calls
- **W3C Trace Context** — header injection and extraction across Yar RPC calls
- **Prometheus metrics** — RPC call counts and latency histograms in `ngx.shared.dict`, standard exposition format at `/metrics` endpoint
- **Metrics buffer mode** — worker-local buffer + `ngx.timer.every` periodic flush, eliminates shared-dict lock contention in high-throughput scenarios

#### Optional Extensions

- C extension acceleration — `cjson` / `cmsgpack` auto-replace pure-Lua codecs
- lua-resty-http transport provider injection (`use_resty_http`)
- Trace context propagation — W3C Trace Context header injection and extraction

#### Engineering

- CI pipeline: lint (luacheck + stylua) + multi-suite test-nginx + OPM build validation
- Multi-version CI matrix (OpenResty 1.21 / 1.25 / 1.27)
- test-nginx suite: `http.t`, `tcp.t`, `client.t`, `observability.t`, `framework.t`, `e2e.t`, `integration.t`, `performance.t`, `functional.t`
- `make coverage` target with luacov integration
- `.editorconfig`, `stylua.toml`, `.luacov` — engineering hygiene
- Bilingual README (English + Chinese)
- Design documentation: positioning, architecture, design philosophy, configuration bridge, handler delegation, observability integration, performance guide

### Changed

- `init.lua` `setup()` — delegates to `config.merge(opts)`, distributes config by domain; hooks via `registry.get_hooks()` + `hooks.adapt()`
- `observability.lua` — `compose_named(list)` for pcall isolation with plugin name in error logs; `_key_cache` for metrics key memoization; `_known_methods` set replaces `get_keys(0)` full scan in export

[Unreleased]: https://github.com/fangfengxiang/lua-resty-yar/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/fangfengxiang/lua-resty-yar/releases/tag/v0.1.0

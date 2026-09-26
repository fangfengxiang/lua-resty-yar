# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.5.0] - 2026-09-26

### Added

- Trace context propagation — W3C Trace Context header injection and extraction across Yar RPC calls
- Standard Prometheus exposition format for metrics export (`/metrics` endpoint)
- `t/framework.t` — plugin registry, priority ordering, config schema, lifecycle hooks integration tests
- `t/observability.t` expanded — key cache verification, export optimization, worker-local buffer flush tests
- `.editorconfig`, `stylua.toml`, `.luacov` — engineering hygiene configuration
- `make coverage` target with luacov integration
- CI: split monolithic `test.yml` into per-suite parallel workflows (http, tcp, client, observability, framework, e2e, integration, performance, functional)
- `docs/design/framework-evolution-plan.md` — framework evolution proposal (5 改造, 3 phases)
- `docs/design/plugin-lifecycle.md` — ADR #14 (plugin registry) + ADR #15 (lifecycle hook adaptation)
- ADR #16 (worker-local metrics buffer + timer flush) in `observability-integration.md`

### Changed

- `init.lua` setup() restructured — nested config domains (server/client/observability/extensions), flat format auto-detected with deprecation warning
- `observability.lua` — worker-local `_buffer` + `ngx.timer.every` batch flush, `_key_cache` for metrics key memoization, `_known_methods` set to replace `get_keys(0)` in export
- `Makefile` — added `stylua-check`, `coverage`, `benchmark` targets
- Version bumped to 0.5.0

### Fixed

- Stylua formatting compliance across all `lib/` and `t/` files
- Luacheck warnings — unused hook args prefixed with underscore

## [0.4.0] - 2026-09-26

### Added

- Worker-local metrics buffer with `ngx.timer.every` periodic flush (configurable via `observability.metrics_buffer`)
- Metrics key cache (`_key_cache`) — memoize `prefix_calls_total{method=...,status=...}` strings to reduce GC pressure
- Export optimization — `_known_methods` set replaces `dict:get_keys(0)` full scan
- `make coverage` target with luacov
- Multi-version CI matrix (OpenResty 1.21 / 1.25 / 1.27)

### Changed

- `observability.lua` metrics_recorder refactored — buffer accumulation + timer flush + key caching
- Default metrics mode: direct incr (backward compatible); buffer mode opt-in via config

## [0.3.0] - 2026-09-26

### Added

- `lib/resty/yar/registry.lua` — plugin registry with `register(name, factory, opts)`, priority-based ordering, named composition
- `lib/resty/yar/hooks.lua` — lifecycle hook adapter: `adapt()` derives `on_error`/`on_timeout` from `on_response`, `on_connect`/`on_init_worker` pass-through
- `lib/resty/yar/config.lua` — structured config schema with nested domains (server/client/observability/extensions), `deep_merge`, flat backward compatibility with deprecation warning
- ADR #13 (nested config schema + flat compat) in `configuration-bridge.md`
- ADR #14 (plugin registry) in `plugin-lifecycle.md`
- ADR #15 (lifecycle hook adaptation) in `plugin-lifecycle.md`

### Changed

- `init.lua` setup() — delegates to `config.merge(opts)`, distributes config by domain; hooks via `registry.get_hooks()` + `hooks.adapt()`
- `observability.lua` compose() extended to `compose_named(list)` — pcall isolation with plugin name in error logs
- Inline `opts.hooks` still works (anonymous plugin, priority=50) — backward compatible

## [0.2.0] - 2026-09-26

### Added

- `log_by_lua` deferred access logging — request lifecycle hooks via `log_by_lua` phase for non-blocking log writes
- `.editorconfig` — 4-space indent, LF, UTF-8, max 120 columns
- `stylua.toml` — Lua code formatting configuration
- CI: `stylua --check` step added to lint workflow
- Badges (CI status, OPM package, license) in README

### Changed

- `Makefile` — added `stylua-check` target
- README.md / README.zh.md — badges, license section, OPM dependency clarification

## [0.1.0] - 2026-07-10

### Added

- Initial OPM package for high-performance Yar RPC server on OpenResty
- HTTP server handler (`resty.yar.server.http`) — `content_by_lua` entry, delegates to lua-yar `serve_callback` mode
- TCP stream server handler (`resty.yar.server.tcp`) — stream `content_by_lua` entry, keepalive loop via `handle({socket})`
- Unified server entry (`resty.yar.server`) — auto-detects HTTP/stream context
- `setup()` initialization with cosocket injection, `ngx.log` writer, and yar-c parameter mapping
- `new_client(uri, opts)` / `get_client(uri, opts)` — client factory with pre-injected connection-level params
- Process-level Server instance reuse — created in `init_by_lua`, shared by all coroutines in worker
- Connection keepalive loop for TCP (multiple messages per connection)
- Graceful TCP close with lingering close (`shutdown("send")`)
- Optional C extension acceleration: `use_cjson` / `use_cmsgpack` auto-registration
- Optional lua-resty-http provider injection (`use_resty_http`)
- Hooks mechanism (`on_request` / `on_response`, pcall-protected)
- test-nginx test suite (`t/http.t`, `t/tcp.t`, `t/client.t`)
- CI pipeline: lint + test + OPM build validation
- Bilingual README (English + Chinese)

[Unreleased]: https://github.com/fangfengxiang/lua-resty-yar/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/fangfengxiang/lua-resty-yar/releases/tag/v0.5.0
[0.4.0]: https://github.com/fangfengxiang/lua-resty-yar/releases/tag/v0.4.0
[0.3.0]: https://github.com/fangfengxiang/lua-resty-yar/releases/tag/v0.3.0
[0.2.0]: https://github.com/fangfengxiang/lua-resty-yar/releases/tag/v0.2.0
[0.1.0]: https://github.com/fangfengxiang/lua-resty-yar/releases/tag/v0.1.0

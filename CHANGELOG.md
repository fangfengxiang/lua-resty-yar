# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/fangfengxiang/lua-resty-yar/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/fangfengxiang/lua-resty-yar/releases/tag/v0.1.0

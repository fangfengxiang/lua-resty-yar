# Changes

## v0.1.0 (2026-07-10)

- Initial OPM package for high-performance Yar RPC server on OpenResty
- HTTP server handler (`resty.yar.server` HTTP context)
- TCP stream server handler (`resty.yar.server` stream context)
- `setup()` initialization with cosocket injection and yar-c parameter mapping
- Connection keepalive loop for TCP (multiple messages per connection)
- Graceful TCP close with lingering close (`shutdown("send")`)
- test-nginx test suite (`t/http.t`, `t/tcp.t`)

# lua-resty-yar 提案重新评测（基于 lua-yar 0.1.0 最新代码）

> 评测时间：2026-07-17 | 基准：lua-yar src/ 最新代码 | 视角：resty-yar 适配层
> 参照：Kong 多阶段架构、lua-resty-redis/http 最佳实践、Lua 生态现状

---

## 一、评测背景与方法论

### 1.1 评测动机

前序 OpenSpec 提案（`adapt-lua-yar-011`）基于对 lua-yar 0.1.0 的初步分析生成。本次重新通读 lua-yar 全部源码后，发现若干此前遗漏的能力点（`ssl_verify`、`Packager.from_codec` 等），需重新审视每个提案的必要性和实现方式。

### 1.2 评测视角

**resty-yar 定位**：薄适配层，不造轮子。职责是将 lua-yar 的纯 Lua 协议能力接入 OpenResty 运行时（cosocket 注入、生命周期集成、配置透传），而非构建全功能 RPC 框架。

**评判标准**：
- **必须做**：Bug 修复、安全缺陷、日志丢失等功能性缺失
- **应该做**：低成本高收益的适配工作（配置透传、延迟加载）
- **可以做**：锦上添花的优化（性能加速、benchmark）
- **不做**：属于 RPC 框架职责的功能（限流/熔断/服务发现/负载均衡），应留给上层

### 1.3 Kong 模式适用性评估框架

Kong 作为 OpenResty 生态最成熟的项目，其工程模式有参考价值，但 Kong 是 API 网关，resty-yar 是 RPC 适配层，定位差异巨大。按以下维度筛选：

| Kong 模式 | Kong 定位 | resty-yar 定位 | 适用性 |
|-----------|----------|---------------|--------|
| Schema 驱动配置 | 网关有大量配置项 | 适配层配置项少 | 轻量版可考虑 |
| PDK 抽象 | 插件生态需要 | lua-yar 已有 provider 抽象 | 已具备 |
| 生命周期阶段 | 网关用全阶段 | 仅 init/init_worker/content | hooks 可替代 log 阶段 |
| 健康检查+熔断 | 上游管理 | 客户端传输层职责 | 不适用 |
| 连接池管理 | 上游连接池 | cosocket 自带连接池 | 已具备 |
| 结构化错误 | API 语义需要 | Yar 协议二进制响应 | 仅 HTTP 错误页 |
| 可观测性 | 网关运维必需 | 适配层应透传 | hooks + ngx.log |
| Worker 事件总线 | 跨 worker 协调 | 无此需求 | 不适用 |
| Admin API | 运行时管理 | 无此需求 | 不适用 |
| 声明式配置 | 网关配置管理 | setup() table 参数 | 不适用 |
| 插件架构 | 网关扩展性 | 适配层应极薄 | 不适用 |
| DNS 解析器 | 上游服务发现 | lua-yar 已有 resolve 选项 | 已具备 |
| 优雅关闭 | 网关零停机 | TCP 已实现 lingering close | 已具备 |

---

## 二、逐提案重新评测

### P0-1：keepalive 参数路由修复

**现状**：`init.lua` `new_client()` 传 `keepalive_idle` 和 `pool_size` 两个扁平键。

**lua-yar 0.1.0 实际**：
- `FLAT_KEY_MAP` 包含 `keepalive = "transport"`（整个子组），但**不包含** `keepalive_idle` 和 `pool_size`
- 嵌套结构为 `transport.keepalive = { pool_size = 64, idle_timeout = 60000 }`
- resty-yar 传的 `keepalive_idle`（注意：lua-yar 用 `idle_timeout`，resty-yar 用 `keepalive_idle`，名字不匹配）和 `pool_size` 都不在 `FLAT_KEY_MAP` 中
- 结果：两个参数被 `deep_merge` 写入 `options` 顶层，`transport.keepalive` 保持默认值

**影响**：`Socket.release(sock, ka.idle_timeout, ka.pool_size)` 读到的是 lua-yar 默认值（`idle_timeout=60000, pool_size=64`），而非 resty-yar 配置的值（`keepalive_idle=60000, pool_size=30`）。巧合的是 `idle_timeout` 默认值相同，但 `pool_size` 不同（30 vs 64）。

**业界对比**：lua-resty-redis 的 `setkeepalive(max_idle_timeout, pool_size)` 直接暴露参数，无路由层。lua-resty-http 同理。lua-yar 的嵌套结构是 Kong 风格，更规范但适配层必须正确路由。

**结论：必须修复。** Bug 确认，参数被静默忽略。

**修复方案**：
```lua
-- 推荐方案：嵌套结构，与 lua-yar 0.1.0 设计一致
client:set_options({
    transport = {
        timeout         = opts.timeout or config.client_timeout,
        connect_timeout = opts.connect_timeout or config.connect_timeout,
        keepalive = {
            idle_timeout = opts.keepalive_idle or config.keepalive_idle,
            pool_size    = opts.pool_size or config.pool_size,
        },
    },
    protocol = {
        packager = opts.packager or config.packager,
    },
})
```

---

### P0-2：handle_message nil 返回检查

**现状**：`server/http.lua` 第 82 行：
```lua
local ok, resp = pcall(server.handle_message, server, data)
if not ok then ... end
-- 未检查 resp == nil 的情况
ngx.print(resp)  -- resp 为 nil 时打印空响应
```

**lua-yar 0.1.0 实际**：`handle_message` 在两处返回 `nil, err`：
- 第 150-151 行：解析失败后渲染错误响应也失败时
- 第 187-188 行：正常处理后渲染响应失败时

pcall 捕获异常（`ok=false`），但 `nil` 正常返回是 `ok=true, resp=nil`。resty-yar 只检查 `ok`，不检查 `resp`，导致 `nil` 返回时静默输出空 200 响应。

**业界对比**：lua-resty-redis/http 的 handler 都有返回值检查。gRPC-Go 的 handler 检查 `err != nil`。这是基本防御编程。

**结论：必须修复。** Bug 确认，静默空响应。

**修复方案**：
```lua
local ok, resp_or_err = pcall(server.handle_message, server, data)
if not ok then
    ngx.log(ngx.ERR, "[resty.yar http] handle_message panic: " .. tostring(resp_or_err))
    ngx.status = HTTP_INTERNAL_SERVER_ERROR
    ngx.header["Content-Type"] = "text/plain"
    ngx.say("internal error")
    return
end
if not resp_or_err then
    -- handle_message 返回 nil, err（渲染失败）
    ngx.log(ngx.ERR, "[resty.yar http] handle_message returned nil")
    ngx.status = HTTP_INTERNAL_SERVER_ERROR
    ngx.header["Content-Type"] = "text/plain"
    ngx.say("internal error")
    return
end
ngx.header["Content-Type"] = "application/octet-stream"
ngx.print(resp_or_err)
```

---

### P1-1：ngx.log writer 注入

**现状**：resty-yar 未调用 `Yar.Log.set_writer()`，lua-yar 默认用 `print()` 输出日志。OpenResty 下 `print()` 等价于 `ngx.print()`，日志会写入响应体而非 nginx error log。

**lua-yar 0.1.0 实际**：`Log.set_writer(fn)` 接受 `fn(level, msg)` 回调。级别常量 `DEBUG=1, INFO=2, WARN=3, ERROR=4`。

**业界对比**：lua-resty-redis/http 全部用 `ngx.log(ngx.ERR, ...)`。Kong 用 PDK `kong.log`，底层也是 `ngx.log`。OpenResty 生态标准做法是日志走 `ngx.log`。

**结论：必须做。** 日志丢失是功能性缺陷。

**修复方案**：
```lua
local LEVEL_MAP = {
    [Yar.Log.DEBUG] = ngx.DEBUG,
    [Yar.Log.INFO]  = ngx.INFO,
    [Yar.Log.WARN]  = ngx.WARN,
    [Yar.Log.ERROR] = ngx.ERR,
}
Yar.Log.set_writer(function(lvl, msg)
    ngx.log(LEVEL_MAP[lvl] or ngx.ERR, "[yar] " .. msg)
end)
```

---

### P1-2：log_level 配置

**现状**：resty-yar 无 `log_level` 配置项，lua-yar 默认 `WARN` 级别。

**lua-yar 0.1.0 实际**：`Log.set_level(lvl)` 运行时控制级别。

**业界对比**：lua-resty-redis/http 无日志级别（全走 `ngx.ERR`）。Kong 有 `log_level` 配置。对适配层来说，暴露 lua-yar 的级别控制是低成本适配。

**结论：应该做。** 低成本，用户可按需开 DEBUG 排障。

**修复方案**：`setup()` 中读 `opts.log_level`，映射到 `Yar.Log.set_level()`。

---

### P1-3：TcpServer 延迟加载

**现状**：`init.lua` 第 27 行模块级 `require("yar.server.tcp")`，纯 HTTP 场景也加载 TCP 模块。

**lua-yar 0.1.0 实际**：`yar/init.lua` 注释明确 "HttpServer/TcpServer 按需加载"，但 resty-yar 强制加载了 TcpServer。

**业界对比**：lua-resty-redis/http 不涉及多传输模式。Kong 的 `require` 是 lazy 的（按插件加载）。OpenResty 最佳实践是可选模块延迟 require。

**结论：应该做。** 纯 HTTP 场景不需要 TCP 模块，减少内存和启动时间。

**修复方案**：
```lua
-- 删除模块级 require，改为 get_tcp_server() 内 lazy require
function _M.get_tcp_server()
    if not _tcp_server then
        local TcpServer = require("yar.server.tcp")
        _tcp_server = TcpServer.new(...)
    end
    return _tcp_server
end
```

---

### P1-4：max_body_len 透传

**现状**：resty-yar 无 `max_body_len` 配置，不透传给客户端传输层。

**lua-yar 0.1.0 实际**：
- `DEFAULT_OPTIONS.transport.max_body_len = nil`（默认用 Framing 的 `DEFAULT_MAX_BODY_LEN`）
- `FLAT_KEY_MAP` 包含 `max_body_len = "transport"`
- TCP 传输层 `Framing.check_body_len(data, max_body_len)` 在发送前校验
- 服务端 `Framing.receive_message(sock, max_body_len)` 在接收时校验

**业界对比**：nginx 有 `client_max_body_size`。gRPC 有 `max_receive_message_length`。lua-resty-http 无此限制（由 HTTP 层 Content-Length 控制）。Kong 有 `nginx_http_client_max_body_size`。

**结论：应该做。** 防止恶意超大请求体耗尽内存，安全加固。

**修复方案**：`default_config` 加 `max_body_len = 10 * 1024 * 1024`，`new_client()` 透传到 `transport.max_body_len`。服务端 TCP handler 也应设置。

---

### P1-5：HTTP handler 热路径缓存

**现状**：`server/http.lua` 每请求调 `init.get_http_server()`，函数内部检查 `_server` 非空后返回。虽然逻辑简单，但每请求一次函数调用 + 条件检查。

**lua-yar 0.1.0 实际**：不涉及，这是 resty-yar 适配层自身的优化。

**业界对比**：lua-resty-redis/http 在模块级缓存。Kong 在 `init_by_lua` 阶段缓存到模块级 upvalue。

**结论：可以做。** 收益极小（一次条件检查），但符合最佳实践，改动成本极低。

**修复方案**：模块级 `local _server` 缓存，`serve()` 中直接用。

---

### P2-1：Schema 配置校验

**现状**：resty-yar `setup()` 直接 `pairs(opts)` 合并，无校验。未知键静默写入 `config` 表。

**lua-yar 0.1.0 实际**：lua-yar 自身无 schema 校验（`set_options` 是 `deep_merge`，任意键都接受）。

**业界对比**：Kong 有完整 schema 系统（`kong.db.schema`）。lua-resty-redis/http 无 schema（配置项少，直接用）。OpenResty 生态中，配置项少的库不做 schema 是常态。

**结论：暂不做。** resty-yar 配置项少（~10 个），适配层加 schema 校验收益低、维护成本高。如果用户传错键，lua-yar 的 `deep_merge` 会静默忽略（不影响功能，只是参数不生效）。Kong 的 schema 系统适合配置项多的网关，不适合薄适配层。

**替代方案**：在 `setup()` 中对关键配置项做简单类型检查（`tonumber()` 校验超时值），不引入完整 schema 框架。

---

### P2-2：客户端 hooks（on_request/on_response）

**现状**：resty-yar 未配置默认 hooks。

**lua-yar 0.1.0 实际**：`Client:call()` 通过 `self.options.hooks` 支持 `on_request(method, params)` 和 `on_response(method, retval, err)` 回调。hook 出错时 pcall 降级为 `Log.warn`，不影响主流程。

**业界对比**：gRPC-Go 有 interceptor 链。Kong 有 plugin 链。但这些都是框架级功能。lua-resty-redis/http 无 hooks（纯客户端库）。OpenTelemetry 的 SDK 通过 instrumentation 库注入，不在核心库。

**结论：暂不做默认 hooks。** 理由：
1. hooks 是可选的，用户可自行配置 `opts.hooks = { on_request = fn, on_response = fn }`
2. 适配层不应强加默认行为，应保持透明
3. 如果要做可观测性，更好的方式是独立的 `resty.yar.observability` 模块，用户按需 require

**替代方案**：文档示例展示如何配置 hooks，而非代码默认注入。

---

### P2-3：服务端 hooks

**现状**：resty-yar 未配置服务端 hooks。

**lua-yar 0.1.0 实际**：`Server:handle_message()` 通过 `self.options.hooks` 支持 `on_request`/`on_response`。`TcpServer:handle_connection()` 透传到 `self.core:handle_message()`。

**结论：暂不做。** 理由同 P2-2。适配层保持透明，用户按需配置。

---

### P2-4：结构化 JSON 错误响应

**现状**：`server/http.lua` 错误路径返回 `ngx.say("internal error")` 等纯文本。

**lua-yar 0.1.0 实际**：Yar 协议的响应是二进制帧（packager 编码），不是 JSON。错误响应在协议层内处理（`Response:set_error()`），HTTP 层的错误（空 body、405、500 panic）是 HTTP 语义层面的，与 Yar 协议无关。

**业界对比**：RFC 7807 Problem Details 是 HTTP API 错误的标准格式。Kong 返回 JSON 错误。但 Yar 协议客户端期望的是二进制 Yar 响应，不是 JSON 错误。PHP Yar 的 HTTP 错误页也是纯文本。

**结论：暂不做。** 理由：
1. Yar 客户端收到非二进制响应会解析失败，无论纯文本还是 JSON
2. 改为 JSON 对 Yar 客户端无帮助，对人类调试有微小改善
3. 是 BREAKING CHANGE（响应格式变化），收益不抵成本
4. 当前纯文本错误响应已经足够（HTTP 状态码 + 简短描述）

**替代方案**：保持纯文本，但确保 HTTP 状态码正确（400/405/500）。日志中记录详细错误。

---

### P2-5：request ID 透传

**现状**：resty-yar 无 request ID。

**lua-yar 0.1.0 实际**：Yar 协议 header 有 `id` 字段（请求 ID），由 `Request.new()` 设置。`handle_message` 在响应中回传相同 `id`。但这是协议级 ID，不是日志追踪 ID。

**业界对比**：gRPC 用 metadata 传 trace ID。Kong 用 `X-Request-Id` header。OpenTelemetry 用 trace context。但这些是分布式追踪场景，resty-yar 作为适配层不需要自建追踪。

**结论：暂不做。** 理由：
1. Yar 协议已有 `id` 字段，可用于请求-响应匹配
2. 分布式追踪应通过 OpenTelemetry instrumentation 实现，不在适配层
3. 如果用户需要日志关联，可在 hooks 中输出 Yar 协议的 `id` 字段

---

### P3-1：cjson 加速器

**现状**：resty-yar 用 lua-yar 默认的纯 Lua JSON packager。

**lua-yar 0.1.0 实际**：`Packager.from_codec(name, pack_fn, unpack_fn)` 可注册 cjson 适配器。`Packager.register("JSON", codec)` 替换默认实现。

**业界对比**：lua-resty-redis/http 不涉及序列化。lua-cjson 是 OpenResty 生态标配（FFI 加速，比纯 Lua 快 10-50x）。Kong 内部用 cjson。

**结论：可以做。** 低成本高性能收益。但需注意 PHP Yar 的 JSON 编码可能与 cjson 有细微差异（如数字精度、Unicode 转义），应作为可选项。

**修复方案**：`opts.use_cjson = true` 时注册 cjson 加速器。

---

### P3-2：cmsgpack 加速器

**结论：可以做。** 同 P3-1，可选注册 cmsgpack。

---

### P3-3：lua-resty-http provider 注入

**现状**：resty-yar 用 lua-yar 默认的手动 HTTP 实现（cosocket 拼 HTTP 报文）。

**lua-yar 0.1.0 实际**：`Client.set_http_provider(fn)` 支持注入第三方 HTTP 库。`Http:send()` 优先用实例级 provider，其次类级，最后回退手动实现。provider 接收 `(url, opts)` 返回 `(body, err)`。

**业界对比**：lua-resty-http 是 OpenResty 生态最成熟的 HTTP 客户端，支持 HTTPS、连接池、流式读取。手动 HTTP 实现不支持 HTTP/2、复杂重定向等。

**结论：可以做。** 但优先级低。手动实现已覆盖 Yar RPC 的基本需求（POST + 二进制 body）。lua-resty-http 的优势在 HTTPS 场景（更完善的 TLS 支持）和复杂 HTTP 场景。

**修复方案**：`opts.use_resty_http = true` 时注入 lua-resty-http provider。

---

### P3-4：性能基准测试

**结论：可以做。** benchmark 数据有助于量化优化效果，但非功能性需求。

---

## 三、新发现：ssl_verify 配置缺失

### 现状

resty-yar 不暴露 `ssl_verify` 配置。

### lua-yar 0.1.0 实际

- `DEFAULT_OPTIONS.transport.ssl_verify = true`（默认开启证书验证）
- `FLAT_KEY_MAP` 包含 `ssl_verify = "transport"`
- HTTP 传输层 `manual_request()` 第 106 行：`local ssl_verify = transport_opts.ssl_verify ~= false`
- HTTPS 请求时 `sock:sslhandshake(nil, host, ssl_verify)` 使用该值
- 注入 lua-resty-http provider 时也透传 `ssl_verify` 字段

### 影响

resty-yar 的 `new_client()` 未传 `ssl_verify`，lua-yar 使用默认值 `true`（安全默认）。用户无法通过 resty-yar 配置关闭证书验证（自签证书场景需要）。

### 业界对比

- lua-resty-http：`ssl_verify = true` 默认开启，可配 `ssl_verify = false`
- luasec：默认验证证书
- Kong：`lua_ssl_verify_certificate = on`（nginx 指令）
- OpenResty cosocket：`sslhandshake(nil, host, verify)` 第三参数控制

### 结论：应该做。

安全默认已正确（`true`），但应暴露配置项让用户在自签证书场景可关闭。低成本适配。

### 修复方案

```lua
-- default_config 加
ssl_verify = true,  -- HTTPS 证书验证（生产环境必须开启）

-- new_client() 透传
client:set_options({
    transport = {
        ssl_verify = opts.ssl_verify ~= false and config.ssl_verify,
        ...
    },
})
```

---

## 四、新发现：resolve 和 proxy 配置缺失

### lua-yar 0.1.0 实际

- `DEFAULT_OPTIONS.transport.resolve = ""`（自定义 DNS 解析）
- `DEFAULT_OPTIONS.transport.proxy = ""`（HTTP 代理地址）
- TCP 传输层用 `Resolve.apply_resolve(host, port, resolve)` 实现自定义 IP
- HTTP 传输层用 `parse_proxy()` 支持代理

### 影响

resty-yar 不暴露 `resolve` 和 `proxy` 配置。用户无法通过 resty-yar 配置 DNS 自定义解析或 HTTP 代理。

### 结论：可以做。

这两个是 lua-yar 已有的能力，适配层透传即可。但使用场景较少（大多数 OpenResty 部署用 nginx 自身的 DNS/代理），优先级低。

### 修复方案

`default_config` 加 `resolve` 和 `proxy` 字段，`new_client()` 透传。

---

## 五、新发现：headers 配置缺失

### lua-yar 0.1.0 实际

- `DEFAULT_OPTIONS.transport.headers = {}`（自定义 HTTP 头）
- HTTP 传输层支持大小写不敏感的头覆盖

### 影响

resty-yar 不暴露 `headers` 配置。用户无法通过 resty-yar 添加自定义 HTTP 头（如认证 token、自定义 User-Agent）。

### 结论：应该做。

低成本透传，用户可能需要添加认证头等。

### 修复方案

`new_client()` 透传 `opts.headers` 到 `transport.headers`。

---

## 六、OpenResty 多阶段加载评估

### 6.1 当前阶段利用

| 阶段 | resty-yar 使用 | lua-yar 0.1.0 需求 | 差距 |
|------|---------------|-------------------|------|
| `init_by_lua_block` | `setup()` 注入 cosocket + 创建实例 | Log.set_writer 注入 | **缺 Log writer 注入** |
| `init_worker_by_lua_block` | `init_worker()` 执行用户回调 | 无额外需求 | 无 |
| `content_by_lua_block` | `serve()` 处理请求 | 无 | 无 |
| `ssl_certificate_by_lua_block` | 未使用 | 不适用 | 无 |
| `log_by_lua_block` | 未使用 | 可做 metrics | 暂不需要 |

### 6.2 Kong 多阶段参考

Kong 利用 OpenResty 全部生命周期阶段：
- `init`：加载配置、初始化 DB、注册插件
- `init_worker`：worker 事件总线、健康检查启动、DNS 初始化
- `ssl_certificate`：SNI 证书选择
- `rewrite/access/header_filter/body_filter/log`：请求生命周期全阶段插件执行
- `balancer`：上游负载均衡

resty-yar 作为适配层，只需要 `init`（注入）+ `init_worker`（回调）+ `content`（处理）。Kong 的其他阶段对 RPC 适配层无意义。

### 6.3 结论

resty-yar 的阶段利用基本正确，唯一差距是 `init_by_lua` 阶段缺少 `Log.set_writer()` 注入（P1-1 已覆盖）。无需引入更多阶段。

---

## 七、综合评测矩阵

| 编号 | 提案 | 优先级 | 评测结论 | 理由 |
|------|------|--------|---------|------|
| P0-1 | keepalive 参数路由 | P0 | **必须修复** | Bug 确认，参数被静默忽略 |
| P0-2 | nil 返回检查 | P0 | **必须修复** | Bug 确认，静默空响应 |
| P0-3 | cosocket 验证 | P0 | **必须做** | 验证 P0-1 修复效果 |
| P1-1 | ngx.log writer | P1 | **必须做** | 日志丢失是功能性缺陷 |
| P1-2 | log_level 配置 | P1 | **应该做** | 低成本，排障需要 |
| P1-3 | TcpServer 延迟加载 | P1 | **应该做** | 减少不必要加载 |
| P1-4 | max_body_len | P1 | **应该做** | 安全加固 |
| P1-5 | 热路径缓存 | P1 | **可以做** | 收益极小但成本极低 |
| P2-1 | Schema 校验 | P2 | **暂不做** | 适配层配置项少，收益低 |
| P2-2 | 客户端 hooks | P2 | **暂不做** | 适配层应保持透明 |
| P2-3 | 服务端 hooks | P2 | **暂不做** | 同 P2-2 |
| P2-4 | 结构化错误 | P2 | **暂不做** | Yar 客户端不识别 JSON |
| P2-5 | request ID | P2 | **暂不做** | 协议已有 id，追踪靠 OTel |
| P3-1 | cjson 加速 | P3 | **可以做** | 高性能收益，可选 |
| P3-2 | cmsgpack 加速 | P3 | **可以做** | 同 P3-1 |
| P3-3 | lua-resty-http | P3 | **可以做** | HTTPS 场景有价值 |
| P3-4 | benchmark | P3 | **可以做** | 非功能性 |
| **新** | ssl_verify 配置 | **P1** | **应该做** | 安全默认已对，需暴露配置 |
| **新** | resolve/proxy 配置 | P3 | **可以做** | 场景少但低成本透传 |
| **新** | headers 配置 | P1 | **应该做** | 用户可能需要认证头 |

---

## 八、修订后的实施计划

### 第一批：P0 Bug 修复（立即）

1. **keepalive 参数路由**：改 `new_client()` 用嵌套 `transport.keepalive` 结构
2. **nil 返回检查**：`server/http.lua` pcall 后增加 `if not resp then` 分支
3. **验证测试**：确认 `sock:setkeepalive(idle_timeout, pool_size)` 收到正确值

### 第二批：P1 基础适配（紧随 P0）

4. **ngx.log writer**：`setup()` 中注入 `Yar.Log.set_writer(fn)`
5. **log_level**：`setup()` 中支持 `opts.log_level`
6. **TcpServer 延迟加载**：删除模块级 require，`get_tcp_server()` 内 lazy require
7. **max_body_len**：`default_config` 加配置，`new_client()` 透传
8. **ssl_verify**：`default_config` 加配置，`new_client()` 透传（默认 `true`）
9. **headers**：`new_client()` 透传 `opts.headers`
10. **热路径缓存**：`server/http.lua` 模块级缓存 `_server`

### 第三批：P3 可选优化（按需）

11. **cjson 加速器**：`opts.use_cjson` 时注册
12. **cmsgpack 加速器**：`opts.use_cmsgpack` 时注册
13. **lua-resty-http provider**：`opts.use_resty_http` 时注入
14. **resolve/proxy 透传**：`new_client()` 透传
15. **benchmark**：编写性能对比测试

### 删除的提案

以下提案从原 OpenSpec change 中移除或降级：

| 提案 | 原优先级 | 新结论 | 理由 |
|------|---------|--------|------|
| Schema 校验 | P2 | 不做 | 适配层配置项少，收益低 |
| 客户端 hooks | P2 | 不做 | 适配层应透明，用户自行配置 |
| 服务端 hooks | P2 | 不做 | 同上 |
| 结构化 JSON 错误 | P2 | 不做 | Yar 客户端不识别 JSON |
| request ID | P2 | 不做 | 协议已有 id，追踪靠 OTel |

### 新增的提案

| 提案 | 优先级 | 理由 |
|------|--------|------|
| ssl_verify 配置 | P1 | lua-yar 0.1.0 新增字段，需暴露配置 |
| headers 配置 | P1 | 用户可能需要自定义 HTTP 头 |
| resolve/proxy 配置 | P3 | lua-yar 已有能力，低成本透传 |

---

## 九、总结

### 核心判断

resty-yar 作为**薄适配层**，其优化应聚焦于：

1. **正确性**（P0）：修复参数路由 Bug、nil 返回 Bug — 必须做
2. **适配完整性**（P1）：将 lua-yar 0.1.0 的能力正确透传 — 应该做
3. **性能优化**（P3）：cjson/cmsgpack 加速 — 可以做

不应做的：

- **不造框架**：Schema 校验、hooks、结构化错误属于框架级功能，适配层应保持极薄
- **不重复造轮子**：追踪靠 OpenTelemetry，限流靠 lua-resty-limit-traffic，不在适配层实现
- **不强加行为**：默认 hooks、默认错误格式会改变用户预期，适配层应透明

### Kong 模式适用结论

Kong 的 14 个工程模式中，resty-yar 已具备 5 个（PDK 抽象、连接池、DNS 解析、优雅关闭、生命周期阶段），不适用 7 个（健康检查、事件总线、Admin API、声明式配置、插件架构、限流熔断、服务发现），可考虑 2 个（轻量 schema、结构化错误 — 但本次评测结论均为暂不做）。

**核心洞察**：Kong 模式的价值在于"参考而非照搬"。resty-yar 的三层分离架构（lua-yar 协议 → resty-yar 适配 → 用户业务）本身就是比 Kong 更彻底的解耦——Kong 的协议层和传输层在同一个代码库中，而 resty-yar 将协议层完全外包给 lua-yar。这种架构下，适配层的最佳策略是"薄而正确"，而非"大而全"。

### 下一步

建议更新 OpenSpec change `adapt-lua-yar-011`：
1. 移除 P2 的 5 个提案（schema/hooks/结构化错误/request ID）
2. 新增 3 个提案（ssl_verify/headers/resolve+proxy）
3. 调整 tasks.md 反映修订后的实施计划
4. 确认后开始 P0 修复实现

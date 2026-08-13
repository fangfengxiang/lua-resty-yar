# lua-resty-yar 优化计划：适配 lua-yar 0.1.0 + OpenResty 分段加载

> 编写时间：2026-07-16 | 底层依赖：lua-yar 0.0.1 → 0.1.0 重大更新
> 目标：适配底层新能力、修复已知缺陷、利用 OpenResty 分段加载优化性能
> 关联文档：`dependency-audit.md`（依赖审计）、`kong-inspired-optimization.md`（Kong 启发分析）

---

## 一、lua-yar 0.1.0 更新摘要

lua-yar 从 0.0.1 升级到 0.1.0，引入了多项重大变更。下表汇总所有变更及其对 resty-yar 的影响：

### 1.1 变更全景

| # | 变更项 | 影响文件 | 对 resty-yar 的影响 | 优先级 |
|---|--------|---------|---------------------|--------|
| 1 | **Socket.release 变参修复** | `transport/socket.lua` | cosocket 连接池参数现在能正确透传 | P0（已修复，resty-yar 侧需适配） |
| 2 | **Client 嵌套选项结构** | `client.lua` | `keepalive_idle`/`pool_size` 扁平键不在 `FLAT_KEY_MAP` 中，被静默忽略 | **P0 Bug** |
| 3 | **Error 模块** | `error.lua`（新增） | 结构化错误对象，可程序化匹配 `.code`/`.message` | P1 |
| 4 | **Log 模块** | `log.lua`（新增） | 可注入 `ngx.log` writer，统一日志输出 | P1 |
| 5 | **Hooks 系统** | `client.lua`/`server/init.lua` | `on_request`/`on_response` 钩子，可做观测/追踪 | P2 |
| 6 | **handle_message 返回签名变更** | `server/init.lua` | 渲染失败时返回 `nil, err`，resty-yar 的 pcall 包装需检查 | **P1 Bug** |
| 7 | **Client.set_http_provider** | `client.lua`/`transport/http.lua` | 可注入 lua-resty-http 替代手动 HTTP 实现 | P2 |
| 8 | **Packager.from_codec** | `packager/packager.lua` | 可用 cjson/cmsgpack C 扩展加速序列化 | P3 |
| 9 | **Framing.check_body_len** | `protocol/framing.lua` | 发送前 body 长度校验，防内存耗尽 | P2 |
| 10 | **max_body_len 配置** | `transport/tcp.lua` | 可配置最大 body 长度 | P2 |
| 11 | **deep_copy / deep_merge** | `client.lua` | Kong 风格递归合并，选项结构更健壮 | 已内部处理 |
| 12 | **FLAT_KEY_MAP 向后兼容** | `client.lua` | 扁平键路由到嵌套组，但部分键未覆盖 | P0（见 §2.1） |

### 1.2 关键代码变更

#### Socket.release 变参修复（P0 已修复）

```lua
-- 修复前（0.0.1）：无参数，pool_size/idle_timeout 被静默忽略
function M.release(sock)
    if sock.setkeepalive then
        return sock:setkeepalive()  -- ← 无参数！
    end
    return sock:close()
end

-- 修复后（0.1.0）：变参透传 setkeepalive(idle_timeout, pool_size)
function M.release(sock, ...)
    if sock.setkeepalive then
        return sock:setkeepalive(...)
    end
    return sock:close()
end
```

调用方（`transport/http.lua`、`transport/tcp.lua`）已更新为：
```lua
local ka = transport_opts.keepalive or {}
Socket.release(sock, ka.idle_timeout, ka.pool_size)
```

#### Client 嵌套选项结构

```lua
local DEFAULT_OPTIONS = {
    protocol = {
        packager = Packager.JSON,
        provider = "",
        token    = "",
    },
    transport = {
        timeout         = 5000,
        connect_timeout = 1000,
        persistent      = false,
        headers          = {},
        proxy            = "",
        resolve          = "",
        max_body_len     = nil,
        http_provider    = nil,
        keepalive        = {
            pool_size     = 64,
            idle_timeout  = 60000,
        },
    },
}
```

#### handle_message 返回签名变更

```lua
-- 0.0.1：总是返回 string（即使渲染失败也返回错误帧）
-- 0.1.0：渲染失败时返回 nil, err
function Server:handle_message(data)
    -- ...
    local ok, rendered = pcall(Protocol.render, response, packager)
    if not ok then
        return nil, "render error: " .. tostring(rendered)  -- ← 新增 nil 返回
    end
    return rendered
end
```

---

## 二、必须修复的缺陷（P0/P1）

### 2.1 P0 Bug：keepalive 参数被静默忽略

**根因**：resty-yar 的 `new_client()` 使用扁平键 `keepalive_idle` 和 `pool_size` 传递连接池参数：

```lua
-- lib/resty/yar/init.lua:155-161（当前代码）
client:set_options({
    connect_timeout  = opts.connect_timeout  or config.connect_timeout,
    timeout          = opts.timeout          or config.client_timeout,
    packager         = opts.packager         or config.packager,
    keepalive_idle   = opts.keepalive_idle   or config.keepalive_idle,  -- ← 不在 FLAT_KEY_MAP
    pool_size         = opts.pool_size         or config.pool_size,      -- ← 不在 FLAT_KEY_MAP
})
```

lua-yar 0.1.0 的 `FLAT_KEY_MAP` 只包含以下键的路由：

| 扁平键 | 路由到 | 说明 |
|--------|--------|------|
| `packager` | `protocol` | 已覆盖 |
| `provider` | `protocol` | 已覆盖 |
| `token` | `protocol` | 已覆盖 |
| `timeout` | `transport` | 已覆盖 |
| `connect_timeout` | `transport` | 已覆盖 |
| `persistent` | `transport` | 已覆盖 |
| `headers` | `transport` | 已覆盖 |
| `keepalive` | `transport` | 已覆盖（但 resty-yar 未用此键） |
| `proxy` | `transport` | 已覆盖 |
| `resolve` | `transport` | 已覆盖 |
| `max_body_len` | `transport` | 已覆盖 |
| `http_provider` | `transport` | 已覆盖 |
| **`keepalive_idle`** | **无** | 不在映射中，被当作未知键写入 `options` 顶层 |
| **`pool_size`** | **无** | 不在映射中，被当作未知键写入 `options` 顶层 |

`keepalive_idle` 和 `pool_size` 不在 `FLAT_KEY_MAP` 中，`set_options` 将它们当作未知键直接写入 `self.options` 顶层，而非 `transport.keepalive` 子组。传输层从 `transport_opts.keepalive.idle_timeout` 和 `transport_opts.keepalive.pool_size` 读取，结果读到的是 `nil`，最终 `Socket.release(sock, nil, nil)` 调用 `sock:setkeepalive()` 无参数版本——cosocket 使用默认池参数，用户配置完全被忽略。

**影响**：连接池配置（`pool_size=30`、`keepalive_idle=60000`）完全不生效。cosocket 使用 OpenResty 默认值（pool_size=30, idle_timeout=60000），巧合与 resty-yar 默认值接近，但用户自定义值不生效。

**修复方案**：改用嵌套结构传递 keepalive 参数：

```lua
-- 修复后
client:set_options({
    connect_timeout = opts.connect_timeout or config.connect_timeout,
    timeout         = opts.timeout         or config.client_timeout,
    packager        = opts.packager        or config.packager,
    persistent      = opts.persistent or false,
    transport       = {
        connect_timeout = opts.connect_timeout or config.connect_timeout,
        timeout         = opts.timeout         or config.client_timeout,
        keepalive       = {
            idle_timeout = opts.keepalive_idle or config.keepalive_idle,
            pool_size    = opts.pool_size       or config.pool_size,
        },
        max_body_len   = opts.max_body_len     or config.max_body_len,
    },
    protocol        = {
        packager = opts.packager or config.packager,
    },
})
```

### 2.2 P1 Bug：handle_message 返回 nil 未处理

**根因**：resty-yar 的 HTTP handler 用 pcall 包装 `handle_message`，但未检查返回值为 `nil` 的情况：

```lua
-- lib/resty/yar/server/http.lua:82-92（当前代码）
local ok, resp = pcall(server.handle_message, server, data)
if not ok then
    ngx.log(ngx.ERR, "[resty.yar http] handle_message error: " .. tostring(resp))
    ngx.status = HTTP_INTERNAL_SERVER_ERROR
    ngx.header["Content-Type"] = "text/plain"
    ngx.say("internal error")
    return
end

-- ← 缺少 resp == nil 检查！
ngx.header["Content-Type"] = "application/octet-stream"
ngx.print(resp)  -- ← resp 为 nil 时 ngx.print(nil) 可能报错或输出空
```

lua-yar 0.1.0 中 `handle_message` 在 `Protocol.render` 失败时返回 `nil, err`。pcall 捕获的是异常（`ok=false`），而 `nil` 返回值是正常返回（`ok=true, resp=nil`），pcall 不会将其视为错误。

**影响**：渲染失败时 `ngx.print(nil)` 行为未定义，可能导致 500 错误或空响应，客户端无法获得错误信息。

**修复方案**：增加 `resp == nil` 检查：

```lua
local ok, resp_or_err = pcall(server.handle_message, server, data)
if not ok then
    ngx.log(ngx.ERR, "[resty.yar http] handle_message panic: " .. tostring(resp_or_err))
    ngx.status = HTTP_INTERNAL_SERVER_ERROR
    ngx.header["Content-Type"] = "text/plain"
    ngx.say("internal error")
    return
end

-- handle_message 返回 nil, err 表示渲染失败（非异常）
if not resp_or_err then
    ngx.log(ngx.ERR, "[resty.yar http] handle_message render failure")
    ngx.status = HTTP_INTERNAL_SERVER_ERROR
    ngx.header["Content-Type"] = "text/plain"
    ngx.say("protocol error")
    return
end

ngx.header["Content-Type"] = "application/octet-stream"
ngx.print(resp_or_err)
```

TCP handler 同理（`server/tcp.lua:38-41`），但 TCP 的 `handle_connection` 内部已检查 `resp == nil` 并 break，resty-yar 的 pcall 包装的是 `handle_connection` 而非 `handle_message`，所以 TCP 侧影响较小。但应确认 `handle_connection` 的 pcall 不会吞掉 `nil` 返回。

---

## 三、新能力适配（P1-P2）

### 3.1 注入 ngx.log 到 Yar.Log（P1）

lua-yar 0.1.0 新增 `Log` 模块，默认 writer 为 `print()`。OpenResty 环境下 `print()` 输出到 `ngx.stdout`（响应体），而非 `ngx.log`（错误日志）。需在 `setup()` 中注入 `ngx.log` writer：

```lua
-- lib/resty/yar/init.lua setup() 中新增
local Log = Yar.Log

-- 映射 lua-yar 日志级别到 ngx 级别
local NGX_LEVEL = {
    [Log.DEBUG] = ngx.DEBUG,
    [Log.INFO]  = ngx.INFO,
    [Log.WARN]  = ngx.WARN,
    [Log.ERROR] = ngx.ERR,
}

Log.set_writer(function(lvl, msg)
    ngx.log(NGX_LEVEL[lvl] or ngx.ERR, "[yar] " .. msg)
end)

-- 日志级别可配置
if opts.log_level then
    Log.set_level(opts.log_level)
end
```

**收益**：lua-yar 内部所有 `Log.debug`/`Log.warn`/`Log.error` 调用将正确输出到 nginx error log，而非污染响应体。

### 3.2 利用 Hooks 系统做可观测性（P2）

lua-yar 0.1.0 在 Client 和 Server 两侧均支持 hooks：

```lua
-- 客户端 hooks
client:set_options({
    hooks = {
        on_request  = function(method, params)  -- 请求发出前
            ngx.update_time()
            ngx.ctx.yar_call_start = ngx.now()
            ngx.ctx.yar_method = method
        end,
        on_response = function(method, retval, err)  -- 响应接收后
            ngx.update_time()
            local elapsed = ngx.now() - (ngx.ctx.yar_call_start or 0)
            if err then
                ngx.log(ngx.WARN, "[yar] " .. method .. " FAILED " ..
                    tostring(err.code) .. " in " .. elapsed .. "s")
            else
                ngx.log(ngx.INFO, "[yar] " .. method .. " ok in " .. elapsed .. "s")
            end
        end,
    },
})

-- 服务端 hooks
server:set_options({
    hooks = {
        on_request  = function(method, params)
            ngx.ctx.yar_req_start = ngx.now()
        end,
        on_response = function(method, retval, err)
            ngx.update_time()
            local elapsed = ngx.now() - (ngx.ctx.yar_req_start or 0)
            -- 可对接 Prometheus 指标 / Zipkin span
        end,
    },
})
```

**收益**：零侵入实现请求级追踪、延迟度量、错误率统计。hooks 在 pcall 保护下运行，不影响主流程。

### 3.3 HTTP Provider 注入（P2）

lua-yar 0.1.0 的 `Client.set_http_provider(provider)` 允许注入第三方 HTTP 库，替代默认手动 HTTP 实现。OpenResty 环境下可注入 `lua-resty-http`：

```lua
-- lib/resty/yar/init.lua setup() 中新增
local ok_http, http = pcall(require, "resty.http")
if ok_http and opts.use_resty_http then
    local function http_provider(url, opts)
        local httpc = http.new()
        local res, err = httpc:request_uri(url, {
            method  = "POST",
            body    = opts.body,
            headers = opts.headers,
            timeout = opts.timeout,
        })
        if not res then
            return nil, err
        end
        if res.status ~= 200 then
            return nil, "http status: " .. res.status
        end
        return res.body
    end
    Client.set_http_provider(http_provider)
end
```

**收益**：
- `lua-resty-http` 支持 HTTP/1.1 连接池、chunked transfer、SSL 等完整 HTTP 语义
- 替代手动 `manual_request` 的手写 HTTP 解析，更健壮
- 连接池由 `lua-resty-http` 管理，与 cosocket 池独立

**注意**：默认不启用（`opts.use_resty_http = false`），仅在用户显式开启时注入。手动 HTTP 实现已满足基本需求，避免引入硬依赖。

### 3.4 Packager.from_codec 加速序列化（P3）

OpenResty 内置 `cjson` 和 `cmsgpack` C 扩展，比纯 Lua 实现快 5-10 倍。可通过 `Packager.from_codec` 注册为 YAR packager：

```lua
-- lib/resty/yar/init.lua setup() 中新增
local Packager = Yar.Packager

-- 注册 cjson 加速器（名称保持 "JSON" 以兼容协议头）
local ok_cjson, cjson = pcall(require, "cjson")
if ok_cjson and opts.use_cjson then
    Packager.register("JSON", {
        name   = "JSON",
        pack   = cjson.encode,
        unpack = cjson.decode,
    })
end

-- 注册 cmsgpack 加速器
local ok_cmsgpack, cmsgpack = pcall(require, "cmsgpack")
if ok_cmsgpack and opts.use_cmsgpack then
    Packager.register("MSGPACK", {
        name   = "MSGPACK",
        pack   = cmsgpack.pack,
        unpack = cmsgpack.unpack,
    })
end
```

**收益**：序列化/反序列化性能提升 5-10x，对大 payload 效果显著。

**注意**：cjson 的 `encode` 默认输出空格分隔符（`{"a": 1}`），需配置 `cjson.encode_sparse_array` 和 `cjson.encode_keep_buffer` 以对齐 YAR 协议。需测试兼容性后启用。

### 3.5 max_body_len 配置（P2）

lua-yar 0.1.0 支持配置最大 body 长度，防止恶意大 body 导致内存耗尽：

```lua
-- lib/resty/yar/init.lua default_config 中新增
local default_config = {
    -- ... 现有配置 ...
    max_body_len     = 10 * 1024 * 1024,  -- 10MB，对齐 Framing.DEFAULT_MAX_BODY_LEN
}

-- new_client() 中透传
client:set_options({
    transport = {
        max_body_len = opts.max_body_len or config.max_body_len,
        -- ...
    },
})
```

---

## 四、OpenResty 分段加载优化

### 4.1 当前加载模式分析

当前 resty-yar 的模块加载时序：

```
init_by_lua_block { require("resty.yar").setup() }
  └─ require("resty.yar")               -- 加载 init.lua
       ├─ require("yar")                 -- 加载 lua-yar 主模块
       │    ├─ require("yar.client")     -- Client（含 Transport/Socket/Http/Packager/Protocol/Message）
       │    ├─ require("yar.server")     -- Server core
       │    ├─ require("yar.packager")   -- Packager 工厂
       │    ├─ require("yar.error")      -- Error 模块
       │    └─ require("yar.log")        -- Log 模块
       └─ require("yar.server.tcp")      -- TcpServer（模块级 eager require!）
            └─ require("yar.server")    -- 已缓存，无重复
```

**问题**：`yar.server.tcp` 在模块级别（`init.lua:27`）被 eager require，即使用户只用 HTTP 场景（不需要 TCP stream server），TcpServer 模块也会被加载。

### 4.2 优化方案：延迟加载 TcpServer

```lua
-- lib/resty/yar/init.lua（优化后）

-- 删除模块级 require
-- local TcpServer = require("yar.server.tcp")  -- ← 删除

-- 改为 setup() 内按需加载
local _M = {}
_M.Yar = Yar
_M.VERSION = "0.1.0"

local Server = Yar.Server
local Client = Yar.Client

local _server
local _tcp_server    -- 延迟初始化
local _tcp_server_loaded = false

--- 获取进程级复用的 TcpServer 实例（延迟加载）
function _M.get_tcp_server()
    if not _tcp_server then
        if not _tcp_server_loaded then
            local TcpServer = require("yar.server.tcp")  -- ← 首次调用时加载
            _tcp_server_loaded = true
            local service = _server and _server.service or {}
            _tcp_server = TcpServer.new(service)
            _tcp_server:set_options({
                packager = config.packager,
                timeout  = config.timeout,
            })
        end
        if not _tcp_server then
            error("resty.yar not initialized: call setup() in init_by_lua first")
        end
    end
    return _tcp_server
end
```

**收益**：
- 纯 HTTP 场景（`content_by_lua_block` + `server/http.lua`）不再加载 `yar.server.tcp`、`yar.protocol.framing`（TcpServer 依赖的帧读取模块）
- 减少 init 阶段模块加载数量，加快 master 进程启动
- 按实际使用路径加载，避免无用模块占用内存

### 4.3 init_by_lua vs init_worker_by_lua 职责划分

OpenResty 的两阶段初始化模型：

| 阶段 | 进程 | 可用 API | 适合做什么 |
|------|------|---------|-----------|
| `init_by_lua_block` | master | 无 cosocket（`ngx.socket` 不可用） | 加载模块、创建共享数据结构、注入 provider |
| `init_worker_by_lua_block` | 每个 worker | cosocket 可用 | 运行时连接、定时任务、worker 级初始化 |

**当前 resty-yar 的划分**：

```
init_by_lua_block { require("resty.yar").setup() }
  ├─ 加载 lua-yar 模块                    正确（master 阶段加载模块）
  ├─ Client.set_socket(ngx.socket)        正确（注入 provider 引用，不实际连接）
  ├─ Server.new(service)                  正确（纯数据结构，无 I/O）
  ├─ TcpServer.new(service)               可延迟（见 §4.2）
  └─ 配置合并                              正确

init_worker_by_lua_block { require("resty.yar").init_worker() }
  └─ 执行用户 on_worker_init 回调          正确
```

**优化建议**：在 `init_worker` 中注入 worker 级 hooks 和日志级别：

```lua
function _M.init_worker()
    -- worker 级日志级别可动态调整
    local Log = Yar.Log
    if config.log_level then
        Log.set_level(config.log_level)
    end

    -- worker 级 hooks（可对接 worker 本地缓存、指标收集）
    if _on_worker_init then
        _on_worker_init()
    end
end
```

### 4.4 content_by_lua 热路径最小化

热路径（`content_by_lua_block`）应只做最少工作：

```lua
-- 当前 server/http.lua 的 serve() 已经很精简：
function _M.serve()
    local server = init.get_http_server()  -- O(1) 表查找
    local method = ngx.req.get_method()
    -- ...
    local ok, resp = pcall(server.handle_message, server, data)  -- 纯协议函数，无 I/O
    -- ...
    ngx.print(resp)
end
```

**已优化点**：
- `get_http_server()` 是 O(1) 局部变量返回
- `handle_message` 是纯协议函数，无 I/O、无 yield、reentrant
- Server 实例进程级复用，方法表 memoize

**可进一步优化**：将 `init.get_http_server()` 的返回值缓存在模块级局部变量中：

```lua
-- server/http.lua 模块级缓存
local _server
local function get_server()
    if not _server then
        _server = require("resty.yar").get_http_server()
    end
    return _server
end

function _M.serve()
    local server = get_server()  -- 首次调用后纯局部变量返回
    -- ...
end
```

---

## 五、Kong 启发改进（选择性采纳）

基于 `kong-inspired-optimization.md` 的分析，结合 lua-yar 0.1.0 新能力，以下改进值得采纳：

### 5.1 Schema 配置校验（P1）

**问题**：当前 `setup()` 无配置校验，任意键值直接写入 `config`。

**方案**：轻量级 schema 校验（不引入完整 schema 框架）：

```lua
-- 配置 schema 定义
local config_schema = {
    connect_timeout  = { type = "number", default = 1000,  min = 0, max = 60000 },
    send_timeout     = { type = "number", default = 5000,  min = 0, max = 60000 },
    read_timeout     = { type = "number", default = 5000,  min = 0, max = 60000 },
    keepalive_idle   = { type = "number", default = 60000, min = 0, max = 300000 },
    pool_size        = { type = "number", default = 30,    min = 1, max = 1000 },
    packager         = { type = "string", default = "JSON", enum = {"JSON", "MSGPACK"} },
    timeout          = { type = "number", default = 5000,  min = 0, max = 60000 },
    client_timeout   = { type = "number", default = 3000,  min = 0, max = 60000 },
    max_body_len     = { type = "number", default = 10485760, min = 0, max = 104857600 },
    log_level        = { type = "number", default = 3,    enum = {1, 2, 3, 4} },
}

local function validate_config(opts)
    local validated = {}
    for key, spec in pairs(config_schema) do
        local val = opts[key]
        if val ~= nil then
            if spec.type == "number" then
                val = tonumber(val)
                if not val then
                    error("config." .. key .. " must be a number, got: " .. tostring(opts[key]))
                end
                if spec.min and val < spec.min then
                    error("config." .. key .. " must be >= " .. spec.min .. ", got: " .. val)
                end
                if spec.max and val > spec.max then
                    error("config." .. key .. " must be <= " .. spec.max .. ", got: " .. val)
                end
            elseif spec.type == "string" then
                val = tostring(val)
                if spec.enum then
                    local found = false
                    for _, e in ipairs(spec.enum) do
                        if val == e then found = true break end
                    end
                    if not found then
                        error("config." .. key .. " must be one of: " .. table.concat(spec.enum, ", "))
                    end
                end
            end
            validated[key] = val
        else
            validated[key] = spec.default
        end
    end
    -- 拒绝未知键
    for key, _ in pairs(opts) do
        if key ~= "service" and key ~= "on_worker_init" and not config_schema[key] then
            error("unknown config key: " .. key)
        end
    end
    return validated
end
```

**收益**：拒绝非法配置，避免运行时静默故障。对齐 Kong 的 schema 驱动思想，但保持轻量。

### 5.2 结构化错误响应（P2）

**问题**：当前 HTTP handler 用纯文本返回错误（`ngx.say("internal error")`），客户端无法程序化解析。

**方案**：利用 lua-yar 0.1.0 的 `Error` 模块，返回结构化 JSON 错误：

```lua
-- server/http.lua 中错误响应
local Error = Yar.Error

local function send_error(status, code, message)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    local err = { code = code, message = message }
    ngx.say(cjson.encode(err))
end

-- 在 pcall 失败时
if not ok then
    send_error(HTTP_INTERNAL_SERVER_ERROR, Error.EXCEPTION, tostring(resp_or_err))
    return
end

if not resp_or_err then
    send_error(HTTP_INTERNAL_SERVER_ERROR, Error.PROTOCOL, "render failure")
    return
end
```

**收益**：客户端可按 `err.code` 程序化处理错误，对齐 Kong 的结构化错误响应模式。

### 5.3 请求追踪 ID（P2）

**方案**：利用 hooks 注入请求追踪 ID：

```lua
-- setup() 中配置 server hooks
_server:set_options({
    hooks = {
        on_request = function(method, params)
            local req_id = ngx.var.request_id or ngx.now()
            ngx.ctx.yar_request_id = req_id
            ngx.ctx.yar_method = method
            ngx.ctx.yar_start = ngx.now()
        end,
        on_response = function(method, retval, err)
            ngx.update_time()
            local elapsed = (ngx.now() - (ngx.ctx.yar_start or 0)) * 1000
            local req_id = ngx.ctx.yar_request_id or "-"
            local status = err and ("error:" .. tostring(err.code)) or "ok"
            ngx.log(ngx.INFO, string.format(
                "[yar] req=%s method=%s status=%s elapsed=%dms",
                req_id, method, status, elapsed
            ))
        end,
    },
})
```

**收益**：每个 RPC 调用有可追踪的日志行，支持全链路追踪。

---

## 六、实施优先级矩阵

| 优先级 | 任务 | 复杂度 | 风险 | 预计工时 | 依赖 |
|--------|------|--------|------|---------|------|
| **P0** | 修复 keepalive 参数路由（§2.1） | 低 | 低 | 1h | 无 |
| **P0** | 修复 handle_message nil 返回（§2.2） | 低 | 低 | 1h | 无 |
| **P1** | 注入 ngx.log writer（§3.1） | 低 | 低 | 0.5h | 无 |
| **P1** | Schema 配置校验（§5.1） | 中 | 中 | 2h | 无 |
| **P1** | 延迟加载 TcpServer（§4.2） | 低 | 低 | 0.5h | 无 |
| **P2** | Hooks 可观测性（§3.2） | 中 | 低 | 1h | §3.1 |
| **P2** | max_body_len 配置（§3.5） | 低 | 低 | 0.5h | §2.1 |
| **P2** | 结构化错误响应（§5.2） | 中 | 中 | 1.5h | §2.2 |
| **P2** | 请求追踪 ID（§5.3） | 低 | 低 | 1h | §3.2 |
| **P2** | content_by_lua 热路径缓存（§4.4） | 低 | 低 | 0.5h | 无 |
| **P3** | HTTP Provider 注入（§3.3） | 中 | 中 | 2h | 无 |
| **P3** | Packager.from_codec 加速（§3.4） | 中 | 中 | 2h | 无 |

**总计**：约 14h 工作量，可分 3 个迭代完成。

---

## 七、实施路线图

### 迭代 1：缺陷修复 + 基础适配（P0 + P1 核心）

**目标**：修复已知缺陷，适配 lua-yar 0.1.0 基础新能力。

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 1 | 修复 keepalive 参数路由 | `init.lua` | `new_client()` 改用嵌套 `transport.keepalive` 结构 |
| 2 | 修复 handle_message nil 返回 | `server/http.lua` | 增加 `resp == nil` 检查 |
| 3 | 注入 ngx.log writer | `init.lua` | `setup()` 中调 `Log.set_writer` |
| 4 | 延迟加载 TcpServer | `init.lua` | 删除模块级 require，改为 `get_tcp_server()` 内按需加载 |
| 5 | max_body_len 配置 | `init.lua` | 新增 `max_body_len` 到 `default_config` 并透传 |
| 6 | content_by_lua 热路径缓存 | `server/http.lua` | 缓存 `get_http_server()` 返回值 |

**验收标准**：
- 现有测试全部通过
- 连接池参数 `pool_size`/`keepalive_idle` 在 cosocket 层面生效
- lua-yar 日志输出到 nginx error log 而非响应体
- 纯 HTTP 场景不加载 `yar.server.tcp` 模块

### 迭代 2：可观测性 + 工程化（P1 剩余 + P2）

**目标**：引入配置校验、hooks 可观测性、结构化错误。

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 7 | Schema 配置校验 | `init.lua` | 新增 `config_schema` + `validate_config()` |
| 8 | Hooks 可观测性 | `init.lua` | `setup()` 中配置默认 hooks（日志/追踪） |
| 9 | 结构化错误响应 | `server/http.lua` | 错误返回 JSON `{code, message}` |
| 10 | 请求追踪 ID | `init.lua` | hooks 中生成/透传 request ID |

**验收标准**：
- 非法配置键在 `setup()` 时报错而非静默忽略
- 每个 RPC 调用有结构化日志行（method/status/elapsed）
- HTTP 错误响应为 JSON 格式，含 `code` 字段

### 迭代 3：性能优化（P3，可选）

**目标**：利用 C 扩展和第三方库提升性能。

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| 11 | cjson/cmsgpack 加速 | `init.lua` | `Packager.from_codec` 注册 C 扩展 |
| 12 | lua-resty-http 注入 | `init.lua` | `Client.set_http_provider` 注入 |

**验收标准**：
- cjson 序列化性能基准测提升 5x+
- lua-resty-http 路径功能等价于手动 HTTP 实现
- 所有现有测试通过

---

## 八、代码变更清单

### 8.1 `lib/resty/yar/init.lua`（主要变更）

**变更 1：删除模块级 TcpServer require，改为延迟加载**

```lua
-- 删除第 27 行：
-- local TcpServer = require("yar.server.tcp")

-- 新增延迟加载机制
local _tcp_server
local _tcp_server_loaded = false

function _M.get_tcp_server()
    if not _tcp_server then
        if not _tcp_server_loaded then
            local TcpServer = require("yar.server.tcp")
            _tcp_server_loaded = true
            local service = _server and _server.service or {}
            _tcp_server = TcpServer.new(service)
            _tcp_server:set_options({
                packager = config.packager,
                timeout  = config.timeout,
            })
        end
        if not _tcp_server then
            error("resty.yar not initialized: call setup() in init_by_lua first")
        end
    end
    return _tcp_server
end
```

**变更 2：setup() 中注入 ngx.log writer**

```lua
-- setup() 中新增（在 Client.set_socket 之后）
local Log = Yar.Log
local NGX_LEVEL = {
    [Log.DEBUG] = ngx.DEBUG,
    [Log.INFO]  = ngx.INFO,
    [Log.WARN]  = ngx.WARN,
    [Log.ERROR] = ngx.ERR,
}
Log.set_writer(function(lvl, msg)
    ngx.log(NGX_LEVEL[lvl] or ngx.ERR, "[yar] " .. msg)
end)
if opts.log_level then
    Log.set_level(opts.log_level)
end
```

**变更 3：setup() 中删除 TcpServer 创建（改为延迟）**

```lua
-- 删除 setup() 中的第 4 步：
-- _tcp_server = TcpServer.new(service)
-- _tcp_server:set_options({ packager = config.packager, timeout = config.timeout })
```

**变更 4：new_client() 改用嵌套选项结构**

```lua
function _M.new_client(uri, opts)
    if not _server then
        error("resty.yar not initialized: call setup() in init_by_lua first")
    end
    opts = opts or {}
    local client = Client.new(uri)
    client:set_options({
        persistent = opts.persistent or false,
        protocol   = {
            packager = opts.packager or config.packager,
            provider = opts.provider or "",
            token    = opts.token    or "",
        },
        transport  = {
            connect_timeout = opts.connect_timeout or config.connect_timeout,
            timeout         = opts.timeout         or config.client_timeout,
            max_body_len    = opts.max_body_len    or config.max_body_len,
            keepalive       = {
                idle_timeout = opts.keepalive_idle or config.keepalive_idle,
                pool_size    = opts.pool_size      or config.pool_size,
            },
        },
    })
    return client
end
```

**变更 5：default_config 新增 max_body_len**

```lua
local default_config = {
    connect_timeout  = 1000,
    send_timeout     = 5000,
    read_timeout     = 5000,
    keepalive_idle   = 60000,
    packager         = Yar.PACKAGER_JSON,
    timeout          = 5000,
    client_timeout   = 3000,
    pool_size        = 30,
    max_body_len     = 10 * 1024 * 1024,  -- 新增
}
```

### 8.2 `lib/resty/yar/server/http.lua`（中等变更）

**变更 1：增加 handle_message nil 返回检查**

```lua
-- 替换第 82-92 行
local ok, resp_or_err = pcall(server.handle_message, server, data)
if not ok then
    ngx.log(ngx.ERR, "[resty.yar http] handle_message panic: " .. tostring(resp_or_err))
    ngx.status = HTTP_INTERNAL_SERVER_ERROR
    ngx.header["Content-Type"] = "text/plain"
    ngx.say("internal error")
    return
end

if not resp_or_err then
    ngx.log(ngx.ERR, "[resty.yar http] handle_message render failure")
    ngx.status = HTTP_INTERNAL_SERVER_ERROR
    ngx.header["Content-Type"] = "text/plain"
    ngx.say("protocol error")
    return
end

ngx.header["Content-Type"] = "application/octet-stream"
ngx.print(resp_or_err)
```

**变更 2：模块级缓存 server 实例**

```lua
-- 替换第 37 行
local _server
local function get_server()
    if not _server then
        _server = init.get_http_server()
    end
    return _server
end

function _M.serve()
    local server = get_server()
    -- ...
end
```

### 8.3 `lib/resty/yar/server/tcp.lua`（小变更）

TCP handler 的 pcall 包装的是 `handle_connection`，lua-yar 内部已处理 `resp == nil`。仅需确认 pcall 不会吞掉异常即可。当前代码已正确。

---

## 九、不采纳的优化项

以下来自 Kong 分析的优化项**不推荐**采纳，原因如下：

| # | 优化项 | 不采纳原因 |
|---|--------|-----------|
| 1 | PDK 抽象层 | resty-yar 是薄适配层，直接引用 `ngx` 是设计意图，引入 PDK 增加间接层无收益 |
| 2 | Admin API | RPC 适配层无需运行时管理 API，配置通过 `setup()` 一次性完成 |
| 3 | 多级缓存 | `handle_message` 已是纯内存函数，无外部 I/O 需缓存 |
| 4 | Worker 事件总线 | 无跨 worker 配置变更需求，`init_by_lua` + `init_worker_by_lua` 已足够 |
| 5 | DNS 解析器 | lua-yar 已有 `resolve` 选项支持自定义解析，无需引入额外 DNS 库 |
| 6 | 健康检查 + 熔断 | 属于上游服务管理范畴，resty-yar 定位为协议适配层，不应承担此职责 |
| 7 | 插件架构 | resty-yar 的 hooks 系统已提供足够扩展点，完整插件架构过重 |

---

## 十、总结

本次优化计划基于 lua-yar 0.1.0 的重大更新，核心工作分为三层：

1. **缺陷修复层（P0/P1）**：修复 keepalive 参数路由缺陷和 handle_message 返回签名适配——这两个是功能性 Bug，必须优先修复。

2. **能力适配层（P1/P2）**：将 lua-yar 新增的 Log/Error/Hooks/HTTP Provider/Codec Adapter 等能力接入 resty-yar，使适配层充分利用底层新特性。

3. **性能优化层（P2/P3）**：利用 OpenResty 分段加载减少冷启动开销，利用 C 扩展加速序列化，利用 lua-resty-http 提升 HTTP 客户端质量。

Kong 启发分析中推荐的 Schema 校验和结构化错误响应也纳入计划，但保持轻量实现，不引入完整框架。健康检查、熔断、Admin API、插件架构等重量级模式不采纳——resty-yar 的定位是薄适配层，不是 API 网关。

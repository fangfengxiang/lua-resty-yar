# lua-resty-yar 改造回顾

> 基于 lua-yar 最新代码（Server Facade 统一架构 + 嵌套选项 + 结构化 Error + 注入式 Log + serve_callback 模式），重新评估 lua-resty-yar 的定位、实现功能点与改造计划。

---

## 一、项目定位

### 1.1 生态定位

lua-resty-yar 是 lua-yar（纯 Lua Yar RPC 协议库）的 **OpenResty OPM 适配层**。

lua-yar 定位为纯协议库 / SDK（运行时无关），不绑定任何特定运行时。lua-resty-yar 负责将 lua-yar 接入 OpenResty 运行时，提供：

- **cosocket 注入**：出向 RPC 走 OpenResty 非阻塞 I/O（替代 luasocket 阻塞 I/O）
- **ngx.log 注入**：lua-yar 日志重定向到 nginx error log
- **进程级实例管理**：Server / Client 实例 worker 内复用
- **OpenResty handler 入口**：`content_by_lua_block` 直接调用的 HTTP / TCP stream handler
- **配置桥接**：nginx 配置参数 → lua-yar 嵌套选项结构
- **C 扩展加速**：cjson / cmsgpack 自动注册（替代纯 Lua 编解码）
- **lua-resty-http 注入**：可选的 HTTP 传输 provider

### 1.2 与 lua-yar 的关系

| 维度 | lua-yar | lua-resty-yar |
|------|---------|---------------|
| 运行时 | 运行时无关（纯 Lua SDK） | OpenResty 专属 |
| I/O 模型 | luasocket（阻塞）/ cosocket（注入后非阻塞） | cosocket（OpenResty 原生） |
| 分发方式 | `Server:handle(spec)` / `listen()` + `loop()` | `content_by_lua_block` handler |
| 日志 | `Log.set_writer(fn)` 注入式 | `ngx.log` writer 注入 |
| 安装方式 | LuaRocks | OPM |
| 依赖 | 零外部依赖（纯 Lua） | 依赖 lua-yar + OpenResty |

### 1.3 对标关系

- **yar-c** → C 语言参考实现，绑定 libcurl（同步阻塞 I/O）
- **yar-php** → PHP 原生实现，绑定 PHP stream / curl
- **lua-yar** → 纯 Lua 协议库，I/O 通过 `transport.socket` 抽象（鸭子类型适配 luasocket / cosocket）
- **lua-resty-yar** → OpenResty 适配层，注入 cosocket + ngx.log + handler 入口

---

## 二、实现功能点（现有）

### 2.1 核心模块

| 文件 | 职责 | 现状 |
|------|------|------|
| `lib/resty/yar/init.lua` | 主入口：setup / 实例管理 / 配置 / 客户端工厂 | 使用旧 API（`Yar.Server`/`Yar.Client` 大写） |
| `lib/resty/yar/server/http.lua` | HTTP handler（content_by_lua_block） | 手动 ngx API，重复 lua-yar serve_callback 逻辑 |
| `lib/resty/yar/server/tcp.lua` | TCP stream handler | 使用旧 `TcpServer:handle_connection()` |
| `lib/resty/yar/server/init.lua` | 自动检测 HTTP/stream 上下文 | 无需改动 |
| `lib/resty/yar/client.lua` | 客户端薄封装 | 无需改动（委托 init） |

### 2.2 功能清单

1. **`setup(opts)`** — init_by_lua 阶段一次性初始化
   - cosocket 注入（`Client.set_socket(ngx.socket)`）
   - ngx.log writer 注入（`Log.set_writer`）
   - 日志级别配置（`Log.set_level`）
   - Server 实例创建 + 选项配置
   - TcpServer 延迟加载（纯 HTTP 场景不加载 TCP 模块）
   - worker init 回调缓存
   - cjson / cmsgpack C 扩展注册
   - lua-resty-http provider 注入

2. **`get_http_server()`** — 进程级 HTTP Server 实例复用

3. **`get_tcp_server()`** — 进程级 TcpServer 实例复用（延迟加载）

4. **`get_config()`** — 合并后的配置表（handler 读连接级参数）

5. **`init_worker()`** — init_worker_by_lua 阶段回调（映射 yar-c `CHILD_INIT`）

6. **`new_client(uri, opts)`** — 创建客户端（配置从 setup 预填，支持 per-client 覆盖）

7. **`get_client(uri, opts)`** — 缓存的 persistent 客户端（同 uri worker 内复用）

8. **`server/http.lua`** — HTTP 服务端 handler
   - GET 内省（返回方法列表 JSON）
   - POST 分发（`handle_message` → 写响应）
   - 405 / 400 / 413 错误处理
   - 大 body 回退临时文件
   - body 长度预检（`max_body_len + HEADER_TOTAL`）

9. **`server/tcp.lua`** — TCP stream 服务端 handler
   - `ngx.req.socket()` 获取下游 cosocket
   - 三段超时设置（connect/send/read）
   - 委托 `handle_connection(sock, {keepalive=true})`
   - 优雅关闭（shutdown + close）

10. **`server/init.lua`** — 自动检测 HTTP/stream 上下文并分发

### 2.3 配置参数

| 参数 | 默认值 | 用途 |
|------|--------|------|
| `connect_timeout` | 1000 | 连接超时（ms） |
| `send_timeout` | 5000 | 发送超时（ms） |
| `read_timeout` | 5000 | 读取超时（ms） |
| `keepalive_idle` | 60000 | TCP 保活空闲超时（ms） |
| `packager` | `"JSON"` | 打包器名称 |
| `timeout` | 5000 | standalone run() per-message 超时 |
| `client_timeout` | 3000 | 出向 RPC 默认超时 |
| `pool_size` | 30 | cosocket 连接池容量 |
| `max_body_len` | 10MB | 最大请求体长度 |
| `ssl_verify` | true | HTTPS 证书验证 |
| `resolve` | `""` | 自定义 DNS 解析 IP |
| `proxy` | `""` | HTTP 代理地址 |

---

## 三、API 差距分析（lua-resty-yar 现状 vs lua-yar 最新）

### 3.1 致命差距（编译/运行时直接报错）

| 差距 | 现有代码 | lua-yar 最新 | 影响 |
|------|----------|-------------|------|
| 导出名大小写 | `Yar.Server` / `Yar.Client` / `Yar.Error` / `Yar.Log` | `Yar.server` / `Yar.client` / `Yar.error` / `Yar.log` | 全部报 nil index 错误 |
| `Yar.Packager` 导出 | `Yar.Packager`（大写） | **已移除**，改为 `Yar.register_packager` / `Yar.get_packager` | http.lua GET 内观 + init.lua cjson 注册报错 |
| `Packager.from_codec` | `Packager.from_codec("JSON", cjson)` | **已移除**，`register` 现在自动检测 encode/decode | cjson/cmsgpack 注册报错 |
| `TcpServer` 路径 | `require("yar.server.tcp")` + `TcpServer.new()` | **已移除**，统一为 `Server Facade` | get_tcp_server() 报错 |
| `handle_connection` | `tcp_server:handle_connection(sock, opts)` | **已移除**，改为 `Server:handle({socket=sock})` | tcp.lua serve() 报错 |

### 3.2 架构差距（可运行但偏离最新设计）

| 差距 | 现有代码 | lua-yar 最新 | 说明 |
|------|----------|-------------|------|
| Server 构造 | `Server.new(service)` + `set_options(opts)` | `Server.new(service, opts)` 一步到位 | 可简化 |
| HTTP handler | 手动 ngx API 重复 serve_callback 逻辑 | `serve_callback(spec, dispatcher, opts)` 已封装 | 可委托 |
| Server 实例 | 分离 `_server`（HTTP）+ `_tcp_server`（TCP） | 统一 Server Facade，`handle(spec)` 分发 | 可统一 |
| Pool 参数 | 旧代码已透传（P0 已在 lua-yar 侧解决） | `release(sock, ...)` vararg 透传 | 已对齐 |

### 3.3 已对齐部分（无需改动）

- 嵌套选项结构 `transport.keepalive = { idle_timeout, pool_size }` — `new_client()` 已使用
- 结构化 Error 对象 — 已导出 `Yar.Error`
- 注入式 Log writer — 已注入 `ngx.log`
- lua-resty-http provider 注入 — 已实现
- `set_http_provider` — 已使用

---

## 四、改造计划

### 4.1 改造原则

1. **OPM 目录结构不变** — `lib/resty/yar/` 层级保持，`dist.ini` / `Makefile` / `t/` 结构不动
2. **对外 API 向后兼容** — `setup()` / `get_http_server()` / `new_client()` / `get_client()` 签名不变
3. **内部实现全面迁移** — 所有 lua-yar API 调用更新为小写 Facade
4. **HTTP handler 委托 serve_callback** — 消除重复逻辑，行为与 lua-yar 一致
5. **TCP handler 委托 handle({socket})** — 统一 Server 实例

### 4.2 改造范围

```
lib/resty/yar/
├── init.lua          ← 重写（API 迁移 + Server 统一）
├── client.lua        ← 不变（薄封装）
└── server/
    ├── init.lua      ← 不变（自动检测）
    ├── http.lua      ← 重写（serve_callback 委托）
    └── tcp.lua       ← 重写（handle({socket}) 委托）
```

### 4.3 逐文件改造方案

#### 4.3.1 `init.lua` — 主入口

**改动点：**

1. 模块引用更新：
   ```lua
   -- 旧
   local Server = Yar.Server
   local Client = Yar.Client
   local Log = Yar.Log
   local Packager = Yar.Packager

   -- 新
   local Server = Yar.server
   local Client = Yar.client
   local Log = Yar.log
   -- Packager 不再导出，用 Yar.register_packager / Yar.get_packager
   ```

2. 导出符号更新：
   ```lua
   -- 旧
   _M.Error = Yar.Error

   -- 新
   _M.Error = Yar.error
   ```

3. `setup()` 内 cosocket 注入：
   ```lua
   -- 旧
   Client.set_socket(ngx.socket)

   -- 新
   Yar.client.set_socket(ngx.socket)
   ```

4. `setup()` 内 Log writer 注入：
   ```lua
   -- 旧
   Log.set_writer(function(lvl, msg) ... end)

   -- 新
   Yar.log.set_writer(function(lvl, msg) ... end)
   ```

5. Server 创建（统一 Facade）：
   ```lua
   -- 旧：分离创建
   _server = Server.new(service)
   _server:set_options(server_opts)

   -- 新：构造器一步到位
   _server = Yar.server.new(service, server_opts)
   ```

6. `get_tcp_server()` 统一：
   ```lua
   -- 旧：延迟加载 TcpServer，手动同步 core 选项
   local TcpServer = require("yar.server.tcp")
   _tcp_server = TcpServer.new(_tcp_service)
   _tcp_server:set_options(...)
   _tcp_server.core:set_options(...)

   -- 新：返回同一个 Server 实例（Facade 统一）
   function _M.get_tcp_server()
       if not _server then
           error("resty.yar not initialized: call setup() in init_by_lua first")
       end
       return _server
   end
   ```

7. cjson / cmsgpack 注册：
   ```lua
   -- 旧
   local adapter, cerr = Packager.from_codec("JSON", cjson)

   -- 新：register 自动检测 encode/decode
   Yar.register_packager(Yar.PACKAGER_JSON, cjson)
   ```

8. `new_client()` 内 Client 创建：
   ```lua
   -- 旧
   local client = Client.new(uri)
   client:set_options(client_opts)

   -- 新（API 名变化，调用方式不变）
   local client = Yar.client.new(uri)
   client:set_options(client_opts)
   ```

9. lua-resty-http provider 注入：
   ```lua
   -- 旧
   Client.set_http_provider(function(url, prov_opts) ... end)

   -- 新
   Yar.client.set_http_provider(function(url, prov_opts) ... end)
   ```

#### 4.3.2 `server/http.lua` — HTTP handler

**改造策略：委托 `serve_callback`**

现有代码手动实现了 GET 内观 / 405 / 400 / 413 / handle_message / 响应写入，这些逻辑在 lua-yar 的 `serve_callback` 中已全部封装。改造后只需：

1. 读 body（保留大 body 临时文件回退）
2. 构造 `spec = { method=..., data=..., writer=... }`
3. 调用 `server:handle(spec)`

```lua
function _M.serve()
    if not _http_server then
        _http_server = init.get_http_server()
    end
    local server = _http_server

    -- 读请求体（大 body 回退临时文件，serve_callback 不处理此场景）
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if not data then
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "rb")
            if f then
                data = f:read("*a")
                f:close()
            end
        end
    end

    -- writer 回调：serve_callback → ngx 输出
    local function writer(status, headers, body)
        ngx.status = status
        for k, v in pairs(headers) do
            ngx.header[k] = v
        end
        ngx.print(body)
    end

    -- 委托 lua-yar serve_callback（处理 GET/POST/405/400/413/handle_message）
    server:handle({
        method = ngx.req.get_method(),
        data   = data or "",
        writer = writer,
    })
end
```

**收益：**
- 删除 ~60 行手动 HTTP 逻辑
- 行为与 lua-yar 内置 HTTP 传输一致
- 不再需要 `Framing.HEADER_TOTAL` 内部模块引用
- 不再需要 `Packager.get` 手动调用

**注意点：**
- `serve_callback` 的 `max_body_len` 检查的是 `#data`（完整 YAR 消息），现有代码检查 `#data > max_body_len + HEADER_TOTAL`（payload + header）。改造后语义统一为 lua-yar 的 `max_body_len`（完整消息长度上限），配置值需相应调整或保持不变（10MB 足够大，差异可忽略）。

#### 4.3.3 `server/tcp.lua` — TCP handler

**改造策略：委托 `handle({socket=sock})`**

```lua
function _M.serve()
    local sock, err = ngx.req.socket()
    if not sock then
        ngx.log(ngx.ERR, "[resty.yar tcp] failed to get downstream socket: " .. tostring(err))
        return
    end

    -- 连接级超时
    local config = init.get_config()
    sock:settimeouts(config.connect_timeout, config.send_timeout, config.read_timeout)

    -- 委托统一 Server Facade（TCP 模式 + keepalive 循环）
    local server = init.get_tcp_server()  -- 现在返回同一个 Server 实例
    server:handle({ socket = sock, keepalive = true })

    -- 优雅关闭
    pcall(sock.shutdown, sock, "send")
    pcall(sock.close, sock)
end
```

**收益：**
- 删除 `pcall(tcp_server.handle_connection, ...)` 旧 API
- 不再需要延迟加载 `yar.server.tcp` 模块
- `handle({socket=sock, keepalive=true})` → `TcpTransport.serve()` 自动处理 keepalive 循环

#### 4.3.4 `server/init.lua` — 自动检测

**无需改动。** 逻辑不变：`pcall(ngx.req.get_method)` 检测上下文，分发到 http/tcp handler。

#### 4.3.5 `client.lua` — 客户端薄封装

**无需改动。** 委托 `init.new_client` / `init.get_client`，不直接引用 lua-yar。

### 4.4 测试影响分析

| 测试文件 | 直接引用 lua-yar 内部模块 | 影响 |
|----------|--------------------------|------|
| `t/http.t` | `Request` / `Protocol` / `Packager` | `Packager.get(Packager.JSON)` 仍可用（内部模块直接 require） |
| `t/tcp.t` | `Request` / `Protocol` / `Packager` / `Framing` | 同上 |
| `t/client.t` | 无（通过 `resty.yar` API） | 无影响 |

测试中直接 `require("yar.packager.packager")` 引用内部模块，这些模块的 API（`Packager.get` / `Packager.JSON`）未变，测试**无需改动**。

唯一需验证：`resty.yar` 导出的 `yar.Error` 是否仍为大写——改造后改为 `Yar.error`，但 `_M.Error = Yar.error` 赋值后外部访问 `yar.Error` 不变。

### 4.5 改造优先级

| 优先级 | 改动 | 原因 |
|--------|------|------|
| P0 | init.lua API 名迁移 | 现有代码无法运行（nil index） |
| P0 | init.lua `from_codec` → `register_packager` | cjson 注册报错 |
| P0 | init.lua Server 统一 + `get_tcp_server` 简化 | TcpServer 路径已移除 |
| P0 | tcp.lua `handle({socket})` 委托 | `handle_connection` 已移除 |
| P1 | http.lua `serve_callback` 委托 | 消除重复逻辑（可选，手动 ngx API 也能工作） |
| P2 | dist.ini `requires` 补充 `lua-yar` | OPM 依赖声明 |

### 4.6 OPM 目录结构确认

```
lua-resty-yar/
├── dist.ini              # OPM 包配置
├── Makefile              # test / lint 目标
├── README.md             # 英文文档
├── Changes.md            # 变更日志
├── LICENSE               # Apache 2.0
├── docs/
│   ├── restructuring-review.md       ← 本文档
│   └── lua-yar-pool-param-refactor.md
├── lib/
│   └── resty/
│       └── yar/
│           ├── init.lua              # 主入口
│           ├── client.lua            # 客户端薄封装
│           └── server/
│               ├── init.lua          # 自动检测入口
│               ├── http.lua          # HTTP handler
│               └── tcp.lua           # TCP stream handler
└── t/
    ├── http.t            # HTTP 服务端测试
    ├── tcp.t            # TCP stream 服务端测试
    └── client.t         # 客户端 RPC 测试
```

**结论：目录结构已符合 OPM 惯例**（对标 lua-resty-core / lua-resty-http / lua-resty-redis），无需调整。改造仅涉及 `lib/` 内文件内容更新。

---

## 五、总结

lua-resty-yar 的定位明确——OpenResty OPM 适配层，将 lua-yar 纯协议库接入 OpenResty 运行时。现有目录结构已符合 OPM 惯例，改造核心是 **API 迁移**：将所有 lua-yar 调用从旧 API（大写 `Server`/`Client`/`Error`/`Log`/`Packager` + `TcpServer` + `handle_connection` + `from_codec`）更新为最新 API（小写 `server`/`client`/`error`/`log` + 统一 Server Facade + `handle({socket})` + `register_packager`）。

改造后收益：
1. 代码可运行（修复致命 API 断裂）
2. HTTP handler 简化（委托 serve_callback，删除 ~60 行重复逻辑）
3. TCP handler 简化（委托 handle({socket})，删除延迟加载逻辑）
4. Server 实例统一（不再分离 HTTP/TCP Server）
5. 行为与 lua-yar 内置传输一致（serve_callback 统一 HTTP 处理逻辑）

# lua-resty-yar 对 lua-yar 依赖审计报告（详细版）

> 审计时间：2026-07-15 | 审计范围：`lib/` 运行时代码（5 文件）+ `t/` 测试代码（3 文件）
> 视角：从 lua-resty-yar（OPM 适配层）逐行审视对 lua-yar（纯 Lua 协议库）的全部依赖
> 审计方法：逐文件逐行对照源码，记录每一个 require、每一个常量引用、每一个函数调用

---

## 一、依赖拓扑与统计

### 1.1 依赖拓扑图

```
                          ┌─────────────────────────────────┐
                          │       用户业务代码               │
                          └──────────────┬──────────────────┘
                                         │
                    ┌────────────────────▼────────────────────┐
                    │         lua-resty-yar (适配层)            │
                    │  ┌─────────────┐  ┌──────────────────┐  │
                    │  │  init.lua   │  │  server/http.lua  │  │
                    │  │  setup()    │  │  serve()          │  │
                    │  │  new_client()│  └────────┬─────────┘  │
                    │  │  get_client()│           │            │
                    │  └──────┬──────┘  ┌────────▼─────────┐  │
                    │  ┌──────▼──────┐  │  server/tcp.lua   │  │
                    │  │ client.lua  │  │  serve()          │  │
                    │  │  new()/get()│  └────────┬─────────┘  │
                    │  └─────────────┘  ┌────────▼─────────┐  │
                    │                   │  server/init.lua  │  │
                    │                   │  serve() 自动检测 │  │
                    │                   └──────────────────┘  │
                    └────────────────────┬────────────────────┘
                                         │
          ┌──────────────────────────────▼──────────────────────────────┐
          │                    lua-yar (纯 Lua 协议库)                    │
          │  ┌──────────┐  ┌───────────┐  ┌──────────────┐              │
          │  │ init.lua  │  │ client.lua │  │ server/     │              │
          │  │ Yar表     │  │ Client    │  │ init.lua    │              │
          │  │ PACKAGER_*│  │ set_socket │  │ handle_msg()│              │
          │  └──────────┘  │ call()     │  │ list_methods│              │
          │                └───────────┘  └──────┬───────┘              │
          │  ┌──────────────┐  ┌──────────────┐  │  ┌──────────────┐    │
          │  │ packager/     │  │ protocol/    │  │  │ server/tcp   │    │
          │  │ packager.lua  │  │ protocol.lua │  │  │ handle_conn()│    │
          │  │ json.lua      │  │ header.lua   │  │  └──────────────┘    │
          │  │ msgpack.lua   │  │ framing.lua  │  │                     │
          │  └──────────────┘  └──────────────┘  │  ┌──────────────┐    │
          │  ┌──────────────┐                     │  │ transport/   │    │
          │  │ message/      │                     │  │ socket.lua   │    │
          │  │ request.lua   │                     │  │ http.lua     │    │
          │  │ response.lua  │                     │  │ tcp.lua      │    │
          │  └──────────────┘                     └──└──────────────┘    │
          └───────────────────────────────────────────────────────────────┘
```

### 1.2 依赖统计总表

| 依赖类别 | 运行时（lib/） | 测试（t/） | 合计 | 必需 | 便捷 |
|---------|:---:|:---:|:---:|:---:|:---:|
| 模块 require（直接对 lua-yar） | 2 | 4 | 6 | 6 | 0 |
| 模块 require（resty-yar 内部） | 3 | 1 | 4 | 4 | 0 |
| 常量引用 | 2 | 1 | 3 | 3 | 0 |
| 函数/API 调用 | 12 | 5 | 17 | 15 | 2 |
| **合计** | **19** | **11** | **30** | **28** | **2** |

### 1.3 文件级依赖矩阵

| lua-resty-yar 文件 | 行数 | 直接 require lua-yar | 引用 lua-yar 常量 | 调用 lua-yar 函数 |
|---|:---:|---|---|---|
| `lib/resty/yar/init.lua` | 185 | `yar`, `yar.server.tcp` | `Yar.PACKAGER_JSON` | `Client.set_socket`, `Client.new`, `Client:set_options`, `Server.new`, `Server:set_options`, `TcpServer.new`, `TcpServer:set_options` |
| `lib/resty/yar/server/http.lua` | 96 | 间接（`init.Yar.Packager`） | `Packager.JSON` | `server:handle_message`, `server:list_methods`, `Packager.get`, `packager.pack` |
| `lib/resty/yar/server/tcp.lua` | 52 | 间接（通过 `init`） | — | `tcp_server:handle_connection` |
| `lib/resty/yar/server/init.lua` | 34 | — | — | —（仅间接通过 http/tcp） |
| `lib/resty/yar/client.lua` | 35 | — | — | —（仅委托 `init`） |

---

## 二、运行时模块依赖明细

### 2.1 `require("yar")` → `Yar` 表

| 属性 | 明细 |
|------|------|
| **调用位置** | `lib/resty/yar/init.lua:22` |
| **调用代码** | `local ok_yar, Yar = pcall(require, "yar")` |
| **调用方式** | `pcall` 保护，失败时 `error("lua-yar not found...")` |
| **定义位置** | `lua-yar/src/yar/init.lua:1-21` |
| **返回值** | `Yar` 表，含：`VERSION`("0.0.1")、`PROTOCOL_VERSION`(1)、`Client`(模块)、`Server`(模块)、`Packager`(模块)、`PACKAGER_JSON`("JSON")、`PACKAGER_MSGPACK`("MSGPACK") |
| **后续引用** | `init.lua:31` `_M.Yar = Yar`；`init.lua:35` `local Server = Yar.Server`；`init.lua:36` `local Client = Yar.Client`；`init.lua:47` `Yar.PACKAGER_JSON` |
| **必要性** | **必需** — 适配层核心职责就是桥接 lua-yar 的 RPC 协议能力 |

**lua-yar `init.lua` 源码对照**：

```lua
-- lua-yar/src/yar/init.lua:1-21
local Yar = {}
Yar.VERSION          = "0.0.1"
Yar.PROTOCOL_VERSION = 1
Yar.Client   = require("yar.client")              -- 第 12 行
Yar.Server   = require("yar.server")              -- 第 13 行
Yar.Packager = require("yar.packager.packager")   -- 第 14 行
Yar.PACKAGER_JSON    = Yar.Packager.JSON           -- 第 17 行, 值="JSON"
Yar.PACKAGER_MSGPACK = Yar.Packager.MSGPACK        -- 第 18 行, 值="MSGPACK"
return Yar
```

### 2.2 `require("yar.server.tcp")` → `TcpServer` 模块

| 属性 | 明细 |
|------|------|
| **调用位置** | `lib/resty/yar/init.lua:27` |
| **调用代码** | `local TcpServer = require("yar.server.tcp")` |
| **调用方式** | 直接 require（非 pcall）— 第 22 行已成功，子模块必然可加载 |
| **定义位置** | `lua-yar/src/yar/server/tcp.lua:1-113` |
| **返回值** | `TcpServer` 表，含方法：`new(service)`、`register(name, func)`、`set_packager(name)`、`set_options(opts)`、`setopt(opt, val)`、`handle_connection(client, opts)`、`run(addr)` |
| **后续引用** | `init.lua:102` `TcpServer.new(service)`；`init.lua:103` `set_options({...})`；`server/tcp.lua:38` `handle_connection(...)` |
| **必要性** | **必需** — TCP stream 传输核心入口 |

### 2.3 `init.Yar` → `Yar.Packager`（http.lua 间接依赖）

| 属性 | 明细 |
|------|------|
| **调用位置** | `lib/resty/yar/server/http.lua:23-25` |
| **调用代码** | `local init = require("resty.yar")` → `local Yar = init.Yar` → `local Packager = Yar.Packager` |
| **定义位置** | `Yar.Packager` = `require("yar.packager.packager")`（`lua-yar/src/yar/init.lua:14`） |
| **返回值** | `Packager` 表，含：`JSON`("JSON")、`MSGPACK`("MSGPACK")、`register(name, packager)`、`get(name)` |
| **后续引用** | `http.lua:43` `Packager.get(Packager.JSON)`；`http.lua:44` `packager.pack(server:list_methods())` |
| **必要性** | **必需** — GET 内省需将方法列表序列化为 JSON |

### 2.4 内部模块依赖（resty-yar 自身，非对 lua-yar 依赖）

| 调用位置 | 调用代码 | 依赖模块 | 用途 | 必要性 |
|---------|---------|---------|------|--------|
| `server/http.lua:23` | `require("resty.yar")` | `init.lua` | 获取进程级 Server 实例 | **必需** |
| `server/tcp.lua:20` | `require("resty.yar")` | `init.lua` | 获取进程级 TcpServer 实例 | **必需** |
| `server/init.lua:26,29` | `require("resty.yar.server.http"/"tcp")` | `http.lua`/`tcp.lua` | 自动检测后分发 | **便捷** |
| `client.lua:14` | `require("resty.yar")` | `init.lua` | 委托 `new_client`/`get_client` | **便捷** |

---

## 三、运行时常量依赖明细

### 3.1 常量依赖总表

| # | 常量 | 定义文件:行 | 定义代码 | 值 | 使用文件:行 | 使用代码 | 作用 | 必要性 |
|---|------|-----------|---------|-----|-----------|---------|------|--------|
| 1 | `Yar.PACKAGER_JSON` | `yar/init.lua:17` | `Yar.PACKAGER_JSON = Yar.Packager.JSON` | `"JSON"` | `resty-yar/init.lua:47` | `packager = Yar.PACKAGER_JSON` | `default_config.packager` 默认值 | **必需** |
| 2 | `Packager.JSON` | `yar/packager/packager.lua:10` | `Packager.JSON = "JSON"` | `"JSON"` | `resty-yar/server/http.lua:43` | `Packager.get(Packager.JSON)` | GET 内省固定用 JSON packager | **必需** |

### 3.2 常量值传递链路

```
lua-yar packager.lua:10     Packager.JSON = "JSON"
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
lua-yar init.lua:17  Yar.PACKAGER_JSON = "JSON"   （公共常量, 对齐 yar-c）
                                │
                    ┌───────────┴──────────────────────┐
                    ▼                                  ▼
resty-yar init.lua:47  config.packager = Yar.PACKAGER_JSON   http.lua:43  Packager.get(Packager.JSON)
                    │                                  │
                    ▼                                  ▼
resty-yar init.lua:99  _server:set_options({packager=...})  http.lua:44  packager.pack(server:list_methods())
                    │
                    ▼
resty-yar init.lua:155  client:set_options({packager=...})
```

### 3.3 未引用但可用的 lua-yar 常量

| 常量 | 定义位置 | 值 | resty-yar 引用 | 原因 |
|------|---------|-----|:---:|------|
| `Yar.VERSION` | `yar/init.lua:9` | `"0.0.1"` | ❌ | resty-yar 有自己的 `_M.VERSION = "0.1.0"` |
| `Yar.PROTOCOL_VERSION` | `yar/init.lua:10` | `1` | ❌ | 由 lua-yar 内部 Header 模块使用 |
| `Yar.PACKAGER_MSGPACK` | `yar/init.lua:18` | `"MSGPACK"` | ❌ | 用户可通过字符串 `"Msgpack"` 指定 |
| `Packager.MSGPACK` | `yar/packager/packager.lua:11` | `"MSGPACK"` | ❌ | 同上 |
| `Header.SIZE` | `yar/protocol/header.lua:9` | `82` | ❌ | 协议头大小由 lua-yar 内部使用 |
| `Header.MAGIC_NUM` | `yar/protocol/header.lua:10` | `0x80DFEC60` | ❌ | 魔数校验由 lua-yar 内部处理 |
| `Response.STATUS_OK` | `yar/message/response.lua:7` | `0` | ❌ | 状态码由 lua-yar 内部处理 |
| `Response.STATUS_ERROR` | `yar/message/response.lua:8` | `1` | ❌ | 同上 |
| `Framing.HEADER_TOTAL` | `yar/protocol/framing.lua:9` | `90` | ❌ | 帧头大小由 lua-yar 内部使用 |
| `Framing.MAX_BODY_LEN` | `yar/protocol/framing.lua:10` | `10MB` | ❌ | body 上限由 lua-yar 内部使用 |

---

## 四、运行时函数/API 依赖明细

### 4.1 客户端侧 API 明细

#### 4.1.1 `Client.set_socket(provider)`

| 属性 | 明细 |
|------|------|
| **定义位置** | `lua-yar/src/yar/client.lua:52-55` |
| **函数签名** | `Client.set_socket(provider: table) -> Client class` |
| **定义代码** | `function Client.set_socket(provider) Transport.set_socket(provider) return Client end` |
| **调用位置** | `lib/resty/yar/init.lua:88` |
| **调用代码** | `Client.set_socket(ngx.socket)` |
| **传入参数** | `ngx.socket` — OpenResty cosocket 模块表，含 `tcp()`、`unix()` 等 |
| **内部调用链** | `Client.set_socket` → `Transport.set_socket` → `Socket.set` → `provider = ngx.socket` |
| **影响范围** | 进程级，所有后续 Client 实例出向连接均走 cosocket |
| **必要性** | **必需** — 不注入则用 luasocket（阻塞），在 OpenResty 中会阻塞 worker |
| **P0 关联** | 注入了 cosocket provider，但 `Socket.release()` 调用 `setkeepalive()` 未透传池参数 |

#### 4.1.2 `Client.new(uri)`

| 属性 | 明细 |
|------|------|
| **定义位置** | `lua-yar/src/yar/client.lua:28-45` |
| **函数签名** | `Client.new(uri: string) -> client instance` |
| **调用位置** | `lib/resty/yar/init.lua:154` |
| **调用代码** | `local client = Client.new(uri)` |
| **传入参数** | `uri: string` — 如 `"http://127.0.0.1:1984/api"` 或 `"tcp://127.0.0.1:19861"` |
| **内部行为** | 创建实例，深拷贝 `DEFAULT_OPTIONS` 到 `self.options` |
| **DEFAULT_OPTIONS** | `packager=JSON, timeout=5000, connect_timeout=1000, provider="", token="", headers={}, proxy="", resolve="", persistent=false` |
| **返回值** | Client 实例 |
| **必要性** | **必需** |

#### 4.1.3 `Client:set_options(opts)`

| 属性 | 明细 |
|------|------|
| **定义位置** | `lua-yar/src/yar/client.lua:60-70` |
| **函数签名** | `Client:set_options(opts: table) -> self` |
| **调用位置** | `lib/resty/yar/init.lua:155-162` |
| **调用代码** | `client:set_options({ connect_timeout=..., timeout=..., packager=..., keepalive_idle=..., pool_size=... })` |
| **内部行为** | 遍历 opts 逐键写入 `self.options`；`socket_provider` 键特殊处理（调用 `Socket.set()`） |
| **返回值** | `self`（链式） |
| **必要性** | **必需** |

**参数透传明细表**：

| resty-yar 配置键 | resty-yar 默认值 | 传入键 | lua-yar DEFAULT_OPTIONS | 实际生效路径 | 生效 |
|---|---|---|---|---|:---:|
| `config.connect_timeout` | `1000`ms | `connect_timeout` | `1000` | → `Socket.set_timeouts(sock, connect_timeout, ...)` → `sock:settimeouts(...)` | ✅ |
| `config.client_timeout` | `3000`ms | `timeout` | `5000` | → `Socket.set_timeouts(sock, ..., timeout, timeout)` | ✅ |
| `config.packager` | `"JSON"` | `packager` | `"JSON"` | → `Packager.get(self.options.packager)` | ✅ |
| `config.keepalive_idle` | `60000`ms | `keepalive_idle` | **无此字段** | → `self.options.keepalive_idle` → `Socket.release(sock)` → `sock:setkeepalive()` **无参数** | ❌ P0 |
| `config.pool_size` | `30` | `pool_size` | **无此字段** | → `self.options.pool_size` → `Socket.release(sock)` → `sock:setkeepalive()` **无参数** | ❌ P0 |

### 4.2 服务端 HTTP 侧 API 明细

#### 4.2.1 `Server.new(service)`

| 属性 | 明细 |
|------|------|
| **定义位置** | `lua-yar/src/yar/server/init.lua:41-48` |
| **函数签名** | `Server.new(service: table\|function) -> server instance` |
| **调用位置** | `lib/resty/yar/init.lua:98`（进程级）、`init.lua:142`（自定义） |
| **传入参数** | `service: table` — RPC 方法表，如 `{ add = function(a,b) return a+b end }`。也接受 function（注册为 `default`） |
| **内部行为** | 1. 创建实例；2. 默认 packager=JSON；3. 默认 timeout=5000ms；4. **memoize**：`collect_methods(service)` 遍历 service，收集所有不以 `_` 开头的 function 字段到 `self.methods` |
| **返回值** | Server 实例 |
| **必要性** | **必需** — 方法表 memoize 是性能关键 |

#### 4.2.2 `Server:set_options(opts)`

| 属性 | 明细 |
|------|------|
| **定义位置** | `lua-yar/src/yar/server/init.lua:73-83` |
| **函数签名** | `Server:set_options(opts: table) -> self` |
| **调用位置** | `lib/resty/yar/init.lua:99` |
| **调用代码** | `_server:set_options({ packager = config.packager, timeout = config.timeout })` |
| **内部行为** | `packager` 键 → `self:set_packager(v)` → `Packager.get(name)`；其他键 → `self.options[k] = v` |
| **必要性** | **必需** |

#### 4.2.3 `server:handle_message(data)` — 核心 RPC 分发

| 属性 | 明细 |
|------|------|
| **定义位置** | `lua-yar/src/yar/server/init.lua:106-147` |
| **函数签名** | `Server:handle_message(data: string) -> string` |
| **调用位置** | `lib/resty/yar/server/http.lua:82` |
| **调用代码** | `local ok, resp = pcall(server.handle_message, server, data)` |
| **传入参数** | `data: string` — 完整 YAR 二进制请求（packager_name[8] + header[82] + body[N]） |
| **返回值** | `string` — 完整 YAR 二进制响应 |
| **pcall 层级** | **第 2 层**（lua-yar 内部 pcall 用户方法）；resty-yar 外层 pcall 为 **第 1 层** |
| **并发安全** | ✅ 纯协议函数，无 I/O、无 yield、无共享可变状态，reentrant |
| **必要性** | **必需** — HTTP RPC 分发核心 |

**handle_message 内部调用链**：

```
server:handle_message(data)
  │
  ├─ Util.trim_null(string.sub(data, 1, 8))          提取 packager 名称
  ├─ pcall(Packager.get, name)                       获取 packager（失败回退 self.packager）
  ├─ Protocol.parse(data, packager)                  解析请求
  │    ├─ Header.unpack(data, 9)                     解析 82 字节协议头
  │    │    ├─ Util.unpack_u32(data, offset)         读取 id/magic/reserved/body_len
  │    │    ├─ Util.unpack_u16(data, offset+4)        读取 version
  │    │    ├─ magic_num 校验 (0x80DFEC60)
  │    │    └─ Util.trim_null(string.sub(...))       提取 provider/token
  │    └─ packager.unpack(body)                      解码 body (JSON/Msgpack)
  │
  ├─ Request.new({id=, method=, params=, ...})       构造请求对象
  ├─ Response.new({id=, provider=, token=})         构造响应对象
  ├─ self.methods[request.method]                    查方法表（memoize）
  ├─ pcall(func, unpack(args))                       执行用户 RPC 方法（第 2 层 pcall）
  │    ├─ response:set_retval(ret)                   成功：设置返回值
  │    └─ response:set_error(tostring(ret))          失败：设置错误信息
  └─ Protocol.render(response, packager)             渲染响应
       ├─ response:pack_body()                       {i,s,r,o,e}
       ├─ packager.pack(payload)                    序列化 body
       ├─ Util.pad_field(packager.name, 8)           packager 名称补 \0
       └─ Header.new({id, provider, token, body_len}):pack()  82 字节协议头
```

#### 4.2.4 `server:list_methods()`

| 属性 | 明细 |
|------|------|
| **定义位置** | `lua-yar/src/yar/server/init.lua:95-101` |
| **函数签名** | `Server:list_methods() -> table (array of strings)` |
| **调用位置** | `lib/resty/yar/server/http.lua:44` |
| **调用代码** | `packager.pack(server:list_methods())` |
| **内部行为** | 遍历 `self.methods` 表，收集所有键到数组 |
| **返回值** | `table` — 方法名数组，如 `{"add", "sub", "greet"}` |
| **必要性** | **必需** — GET 内省功能核心 |

### 4.3 服务端 TCP 侧 API 明细

#### 4.3.1 `TcpServer.new(service)`

| 属性 | 明细 |
|------|------|
| **定义位置** | `lua-yar/src/yar/server/tcp.lua:14-19` |
| **函数签名** | `TcpServer.new(service: table\|function) -> tcp_server instance` |
| **调用位置** | `lib/resty/yar/init.lua:102` |
| **内部行为** | 创建实例，内部 `self.core = Server.new(service)` 复用 HTTP Server 的 handle_message |
| **返回值** | TcpServer 实例 |
| **必要性** | **必需** |

#### 4.3.2 `TcpServer:set_options(opts)`

| 属性 | 明细 |
|------|------|
| **定义位置** | `lua-yar/src/yar/server/tcp.lua:41-53` |
| **函数签名** | `TcpServer:set_options(opts: table) -> self` |
| **调用位置** | `lib/resty/yar/init.lua:103` |
| **调用代码** | `_tcp_server:set_options({ packager = config.packager, timeout = config.timeout })` |
| **内部行为** | `packager` → `self.core:set_packager(v)`；`socket_provider` → `Socket.set(v)`；其他 → `self.options[k] = v` |
| **必要性** | **必需** |

#### 4.3.3 `tcp_server:handle_connection(client, opts)` — TCP 连接级 handler

| 属性 | 明细 |
|------|------|
| **定义位置** | `lua-yar/src/yar/server/tcp.lua:68-88` |
| **函数签名** | `TcpServer:handle_connection(client: socket, opts: table\|nil) -> nil` |
| **调用位置** | `lib/resty/yar/server/tcp.lua:38` |
| **调用代码** | `pcall(tcp_server.handle_connection, tcp_server, sock, { keepalive = true })` |
| **传入参数** | `client: socket` — 下游 cosocket（`ngx.req.socket()` 返回）；`opts: { keepalive = true }` |
| **内部行为** | `keepalive=true` 时循环：`Framing.receive_message(client)` → `self.core:handle_message(data)` → `client:send(resp)`，直到读不到数据或发送失败 |
| **返回值** | 无 |
| **pcall 层级** | resty-yar 外层 pcall 保护 |
| **必要性** | **必需** — TCP 服务端核心逻辑 |

**handle_connection 内部调用链**：

```
tcp_server:handle_connection(sock, {keepalive=true})
  │
  └─ while true do  （keepalive 循环）
       ├─ Framing.receive_message(client)              帧读取
       │    ├─ Framing.receive_exact(sock, 90)          读 packager(8)+header(82)
       │    │    └─ 循环 sock:receive(n) 直到收满 90 字节
       │    ├─ Header.unpack(head, 9)                  解析协议头
       │    │    └─ 校验 magic_num, 读取 body_len
       │    ├─ body_len > MAX_BODY_LEN(10MB) ? 拒绝    防恶意大 body
       │    └─ Framing.receive_exact(sock, body_len)   读 body
       │
       ├─ self.core:handle_message(data)               纯协议分发（见 4.2.3）
       │
       ├─ client:send(resp)                            发送响应
       │    └─ 发送失败 → break
       │
       └─ Framing.receive_message 返回 nil → break      客户端断开
```

### 4.4 Packager 侧 API 明细

#### 4.4.1 `Packager.get(name)`

| 属性 | 明细 |
|------|------|
| **定义位置** | `lua-yar/src/yar/packager/packager.lua:29-36` |
| **函数签名** | `Packager.get(name: string) -> packager module` |
| **调用位置** | `lib/resty/yar/server/http.lua:43` |
| **调用代码** | `local packager = Packager.get(Packager.JSON)` |
| **传入参数** | `name: string` — packager 名称，如 `"JSON"` |
| **内部行为** | `string.upper(name)` → 查注册表 `registry[name]` → 找不到则 `error("unsupported packager")` |
| **返回值** | packager 模块表，含 `name`、`pack(v)`、`unpack(s)` |
| **必要性** | **必需** — 内省需要获取 JSON packager |

#### 4.4.2 `packager.pack(data)`

| 属性 | 明细 |
|------|------|
| **定义位置** | `lua-yar/src/yar/packager/json.lua:89-91`（JSON packager） |
| **函数签名** | `Json.pack(v: any) -> string` |
| **调用位置** | `lib/resty/yar/server/http.lua:44` |
| **调用代码** | `ngx.print(packager.pack(server:list_methods()))` |
| **传入参数** | `v: table` — 方法名数组，如 `{"add", "sub", "greet"}` |
| **内部行为** | 纯 Lua JSON 编码器：判断 table 是数组还是对象 → 遍历编码 → `table.concat` 拼接 |
| **返回值** | `string` — JSON 字符串，如 `["add","sub","greet"]` |
| **必要性** | **必需** — 内省响应序列化 |

---

## 五、测试级依赖明细

### 5.1 测试模块依赖总表

| 测试文件 | 直接 require lua-yar 模块 | 用途 |
|---------|---|---|
| `t/http.t` | `yar.message.request`、`yar.protocol.protocol`、`yar.packager.packager` | 构造 YAR 二进制请求体 |
| `t/tcp.t` | `yar.message.request`、`yar.protocol.protocol`、`yar.packager.packager`、`yar.protocol.framing` | 构造请求 + 帧封装/接收 |
| `t/client.t` | 无直接 require lua-yar | 仅通过 `resty.yar.client` 间接依赖 |

### 5.2 测试函数/API 依赖明细表

| # | 测试文件 | 调用函数 | 定义位置 | 调用代码 | 用途 | 必要性 |
|---|---------|---------|---------|---------|------|--------|
| 1 | `t/http.t` | `Request.new` | `yar/message/request.lua:3-15` | `Request.new({id=1, method="add", params={1,2}})` | 构造 RPC 请求对象 | **必需** |
| 2 | `t/http.t` | `Protocol.render` | `yar/protocol/protocol.lua:14-40` | `Protocol.render(request, packager)` | 渲染为 YAR 二进制 | **必需** |
| 3 | `t/http.t` | `Packager.get` | `yar/packager/packager.lua:29-36` | `Packager.get(Packager.JSON)` | 获取 JSON packager | **必需** |
| 4 | `t/tcp.t` | `Request.new` | 同 #1 | 同 #1 | 同上 | **必需** |
| 5 | `t/tcp.t` | `Protocol.render` | 同 #2 | 同 #2 | 同上 | **必需** |
| 6 | `t/tcp.t` | `Packager.get` | 同 #3 | 同 #3 | 同上 | **必需** |
| 7 | `t/tcp.t` | `Framing.send_message` | `yar/protocol/framing.lua:26-35` | `Framing.send_message(sock, data)` | 发送带帧头的 YAR 消息 | **必需** |
| 8 | `t/tcp.t` | `Framing.receive_message` | `yar/protocol/framing.lua:37-52` | `Framing.receive_message(sock)` | 接收并解析 YAR 响应 | **必需** |

### 5.3 测试调用链 — `http.t` TEST 1（RPC add）

```
--- 测试端（Nginx content_by_lua_block） ---
require("yar.message.request")   → Request
require("yar.protocol.protocol") → Protocol
require("yar.packager.packager") → Packager

Request.new({id=1, method="add", params={1,2}})
  └─ 设置 retval, status, provider, token

Protocol.render(request, Packager.get(Packager.JSON))
  ├─ request:pack_body()              → {i=1, s=0, r={1,2}, o="JSON", e=nil}
  ├─ Packager.get("JSON"):pack(body)  → JSON 字符串
  ├─ Util.pad_field("JSON", 8)        → "JSON\0\0\0\0"
  └─ Header.new({...}):pack()         → 82 字节二进制头

ngx.location.capture("/api", {
    method = ngx.HTTP_POST,
    body  = rendered_data               → 90 + body_len 字节
})

--- 服务端（lua-resty-yar） ---
http.lua:serve()
  ├─ ngx.req.get_body_data()           → data (90+N bytes)
  ├─ pcall(server.handle_message, server, data)
  │    └─ Protocol.parse → 查方法表 → pcall(add, 1, 2) → Protocol.render
  └─ ngx.print(resp)                   → 90+M bytes YAR 响应

--- 测试端断言 ---
response = Protocol.parse(resp_body, packager)
assert(response.status == 0)           → s=0 表示成功
assert(response.retval == 3)           → 1+2=3
```

### 5.4 测试调用链 — `tcp.t` TEST 1（TCP RPC）

```
--- 测试端（Nginx content_by_lua_block） ---
require 4 个模块

sock = ngx.socket.tcp()
sock:connect("127.0.0.1", 19861)

request = Request.new({id=1, method="add", params={1,2}})
data = Protocol.render(request, Packager.get(Packager.JSON))

Framing.send_message(sock, data)
  └─ sock:send(Framing.HEADER_TOTAL标记 + data)

resp = Framing.receive_message(sock)
  ├─ Framing.receive_exact(sock, 90)    → 读 packager+header
  ├─ Header.unpack(head, 9)            → 解析 header, 取 body_len
  └─ Framing.receive_exact(sock, body_len) → 读 body

response = Protocol.parse(resp, packager)
assert(response.retval == 3)

--- 服务端（lua-resty-yar server/tcp.lua） ---
tcp.lua:serve()
  ├─ sock = ngx.req.socket()           → 下游 cosocket
  ├─ sock:settimeouts(connect, send, read)
  ├─ pcall(tcp_server.handle_connection, tcp_server, sock, {keepalive=true})
  │    └─ while keepalive:
  │         Framing.receive_message(sock) → handle_message(data) → sock:send(resp)
  └─ pcall(sock.shutdown, sock, "send")  → 优雅关闭
```

---

## 六、端到端调用链分析

### 6.1 HTTP POST RPC 完整调用链

```
[用户请求] POST /api
    │
    ▼
[OpenResty] content_by_lua_block → require("resty.yar.server").serve()
    │
    ▼
[resty-yar server/init.lua:26-30] 检测 ngx.req.socket() 是否可用
    │
    ├─ 可用 → server/tcp.lua:serve()   （stream 模式）
    └─ 不可用 → server/http.lua:serve() （HTTP 模式）
    │
    ▼
[resty-yar server/http.lua:serve()]
    │
    ├─ init = require("resty.yar")              获取进程级实例
    ├─ server = init.get_server()               获取 Server 实例
    ├─ data = ngx.req.get_body_data()           读取 POST body
    │
    ├─ data == nil ?
    │    └─ ngx.exit(HTTP_BAD_REQUEST)           400
    │
    ├─ pcall(server.handle_message, server, data)
    │    │
    │    ▼
    │  [lua-yar server/init.lua:handle_message]
    │    ├─ packager_name = trim_null(sub(data,1,8))    "JSON"
    │    ├─ pcall(Packager.get, "JSON") → json_packager
    │    ├─ Protocol.parse(data, packager)
    │    │    ├─ Header.unpack(data, 9)
    │    │    │    ├─ unpack_u32 → id, magic, reserved, body_len
    │    │    │    ├─ unpack_u16 → version
    │    │    │    ├─ magic == 0x80DFEC60 ? ✅
    │    │    │    └─ trim_null → provider, token
    │    │    └─ packager:unpack(body) → {i,s,r,o,e}
    │    │
    │    ├─ request = Request.new({id, method, params, ...})
    │    ├─ response = Response.new({id, provider, token})
    │    ├─ func = self.methods["add"]               O(1) memoize 查找
    │    ├─ pcall(func, unpack(params))              执行用户方法
    │    │    ├─ success → response:set_retval(retval)
    │    │    └─ fail    → response:set_error(tostring(err))
    │    └─ Protocol.render(response, packager)     渲染响应
    │
    ├─ ok ?
    │    ├─ yes → ngx.print(resp)                   200 OK
    │    └─ no  → ngx.exit(HTTP_INTERNAL_SERVER_ERROR)  500
    │
    └─ [完成]
```

### 6.2 HTTP GET 内省完整调用链

```
[用户请求] GET /api
    │
    ▼
[resty-yar server/http.lua:serve()]
    │
    ├─ method == "GET" ?
    │
    ├─ local packager = Packager.get(Packager.JSON)
    │    └─ registry["JSON"] → json_packager 模块
    │
    ├─ local methods = server:list_methods()
    │    └─ 遍历 self.methods 表 → {"add", "sub", "greet"}
    │
    ├─ ngx.print(packager.pack(methods))
    │    └─ Json.pack({"add","sub","greet"})
    │         └─ 判断 array → 遍历编码 → ["add","sub","greet"]
    │
    └─ [完成, 200 OK, Content-Type: application/json]
```

### 6.3 TCP Stream RPC 完整调用链

```
[用户请求] stream { lua-resty-yar serve(); }
    │
    ▼
[resty-yar server/init.lua:26-30] 检测 ngx.req.socket() → 可用
    │
    ▼
[resty-yar server/tcp.lua:serve()]
    │
    ├─ init = require("resty.yar")
    ├─ tcp_server = init.get_tcp_server()
    ├─ sock = assert(ngx.req.socket())
    │
    ├─ sock:settimeouts(
    │    config.connect_timeout,   -- 连接超时（下游已连接，通常不触发）
    │    config.send_timeout,      -- 发送超时
    │    config.read_timeout       -- 读取超时
    │  )
    │
    ├─ pcall(tcp_server.handle_connection, tcp_server, sock, {keepalive=true})
    │    │
    │    ▼
    │  [lua-yar server/tcp.lua:handle_connection]
    │    └─ while true do  (keepalive 循环)
    │         │
    │         ├─ Framing.receive_message(sock)
    │         │    ├─ receive_exact(sock, 90)
    │         │    │    └─ loop: sock:receive(n) until 90 bytes
    │         │    ├─ Header.unpack(head, 9)
    │         │    │    └─ magic 校验, body_len 提取
    │         │    ├─ body_len > 10MB ? → return nil (拒绝)
    │         │    └─ receive_exact(sock, body_len)
    │         │
    │         ├─ data == nil ? → break (客户端断开)
    │         │
    │         ├─ self.core:handle_message(data)
    │         │    └─ (同 6.1 的 handle_message 调用链)
    │         │
    │         ├─ client:send(resp)
    │         │    └─ 失败 → break
    │         │
    │         └─ (循环回到顶部)
    │
    ├─ pcall(sock.shutdown, sock, "send")   优雅半关闭
    └─ sock:close()                         或由 setkeepalive 回收
```

### 6.4 Client 出向调用完整调用链

```
[用户代码] local client = require("resty.yar.client").new("http://...")
    │
    ▼
[resty-yar client.lua:14] require("resty.yar")
    │
    ▼
[resty-yar init.lua:new_client(uri)]
    │
    ├─ 查 _client_cache[uri] (weak-value table)
    │    ├─ 命中 → 返回缓存的 client 实例
    │    └─ 未命中 ↓
    │
    ├─ client = Client.new(uri)                    [lua-yar]
    │    └─ 深拷贝 DEFAULT_OPTIONS → self.options
    │
    ├─ client:set_options({
    │    connect_timeout = config.connect_timeout,   1000ms
    │    timeout         = config.client_timeout,    3000ms
    │    packager        = config.packager,          "JSON"
    │    keepalive_idle  = config.keepalive_idle,    60000ms  ← 存入 options 但❌不生效
    │    pool_size       = config.pool_size          30       ← 存入 options 但❌不生效
    │  })
    │
    ├─ _client_cache[uri] = client                  weak-value 缓存
    └─ return client

[用户代码] client:call("add", {1, 2})
    │
    ▼
[lua-yar client.lua:call(method, params)]
    │
    ├─ request = Request.new({id=self:next_id(), method=method, params=params})
    ├─ data = Protocol.render(request, self.packager)
    ├─ Transport.send(data)                         [lua-yar transport/http.lua]
    │    │
    │    ├─ sock = Socket.new()                     [lua-yar transport/socket.lua]
    │    │    └─ sock = ngx.socket.tcp()            cosocket (已注入)
    │    │
    │    ├─ Socket.set_timeouts(sock, connect_t, send_t, read_t)
    │    │    └─ sock:settimeouts(connect_t, send_t, read_t)
    │    │
    │    ├─ sock:connect(host, port)
    │    ├─ sock:sslhandshake(...)                  (HTTPS 时)
    │    ├─ sock:send(data)
    │    │
    │    ├─ response_data = Socket.receive(sock)    读响应
    │    │
    │    └─ Socket.release(sock)                    ★ P0 BUG
    │         └─ sock:setkeepalive()               无参数！keepalive_idle/pool_size 丢失
    │
    ├─ response = Protocol.parse(response_data, self.packager)
    └─ return response.retval
```

---

## 七、参数透传链路分析

### 7.1 服务端参数透传

| 参数 | resty-yar 配置默认值 | 透传路径 | 最终调用 | 生效 |
|------|---------------------|---------|---------|:---:|
| `packager` | `"JSON"` (Yar.PACKAGER_JSON) | `init.lua:99` → `_server:set_options({packager=...})` → `Server:set_packager(v)` → `Packager.get(name)` | `Packager.get("JSON")` | ✅ |
| `timeout` | `5000`ms | `init.lua:99` → `_server:set_options({timeout=...})` → `self.options.timeout = v` | Server 内部使用 | ✅ |
| `packager` (TCP) | `"JSON"` | `init.lua:103` → `_tcp_server:set_options({packager=...})` → `self.core:set_packager(v)` | 同上 | ✅ |
| `timeout` (TCP) | `5000`ms | `init.lua:103` → `_tcp_server:set_options({timeout=...})` → `self.options.timeout = v` | TcpServer 内部使用 | ✅ |
| `connect_timeout` | `1000`ms | `tcp.lua:34` → `sock:settimeouts(config.connect_timeout, ...)` | `sock:settimeouts(1000, 5000, 5000)` | ✅ |
| `send_timeout` | `5000`ms | `tcp.lua:34` → `sock:settimeouts(..., config.send_timeout, ...)` | 同上 | ✅ |
| `read_timeout` | `5000`ms | `tcp.lua:34` → `sock:settimeouts(..., config.read_timeout)` | 同上 | ✅ |

### 7.2 客户端参数透传

| 参数 | resty-yar 配置默认值 | 透传路径 | 最终调用 | 生效 |
|------|---------------------|---------|---------|:---:|
| `connect_timeout` | `1000`ms | `init.lua:155` → `client:set_options({connect_timeout=...})` → `self.options.connect_timeout = v` → `Transport.send` → `Socket.set_timeouts(sock, connect_t, ...)` → `sock:settimeouts(...)` | cosocket connect 超时 | ✅ |
| `timeout` (client) | `3000`ms (config.client_timeout) | `init.lua:155` → `client:set_options({timeout=...})` → `self.options.timeout = v` → `Socket.set_timeouts(sock, ..., timeout, timeout)` → `sock:settimeouts(...)` | cosocket send/read 超时 | ✅ |
| `packager` | `"JSON"` | `init.lua:155` → `client:set_options({packager=...})` → `self.options.packager = v` → `Packager.get(self.options.packager)` | 请求/响应序列化 | ✅ |
| `keepalive_idle` | `60000`ms | `init.lua:155` → `client:set_options({keepalive_idle=...})` → `self.options.keepalive_idle = v` → `Transport.send` → `Socket.release(sock)` → `sock:setkeepalive()` **无参数** | **❌ P0 — 未透传到 cosocket** |
| `pool_size` | `30` | `init.lua:155` → `client:set_options({pool_size=...})` → `self.options.pool_size = v` → `Transport.send` → `Socket.release(sock)` → `sock:setkeepalive()` **无参数** | **❌ P0 — 未透传到 cosocket** |

### 7.3 P0 Bug 根因定位

**Bug 位置**：`lua-yar/src/yar/transport/socket.lua:116-121`

```lua
-- lua-yar/src/yar/transport/socket.lua:116-121
function M.release(sock)
    if sock.setkeepalive then
        sock:setkeepalive()  -- ← 无参数！keepalive_idle 和 pool_size 被忽略
    else
        sock:close()
    end
end
```

**影响**：
- `lua-resty-yar` 配置的 `keepalive_idle=60000`（60秒空闲保活）**不生效**，cosocket 使用 OpenResty 默认值（60秒）
- `lua-resty-yar` 配置的 `pool_size=30`（连接池大小）**不生效**，cosocket 使用 OpenResty 默认值（10）

**正确实现应为**：

```lua
function M.release(sock, opts)
    if sock.setkeepalive then
        local idle = opts and opts.keepalive_idle
        local pool = opts and opts.pool_size
        return sock:setkeepalive(idle, pool)
    else
        sock:close()
    end
end
```

**影响范围**：`transport/http.lua:180`、`transport/tcp.lua:88,97` 共 3 处调用 `Socket.release(sock)` 均受影响。

---

## 八、适配层工程化评估

### 8.1 高性能评估

| 维度 | 评估 | 证据 | 评分 |
|------|------|------|:---:|
| 方法查找 O(1) | ✅ 优秀 | `Server.new` 时 `collect_methods` memoize 方法表，`handle_message` 中 `self.methods[request.method]` 直接哈希查找 | ⭐⭐⭐⭐⭐ |
| 协议解析零冗余 | ✅ 优秀 | `handle_message` 纯协议函数，无 I/O、无 yield，不阻塞 worker | ⭐⭐⭐⭐⭐ |
| 进程级实例复用 | ✅ 优秀 | `_server`/`_tcp_server` 进程级单例，避免每次请求重建 | ⭐⭐⭐⭐⭐ |
| cosocket 非阻塞 | ✅ 优秀 | `Client.set_socket(ngx.socket)` 注入 cosocket，出向连接不阻塞 worker | ⭐⭐⭐⭐⭐ |
| 客户端连接池 | ⚠️ 受限 | weak-value 缓存 Client 实例 ✅，但 cosocket 连接池参数 `pool_size`/`keepalive_idle` **未透传** ❌ P0 | ⭐⭐⭐ |
| TCP keepalive 循环 | ✅ 优秀 | 单连接复用，`Framing.receive_message` → `handle_message` → `send` 流水线 | ⭐⭐⭐⭐⭐ |

### 8.2 高并发评估

| 维度 | 评估 | 证据 | 评分 |
|------|------|------|:---:|
| 无共享可变状态 | ✅ 优秀 | `handle_message` 纯函数，`Server.methods` 只读，多请求并发安全 | ⭐⭐⭐⭐⭐ |
| cosocket 并发模型 | ✅ 优秀 | OpenResty cosocket 基于 Nginx 事件循环，每 worker 可维持数万 cosocket | ⭐⭐⭐⭐⭐ |
| weak-value 客户端缓存 | ✅ 良好 | `setmetatable(_client_cache, {__mode="v"})` — GC 自动回收无引用客户端 | ⭐⭐⭐⭐ |
| 连接池上限可控 | ⚠️ 受限 | `pool_size=30` 配置存在但 **不生效** ❌ P0，默认池大小仅 10 | ⭐⭐⭐ |
| pcall 隔离 | ✅ 优秀 | 双层 pcall：lua-yar 内部 pcall 用户方法 + resty-yar 外层 pcall handle_message | ⭐⭐⭐⭐⭐ |

### 8.3 高可用评估

| 维度 | 评估 | 证据 | 评分 |
|------|------|------|:---:|
| 双层 pcall 防护 | ✅ 优秀 | 用户方法错误 → lua-yar 内层 pcall 捕获 → 返回 YAR 错误响应(s=1)；协议错误 → resty-yar 外层 pcall 捕获 → 500 | ⭐⭐⭐⭐⭐ |
| 优雅关闭 | ✅ 良好 | `pcall(sock.shutdown, sock, "send")` 半关闭 + `sock:close()` | ⭐⭐⭐⭐ |
| 魔数校验 | ✅ 优秀 | `Header.unpack` 校验 `magic_num == 0x80DFEC60`，拒绝非法请求 | ⭐⭐⭐⭐⭐ |
| 超大 body 防护 | ✅ 优秀 | `Framing.MAX_BODY_LEN = 10MB`，超过即拒绝 | ⭐⭐⭐⭐⭐ |
| 超时三段控制 | ✅ 优秀 | `connect_timeout` / `send_timeout` / `read_timeout` 独立配置 | ⭐⭐⭐⭐⭐ |
| 模块加载容错 | ✅ 良好 | `pcall(require, "yar")` 保护，失败时明确报错 | ⭐⭐⭐⭐ |
| 连接池保活 | ⚠️ 受限 | `setkeepalive` 回收 cosocket 到池 ✅，但 `keepalive_idle` 不生效 ❌ P0 | ⭐⭐⭐ |

### 8.4 设计模式评估

| 维度 | 评估 | 证据 | 评分 |
|------|------|------|:---:|
| Provider 抽象 | ✅ 优秀 | `Client.set_socket(ngx.socket)` 注入 cosocket，lua-yar 框架代码零 `ngx` 引用 | ⭐⭐⭐⭐⭐ |
| 三层分离 | ✅ 优秀 | `handle_message`(纯协议) / `handle_connection`(连接级) / `run`(accept 循环) 职责清晰 | ⭐⭐⭐⭐⭐ |
| 适配层薄度 | ✅ 优秀 | resty-yar 仅 5 文件 ~400 行，核心逻辑全在 lua-yar | ⭐⭐⭐⭐⭐ |
| 常量复用 | ✅ 优秀 | `Yar.PACKAGER_JSON` 直接引用，不硬编码 | ⭐⭐⭐⭐⭐ |
| HTTP 状态码兼容 | ✅ 优秀 | `ngx.HTTP_METHOD_NOT_ALLOWED or 405` 版本兼容回退 | ⭐⭐⭐⭐⭐ |
| 配置集中管理 | ✅ 优秀 | `init.lua:setup(config)` 统一入口，`default_config` 带默认值 | ⭐⭐⭐⭐⭐ |

### 8.5 综合评分

| 维度 | 权重 | 评分 | 加权 |
|------|:---:|:---:|:---:|
| 高性能 | 25% | 4.3/5 | 1.08 |
| 高并发 | 25% | 4.0/5 | 1.00 |
| 高可用 | 25% | 4.3/5 | 1.08 |
| 设计模式 | 25% | 5.0/5 | 1.25 |
| **总计** | 100% | — | **4.4/5** |

> **扣分项**：cosocket 连接池参数 `pool_size` / `keepalive_idle` 未透传（P0 Bug），影响高并发连接复用效率。修复后预计可达 **4.7/5**。

---

## 九、依赖必要性总结

### 9.1 必需依赖（28 项）

| 类别 | 数量 | 明细 | 必要性理由 |
|------|:---:|------|-----------|
| 模块 require | 6 | `yar`、`yar.server.tcp`、`yar.packager.packager`（间接）、`resty.yar`、`resty.yar.server.http`、`resty.yar.server.tcp` | 适配层核心职责：桥接 lua-yar RPC 协议能力到 OpenResty cosocket |
| 常量引用 | 3 | `Yar.PACKAGER_JSON`、`Packager.JSON`（×2，运行时+测试） | 避免硬编码字符串，与 yar-c 协议对齐 |
| 函数/API | 15 | `Client.set_socket`、`Client.new`、`Client:set_options`、`Server.new`、`Server:set_options`、`handle_message`、`list_methods`、`TcpServer.new`、`TcpServer:set_options`、`handle_connection`、`Packager.get`、`packager.pack` + 3 测试 API | 每个 API 都有不可替代的职责 |
| 测试 API | 4 | `Request.new`、`Protocol.render`、`Framing.send_message`、`Framing.receive_message` | 测试需构造和解析 YAR 二进制协议 |

### 9.2 便捷依赖（2 项）

| # | 依赖 | 位置 | 替代方案 | 必要性 |
|---|------|------|---------|--------|
| 1 | `server/init.lua` 自动检测分发 | `init.lua:26,29` | 用户可直接 `require("resty.yar.server.http").serve()` | **便捷** — 简化用户配置 |
| 2 | `client.lua` 薄包装委托 | `client.lua:14` | 用户可直接 `require("resty.yar").new_client(uri)` | **便捷** — 提供语义化入口 |

### 9.3 冗余依赖检查

| 检查项 | 结果 |
|--------|------|
| 是否有未使用的 require？ | ❌ 无 — 所有 require 均有后续引用 |
| 是否有未使用的常量？ | ❌ 无 — `Yar.PACKAGER_JSON` 和 `Packager.JSON` 各有引用 |
| 是否有可合并的依赖？ | ❌ 无 — 每个 API 调用职责独立 |
| 是否有可内联的依赖？ | ❌ 无 — 所有依赖均为 lua-yar 核心功能，不可在适配层重新实现 |

**结论**：30 项依赖中 28 项必需、2 项便捷、**0 项冗余**。依赖关系精简无冗余。

---

## 十、总结

### 10.1 核心价值

`lua-resty-yar` 作为 OPM 适配层，核心价值在于：

1. **cosocket 注入**：通过 `Client.set_socket(ngx.socket)` 将 lua-yar 的出向连接从阻塞 luasocket 切换到非阻塞 cosocket，使其在 OpenResty worker 中安全运行
2. **进程级实例管理**：`_server`/`_tcp_server` 单例 + weak-value 客户端缓存，避免每请求重建对象
3. **HTTP/TCP 双协议适配**：自动检测 `ngx.req.socket()` 可用性，分发到 HTTP 或 TCP handler
4. **配置集中化**：`setup(config)` 统一入口，超时/连接池/packager 一站式配置

### 10.2 依赖健康度

| 指标 | 数值 | 评价 |
|------|------|------|
| 总依赖点 | 30 | 精简 |
| 必需率 | 93.3% (28/30) | 优秀 |
| 冗余率 | 0% (0/30) | 优秀 |
| 便捷率 | 6.7% (2/30) | 合理 |
| 直接 require lua-yar | 2 个模块 | 最小化 |
| 间接引用 lua-yar | 10 个 API + 2 个常量 | 职责清晰 |

### 10.3 已识别问题

| 严重度 | 问题 | 位置 | 影响 | 修复方案 |
|:---:|------|------|------|---------|
| **P0** | cosocket `setkeepalive()` 未透传 `keepalive_idle` 和 `pool_size` | `lua-yar/transport/socket.lua:117` | 连接池参数配置不生效，高并发连接复用效率降低 | `Socket.release(sock, opts)` 增加参数，透传 `sock:setkeepalive(idle, pool)` |
| P2 | `client.lua` 薄包装层无独立逻辑 | `resty-yar/client.lua` | 增加一层间接调用 | 可保留（语义化入口有价值）或内联 |
| P3 | `server/init.lua` 自动检测逻辑简单 | `resty-yar/server/init.lua` | 仅检测 `ngx.req.socket` 可用性 | 可保留（满足当前需求） |

### 10.4 改进路径

1. **P0 修复**（优先）：修改 `lua-yar/transport/socket.lua` 的 `Socket.release` 函数，透传 `keepalive_idle` 和 `pool_size` 到 `sock:setkeepalive(idle, pool)`，并在 `transport/http.lua` 和 `transport/tcp.lua` 的调用处传入 `self.options`
2. **可选优化**：在 `lua-resty-yar` 中增加 `keepalive` 配置项的运行时验证和日志告警，当配置了 `pool_size` 但 lua-yar 版本不支持透传时输出 `warn` 级别日志
3. **长期**：考虑在 lua-yar 中增加 `Socket.set_keepalive_opts(idle, pool)` 方法，使连接池参数配置更显式

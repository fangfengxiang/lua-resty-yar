# lua-resty-yar

[English](README.md) | [简体中文](README.zh.md)

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![OPM](https://img.shields.io/badge/OPM-lua--resty--yar-blue.svg)](https://opm.openresty.org/package/fangfengxiang/lua-resty-yar/)
[![Test](https://github.com/fangfengxiang/lua-resty-yar/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/fangfengxiang/lua-resty-yar/actions/workflows/test.yml)
[![Release](https://img.shields.io/github/v/release/fangfengxiang/lua-resty-yar)](https://github.com/fangfengxiang/lua-resty-yar/releases)

> **高性能 OpenResty Yar RPC 服务端。**
> 基于 [lua-yar](https://github.com/fangfengxiang/lua-yar) 的 OpenResty OPM 适配层 —— 提供 cosocket 注入、`content_by_lua` handler 入口、进程级实例管理，开箱即用。

[Yar](https://github.com/laruence/yar)（Yet Another RPC Framework）是 PHP 生态中流行的轻量级 RPC 框架。[lua-yar](https://github.com/fangfengxiang/lua-yar) 是纯 Lua 协议实现；**lua-resty-yar** 将其接入 OpenResty 非阻塞 I/O 运行时 —— 生产环境即装即用。

---

## 特性

- **HTTP 服务端 handler** — `content_by_lua` 入口，每请求独立协程，纯协议分发
- **TCP 流式服务端 handler** — stream `content_by_lua` 入口，每连接独立协程，keepalive 循环
- **cosocket 注入** — 出向 RPC 调用走 OpenResty 非阻塞 I/O，配合连接池实现 keepalive
- **yar-c 参数映射** — `READ_TIMEOUT` → 三段 cosocket 超时，`CHILD_INIT` → `on_worker_init` 钩子
- **进程级实例复用** — Server 实例在 `init_by_lua` 创建，worker 内所有协程共享
- **可选 C 扩展加速** — cjson / cmsgpack 自动注册，替代纯 Lua 编解码
- **lua-resty-http provider** — 可选的 HTTP 传输 provider 注入
- **结构化错误对象** — 5 类错误码（TRANSPORT / TIMEOUT / PROTOCOL / NOT_FOUND / EXCEPTION），支持 `err.code` 程序化匹配
- **Hooks 机制** — 请求/响应拦截（pcall 保护，未使用时零开销）

## 环境要求

- **OpenResty** >= 1.19.3.1
- **lua-yar** >= 0.1.0（通过 LuaRocks 或 OPM 安装）

## 安装

### OPM（推荐）

```bash
opm get fangfengxiang/lua-resty-yar
```

### 前置依赖：lua-yar

lua-resty-yar 依赖 [lua-yar](https://github.com/fangfengxiang/lua-yar)（纯 Lua 协议库），需先安装：

```bash
# 通过 LuaRocks
luarocks install lua-yar

# 或通过 OPM
opm install lua-yar
```

然后在 nginx 配置中确保 `lua_package_path` 包含 lua-yar 的源码路径（见快速开始）。

## 快速开始

### HTTP 服务端

```nginx
http {
    lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";

    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
                sub = function(a, b) return a - b end,
            }
        }
    }

    server {
        listen 8888;
        location /api {
            content_by_lua_block {
                require("resty.yar.server").serve()
            }
        }
    }
}
```

### TCP 流式服务端

```nginx
stream {
    lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";

    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
            }
        }
    }

    server {
        listen 9999;
        content_by_lua_block {
            require("resty.yar.server").serve()
        }
    }
}
```

> **更多示例：** `t/` 目录包含完整的 test-nginx 测试套件（`http.t`、`tcp.t`、`client.t`），覆盖 HTTP 服务端、TCP 流式服务端、客户端使用模式。

## API

### `require("resty.yar").setup(opts)`

在 `init_by_lua_block` 中调用一次。合并配置、注入 cosocket、创建 Server 实例。

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `service` | table | `{add, sub, greet}` | RPC 服务对象（函数字段 = RPC 方法） |
| `packager` | string | `"JSON"` | 响应编码：`"JSON"` 或 `"Msgpack"` |
| `connect_timeout` | number | `1000` | 连接超时（ms） |
| `send_timeout` | number | `5000` | 发送超时（ms） |
| `read_timeout` | number | `5000` | 读取超时（ms） |
| `keepalive_idle` | number | `60000` | TCP 保活空闲超时（ms） |
| `timeout` | number | `5000` | standalone `run()` 模式 per-message 超时（ms） |
| `client_timeout` | number | `3000` | 出向 RPC 默认超时（ms） |
| `pool_size` | number | `30` | cosocket 连接池容量 |
| `max_body_len` | number | `10485760` | 最大请求体长度（bytes） |
| `ssl_verify` | boolean | `true` | HTTPS 证书验证 |
| `on_worker_init` | function | `nil` | worker 初始化回调（CHILD_INIT 映射） |
| `log_level` | number | `INFO` | 日志级别（1=DEBUG ~ 4=ERROR） |
| `hooks` | table | `nil` | `{on_request=fn, on_response=fn}` 拦截 |
| `use_cjson` | boolean | `false` | 注册 cjson C 扩展加速 JSON 编解码 |
| `use_cmsgpack` | boolean | `false` | 注册 cmsgpack C 扩展加速 Msgpack 编解码 |
| `use_resty_http` | boolean | `false` | 注入 lua-resty-http 作为 HTTP 传输 provider |
| `json_max_depth` | number | `512` | JSON 最大嵌套深度（内置编解码器） |
| `msgpack_max_depth` | number | `512` | Msgpack 最大嵌套深度（内置编解码器） |

### 服务端 API

```lua
local yar = require("resty.yar")

-- 进程级 Server 实例（由 setup() 创建）
local server = yar.get_server()

-- worker 初始化钩子（在 init_worker_by_lua_block 中调用）
yar.init_worker()

-- 合并后的配置表
local config = yar.get_config()
```

**handler 入口**（在 `content_by_lua_block` 中调用）：

```lua
-- 自动检测 HTTP/stream 上下文（便捷入口，有微小 pcall 开销）
require("resty.yar.server").serve()

-- 直接调用（生产热路径，无检测开销）
require("resty.yar.server.http").serve()  -- HTTP 上下文
require("resty.yar.server.tcp").serve()  -- stream 上下文
```

### 客户端 API

#### `yar.new_client(uri, opts)`

创建新的 `Yar.Client` 实例，连接级参数从 `setup()` 配置预填。

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `uri` | string | — | 服务地址：`http://host/api` 或 `tcp://host:port` |
| `opts.timeout` | number | `client_timeout` | 每次调用超时（ms） |
| `opts.packager` | string | `"JSON"` | 请求编码 |
| `opts.connect_timeout` | number | `connect_timeout` | 连接超时（ms） |
| `opts.keepalive_idle` | number | `keepalive_idle` | 连接池空闲超时（ms） |
| `opts.pool_size` | number | `pool_size` | 连接池大小 |
| `opts.ssl_verify` | boolean | `true` | HTTPS 证书验证 |
| `opts.headers` | table | `nil` | 自定义 HTTP 头 |
| `opts.resolve` | string | `""` | 自定义 DNS（host:ip） |
| `opts.proxy` | string | `""` | HTTP 代理地址 |
| `opts.persistent` | boolean | `false` | 持久 TCP 连接（跨调用复用） |
| `opts.hooks` | table | `nil` | `{on_request=fn, on_response=fn}` |

```nginx
location /t {
    content_by_lua_block {
        local yar = require("resty.yar")
        local client = yar.new_client("http://127.0.0.1:8888/api")
        local result = client:call("add", { 1, 2 })  -- 返回 3
    }
}
```

#### `yar.get_client(uri, opts)`

返回按 `uri` 缓存的 persistent Client 实例。同一 `uri` 在 worker 内返回同一实例，实现跨调用 socket 复用。

```nginx
location /t {
    content_by_lua_block {
        local yar = require("resty.yar")
        local client = yar.get_client("tcp://127.0.0.1:9999")
        local r1 = client:call("add", { 1, 2 })     -- persistent，socket 复用
        local r2 = client:call("add", { 3, 4 })     -- 同一连接
    }
}
```

#### 错误处理

```lua
local ret, err = client:call("add", { 1, 2 })
if not ret then
    -- err 是结构化 Error 对象，通过 .code 匹配
    if err.code == require("resty.yar").Error.TIMEOUT then
        -- 超时处理
    end
end
```

### `require("resty.yar.client")` 模块

薄封装，提供 `new(uri, opts)` 和 `get(uri, opts)`：

```lua
local client = require("resty.yar.client").new("http://host/api")
local pclient = require("resty.yar.client").get("tcp://host:9999")
```

## yar-c 参数映射

| yar-c 参数 | OpenResty 等价物 | 方式 |
|-----------|-----------------|------|
| `READ_TIMEOUT` | `setup({connect_timeout, send_timeout, read_timeout})` | 通过 `sock:settimeouts()` 设三段 cosocket 超时 |
| `CHILD_INIT` | `setup({on_worker_init = fn})` + `init_worker()` | 在 `init_worker_by_lua_block` 中调用 |
| `PARENT_INIT` | `setup()` 本身 | 在 `init_by_lua_block` 中调用 |
| `CUSTOM_DATA` | `service` 对象闭包 | 通过 `setup({service = {...}})` 传入 |
| `MAX_CHILDREN` | `worker_processes` | nginx.conf 指令 |
| `PID_FILE` | `pid` | nginx.conf 指令 |
| `LOG_FILE` / `LOG_LEVEL` | `error_log` | nginx.conf 指令 |
| `CHILD_USER` / `CHILD_GROUP` | `user` | nginx.conf 指令 |

## 架构

```
+---------------------------------------------------------+
|              OpenResty (nginx + LuaJIT)                  |
|  +-----------------------------------------------------+|
|  |           lua-resty-yar（适配层）                    ||
|  |  +----------+  +----------+  +------------------+   ||
|  |  | init.lua |  | client   |  | server/          |   ||
|  |  | setup()  |  | new/get  |  | http/tcp/init    |   ||
|  |  | cosocket |  | 薄封装   |  | handler 入口     |   ||
|  |  | ngx.log  |  |          |  |                  |   ||
|  |  +----+-----+  +----+-----+  +--------+--------+   ||
|  |       |             |               |              ||
|  |       +-------------+---------------+             ||
|  |                     | 委托                          ||
|  +---------------------+------------------------------+|
|                        v                              |
|  +-----------------------------------------------------+|
|  |              lua-yar（协议库）                      ||
|  |  Server Facade / Dispatcher / Transport /           ||
|  |  Protocol / Framing / Packager / Message /          ||
|  |  Client / Error / Log                               ||
|  +-----------------------------------------------------+|
+---------------------------------------------------------+
```

适配层薄而清晰：cosocket 注入、`ngx.log` writer、handler 入口、配置桥接。所有协议逻辑（帧解析、header 校验、编解码、packager registry、hooks、Error 分类）全部委托 lua-yar。

## 文档

- [API 参考](docs/api.md) — 完整方法签名与选项
- [项目定位](docs/positioning.md) — lua-resty-yar 是什么、不是什么
- [设计决策 (ADR)](docs/design/decisions.md) — 11 个架构决策记录
- [评估报告](docs/reports/) — 工程化测评、依赖审计、优化计划

## 开发

### 前置条件

- OpenResty >= 1.19.3.1
- lua-yar（通过 LuaRocks 安装）
- Perl（用于 test-nginx）
- luacheck（用于代码检查）

### 运行测试

```bash
make test
```

### 代码检查

```bash
make lint
```

### OPM 构建验证

```bash
opm build
```

## License

[Apache License 2.0](LICENSE)

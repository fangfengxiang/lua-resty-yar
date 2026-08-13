# 配置桥接设计决策

配置桥接是 lua-resty-yar 将 OpenResty/nginx 配置参数映射到 lua-yar 嵌套选项结构的设计。

---

## 10. 嵌套选项结构桥接 lua-yar

- **状态**：已实现
- **决策驱动因素**：配置一致性
- **关联决策**：#1（适配层定位）、#11（yar-c 参数映射）

### 背景

lua-yar 的客户端选项采用嵌套结构（`transport.timeout` / `transport.keepalive.pool_size` / `protocol.packager`），对标 cosocket API 参数。lua-resty-yar 的 `setup(opts)` 接受扁平配置（`connect_timeout` / `pool_size` / `packager`），需要桥接到 lua-yar 的嵌套结构。

### 思考与取舍

> "Convention over configuration." — Rails 哲学
> "约定优于配置。" — Rails 哲学

决策：`setup(opts)` 接受扁平配置，`new_client(uri, opts)` 内部桥接到 lua-yar 嵌套结构。

**扁平配置的理由：**
- 用户在 nginx 配置中写 `setup({ connect_timeout = 2000 })` 比 `setup({ transport = { connect_timeout = 2000 } })` 更简洁
- 扁平配置是 OpenResty 社区惯例（lua-resty-redis 的 `redis:connect(host, port, opts)` 用扁平 opts）
- 嵌套结构是 lua-yar 协议库的内部需求，适配层负责桥接

**桥接实现：**
```lua
local client_opts = {
    transport = {
        timeout          = opts.timeout          or config.client_timeout,
        connect_timeout  = opts.connect_timeout  or config.connect_timeout,
        ssl_verify       = ssl_verify,
        keepalive = {
            idle_timeout = opts.keepalive_idle or config.keepalive_idle,
            pool_size    = opts.pool_size      or config.pool_size,
        },
    },
    protocol = {
        packager = opts.packager or config.packager,
    },
}
client:set_options(client_opts)
```

**配置分层：**
- `config` 表（模块级）：连接级参数（connect_timeout/send_timeout/read_timeout/keepalive_idle/pool_size/ssl_verify/resolve/proxy）
- `server_opts`（setup 内构造）：服务端级参数（packager/timeout/max_body_len/hooks/json_max_depth/msgpack_max_depth）
- `client_opts`（new_client 内构造）：客户端级参数（嵌套结构，桥接 lua-yar）

**EXCLUDE_FROM_CONFIG 机制：**
- 非连接级参数（service/on_worker_init/log_level/use_cjson/use_cmsgpack/use_resty_http/hooks/json_max_depth/msgpack_max_depth）不混入 config 表
- 这些参数是 setup 专用（一次性配置），handler 不需要读取

### 业界参考

- **lua-resty-redis**：`redis:connect(host, port, opts)` 扁平 opts（`pool` / `pool_size` / `backlog`）
- **lua-resty-http**：`httpc:connect(host, port, opts)` 扁平 opts（`ssl_verify` / `pool` / `pool_size`）
- **PHP Yar**：`Yar_Client::__construct($url, $options)` 扁平配置

### 代码评价

`init.lua` 的 `new_client()` 桥接逻辑清晰——从 `config` 和 `opts` 合并，构造嵌套 `client_opts`。`ssl_verify` 特殊处理 `false` 值（Lua `and/or` 短路将 false 视为 falsy，需显式 `if ssl_verify == nil then` 检查）。`hooks` 条件传递（`if opts.hooks then` 避免空表覆盖默认值）。`EXCLUDE_FROM_CONFIG` 用集合表实现，O(1) 查找。

### 知识领域

1. *The Pragmatic Programmer*（Hunt & Thomas）— 配置管理与约定
2. *YAR PHP Extension Spec* — Yar 客户端选项规范

---

## 11. yar-c 参数映射

- **状态**：已实现
- **决策驱动因素**：兼容性
- **关联决策**：#10（嵌套选项桥接）

### 背景

yar-c 是 Yar RPC 协议的 C 语言参考实现，绑定 libcurl（同步阻塞 I/O）。yar-c 有一套配置参数（`READ_TIMEOUT` / `CHILD_INIT` / `PARENT_INIT` 等），从 C 迁移到 OpenResty 的用户需要知道参数对应关系。

### 思考与取舍

> "Be liberal in what you accept, conservative in what you send." — Jon Postel
> "宽容地接受，保守地发送。" — Jon Postel

决策：提供 yar-c → OpenResty 参数映射表，帮助迁移用户理解对应关系。

**参数映射：**

| yar-c 参数 | OpenResty 等价 | 实现方式 |
|------------|---------------|---------|
| `READ_TIMEOUT` | `setup({connect_timeout, send_timeout, read_timeout})` | 三段 cosocket 超时 `sock:settimeouts()` |
| `CHILD_INIT` | `setup({on_worker_init = fn})` + `init_worker()` | `init_worker_by_lua_block` 调用 |
| `PARENT_INIT` | `setup()` 本身 | `init_by_lua_block` 调用 |
| `CUSTOM_DATA` | `service` 对象闭包 | `setup({service = {...}})` |
| `MAX_CHILDREN` | `worker_processes` | nginx.conf 指令 |
| `PID_FILE` | `pid` | nginx.conf 指令 |
| `LOG_FILE` / `LOG_LEVEL` | `error_log` | nginx.conf 指令 |
| `CHILD_USER` / `CHILD_GROUP` | `user` | nginx.conf 指令 |

**设计要点：**
- `READ_TIMEOUT` 拆分为三段超时（connect/send/read），因为 cosocket 的 `settimeouts` 支持三段独立配置，比 yar-c 的单一超时更精细
- `CHILD_INIT` 映射到 `on_worker_init` 回调 + `init_worker()` 函数，对标 PHP Yar 的 `CHILD_INIT` 阶段
- `PARENT_INIT` 映射到 `setup()` 本身，在 `init_by_lua_block` 调用
- nginx.conf 指令（`worker_processes` / `pid` / `error_log` / `user`）由 nginx 管理，lua-resty-yar 不干预

**为什么 READ_TIMEOUT 拆分为三段：**
- yar-c 用 libcurl 的 `CURLOPT_TIMEOUT`（单一总超时）
- cosocket 的 `settimeouts(connect, send, read)` 支持三段独立配置
- 三段超时更精细：连接阶段超时（可能 DNS 解析慢）与读取阶段超时（服务端处理慢）可独立诊断
- 对标 lua-resty-redis：`redis:settimeout(connect_timeout, send_timeout, read_timeout)`

### 业界参考

- **yar-c 源码**：`yar_server_init` / `yar_server_loop` / `READ_TIMEOUT` 宏定义
- **PHP Yar**：`Yar_Server::__construct($service, $options)` + `Yar_Client::__construct($url, $options)`
- **lua-resty-redis**：`redis:settimeout()` 三段超时设计
- **RFC 7230** — HTTP/1.1 消息语法，连接超时语义

### 代码评价

README 的"yar-c Parameter Mapping"表格清晰展示参数对应关系。`setup()` 的 `connect_timeout` / `send_timeout` / `read_timeout` 三个参数直接映射 cosocket `settimeouts`。`on_worker_init` 回调 + `init_worker()` 函数的设计对标 yar-c 的 `CHILD_INIT` 钩子。nginx.conf 指令不干预，保持 nginx 原生管理。

### 知识领域

1. *yar-c source code* — C 语言参考实现，参数定义
2. *RFC 7230* — HTTP/1.1 消息语法，连接超时语义

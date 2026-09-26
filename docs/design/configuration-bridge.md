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

---

## 13. 嵌套分域配置 Schema + flat 向后兼容

- **状态**：已实现
- **决策驱动因素**：配置可扩展性 / 框架演进
- **关联决策**：#10（嵌套选项桥接）、#7（ngx.log writer 注入）、#8（结构化 JSON 访问日志）

### 背景

决策 #10 将 `setup(opts)` 设计为扁平配置，桥接到 lua-yar 嵌套选项。适配层初期只有 server/client 两类参数，扁平足够。随框架演进（observability 集成 #7-#9、extensions C 扩展开关、未来 plugin/中间件配置），扁平 key 数量膨胀（20+），缺乏域归属标识，难以扩展和校验。

### 思考与取舍

> "Make the common case fast." — 计算机体系结构原则
> "让常见情况快速。" — 计算机体系结构原则

> "Be liberal in what you accept, conservative in what you send." — Jon Postel
> "宽容地接受，保守地发送。" — Jon Postel

决策：引入四域嵌套 DEFAULTS（server/client/observability/extensions），`config.merge()` 递归 `deep_merge` 合并用户覆盖。同时保留 flat 格式向后兼容——`convert_flat()` 检测顶层 flat key 自动映射到对应域，并 `ngx.log(ngx.WARN)` 提示弃用。

**四域划分依据 OpenResty 配置层级：**
- `server` — handler 层（packager/timeout/max_body_len/service/hooks）
- `client` — cosocket 层（timeout/connect_timeout/pool_size/ssl_verify 等）
- `observability` — log/shdict 层（metrics_dict/metrics_prefix/access_log/trace）
- `extensions` — C 扩展加速器开关（use_cjson/use_cmsgpack/use_resty_http）

**为什么不用单一 flat 表 + 前缀分组（如 `server_timeout` / `client_timeout`）：**
- 前缀命名冗长，且 Lua table 访问 `config.server_timeout` 不如 `config.server.timeout` 语义清晰
- 嵌套结构天然支持子域整体覆盖：`setup({ observability = { metrics_dict = "my_dict" } })` 只改一个值，其余取默认
- 嵌套结构与 lua-yar 内部选项结构对齐，减少桥接层转换

**flat 向后兼容策略：**
- `FLAT_MAP` 表定义 flat key → domain 映射（值为字符串时 domain key = flat key；值为 `{domain, key}` 时支持重命名，如 `client_timeout → client.timeout`）
- `convert_flat()` 检测 flat key，映射到嵌套结构，nested 优先（同时提供 flat 和 nested 时用 nested 值，WARN 日志提示冲突）
- `max_body_len` 特殊处理：同时复制到 server 和 client 两个域（协议层和服务端都需要此限制）
- 弃用提示：检测到 flat 格式时 `ngx.log(ngx.WARN, ...)` 提示迁移到嵌套格式，不中断运行

**类型校验 fail-fast：**
- `TYPE_SPEC` 表定义域 → 键 → 期望类型
- `validate()` 在 `init_by_lua` 阶段（`setup()` 调用时）校验，类型不匹配 `error(msg, 2)` 指向调用方
- 编程错误（类型错误）用 `error()`，运行时错误（配置缺失/默认值）用默认值兜底

**deep_merge 设计：**
- 递归合并 table 值（子表也深合并），标量值直接覆盖
- 不修改入参（返回新表），避免 DEFAULTS 被污染
- 对标 Lua 社区惯例：lua-resty-core `ngx.config` 也用嵌套表

### 业界参考

- **lua-resty-core**：`ngx.config` 嵌套配置结构
- **lor**（OpenResty web 框架）：`app.conf` 嵌套配置 + 默认值合并
- **Kong**： declarative config 用 YAML 嵌套结构，`kong.configuration` 表分域
- **nginx.conf** 本身：`http {}` / `server {}` / `location {}` 嵌套分域，指令继承+覆盖语义

### 代码评价

`config.lua` 实现简洁（244 行）：`DEFAULTS` 表自文档化（四域一目了然），`FLAT_MAP` 表驱动映射（添加新 flat key 只需加一行），`TYPE_SPEC` 表驱动校验（扩展校验只加一行），`deep_merge` 递归但无循环引用风险（DEFAULTS 是纯数据无元表）。`convert_flat()` 的 nested 优先 + WARN 冲突提示确保迁移期安全。`validate()` 的 `error(msg, 2)` level=2 指向 `setup()` 调用方（nginx.conf 中 `init_by_lua_block`），报错信息含域名+键名+期望类型+实际类型，开发者可直接定位。

### 知识领域

1. *The Pragmatic Programmer*（Hunt & Thomas）— 配置管理与约定
2. *nginx documentation* — 嵌套配置块继承与覆盖语义

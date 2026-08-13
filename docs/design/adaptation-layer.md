# 适配层定位设计决策

适配层定位是 lua-resty-yar 最核心的架构决策——它是什么、不是什么、如何与 lua-yar 分工。

---

## 1. 适配层定位：OPM 适配层而非独立实现

- **状态**：已实现
- **决策驱动因素**：不重复造轮子
- **关联决策**：#4（HTTP handler 委托）、#5（TCP handler 委托）、#10（配置桥接）

### 背景

Yar RPC 协议有多个语言实现：PHP Yar（PHP 原生）、yar-c（C 语言 + libcurl）、lua-yar（纯 Lua 协议库）。lua-yar 定位为运行时无关的纯协议库 / SDK，不绑定任何特定运行时。

OpenResty 是基于 nginx + LuaJIT 的高性能 Web 平台，提供 cosocket（非阻塞 I/O）、ngx.log（日志）、ngx.req（请求处理）等原生能力。lua-yar 默认使用 luasocket（阻塞 I/O），在 OpenResty 中需要适配才能发挥非阻塞 I/O 优势。

### 思考与取舍

> "Don't repeat yourself." — Hunt & Thomas
> "不要重复自己。" — Hunt & Thomas

决策：lua-resty-yar 定位为 **OPM 适配层**，而非独立协议实现。

**选择适配层而非独立实现的理由：**
- lua-yar 已有完整的协议实现（帧解析、header 校验、JSON/Msgpack 编解码、packager registry、hooks 机制、结构化 Error），重新实现是重复劳动
- 适配层职责单一：cosocket 注入、ngx.log 桥接、handler 入口、配置映射——薄而清晰
- 协议演进时只需更新 lua-yar，适配层无需改动
- 对标业界：lua-resty-redis 是 lua-resty-core 对 redis 服务的适配，不重新实现 RESP 协议

**不适配的部分（保持 lua-yar 原样）：**
- 协议解析（Protocol.parse / Protocol.render）
- 帧处理（Framing.receive_exact / receive_message）
- 编解码（Json.pack / Msgpack.pack）
- 错误分类（Error.new + 5 错误码）
- hooks 机制（on_request / on_response + pcall 保护）

### 业界参考

- **lua-resty-core**：OpenResty 对 ngx API 的 FFI 适配层，不重新实现 nginx 功能
- **lua-resty-redis**：对 Redis 服务的 cosocket 适配，不重新实现 RESP 协议
- **lua-resty-http**：HTTP 客户端库，cosocket 原生实现（因没有独立的 HTTP 协议库可适配）

### 代码评价

`init.lua` 的 `setup()` 函数是适配层的核心——10 行代码完成全部适配：cosocket 注入、ngx.log writer 注入、Server Facade 创建、配置合并。handler 文件（http.lua/tcp.lua）各 30-50 行，只做 I/O 桥接和委托。适配层总代码量 < 300 行，远小于 lua-yar 协议核心。

### 知识领域

1. *The Pragmatic Programmer*（Hunt & Thomas）— DRY 原则与适配层设计
2. *The Art of Unix Programming*（Raymond）— "Do one thing and do it well" 与职责单一

---

## 2. OPM 目录结构：lib/resty/yar/ 层级

- **状态**：已实现
- **决策驱动因素**：社区惯例
- **关联决策**：#1（适配层定位）

### 背景

OpenResty 包管理器（OPM）要求库代码放在 `lib/` 下，模块路径通过 `lua_package_path` 解析。目录结构需要符合 OPM 惯例，同时保持与 lua-yar 的命名区分（lua-yar 用 `yar.` 模块路径，lua-resty-yar 用 `resty.yar.`）。

### 思考与取舍

> "Convention over configuration." — Rails 哲学
> "约定优于配置。" — Rails 哲学

决策：采用 `lib/resty/yar/` 层级结构。

**目录结构：**
```
lib/resty/yar/
├── init.lua          # 主入口：setup / get_server / new_client / get_client
├── client.lua        # 客户端薄封装
└── server/
    ├── init.lua      # 自动检测入口
    ├── http.lua      # HTTP handler
    └── tcp.lua       # TCP stream handler
```

**选择 `resty.yar` 而非 `yar` 模块路径的理由：**
- OPM 惯例：`resty.*` 前缀是 OpenResty 生态的命名空间约定（lua-resty-core、lua-resty-http、lua-resty-redis 均如此）
- 避免与 lua-yar 的 `yar` 模块路径冲突——用户可同时 `require("yar")` 和 `require("resty.yar")`
- `resty.yar.server` vs `yar.server`：前者是 OpenResty 适配层入口，后者是协议库入口，语义清晰

**dist.ini 配置：**
- `lib_dir=lib` — OPM 包代码根目录
- `main_module=lib/resty/yar/init.lua` — 主模块入口
- `requires = luajit, openresty >= 1.19.3.1, lua-yar >= 0.1.0` — 依赖声明

### 业界参考

- **lua-resty-core**：`lib/resty/core/` 结构，`resty.core.*` 模块路径
- **lua-resty-http**：`lib/resty/http.lua`，`resty.http` 模块路径
- **lua-resty-redis**：`lib/resty/redis.lua`，`resty.redis` 模块路径
- **OPM 文档**：`lib_dir` 指定代码根目录，`lua_package_path` 解析 `?.lua` 和 `?/init.lua`

### 代码评价

目录结构简洁——5 个 Lua 文件，职责清晰。`init.lua` 是主入口（setup + 实例管理），`client.lua` 是薄封装（委托 init），`server/` 是 handler 三件套（自动检测 + HTTP + TCP）。与 lua-yar 的 `src/yar/` 结构对称，便于理解对应关系。

### 知识领域

1. *OPM Documentation* — 包结构与 lua_package_path 解析规则
2. *lua-resty-core 源码* — `resty.*` 命名空间惯例

---

## 3. 进程级 Server 实例复用

- **状态**：已实现
- **决策驱动因素**：性能
- **关联决策**：#1（适配层定位）、#5（TCP handler 委托）

### 背景

OpenResty 的 `init_by_lua` 阶段在 master 进程加载时执行一次，`init_worker_by_lua` 在每个 worker 启动时执行。Server Facade 实例（含 dispatcher + 方法表 + packager）创建开销集中在方法表收集和 packager 初始化，不应每请求重建。

### 思考与取舍

> "The fastest I/O is no I/O." — Mythical Man-Month
> "最快的 I/O 是不做 I/O。" — 人月神话

决策：Server Facade 实例在 `init_by_lua` 阶段创建一次，worker 内全局复用。

**实现方式：**
- `setup()` 在 `init_by_lua` 调用，创建 `_server` 模块级局部变量
- `get_server()` 返回缓存的 `_server`，所有 handler 共享同一实例
- handler 函数模块级缓存 `_server` 引用，避免每请求调用 `get_server()`

**为什么 worker 内复用是安全的：**
- Server Facade 的 `handle(spec)` / `handle_message(data)` 是纯协议函数，无 I/O、无 yield、reentrant
- dispatcher 的方法表（`self.methods`）是只读的（构造后不变），元表查找是只读操作
- 每请求/连接独立协程，实例数据 per-instance（request/response 对象在 handle_message 内创建）
- 对标 lua-resty-redis：`resty.redis` 实例可跨请求复用（连接池模式），lua-resty-yar 的 Server 实例复用同理

**与 lua-yar 原生模式的区别：**
- lua-yar 原生模式：`Server:listen(addr)` + `Server:loop()` 顺序阻塞，Server 实例生命周期与进程绑定
- lua-resty-yar 模式：nginx 管理连接生命周期（accept + 协程调度），Server 实例只做协议处理，worker 内复用

### 业界参考

- **lua-resty-core**：`ngx.re.*` 模块在 `init_by_lua` 预编译正则，worker 内复用
- **lua-resty-redis**：连接池模式，`resty.redis` 实例跨请求复用 cosocket
- **PHP Yar**：`Yar_Server` 实例在 `parent_init` 创建，`CHILD_INIT` 阶段初始化，worker 进程 fork 后继承

### 代码评价

`init.lua` 用模块级局部变量 `_server` 缓存，`get_server()` 做初始化检查（未初始化则 `error()`）。handler 文件用模块级 `_server` 做二次缓存（避免每请求调用 `get_server()` 函数开销）。两层缓存设计合理——init 层做初始化守卫，handler 层做热路径优化。

### 知识领域

1. *Release It!*（Nygard）— 实例复用与连接池模式
2. *Programming in Lua*（Ierusalimschy）— 协程安全与元表查找

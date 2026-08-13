# Handler 委托策略设计决策

Handler 委托是 lua-resty-yar 的核心实现——HTTP/TCP handler 如何将 OpenResty 的 I/O 能力桥接到 lua-yar 的协议处理。

---

## 4. HTTP handler 委托 serve_callback

- **状态**：已实现
- **决策驱动因素**：消除重复逻辑
- **关联决策**：#1（适配层定位）、#6（自动检测）

### 背景

lua-yar 的 HTTP 传输层提供 `serve_callback(spec, dispatcher, opts)` 模式（WSGI-style），封装了 GET 内观 / 405 / 400 / 413 / handle_message / 响应写入全部逻辑。lua-resty-yar 的 HTTP handler 需要将 OpenResty 的 `ngx.req` / `ngx.status` / `ngx.header` / `ngx.print` 桥接到 serve_callback 的 `writer(status, headers, body)` 回调。

### 思考与取舍

> "Don't repeat yourself." — Hunt & Thomas
> "不要重复自己。" — Hunt & Thomas

决策：HTTP handler 委托 `server:handle({ method, data, writer })`，不手动实现 HTTP 逻辑。

**委托而非手动实现的理由：**
- lua-yar `serve_callback` 已封装全部 HTTP 语义（GET 内观返回方法列表 JSON、POST 分发 handle_message、405/400/413 错误处理、Content-Type 设置）
- 手动实现会重复 ~60 行逻辑，且行为可能与 lua-yar 不一致
- writer 回调 `function(status, headers, body) ngx.status=status; ngx.header[k]=v; ngx.print(body) end` 是 WSGI 标准模式，简洁清晰

**handler 只做两件事：**
1. 读请求体（含大 body 临时文件回退——serve_callback 不处理此场景）
2. 构造 spec 并委托 `server:handle()`

**writer 回调参数顺序 = HTTP 线序 = 回调执行序：**
- `status` → `headers` → `body`
- 对标 WSGI `start_response(status, headers)` + `response_body`
- `ngx.status` 必须在 `ngx.header` 和 `ngx.print` 之前设置（OpenResty 要求）

**max_body_len 语义统一：**
- 旧代码检查 `#data > max_body_len + HEADER_TOTAL`（payload + 90 字节 header）
- serve_callback 检查 `#data > max_body_len`（完整消息长度上限）
- 10MB 默认值下 90 字节差异可忽略，统一语义更符合直觉

### 业界参考

- **WSGI (PEP 333)**：`start_response(status, response_headers)` + `response_body`，writer 回调对标此模式
- **lua-resty-http**：`httpc:request()` 返回 `res.status` / `res.headers` / `res.body`，三段式响应结构
- **Express.js**：`res.status(code).set(headers).send(body)`，链式调用但语义相同

### 代码评价

`http.lua` 仅 30 行（不含注释），逻辑清晰：读 body → 构造 writer → 委托 handle。writer 回调 5 行完成 ngx 输出桥接。大 body 临时文件回退保留（serve_callback 不处理 `ngx.req.get_body_file()` 场景）。模块级 `_server` 缓存避免每请求调用 `get_server()`。

### 知识领域

1. *WSGI (PEP 333)* — Python Web 服务器网关接口，writer 回调模式
2. *lua-resty-http 源码* — OpenResty HTTP 客户端实现参考

---

## 5. TCP handler 委托 handle({socket})

- **状态**：已实现
- **决策驱动因素**：统一 Server 实例
- **关联决策**：#1（适配层定位）、#3（进程级实例复用）

### 背景

lua-yar Server Facade 的 `handle(spec)` 根据 spec 内容分发：`spec.socket` → TCP/HTTP socket 模式（委托 TcpTransport.serve / HttpTransport.serve），`spec.{method, data, writer}` → HTTP callback 模式。TCP handler 需要将 OpenResty stream 模块的下游 cosocket 传给 Server Facade。

### 思考与取舍

> "Favor object composition over class inheritance." — Gang of Four
> "优先组合而非继承。" — 四人帮

决策：TCP handler 委托 `server:handle({ socket=sock, keepalive=true })`，不直接调用 TcpTransport。

**委托而非直接调用的理由：**
- lua-yar 旧 API 有分离的 `TcpServer` 类和 `handle_connection(sock, opts)` 方法，已移除
- 统一 Server Facade 的 `handle({socket=sock})` 根据 `self.protocol` 分发到 TcpTransport.serve
- handler 不需要知道 TcpTransport 的存在——Facade 隐藏内部架构

**handler 只做三件事：**
1. 获取下游 cosocket（`ngx.req.socket()`）
2. 设置三段超时（connect/send/read）
3. 委托 `server:handle({ socket=sock, keepalive=true })`

**keepalive=true 的语义：**
- TcpTransport.serve 内部处理 keepalive 循环——一个 TCP 连接处理多条 YAR 消息
- 对标 HTTP keepalive：一个 TCP 连接处理多个 HTTP 请求
- 连接复用减少 TCP 握手开销

**优雅关闭：**
- `pcall(sock.shutdown, sock, "send")` — lingering close，避免内核发 RST
- `pcall(sock.close, sock)` — stream 下游 socket 由 nginx 管理生命周期，close 可能失败，pcall 包裹忽略

### 业界参考

- **lua-resty-redis**：`redis:subscribe()` 委托 cosocket，连接复用
- **nginx stream module**：`content_by_lua_block` 提供下游 cosocket，handler 委托业务逻辑
- **PHP Yar TCP 模式**：`Yar_Server` 接受 TCP 连接，循环处理请求（keepalive）

### 代码评价

`tcp.lua` 仅 25 行（不含注释），逻辑清晰：获取 socket → 设超时 → 委托 handle。三段超时从 config 读取，连接级配置。优雅关闭用 pcall 包裹，符合"不可控第三方 API 用 pcall"原则（socket 可能已关闭）。模块级 `_server` 缓存同 HTTP handler。

### 知识领域

1. *Design Patterns*（GoF）— 组合优于继承，Facade 隐藏内部架构
2. *Programming in Lua*（Ierusalimschy）— 协程安全与 socket 复用

---

## 6. 自动检测 HTTP/stream 上下文

- **状态**：已实现
- **决策驱动因素**：易用性
- **关联决策**：#4（HTTP handler 委托）、#5（TCP handler 委托）

### 背景

OpenResty 的 `http {}` 和 `stream {}` 两个上下文都可以用 `content_by_lua_block`。HTTP 上下文有 `ngx.req.get_method()`，stream 上下文没有。用户可能希望用一个统一入口 `require("resty.yar.server").serve()` 自动检测上下文，而非手动选择 http/tcp handler。

### 思考与取舍

> "Make the common case fast." — 计算机体系结构原则
> "让常见情况快。" — 计算机体系结构原则

决策：提供 `server/init.lua` 统一入口，用 `pcall(ngx.req.get_method)` 检测上下文。

**自动检测而非强制指定的理由：**
- 易用性：用户只需记住一个入口 `require("resty.yar.server").serve()`
- nginx 配置中 HTTP 和 stream 的 `content_by_lua_block` 语法相同，自动检测减少配置错误

**性能取舍：**
- 每请求一次 `pcall(ngx.req.get_method)` 开销极小（pcall + 一次函数调用）
- 生产环境热路径建议直接调用 `require("resty.yar.server.http").serve()` 或 `.tcp.serve()`，避免 pcall 开销
- 文档明确提示此取舍

**检测原理：**
- HTTP 上下文：`ngx.req.get_method()` 返回 "GET"/"POST"/...
- stream 上下文：`ngx.req.get_method()` 抛错（ngx.req 不可用）
- `pcall` 捕获错误，ok=true → HTTP，ok=false → stream

### 业界参考

- **nginx stream module**：`content_by_lua_block` 在 stream 上下文提供下游 cosocket
- **lua-resty-core**：`ngx.req.get_method()` 仅在 HTTP 上下文可用
- **OpenResty 文档**：HTTP 和 stream 上下文的 ngx API 差异

### 代码评价

`server/init.lua` 仅 15 行（不含注释），逻辑简洁。`pcall(ngx.req.get_method)` 检测 + `require` 延迟加载对应 handler。注释明确提示"生产环境热路径建议直接调用 http/tcp handler 以避免 pcall 开销"，帮助用户做性能取舍。

### 知识领域

1. *The Art of Unix Programming*（Raymond）— "Make the common case fast" 与易用性
2. *nginx stream module docs* — HTTP/stream 上下文差异

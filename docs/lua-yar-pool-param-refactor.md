# 从 lua-resty-yar 反向审视 lua-yar

> 本文档站在 lua-resty-yar（OpenResty OPM 适配层）的视角，参考 yar-c / yar-php 的定位实现，结合业界 Lua 网络库与 OPM 包的工程化实践，对 lua-yar（纯 Lua 协议库）的代码与实现进行系统性反向审视。

---

## 一、定位参照系

### 1.1 yar-c 的定位

yar-c 是 Yar 的 C 语言实现，定位为**自带进程管理的 TCP daemon**：

- libevent 事件驱动 + pre-fork 多 worker
- 11 项 daemon 运维选项（`PID_FILE` / `LOG_FILE` / `LOG_LEVEL` / `CHILD_USER` / `CHILD_GROUP` / `MAX_CHILDREN` / `READ_TIMEOUT` / `PARENT_INIT` / `CHILD_INIT` / `CUSTOM_DATA` / `STAND_ALONE`）
- 仅支持 msgpack，不支持 JSON
- 仅支持 TCP/Unix socket 传输，不支持 HTTP
- 协议核心与传输层耦合（server 绑定 libevent I/O）

### 1.2 yar-php 的定位

PHP yar 扩展是 Yar 的原始实现，定位为 **PHP-FPM/Apache 模块内的 RPC 客户端 + 服务端**：

- 客户端选项丰富（9 项 `YAR_OPT_*`：packager / timeout / connect_timeout / persistent / header / token / provider / resolve / proxy）
- 服务端委托 PHP-FPM 进程管理，自身只做协议派发
- 支持 JSON / Msgpack 双 packager
- 支持 HTTP 传输（PHP 天然 Web 语境）

### 1.3 lua-yar 的定位

lua-yar 定位为**纯 Lua 协议库，不绑定运行时**：

- 零 C 扩展依赖（JSON / Msgpack 纯 Lua 实现）
- 协议核心（`handle_message`）与传输层解耦
- Socket 提供者抽象（luasocket 默认，cosocket 可注入）
- `handle_connection` 与 `run` 分离，并发能力按需引入

### 1.4 lua-resty-yar 的定位

lua-resty-yar 定位为 **OpenResty OPM 适配层**：

- 将 lua-yar 的协议能力适配到 OpenResty 的 `content_by_lua` / `init_by_lua` / `init_worker_by_lua` 生命周期
- 注入 cosocket（`Client.set_socket(ngx.socket)`），出向 RPC 走非阻塞 I/O + 连接池
- 进程级 Server / TcpServer 实例复用（`init_by_lua` 创建，worker 内共享）
- 将 yar-c 的 `READ_TIMEOUT` 映射为 cosocket 三段超时，`CHILD_INIT` 映射为 `init_worker_by_lua` 钩子

**关系链**：`yar-c / yar-php` → `lua-yar`（协议库）→ `lua-resty-yar`（OpenResty 适配层）

---

## 二、做得好的地方

### 2.1 协议核心与传输层完全解耦

**表现**：`handle_message(data)` 是纯协议函数，接收一条完整 YAR 二进制消息，解析 → 派发 → 渲染响应，全程无 I/O、无 yield、reentrant。

**理由**：

- lua-resty-yar 的 HTTP handler 在 `content_by_lua` 中直接调用 `server:handle_message(data)`，OpenResty 每请求一协程，N 个并发请求 = N 个协程并行调用同一个进程级 Server 实例，天然安全
- 对比 yar-c：server 绑定 libevent I/O，协议处理和传输耦合在同一个事件循环中，无法被外部运行时复用
- 对比 gRPC-Go 的 `ServiceDesc` 与传输分离、Twisted 的 Protocol/Transport 分离，lua-yar 的三层分离（`handle_message` / `handle_connection` / `run`）是 RPC 框架设计的最佳实践

**lua-resty-yar 侧收益**：无需包装或代理 `handle_message`，直接透传即可。HTTP handler 只负责读 body / 写 response，协议逻辑全在 lua-yar。

### 2.2 Socket 提供者抽象

**表现**：`transport/socket.lua` 用 `wrap(s)` + 鸭子类型检测（`settimeouts` / `setkeepalive` / `poolable`）实现跨运行时抽象。lua-resty-yar 在 `setup()` 中一行 `Client.set_socket(ngx.socket)` 即完成 cosocket 注入。

**理由**：

- 与 Go `DialContext` / `Transport` 接口思路一致 — 不绑定具体网络实现，通过接口注入
- 对比 `lua-resty-http`（硬绑定 cosocket，仅 OpenResty 可用）、`lua-http`（硬绑定 cqueues，C 扩展），lua-yar 一份代码覆盖 luasocket + cosocket 两个生态
- 超时统一为毫秒（luasocket 秒 → cosocket 毫秒），消除了两个生态的 API 差异

**lua-resty-yar 侧收益**：框架代码零 `ngx` 引用、零分支判断，出向 RPC 自动走 cosocket 非阻塞 I/O + 连接池。

### 2.3 Packager 自适应

**表现**：`handle_message` 从消息头部前 8 字节读取 packager 名称，按客户端声明的 packager 解析与响应。服务端无需预配置 packager。

**理由**：

- 对比 yar-c 写死 msgpack，lua-yar 更灵活
- 客户端用 JSON 发，服务端用 JSON 解；用 msgpack 发，用 msgpack 解。响应也用同一 packager 回写
- lua-resty-yar 的 `setup()` 虽然设置了默认 packager，但仅作为 fallback（请求头 packager 未知时）

**lua-resty-yar 侧收益**：无需在适配层管理 packager 匹配逻辑，一个 Server 实例同时服务 JSON 和 msgpack 客户端。

### 2.4 `handle_connection` 与 `run` 分离

**表现**：`TcpServer:handle_connection(client, opts)` 是连接级处理函数，与 `run(addr)` 的 accept 循环分离。`handle_connection` 可由任意协程运行时调度。

**理由**：

- `run(addr)` 是阻塞 accept 循环（开发/测试用），`handle_connection` 是连接级 handler（可并发调度）
- lua-resty-yar 的 TCP handler 直接调用 `tcp_server:handle_connection(sock, {keepalive=true})`，复用 lua-yar 内置的帧读取 + keepalive 循环
- 对比 yar-c 的 server 绑定 libevent 事件循环，lua-yar 的分离设计让 OpenResty stream 模块可以直接复用

**lua-resty-yar 侧收益**：TCP handler 只需组装：拿 socket → 设超时 → 委托 `handle_connection` → 关闭，无需重新实现帧读取和 keepalive 逻辑。

### 2.5 `handle_message` 内部 pcall 用户方法

**表现**：`handle_message` 内部用 `pcall(func, unpack(args))` 包裹用户 RPC 方法，方法抛错时返回 YAR 错误响应（`s=1, e=err_msg`），而非向上抛出 Lua 异常。

**理由**：

- 用户方法（如 `function(a, b) error("db down") end`）抛错不会 crash server
- 错误被捕获并编码进 YAR response body 的 `e` 字段，客户端能收到结构化错误信息
- 对比 yar-c 需要在 C 层手动 `try/catch`，lua-yar 用 Lua 原生 `pcall` 更简洁

**lua-resty-yar 侧收益**：HTTP handler 虽然额外包了一层 `pcall` 作为 defense-in-depth，但实际 `handle_message` 已不会因用户方法异常而抛出。这层 pcall 主要是防御协议解析层面的边界异常。

### 2.6 零 C 扩展依赖的序列化器

**表现**：内置纯 Lua JSON（~240 行）和 MessagePack（~370 行），用闭包保证可重入性，用纯数学实现 IEEE754 double 编解码。

**理由**：

- 兼容 Lua 5.1 / LuaJIT / 5.3+（不依赖 `string.pack`，LuaJIT 无此函数）
- 闭包持有解析状态（`str/pos/len` 作为 upvalue），多协程并发安全，无需锁
- `Packager.register` 预留扩展点，未来可注入 cjson / cmsgpack 高性能版本

**lua-resty-yar 侧收益**：无需在 OPM 包中额外依赖 cjson（虽然 OpenResty 内置），lua-yar 自带的序列化器已足够。生产环境如需高性能路径，可通过注册注入。

### 2.7 错误前缀分类

**表现**：`Client:call()` 失败时返回 `nil, err`，`err` 字符串带前缀：`transport:` / `timeout:` / `protocol:` / 无前缀（协议内错误）。

**理由**：

- Lua 惯例的字符串前缀分类法，调用方用 `string.match` 做错误路由，无需引入 error code 常量
- 对比 yar-c 返回 `NULL` 无错误分类，PHP yar 返回 `false` + `trigger_error`
- 四类错误对应四个处理层面：传输层（检查连接）、超时（调大 timeout）、协议层（检查 packager）、方法级（业务错误）

**lua-resty-yar 侧收益**：网关场景中，lua-resty-yar 可以根据错误前缀决定是否重试（`transport:` 可重试，`protocol:` 不可重试）。

### 2.8 Framing 层共享

**表现**：`protocol/framing.lua` 的 `receive_exact(sock, n)` 和 `receive_message(sock)` 被客户端（`transport/tcp.lua`）和服务端（`server/tcp.lua`）共用。

**理由**：

- TCP 流式读取的 partial read 问题（`receive(n)` 可能返回少于 n 字节）在 `receive_exact` 中统一处理
- `MAX_BODY_LEN = 10MB` 防止恶意大 body 导致内存耗尽
- 客户端和服务端共用同一帧拆解逻辑，避免重复实现和不一致

**lua-resty-yar 侧收益**：TCP handler 无需自行实现帧读取，`handle_connection` 内部已调用 `Framing.receive_message`。

### 2.9 Persistent 连接的 partial send 处理

**表现**：`Tcp:send(data)` 在 persistent 模式下，缓存的 socket 发送失败时区分 `sent > 0`（partial send，不可重试）和 `sent == nil/0`（安全重试）。

**理由**：

- `sent > 0`：部分数据已到达服务端，服务端可能已处理请求，重发会导致重复执行
- `sent == nil/0`：数据未到达服务端，安全走新建连接逻辑
- 这是正确的 TCP 语义处理，对比简单的"失败就重试"策略更安全

**lua-resty-yar 侧收益**：`get_client(uri)` 返回的 persistent 客户端在连接断开时能正确恢复，不会因 partial send 重试导致业务数据重复。

---

## 三、需要改进的方向

### 3.1 连接池参数无法透传（核心问题）

**表现**：`Socket.release(sock)` 调用 `sock:setkeepalive()` **不带参数**，使用 cosocket 默认值（idle 60s, pool 60）。lua-resty-yar 的 `setup()` 虽然在配置中引入了 `pool_size` / `keepalive_idle`，但无法透传到 cosocket。

**理由**：

- OpenResty cosocket 的 `setkeepalive(max_idle_timeout, pool_size)` 支持两个参数，控制连接池容量和空闲超时
- lua-yar 的 `release(sock)` 签名不接受 options，`Tcp:send` / `Tcp:close` / `Http.request` 调用 `release` 时也不传 `self.options`
- lua-resty-yar 在 `new_client` 中设置了 `keepalive_idle` 和 `pool_size` 到 client options，但这些参数在 `release` 时被丢弃
- 影响：高并发场景下连接池容量无法调优，空闲连接回收时间不可控

**改造方案**（已在 lua-yar 侧实施）：

```lua
-- socket.lua
function M.release(sock, opts)
    if sock.setkeepalive then
        local idle = opts and opts.keepalive_idle
        local size = opts and opts.pool_size
        if idle and size then
            sock:setkeepalive(idle, size)
        elseif idle then
            sock:setkeepalive(idle)
        else
            sock:setkeepalive()
        end
    else
        sock:close()
    end
end

-- tcp.lua / http.lua 调用处传 self.options
Socket.release(sock, self.options)
```

**lua-resty-yar 侧配合**：`new_client` 中已设置 `keepalive_idle` / `pool_size` 到 client options，lua-yar 改造后自动透传，无需适配层额外处理。

### 3.2 三段超时未在传输层充分使用

**表现**：lua-yar 的传输层（`tcp.lua` / `http.lua`）只使用 `timeout`（单一值）和 `connect_timeout` 两个超时参数。`Socket.set_timeouts(sock, connect_t, send_t, read_t)` 虽然支持三段，但调用处传入的是 `(connect_timeout, timeout, timeout)` — send 和 read 共用同一个值。

**理由**：

- OpenResty cosocket 的 `settimeouts(connect, send, read)` 支持三段独立超时，这是 cosocket 相对 luasocket 的优势
- lua-resty-yar 的 `setup()` 已定义 `connect_timeout` / `send_timeout` / `read_timeout` 三个参数，但 `new_client` 只传了 `connect_timeout` 和 `timeout`（作为 `client_timeout`），没有独立的 `send_timeout` / `read_timeout`
- 实际场景中，连接超时、发送超时、读取超时往往需要不同值：连接超时通常较短（网络不通快速失败），读取超时可能较长（等待服务端处理）
- yar-c 的 `READ_TIMEOUT` 是单一值，但 OpenResty cosocket 支持更细粒度的控制，不利用是浪费

**改进方向**：

- lua-yar 传输层增加 `send_timeout` / `read_timeout` 选项（可选，不传时退化为 `timeout`）
- `Socket.set_timeouts(sock, connect_t, send_t or timeout, read_t or timeout)` 兼容退化
- lua-resty-yar 的 `new_client` 传入三段超时

### 3.3 `handle_connection` 缺少超时契约文档

**表现**：`TcpServer:handle_connection(client, opts)` 接受 `{keepalive=bool}` 选项，但不接受超时参数。调用方需要在调用前自行设置 socket 超时。

**理由**：

- lua-resty-yar 的 TCP handler 在调用 `handle_connection` 前用 `sock:settimeouts(connect, send, read)` 设置超时，`handle_connection` 内部使用 socket 时依赖超时已设好
- 这个"调用方负责设超时"的契约是隐式的，没有在 `handle_connection` 的文档中说明
- 如果调用方忘记设超时，`handle_connection` 内部的 `Framing.receive_message` 会使用 socket 的默认超时（cosocket 默认 60s），可能导致慢连接占用协程过久

**改进方向**：

- 在 `handle_connection` 的 ldoc 注释中明确说明"调用方应在调用前设置 socket 超时"
- 或在 `opts` 中增加 `connect_timeout` / `send_timeout` / `read_timeout` 字段，`handle_connection` 内部调用 `Socket.set_timeouts`

### 3.4 HTTP 传输层手写 HTTP/1.1 协议

**表现**：`transport/http.lua` 手写 HTTP/1.1 请求构建（请求行 + headers + body）和响应解析（status line + headers + chunked/content-length body）。

**理由**：

- YAR over HTTP 仅需 POST 二进制 body，手写 HTTP 降低了依赖，但增加了协议解析的维护负担
- chunked transfer encoding 的解析逻辑（按 chunk size 行读取）虽然正确，但手写容易遗漏边界情况（如 chunk extensions、trailer headers 的变体）
- 对比 `lua-resty-http`（OpenResty 生态标准 HTTP 客户端），它完整实现了 HTTP/1.1 解析，包括 connection reset、100-continue、gzip 等边缘场景
- 在 OpenResty 环境下，用户可能期望用 `lua-resty-http` 替代手写 HTTP 传输，但 lua-yar 的 transport 工厂按 URL scheme 硬选择 `Http` 模块，无法注入

**改进方向**：

- 短期：保持手写 HTTP（纯 Lua 环境需要），但补充更多边界测试
- 长期：在 `transport/socket.lua` 的提供者抽象中增加 `http_request(url, data, options)` 高层接口，允许 OpenResty 环境注入 `lua-resty-http` 作为 HTTP 传输后端，手写 HTTP 仅作纯 Lua fallback

### 3.5 缺少 `setkeepalive` 前的连接健康检查

**表现**：`Socket.release(sock)` 直接调用 `sock:setkeepalive()`，不检查连接是否处于健康状态（如服务端是否发了 RST、是否有未读残留数据）。

**理由**：

- cosocket 的 `setkeepalive` 会将连接归还连接池，但如果连接已被服务端关闭（半关闭），下次复用时 `receive` 会立即返回 `closed` 错误
- lua-yar 的 `Tcp:send` 在 persistent 模式下有简单的健康检查：发送失败 → 关闭旧连接 → 新建。但非 persistent 模式下 `release` 时不检查
- 对比 `lua-resty-redis` 的 `set_keepalive` 前会检查 `sock:setkeepalive()` 的返回值，失败则 `close`

**改进方向**：

- `release(sock, opts)` 检查 `setkeepalive` 返回值，失败时 fallback 到 `close`
- 或在 `receive_message` 成功后确保已读完所有响应数据（目前 `Framing.receive_message` 按 `body_len` 精确读取，已保证无残留）

### 3.6 Server 实例的 `set_options` 不支持连接级参数

**表现**：`Server:set_options(opts)` 只接受 `packager` 和 `timeout`，不接受连接级参数（`connect_timeout` / `send_timeout` / `read_timeout` / `keepalive_idle` / `pool_size`）。

**理由**：

- lua-resty-yar 在 `setup()` 中将连接级参数存入 `config` 表，TCP handler 从 `config` 读取并设在 cosocket 上，绕过了 lua-yar 的 Server 实例
- 这导致连接级参数的管理分裂为两处：lua-yar 管 `packager` / `timeout`，lua-resty-yar 管 `connect_timeout` / `send_timeout` / `read_timeout` / `keepalive_idle` / `pool_size`
- 从 API 一致性角度，`set_options` 应该能接受所有参数，内部按归属分发

**改进方向**：

- `Server:set_options` 接受所有参数，连接级参数存入 `self.options`，`handle_connection` 内部使用
- 或保持现状（lua-resty-yar 在适配层管理连接级参数），但在 lua-yar 文档中明确说明"连接级参数由调用方管理"

### 3.7 缺少 `on_error` / 日志钩子

**表现**：lua-yar 在错误路径上使用 `print` 输出错误（如 `TcpServer:run` 中的 `print("[Yar TCP] handler error: ...")`），没有日志级别区分和可注入的日志钩子。

**理由**：

- OpenResty 环境下应使用 `ngx.log(ngx.ERR, ...)` 而非 `print`
- lua-resty-yar 的 TCP handler 已自行用 `ngx.log` 记录 `handle_connection` 的错误，但 lua-yar 内部（如 `Framing.receive_message` 的 body 超长错误、`handle_message` 的 packager 未知错误）仍走 `print` 或无日志
- 对比 `lua-resty-core` 系列库使用 `ngx.log` 或可注入的日志函数，lua-yar 缺少这层抽象

**改进方向**：

- 增加 `Yar.set_logger(fn)` 注入日志函数，默认 `print`，OpenResty 下注入 `function(level, msg) ngx.log(level, msg) end`
- 或在 `socket.lua` 提供者抽象中增加 `log(level, msg)` 方法，由 provider 提供日志实现

### 3.8 `collect_methods` 不支持运行时动态注册后的方法表更新

**表现**：`Server.new(service)` 在构造时调用 `collect_methods(service)` 一次性建立方法表（memoize）。`Server:register(name, func)` 会更新 `self.methods`，但如果直接修改 `service` 表新增方法，Server 的方法表不会更新。

**理由**：

- memoize 是正确的热路径优化（避免每请求遍历 service 表）
- `register` 方法提供了运行时新增方法的接口，但直接修改 service 表的用法不支持
- 这不是严重问题（`register` 已覆盖正常用法），但文档应明确说明"构造后新增方法请用 `register`，不要直接修改 service 表"

**改进方向**：

- 文档补充说明（当前 README 已提到"运行时新增方法请用 `register`"，足够）
- 或提供 `Server:refresh_methods()` 重新收集方法表（低优先级）

---

## 四、改进方向与 lua-resty-yar 的关系

| 改进方向 | lua-yar 侧改动 | lua-resty-yar 侧影响 | 优先级 |
|---------|---------------|---------------------|--------|
| 3.1 连接池参数透传 | `release(sock, opts)` + 调用处传 options | 无需改动（options 已设置） | **P0** — 已实施 |
| 3.2 三段超时 | 传输层增加 `send_timeout` / `read_timeout` | `new_client` 传入三段超时 | P1 |
| 3.3 handle_connection 超时契约 | 文档补充 / opts 增加超时字段 | 无需改动（已在调用前设超时） | P2 |
| 3.4 HTTP 传输层 | 提供 `http_request` 高层注入点 | 可选注入 `lua-resty-http` | P3 |
| 3.5 连接健康检查 | `release` 检查 `setkeepalive` 返回值 | 无需改动 | P2 |
| 3.6 Server set_options | 接受连接级参数 / 或文档明确 | 可选简化 config 管理 | P3 |
| 3.7 日志钩子 | `Yar.set_logger(fn)` | 注入 `ngx.log` | P2 |
| 3.8 方法表更新 | 文档补充 | 无影响 | P4 |

---

## 五、总体评价

### 做得好的总结

lua-yar 的核心架构设计 — **三层分离**（`handle_message` 纯协议 / `handle_connection` 连接级 / `run` accept 循环）+ **提供者抽象**（`socket.lua` 跨运行时）— 是 Lua 生态中罕见的工程高度。从 lua-resty-yar 的视角看，这两个设计让 OPM 适配层的工作量极小：

- HTTP handler：读 body → `handle_message(data)` → 写 response（3 行核心代码）
- TCP handler：拿 socket → 设超时 → `handle_connection(sock, {keepalive=true})` → 关闭（4 行核心代码）
- Client 注入：`Client.set_socket(ngx.socket)`（1 行）

这种"适配层极薄"的体验，正是 lua-yar 架构设计成功的最好证明。

### 需要改进的总结

改进方向集中在 **cosocket 能力的未充分利用**：

- 连接池参数（`pool_size` / `keepalive_idle`）无法透传 — 核心问题，已实施改造
- 三段超时（`connect` / `send` / `read`）未在传输层独立使用
- 连接健康检查缺失

这些改进的共同特征是：lua-yar 的提供者抽象已正确建模了 cosocket 能力（`settimeouts` / `setkeepalive` 鸭子类型检测），但传输层的调用处没有充分利用这些能力。改进的核心思路是让 options 在传输层全链路透传，从 `Client:call` → `transport:send` → `Socket.release`，不在中途丢弃。

### 与业界 OPM 包的对比

| 维度 | lua-resty-redis | lua-resty-http | lua-resty-yar |
|------|----------------|---------------|--------------|
| 底层库 | 硬绑定 cosocket | 硬绑定 cosocket | lua-yar（可跨运行时） |
| 连接池参数 | `set_keepalive_idle` / `set_pool_size` 直接设 | cosocket 默认 | 透传到 lua-yar `release` |
| 三段超时 | `set_timeouts` | `set_timeouts` | 透传到 lua-yar transport |
| 协议核心解耦 | 协议与 cosocket 耦合 | 协议与 cosocket 耦合 | `handle_message` 纯函数 |
| 跨运行时 | ❌ | ❌ | ✅ |

lua-resty-yar 的独特价值在于：它是少数能跨运行时（OpenResty / 标准 Lua / lua-eco / Skynet）的 OPM 包，这得益于 lua-yar 的提供者抽象。改进方向是让 cosocket 的能力（连接池、三段超时）在传输层充分透传，达到与 `lua-resty-redis` / `lua-resty-http` 同级的 cosocket 利用度。

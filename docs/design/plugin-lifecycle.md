# 插件与生命周期设计决策

## 14. 插件注册体系 — register + priority + named compose

- **状态**：已实现
- **决策驱动因素**：框架特征 / 调试友好性
- **关联决策**：#7（ngx.log writer 注入）、#8（结构化访问日志）、#9（trace context 传播）、#13（嵌套配置 schema）

### 背景

Phase 1 前，用户使用可观测性三件套需手动 `compose(access_logger(), trace_middleware(), metrics_recorder())`。这种方式有三个问题：1) 无注册接口，每次手动 compose；2) 无优先级，执行顺序依赖参数位置；3) hook 报错时日志只记 index（第几个 hook），不记插件名，调试困难。

### 思考与取舍

> "Make the common case fast." — 计算机体系结构原则
> "让常见情况快速。" — 计算机体系结构原则

> "Convention over configuration." — Rails 哲学
> "约定优于配置。" — Rails 哲学

决策：引入 `registry.lua` 模块，`register(name, factory, opts)` 链式 API。factory 是无参函数返回 hooks 表。`get_hooks(user_hooks)` 遍历已注册插件调 factory()，按 priority 升序 + name 字母序排序后调 `compose_named` 组合。

**为什么用 factory 模式而非直接传 hooks 表：**
- factory 延迟实例化——注册时只存 factory 函数，setup() 时才调 factory() 创建 hooks。这避免了注册阶段就创建 hooks 闭包（此时配置可能未就绪）。
- 对标 Lua 业界：lua-resty-http `http.new()`、lua-cjson `cjson.new()` 均用 factory 延迟创建。

**优先级排序设计：**
- priority 升序（数字小先执行），对标 nginx `init_by_lua` phase 优先级
- 相同 priority 按 name 字母序，保证执行顺序确定性（Lua `pairs` 遍历顺序不确定）
- inline hooks 直传当匿名插件 priority=50（向后兼容）

**named compose：**
- `compose_named(list)` 扩展 `compose()`，每个 hook 报错时日志显示插件 name 而非 index
- pcall 隔离每个 hook（对标 compose 的既有模式）
- 错误日志格式：`[resty.yar] on_response hook 'metrics' error: ...`

**为什么不用 Kong PDK 完整插件系统：**
- Kong PDK 有完整的 plugin context、schema 验证、优先级迁移等，是平台级功能。lua-resty-yar 是框架（非平台），register + priority + named compose 足够。
- 过度复杂反而增加学习成本和维护负担。

### 业界参考

- **lor**（OpenResty web 框架）：`app:use(middleware)` + 顺序执行，命名中间件
- **Kong PDK**：`kong.plugins` 完整生命周期 + 优先级 + schema
- **Express.js**：`app.use(name, middleware)` 命名中间件
- **Dubbo SPI**：`@SPI` 注解 + `@Adaptive` + init/ref/destroy 生命周期

### 代码评价

`registry.lua`（73 行）：`_plugins` 表用 name 做索引（O(1) 查找/覆盖）；`get_hooks()` 遍历 + 排序 + compose，工厂模式延迟创建；`table.sort` 比较函数 priority 优先 + name tiebreaker 保证确定性；`clear()` 和 `list()` 用于测试和自省。代码简洁，表驱动设计，扩展新插件只调 `register()`。

### 知识领域

1. *Programming in Lua*（Ierusalimschy）第 16 章 — Lua OOP 与工厂模式
2. *Design Patterns*（GoF）— 工厂方法模式

---

## 15. 框架生命周期钩子适配 — on_error/on_timeout 派生 + on_connect/on_init_worker 框架层管理

- **状态**：已实现
- **决策驱动因素**：框架特征 / 生命周期完整性
- **关联决策**：#5（TCP handler 委托）、#14（插件注册体系）

### 背景

lua-yar 协议层只有 `on_request(method, params)` / `on_response(method, retval, err_obj)` 两个钩子。框架层需要更细粒度的生命周期感知：错误时清理资源、超时时告警、连接时建立链路追踪、worker 启动时初始化 timer。但不改 lua-yar 协议层（协议库极简设计）。

### 思考与取舍

> "Be liberal in what you accept, conservative in what you send." — Jon Postel
> "宽容地接受，保守地发送。" — Jon Postel

> "The best way to predict the future is to invent it." — Alan Kay
> "预测未来的最好方式是创造它。" — Alan Kay

决策：在框架层 `hooks.lua` 的 `adapt()` 函数中从 `on_response` 派生 `on_error` / `on_timeout`，不改 lua-yar 协议层。`on_connect` / `on_init_worker` 不走 lua-yar hooks 通道，由 init.lua 框架层直接调用。

**派生逻辑（adapt 函数）：**
1. 先调原始 `on_response(method, retval, err_obj)`
2. err_obj 非 nil 时派生 `on_error(method, err_obj)`
3. err_obj.code == Error.TIMEOUT 时派生 `on_timeout(method)`

**为什么从 on_response 派生而非改 lua-yar：**
- lua-yar 是纯协议库，对标 dkjson/lua-MessagePack，极简设计是核心价值
- on_response 已经携带 err_obj 参数，信息充分，框架层完全可派生
- 改协议层 hooks 通道会破坏协议库的稳定性，引入不必要的复杂度

**on_connect / on_init_worker 为什么不走 hooks 通道：**
- on_connect 是连接生命周期事件，不绑定 RPC 调用
- on_init_worker 是 worker 进程生命周期事件，不绑定请求/连接
- 这两个钩子由 init.lua 在 `new_client()` / `init_worker()` 中直接调用

**向后兼容：**
- 旧 `{ on_request, on_response }` hooks（无 on_error/on_timeout）→ adapt 条件检查 nil，正常工作
- 旧 `compose()` 产出 hooks 仍直接传给 lua-yar（不经 adapt）
- inline hooks 直传 → registry 当匿名插件处理 → 经 adapt

### 业界参考

- **gRPC-go interceptor**：unary/stream/err interceptor，生命周期细粒度拦截
- **Dubbo SPI**：`init` / `refer` / `destroy` 三阶段生命周期
- **WSGI/ASGI**：`start_response(status, headers)` 回调派生错误处理
- **Express.js middleware**：`err` middleware `(err, req, res, next)` 三参数签名区分错误处理

### 代码评价

`hooks.lua`（55 行）：`adapt()` 函数包装 on_response 派生 on_error/on_timeout，逻辑清晰（先原始 → 后派生 → 再细分超时）。`Error.TIMEOUT` 检查用 `type(code) == "string"` 防御（err_obj 可能非 Error 对象）。on_connect/on_init_worker 透传（adapt 不包装，init.lua 直接调用）。代码简洁，职责单一，不改协议层。

### 知识领域

1. *Programming in Lua*（Ierusalimschy）第 24 章 — 协程与回调的安全隔离
2. *Distributed Systems*（Tanenbaum）— 生命周期事件与故障检测

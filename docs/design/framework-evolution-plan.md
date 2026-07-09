# lua-resty-yar 框架化改造方案

> **状态**: Implemented — 已实现（v0.1.0，全部 5 项改造落地）
> **创建**: 2026-09-26
> **定位前提**: lua-resty-yar = OpenResty 下 Yar RPC **开发框架**（对标 lor/Dubbo/gRPC-go），lua-yar = 纯协议库

## 一、问题陈述

当前 lua-resty-yar 具备框架的地基（可观测性/连接管理/错误模型），但**框架特征不完整**：

| 差距 | 现状 | 框架应有 |
|------|------|----------|
| 插件体系 | 手动 `compose()` 组合函数 | 注册 + 优先级 + 元数据 |
| 配置体系 | flat + EXCLUDE 排除列表 | 嵌套分域 schema |
| 生命周期钩子 | on_request / on_response（2 个） | 6 个（含 connect/error/timeout/init_worker） |
| 性能热路径 | 6-13 次 shdict:incr/调用 | worker-local 缓冲 + batch flush |
| 工程卫生 | 无格式化/无覆盖率 | stylua + luacov |

## 二、OpenResty 特性利用

改造方案每一步都**贴合 OpenResty 运行时模型**，不做脱离 OpenResty 的抽象：

| OpenResty 特性 | 框架利用方式 |
|----------------|-------------|
| **Phase 模型** (init→init_worker→content→log) | 插件可注册 phase 回调（`init_worker`/`content`/`log`） |
| **ngx.shared.dict** (worker 间共享内存) | metrics 存储 + 原子 incr |
| **ngx.ctx** (per-request 上下文) | trace 传播 + 请求级元数据 |
| **cosocket** (非阻塞 I/O) | 连接池管理 + persistent 复用 |
| **ngx.timer.every** (周期定时器) | metrics buffer 定期 flush 到 shdict |
| **worker 进程模型** (多 worker 独立 VM) | worker-local 缓冲无锁竞争 |
| **init_by_lua 一次性执行** | 配置 schema 校验 fail-fast |
| **log_by_lua 延迟执行** | access_log 不阻塞 content phase |

**核心原则**: 不引入 OpenResty 不存在的抽象。插件注册不走 Kong PDK 那套完整 plugin lifecycle（那是平台级），而是 OpenResty phase + hooks 组合的轻量方案。

## 三、分项改造方案

### 改造一：插件注册体系

#### 现状

```lua
-- 用户手动 compose 三个 hook
local hooks = yar.observability.compose(
    yar.observability.access_logger(),
    yar.observability.trace_middleware(),
    yar.observability.metrics_recorder()
)
yar.setup({ hooks = hooks })
```

问题：无注册接口、无优先级、无元数据、调试时 hook 报错只记 index 不记名。

#### 目标

```lua
-- 注册插件（setup 前）
yar.register("access-log", yar.observability.access_logger, { priority = 100 })
yar.register("trace", yar.observability.trace_middleware, { priority = 50 })
yar.register("metrics", yar.observability.metrics_recorder, { priority = 200 })

-- setup 时自动按 priority 排序 + compose
yar.setup({
    service = { add = function(a, b) return a + b end },
    -- 不再手动 compose hooks
})

-- 也可直接传 inline hooks（等价于匿名插件 priority=100）
yar.setup({
    hooks = { on_request = fn, on_response = fn },
})
```

#### 设计

```lua
-- registry.lua（新模块）
local _plugins = {}  -- name -> { name, factory, priority, version }

function _M.register(name, factory, opts)
    opts = opts or {}
    _plugins[name] = {
        name     = name,
        factory  = factory,   -- function(opts) -> hooks table
        priority = opts.priority or 100,
        version  = opts.version or "1.0",
    }
    return _M
end

function _M.get_hooks(user_hooks)
    local list = {}
    for _, p in pairs(_plugins) do
        local h = p.factory()
        if h then
            list[#list + 1] = { name = p.name, priority = p.priority, hooks = h }
        end
    end
    if user_hooks then
        list[#list + 1] = { name = "user", priority = 50, hooks = user_hooks }
    end
    table.sort(list, function(a, b) return a.priority < b.priority end)
    -- compose 时携带 name 供日志定位
    return _compose_named(list)
end
```

#### OpenResty 角度

- 插件注册在 `init_by_lua`（setup 调用时）完成，worker fork 后继承，无并发问题
- `ngx.timer.every` 注册的 flush 定时器是 worker 级的，插件注册的 timer 也在 worker 内
- 对标 lor middleware：lor 用 `app:use(middleware)` 注册 + 顺序执行，lua-resty-yar 用 `register(name, factory, priority)` + 优先级排序

#### 取舍

| 备选方案 | 优缺点 | 结论 |
|----------|--------|------|
| A. 完整 PDK 模式（schema+config+DAO） | Kong 式，功能强但过度复杂 | **否决** — 框架非平台 |
| B. 注册 + 优先级 + 元数据 | 轻量，调试友好，向后兼容 | **采纳** |
| C. 仅给 compose 加 name 参数 | 最小改动，但无注册/优先级 | **否决** — 不解决核心问题 |

#### 影响范围

- 新增 `lib/resty/yar/registry.lua`（~60 行）
- `init.lua` setup() 中用 `registry.get_hooks(opts.hooks)` 替代直接传 opts.hooks
- `observability.lua` compose() 扩展为 `_compose_named(list)` 携带 name
- 向后兼容：`opts.hooks` 直传仍可用（匿名插件 priority=50）

---

### 改造二：结构化配置 Schema

#### 现状

```lua
-- flat 配置 + EXCLUDE 排除列表
local config = {}
for k, v in pairs(opts) do
    if not EXCLUDE_FROM_CONFIG[k] then
        config[k] = v
    end
end
```

问题：9 个排除键硬编码，新增配置项容易遗漏；flat 结构无法表达层级关系。

#### 目标

```lua
yar.setup({
    server = {
        service     = { add = function(a, b) return a + b end },
        packager    = "JSON",
        timeout     = 5000,
        max_body_len = 10485760,
    },
    client = {
        timeout         = 3000,
        connect_timeout = 1000,
        pool_size       = 30,
        ssl_verify      = true,
        resolve         = "",
        proxy           = "",
    },
    observability = {
        metrics_dict  = "yar_metrics",
        metrics_prefix = "yar_rpc",
        access_log     = { level = ngx.INFO, defer = true },
        trace          = { header = "X-Request-Id" },
    },
    extensions = {
        use_cjson      = true,
        use_cmsgpack   = false,
        use_resty_http = false,
    },
    log_level  = Yar.log.DEBUG,
    on_worker_init = function() end,
})
```

#### 设计

```lua
-- config.lua（新模块）
local DEFAULTS = {
    server = {
        packager     = Yar.PACKAGER_JSON,
        timeout      = 5000,
        max_body_len = 10 * 1024 * 1024,
    },
    client = {
        timeout         = 3000,
        connect_timeout = 1000,
        send_timeout    = 5000,
        read_timeout    = 5000,
        keepalive_idle  = 60000,
        pool_size       = 30,
        ssl_verify      = true,
        resolve         = "",
        proxy           = "",
        max_body_len    = 10 * 1024 * 1024,
    },
    observability = {
        metrics_dict   = "yar_metrics",
        metrics_prefix = "yar_rpc",
        access_log     = { level = nil, defer = false },
        trace          = { header = "X-Request-Id" },
    },
    extensions = {
        use_cjson      = false,
        use_cmsgpack   = false,
        use_resty_http = false,
    },
}

function _M.merge(user_opts)
    -- 深合并：递归合并 user_opts 到 DEFAULTS
    -- 校验：init_by_lua 阶段 fail-fast（类型错误 error(msg, 2)）
    return deep_merge(DEFAULTS, user_opts)
end
```

#### OpenResty 角度

- 配置校验在 `init_by_lua`（master 进程一次性执行），校验失败 nginx 启动失败 = fail-fast
- 嵌套结构对应 OpenResty 配置层级：server→handler、client→cosocket、observability→log/shdict、extensions→setup
- 对标 OpenResty nginx.conf 的 directive 层级（http→server→location）

#### 取舍

| 备选 | 优缺点 | 结论 |
|------|--------|------|
| A. 完全重写为 schema 驱动（声明+验证+默认） | 功能强，但 Lua 生态无成熟 schema 库，自造轮子 | **否决** |
| B. 嵌套分域 + deep_merge | 简洁，消除 EXCLUDE，语义清晰 | **采纳** |
| C. 保持 flat + 扩展 EXCLUDE | 零改动，但问题不解决 | **否决** |

#### 向后兼容

setup() 同时接受旧 flat 格式（检测顶层是否有 `service`/`connect_timeout` 等 flat key，自动转换为新格式 + deprecation warn）。

#### 影响范围

- 新增 `lib/resty/yar/config.lua`（~80 行）
- `init.lua` setup() 重构为调用 `config.merge(opts)` + 按域分发
- `new_client()`/`get_server()` 从 `config.client`/`config.server` 读配置（替代 flat `config.xxx`）

---

### 改造三：生命周期钩子扩展

#### 现状

lua-yar 协议层只有 `on_request(method, params)` / `on_response(method, retval, err_obj)`。
lua-resty-yar 的 compose 只传递这两个。

#### 目标

框架层在 lua-yar 的 2 个钩子之上，**派生** 4 个框架钩子（不改 lua-yar）：

| 钩子 | 触发时机 | 实现 |
|------|---------|------|
| `on_request(method, params)` | 请求发送前 | lua-yar 原生 |
| `on_response(method, retval, err)` | 响应接收后 | lua-yar 原生 |
| `on_error(method, err)` | err != nil 时 | on_response 派生：`if err then on_error(method, err) end` |
| `on_timeout(method)` | err.code == TIMEOUT | on_error 派生：`if err.code == Error.TIMEOUT then on_timeout(method) end` |
| `on_connect(uri)` | client 创建/连接前 | 框架层：new_client 包装 |
| `on_init_worker()` | init_worker_by_lua | 框架层：init_worker 增强 |

#### 设计

```lua
-- hooks.lua（新模块，框架钩子适配）

-- 将框架钩子适配为 lua-yar 的 on_request/on_response 协议
function _M.adapt(framework_hooks)
    local function on_response(method, retval, err_obj)
        -- 1. 先调原始 on_response
        if framework_hooks.on_response then
            framework_hooks.on_response(method, retval, err_obj)
        end
        -- 2. 派生 on_error
        if err_obj and framework_hooks.on_error then
            framework_hooks.on_error(method, err_obj)
        end
        -- 3. 派生 on_timeout
        if err_obj and err_obj.code == Error.TIMEOUT and framework_hooks.on_timeout then
            framework_hooks.on_timeout(method)
        end
    end

    return {
        on_request  = framework_hooks.on_request,
        on_response = on_response,  -- 适配后的
    }
end
```

`on_connect` 和 `on_init_worker` 不走 lua-yar hooks，由框架在 `new_client` / `init_worker` 中直接调用。

#### OpenResty 角度

- `on_init_worker` 映射 OpenResty `init_worker_by_lua` phase — 插件可在此启动 timer（如 metrics flush）
- `on_connect` 在 cosocket 连接前触发 — 插件可做连接前检查/限流
- `on_timeout` 精确对应 cosocket 超时 — 插件可做超时告警/熔断
- 对标 gRPC-go interceptor：`unary interceptor` → on_request/on_response，`stream interceptor` → on_connect/on_disconnect，`err` → on_error

#### 取舍

| 备选 | 优缺点 | 结论 |
|------|--------|------|
| A. 改 lua-yar 加 4 个钩子 | 协议层支持，但破坏协议库极简设计 | **否决** — lua-yar 保持极简 |
| B. 框架层从 on_response 派生 on_error/on_timeout | 不改协议层，零侵入 | **采纳** |
| C. 包装 Client 为 proxy 拦截 call() | 可拦截 on_connect/disconnect，但增加调用层 | **次选** — on_connect 用此方式 |

#### 影响范围

- 新增 `lib/resty/yar/hooks.lua`（~50 行）
- `observability.lua` 的 compose() 扩展支持 named hooks
- `init.lua` new_client 可选调用 on_connect（如果注册了的话）
- 向后兼容：旧的 `{ on_request, on_response }` hooks 仍直接透传

---

### 改造四：性能优化（hot-path）

#### 4.1 metrics incr 批量化

##### 现状

每次 RPC 调用 on_response 触发 6-13 次 `dict:incr`（shared dict 原子操作，有锁竞争）。

##### 目标

worker-local 缓冲 + `ngx.timer.every` 定期 batch flush。

##### 设计

```lua
-- worker-local 缓冲（upvalue，无锁竞争）
local _buffer = {}  -- key -> accumulated value

local function record(method, status, duration_ms)
    -- 累加到 worker-local buffer（纯 Lua table 操作，零 shdict 调用）
    local k_total = _counter_key_cached(method, "total")
    _buffer[k_total] = (_buffer[k_total] or 0) + 1
    local k_status = _counter_key_cached(method, status)
    _buffer[k_status] = (_buffer[k_status] or 0) + 1
    -- histogram buckets 同理累加
end

-- 定期 flush（OpenResty native timer）
local function start_flush_timer(dict, interval)
    ngx.timer.every(interval, function()
        for key, val in pairs(_buffer) do
            dict:incr(key, val, 0)
            _buffer[key] = nil  -- 清零
        end
    end)
end
```

##### OpenResty 角度

- worker-local upvalue 无锁，OpenResty 每个 worker 是独立 Lua VM
- `ngx.timer.every` 是 OpenResty 原生定时器，不占 cosocket，在 worker 内协作调度
- 取舍：worker crash 时 buffer 丢失（≤1 秒数据）。对标 nginx access_log buffer 也有同样行为（`buffer=size flush=1s`），生产可接受

#### 4.2 metrics key 缓存

##### 现状

每次 record 调用拼接 `prefix .. "_calls_total{method=\"" .. method .. "\",status=\"" .. kind .. "\"}"`，GC 压力大。

##### 目标

method × status 组合有限（method 数有限 × status 7 种），预计算缓存。

##### 设计

```lua
local _key_cache = {}  -- "method\0status" -> full key

local function counter_key(method, status)
    local cache_key = method .. "\0" .. status
    local k = _key_cache[cache_key]
    if not k then
        k = prefix .. '_calls_total{method="' .. method .. '",status="' .. status .. '"}'
        _key_cache[cache_key] = k
    end
    return k
end
```

#### 4.3 export 避免 get_keys(0)

##### 现状

`dict:get_keys(0)` 获取 dict 中所有 key（不只 yar 的），再 string.match 过滤。大 dict 上性能差。

##### 目标

维护已注册 method 列表，export 时只查已知 key。

##### 设计

```lua
local _known_methods = {}  -- set

-- record 时注册 method
local function record(method, ...)
    if not _known_methods[method] then
        _known_methods[method] = true
    end
    -- ...
end

-- export 时从已知 method 构造 key
local function export()
    local methods = {}
    for m in pairs(_known_methods) do methods[#methods + 1] = m end
    table.sort(methods)
    for _, m in ipairs(methods) do
        -- 直接 dict:get(counter_key(m, "total")) 等
    end
end
```

#### 取舍

| 备选 | 优缺点 | 结论 |
|------|--------|------|
| A. worker-local buffer + timer flush | 性能最优，但 crash 丢数据 | **采纳**（可选启用，默认仍 direct incr） |
| B. 仅 key 缓存 + export 优化 | 无数据丢失风险，改动小 | **采纳**（默认启用） |
| C. 保持现状 | 零改动 | **否决** — hot-path 性能不达标 |

建议分两阶段：
- **Phase 1**: key 缓存 + export 优化（零风险，立即生效）
- **Phase 2**: worker-local buffer + timer flush（可选，配置启用 `metrics_buffer = { enabled = true, flush_interval = 1 }`）

#### 影响范围

- `observability.lua` metrics_recorder 函数内部重构（~50 行改动）
- 新增配置项 `metrics_buffer`（结构化配置中 observability 域）
- export 逻辑重构

---

### 改造五：工程卫生

#### 清单

| 项目 | 方案 | 优先级 |
|------|------|--------|
| `.editorconfig` | 缩进 4 空格、LF、UTF-8、max 120 列 | P1 |
| `stylua.toml` | 配置 + CI `stylua --check` 步骤 | P1 |
| luacov 覆盖率 | Makefile `make coverage` target + CI 上传 | P2 |
| 多版本矩阵 | CI 矩阵 OpenResty 1.21/1.25/1.27 | P2 |
| release notes 自动化 | GitHub Auto-generated + conventional-commits | P3 |

## 四、改造优先级与路线图

### Phase 1（P1 — 地基重构，1-2 天）

1. **结构化配置 schema**（改造二）— 消除 EXCLUDE_FROM_CONFIG，嵌套分域
2. **key 缓存 + export 优化**（改造四 Phase 1）— 零风险性能提升
3. **工程卫生**（改造五 P1）— .editorconfig + stylua

### Phase 2（P2 — 框架特征，2-3 天）

4. **插件注册体系**（改造一）— register + priority + named compose
5. **生命周期钩子扩展**（改造三）— on_error/on_timeout/on_connect/on_init_worker
6. **observability.defaults()** — 一键启用三件套

### Phase 3（P3 — 性能进阶，1 天）

7. **metrics buffer + timer flush**（改造四 Phase 2）— 可选启用
8. **luacov 覆盖率** + **多版本 CI 矩阵**

### 不做（YAGNI）

- ❌ Kong PDK 式完整插件系统（schema/config/DAO/migrations）— 那是平台
- ❌ 插件热加载 / 运行时卸载 — OpenResty 模块加载不可逆
- ❌ 声明式配置文件（YAML/JSON）驱动 — 框架代码级集成，不要配置文件
- ❌ 服务发现 / 负载均衡 — 那是 lua-resty-php-beacon 平台的职责

## 五、文件变更清单

### 新增文件

| 文件 | 行数估计 | 用途 |
|------|---------|------|
| `lib/resty/yar/config.lua` | ~80 | 结构化配置 merge + 校验 |
| `lib/resty/yar/registry.lua` | ~60 | 插件注册 + 优先级排序 |
| `lib/resty/yar/hooks.lua` | ~50 | 框架钩子适配（on_error/on_timeout 派生） |
| `.editorconfig` | ~15 | 编辑器统一配置 |
| `stylua.toml` | ~10 | Lua 格式化配置 |

### 修改文件

| 文件 | 改动范围 | 说明 |
|------|---------|------|
| `init.lua` | setup() 重构 + new_client 适配 | 配置分层 + hooks 适配 + on_connect |
| `observability.lua` | compose named + metrics key 缓存 + export 优化 | 改造一/四 |
| `.luacheckrc` | 新增 registry/hooks/config 模块声明 | lint 适配 |
| `Makefile` | 新增 `stylua-check` / `coverage` target | 工程卫生 |
| `dist.ini` | version → 0.1.0 | 版本升级 |
| `.github/workflows/lint.yml` | 加 stylua --check 步骤 | CI 适配 |
| `docs/design/decisions.md` | 新增 ADR #13-#16 | 记录改造决策 |

### 测试文件

| 文件 | 说明 |
|------|------|
| `t/framework.t` | 新增：插件注册 + 优先级 + 配置 schema + 生命周期钩子 |
| `t/observability.t` | 扩展：key 缓存 + export 优化验证 |

## 六、向后兼容策略

| 变更 | 兼容策略 |
|------|---------|
| setup() flat → nested | 自动检测 flat key + 转换 + WARN 日志（1 个 minor 版本） |
| compose → register | 旧 `opts.hooks` 直传仍可用（匿名插件 priority=50） |
| on_response → 派生 on_error | 旧 hooks 不受影响，新钩子是增量 |
| metrics direct → buffer | 默认仍 direct incr，buffer 显式启用 |

**版本策略**: 0.3.0（Phase 1+2），0.4.0（Phase 3），保持 semver。

## 七、对标总结

| 维度 | Dubbo | gRPC-go | lor | lua-resty-yar 改造后 |
|------|-------|---------|-----|---------------------|
| 配置体系 | XML/注解 schema | struct | app:config() | 嵌套分域 deep_merge |
| 插件体系 | SPI 注册 | interceptor 注册 | middleware priority | register + priority |
| 生命周期钩子 | init/ref/destroy | before/after/destroy | before/after | 6 钩子（含派生） |
| 可观测性 | 内置 | interceptor | 无 | 内置 + 可插拔 |
| 性能 | 高 | 高 | 中 | worker-local buffer |
| 工程化 | 完善 | 完善 | 基本 | stylua + luacov + 多版本 CI |

改造后 lua-resty-yar 达到 **OpenResty RPC 框架**水准，在 OpenResty 生态中定位清晰：比单功能库（lua-resty-http/redis）高一层次，比平台（Kong/APISIX）轻量。

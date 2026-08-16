# OpenResty 多阶段特性优化评估

> 评估时间：2026-08-17 | 评估对象：lua-resty-yar 多阶段特性利用空间
> 评估方法：适配层 vs 平台分界判断 + 跨语言对标 + 八维度提案

---

## 一、核心判断：适配层 vs 平台

提问中混了两个层次，必须先厘清：

1. **"借鉴 Kong 的思想"** — 平台级架构思想（插件系统、PDK、Admin API、Worker 事件总线）
2. **"利用 OpenResty 的多阶段特性"** — 运行时原生能力（`init_by_lua` / `init_worker_by_lua` / `access_by_lua` / `content_by_lua` / `log_by_lua`）

Kong 的"多阶段"是**平台自己实现的插件生命周期编排**（preread→access→header_filter→body_filter→log），Kong 拥有请求生命周期，把插件挂到各相。lua-resty-yar 的关系是反过来的——**OpenResty 拥有阶段，lua-resty-yar 被邀请进入特定阶段**（通过 `_by_lua` 指令）。

所以问题不是"lua-resty-yar 要不要实现自己的多阶段系统"（那是平台越权），而是 **"lua-resty-yar 目前挂接了 OpenResty 的哪些阶段，还有哪些阶段值得挂接"**。

**结论：同意此分界。适配层只做阶段挂接映射，不实现自己的 phase 编排系统。**

---

## 二、现状盘点：当前挂接的 OpenResty 阶段

| OpenResty 阶段 | 适配层入口 | 做了什么 |
|---|---|---|
| `init_by_lua` | `setup()` | cosocket 注入、ngx.log writer 注入、Server Facade 创建、配置合并 |
| `init_worker_by_lua` | `init_worker()` | 仅执行用户 `on_worker_init` 回调 |
| `content_by_lua` | `server.http/tcp.serve()` | 读 body → 委托 `server:handle()` → writer 输出 |
| `log_by_lua` | **未挂接**（本次改造补上） | — |
| `access_by_lua` | 未挂接 | — |
| `rewrite_by_lua` | 未挂接 | — |

**关键发现：适配层只挂了 3 个阶段，`log_by_lua` 这个高价值阶段完全没用到。**

---

## 三、已有的"多阶段"能力（hooks = RPC 拦截器链）

`observability.lua` 已通过 lua-yar hooks 实现 RPC 库层面的"阶段"：

| hook | 时机 | 对标概念 |
|---|---|---|
| `on_request(method, params)` | RPC 请求进入分发前 | 入口日志 / 鉴权 / 限流切面 |
| `on_response(method, retval, err)` | RPC 响应返回前 | 出口日志 / metrics 切面 |
| `compose(h1, h2, ...)` | 多 hook 串联 + pcall 隔离 | 中间件链 |

已实现：`access_logger`（结构化 JSON 日志）、`trace_middleware`（request ID 注入）、`metrics_recorder`（Prometheus 指标 + shared dict）、`compose`（组合）。

**这已经是 RPC 库业界对标"多阶段"的正确形态。** 跨语言看：
- gRPC（Go）用 interceptor（before/after），不是 phase 系统
- Dubbo（Java）用 Filter 链（SPI），before/after invoke
- PHP Yar / yar-c：无阶段，同步请求响应

**RPC 库的"多阶段"= 拦截器链（before/after），不是网关的 phase 系统。** lua-resty-yar 的 hooks 已经做对了。再加一套 phase 系统是平台越权。

---

## 四、log_by_lua 延迟访问日志提案（八维度）

### ① 评估

当前 `access_logger` 的 `on_response` hook 在**请求处理过程中同步写日志**（`ngx.log(ngx.INFO, ...)`）。日志 I/O 在响应热路径上，如果日志采集慢（如写共享 dict 竞争），拖慢响应。出口日志理论上应该在请求"结束"后写，而非响应"返回前"。OpenResty 的 `log_by_lua` 阶段在响应已发给客户端**之后**执行，是 OpenResty 原生的访问日志阶段。

### ② 改动涉及范围

- `observability.lua`：`access_logger(opts)` 新增 `defer` 选项；新增 `flush_logs(opts)` 函数
- `server/http.lua`：无改动（用户在 nginx.conf 的 `log_by_lua_block` 调用 `flush_logs()`）
- `server/tcp.lua`：无改动（stream 无 `log_by_lua` 阶段，defer 模式仅 HTTP 可用）
- nginx.conf：用户在 location 内加 `log_by_lua_block { require("resty.yar.observability").flush_logs() }`

### ③ 风险点

- `ngx.ctx` 数据在 `log_by_lua` 阶段仍可读（OpenResty 保证），但 TCP/stream 模式无 `log_by_lua` 阶段——需文档说明 HTTP 专属
- 两套日志路径（in-request hooks vs log-phase），用户需理解何时用哪个
- `ngx.location.capture` 子请求的 log phase 执行时机需测试验证

### ④ 带来收益

- 日志 I/O 移出响应热路径，响应延迟降低
- 日志故障（如 shared dict 竞争）不影响响应
- 对标 nginx `access_log` 的 log phase 语义，符合 OpenResty 原生惯例

### ⑤ 引入问题

- TCP 模式不支持 defer 模式（stream 无 `log_by_lua`），需显式说明
- 用户需在 nginx.conf 额外配置 `log_by_lua_block`，增加配置复杂度
- `on_response` 仍需组装 entry（计算 duration 等），只是输出延迟，CPU 开销未消除

### ⑥ Lua 业界处理方式对比

| 项目 | 访问日志阶段 | 方式 |
|------|------------|------|
| Kong | `log_by_lua` | log phase plugin，响应后异步写 |
| nginx 原生 | log phase | `access_log` 指令，响应后写 |
| lua-resty-http | 不涉及 | 客户端库，无服务端日志 |
| lua-resty-core | 不涉及 | 非请求级 |

对标结论：`log_by_lua` 是 OpenResty 生态访问日志的标准阶段，lua-resty-yar 补此阶段是回归业界惯例。

### ⑦ 预期改动

```lua
-- observability.lua 改动

-- access_logger 增加 defer 选项
function _M.access_logger(opts)
    opts = opts or {}
    local writer = opts.writer or function(_level, msg) ngx.log(ngx.INFO, msg) end
    local defer = opts.defer  -- true = 延迟到 log_by_lua 阶段输出

    return {
        on_request = function(_method, params)
            local ctx = ngx.ctx
            ctx[CTX_START_TIME] = ngx.now()
            ctx[CTX_PARAMS_SIZE] = estimate_size(params)
        end,
        on_response = function(method, retval, err_obj)
            -- ... 组装 entry（不变）...
            if defer then
                ngx.ctx[CTX_LOG_ENTRY] = entry  -- 存 ctx，不输出
            else
                writer(level, to_json(entry))    -- 即时输出（现有行为）
            end
        end,
    }
end

-- 新增 flush_logs，在 log_by_lua 阶段调用
function _M.flush_logs(opts)
    opts = opts or {}
    local writer = opts.writer or function(_level, msg) ngx.log(ngx.INFO, msg) end
    local entry = ngx.ctx[CTX_LOG_ENTRY]
    if not entry then return end
    writer((entry.status == "ok") and ngx.INFO or ngx.WARN, to_json(entry))
end
```

```nginx
# nginx.conf 用法
location /api {
    content_by_lua_block { require("resty.yar.server.http").serve() }
    log_by_lua_block { require("resty.yar.observability").flush_logs() }
}
```

### ⑧ 取舍

| 备选 | 描述 | 优缺点 | 推荐 |
|------|------|--------|------|
| A. 保持现状 | in-request 同步输出 | 简单但阻塞热路径 | 否 |
| B. log_by_lua 延迟 | defer=true + flush_logs() | 移出热路径，TCP 不支持 | **是** |
| C. 两者都提供 | defer 选项切换 | 灵活，用户按场景选 | **是（采用）** |

决策：采用 C，`access_logger` 的 `defer` 选项默认 false（兼容现有行为），用户显式设 `defer=true` 启用延迟模式。

---

## 五、阶段委托入口（薄映射）

当前适配层入口是 `setup()` / `serve()`，没有显式暴露"哪个阶段做什么"。提供阶段映射文档：

```
init_by_lua:        require("resty.yar").setup(opts)
init_worker_by_lua: require("resty.yar").init_worker()
content_by_lua:     require("resty.yar.server").serve()
log_by_lua:         require("resty.yar.observability").flush_logs()
```

这不是新功能，只是把已有的分散入口显式映射到 OpenResty 阶段，降低用户认知成本。成本为零（纯文档）。

---

## 六、明确不建议做的（平台越权）

| 项 | Kong 有 | lua-resty-yar 不该有 | 理由 |
|---|---|---|---|
| 插件架构（priority + schema + lifecycle） | ✅ | ❌ | hooks 已是 RPC 库正确的扩展点；插件系统是平台级 |
| PDK 抽象层 | ✅ | ❌ | 已有 Socket provider 注入；适配层职责就是桥接 ngx |
| Worker 事件总线 + 配置热更新 | ✅ | ❌ | RPC 配置不需频繁变更；reload 成本可接受 |
| Admin API | ✅ | ❌ | RPC 方法静态定义，动态注册场景极少 |
| 多级缓存（mlcache） | ✅ | ❌ | RPC 结果不该缓存 |
| 健康检查 + 熔断 | ✅ | ⚠️ 可选 | 单后端收益有限；多后端场景用户自行引入 `lua-resty-healthcheck` |

详见 `docs/reports/kong-inspired-optimization.md` 的 15 项分析（P0-P4 分级）。

---

## 七、结论

| 优化项 | 判断 | 理由 |
|---|---|---|
| **`log_by_lua` 延迟访问日志** | ✅ 已实现 | 唯一既利用多阶段又不越权的优化；薄、原生、高价值 |
| **阶段委托入口（文档映射）** | ✅ 已实现 | 零成本降低认知负担 |
| **hooks 已有的 on_request/on_response** | ✅ 已完成，不动 | 这就是 RPC 库正确的"多阶段"形态 |
| **observability.lua 现有功能** | ✅ 已完成 | access_logger/trace/metrics/compose 齐全 |
| **Kong 式插件/PDK/Worker事件/Admin** | ❌ 不做 | 平台越权，违背适配层定位 |

**一句话：lua-resty-yar 的"多阶段"已经做对了（hooks = RPC 拦截器链），本次补的是把访问日志延迟到 `log_by_lua` 阶段——这是 OpenResty 原生能力，不是 Kong 式平台架构。**

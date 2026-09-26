-- lib/resty/yar/observability.lua
-- lua-resty-yar 可观测性模块：结构化访问日志 + request ID 追踪 + RPC metrics。
--
-- 通过 lua-yar hooks 机制注入（on_request / on_response + pcall 保护 + 零开销），
-- 不修改协议层代码，不影响 YAR 协议互操作性。
--
-- 用法：
--   local obs = require("resty.yar.observability")
--   require("resty.yar").setup {
--       service = { add = function(a, b) return a + b end },
--       hooks = obs.compose(
--           obs.trace_middleware(),
--           obs.access_logger(),
--           obs.metrics_recorder({ dict_name = "yar_metrics" }),
--       ),
--   }

local ngx = ngx
local pcall = pcall
local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local string = string
local math = math
local table = table

local _M = {}

-- 延迟统计的直方图 bucket 边界（ms），对标 Prometheus histogram 默认 bucket
-- 按功能命名（延迟分桶边界），消除魔数
local LATENCY_BUCKETS = { 1, 5, 10, 50, 100, 500, 1000, 5000 }

-- request ID 生成用的进程内单调递增计数器（per-worker）
local request_seq = 0

--- 生成 request ID（多熵源混合，per-worker 唯一）
-- 熵源：ngx.time（秒级时间）+ ngx.worker.pid（进程区分）+ 计数器（进程内单调递增）
-- 对标 lua-yar default_gen_id 设计，但不调用 math.randomseed（库不越权播种）
-- @return string request ID（16 进制字符串，便于日志阅读）
local function gen_request_id()
    request_seq = request_seq + 1
    local t = ngx.time() or 0
    local pid = ngx.worker.pid() or 0
    local id = (t * 1000000 + pid * 10000 + request_seq) % 0x100000000
    return string.format("%08x", id)
end

--- 获取当前 request ID（从 ngx.ctx 读取，不存在则生成并注入）
-- @return string request ID
local function get_or_create_request_id()
    local ctx = ngx.ctx
    if ctx.request_id then
        return ctx.request_id
    end
    local id = gen_request_id()
    ctx.request_id = id
    return id
end

--- 简易 JSON 序列化（零依赖，不依赖 cjson）
-- 仅支持扁平 table（string/number/boolean/nil 值），足够访问日志使用
-- key 按字母序排序输出，保证日志确定性（ELK/Loki diff 友好）
-- @param t table 待序列化的表
-- @return string JSON 字符串
local function to_json(t)
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local parts = {}
    for i = 1, #keys do
        local k = keys[i]
        local v = t[k]
        local val
        local tv = type(v)
        if tv == "string" then
            local s = string.gsub(v, "\\", "\\\\")
            s = string.gsub(s, '"', '\\"')
            s = string.gsub(s, "\n", "\\n")
            s = string.gsub(s, "\r", "\\r")
            s = string.gsub(s, "\t", "\\t")
            -- RFC 8259 §7: U+0000–U+001F 全部控制字符必须转义
            -- 已处理 \t(09) \n(0A) \r(0D)，此处覆盖剩余 29 个
            s = string.gsub(s, "[%z\1-\8\11\12\14-\31]", function(c)
                return string.format("\\u%04x", string.byte(c))
            end)
            val = '"' .. s .. '"'
        elseif tv == "number" then
            val = tostring(v)
        elseif tv == "boolean" then
            val = v and "true" or "false"
        elseif v == nil then
            val = "null"
        else
            val = '"' .. tostring(v) .. '"'
        end
        parts[#parts + 1] = '"' .. k .. '":' .. val
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

--- 计算表/值的"大小"（用于 params_size / retval_size 日志字段）
-- @param v any 值
-- @return number 大小（数组长度，或字符串长度，或 0）
local function estimate_size(v)
    if v == nil then
        return 0
    end
    local tv = type(v)
    if tv == "table" then
        local n = 0
        for _ in pairs(v) do
            n = n + 1
        end
        return n
    elseif tv == "string" then
        return #v
    end
    return 1
end

--- 从 Error 对象提取错误类型字符串
-- @param err_obj table|nil Error 对象（.code 字段）
-- @return string 错误类型（"ok" / "transport" / "timeout" / "protocol" / "not_found" / "exception"）
local function error_status(err_obj)
    if not err_obj then
        return "ok"
    end
    local code = err_obj.code or "unknown"
    -- 守卫非字符串 code（用户自定义 Error 可能用数字码），避免 string.lower 崩溃
    if type(code) ~= "string" then
        code = tostring(code)
    end
    return string.lower(code)
end

-- 请求级时间戳和参数大小存储 key（ngx.ctx 中的字段名）
-- 注意：access_logger 和 metrics_recorder 共享 CTX_START_TIME。
-- compose 组合时后执行的 on_request 会覆盖前者写入的值，但两次 ngx.now() 间隔在微秒级，影响可忽略。
local CTX_START_TIME = "yar_obs_start_time"
local CTX_PARAMS_SIZE = "yar_obs_params_size"
-- 延迟日志模式：on_response 组装 entry 存到此 key，由 flush_logs() 在 log_by_lua 阶段输出
local CTX_LOG_ENTRY = "yar_obs_log_entry"

--- 结构化 JSON 访问日志工厂函数
-- 返回 hooks 表 { on_request, on_response }，注入 setup({ hooks = ... })
-- on_request 记录开始时间和参数大小，on_response 计算 duration 并组装日志 entry
--
-- 输出模式（opts.defer）：
--   false/nil（默认）：on_response 立即输出 JSON 日志（in-request，响应热路径内）
--   true：on_response 仅将 entry 存到 ngx.ctx，由 flush_logs() 在 log_by_lua 阶段输出
--         日志 I/O 移出响应热路径，对标 nginx access_log 的 log phase 语义
--         仅 HTTP 上下文可用（stream 无 log_by_lua 阶段）
--
-- @param opts table|nil { writer = fn(level, msg), defer = boolean }
-- @return table hooks 表
function _M.access_logger(opts)
    opts = opts or {}
    local writer = opts.writer or function(_level, msg)
        ngx.log(ngx.INFO, msg)
    end
    local defer = opts.defer

    return {
        on_request = function(_method, params)
            local ctx = ngx.ctx
            ctx[CTX_START_TIME] = ngx.now()
            ctx[CTX_PARAMS_SIZE] = estimate_size(params)
        end,
        on_response = function(method, retval, err_obj)
            local start = ngx.ctx[CTX_START_TIME] or ngx.now()
            local duration_ms = (ngx.now() - start) * 1000
            local status = error_status(err_obj)
            local request_id = get_or_create_request_id()
            local entry = {
                ts = ngx.localtime(),
                level = (status == "ok") and "info" or "warn",
                module = "yar.rpc",
                method = method or "unknown",
                params_size = ngx.ctx[CTX_PARAMS_SIZE] or 0,
                status = status,
                duration_ms = math.floor(duration_ms * 1000) / 1000,
                request_id = request_id,
            }
            if err_obj then
                entry.error = err_obj.message or ""
            else
                entry.retval_size = estimate_size(retval)
            end
            if defer then
                -- 延迟模式：存到 ngx.ctx，由 flush_logs() 在 log_by_lua 阶段输出
                ngx.ctx[CTX_LOG_ENTRY] = entry
            else
                -- 即时模式：立即输出
                local json = to_json(entry)
                local level = (status == "ok") and ngx.INFO or ngx.WARN
                writer(level, json)
            end
        end,
    }
end

--- 在 log_by_lua 阶段输出延迟的访问日志
-- 配合 access_logger({ defer = true }) 使用：
--   init_by_lua:      hooks = obs.access_logger({ defer = true })
--   log_by_lua_block: require("resty.yar.observability").flush_logs()
-- 从 ngx.ctx 读取 on_response 组装的 entry 并输出。
-- 若 entry 不存在（非 RPC 请求或未配置 defer 模式），静默返回。
-- @param opts table|nil { writer = fn(level, msg) }，默认 ngx.log(ngx.INFO, ...)
function _M.flush_logs(opts)
    opts = opts or {}
    local writer = opts.writer or function(_level, msg)
        ngx.log(ngx.INFO, msg)
    end
    local entry = ngx.ctx[CTX_LOG_ENTRY]
    if not entry then
        return
    end
    local json = to_json(entry)
    local level = (entry.status == "ok") and ngx.INFO or ngx.WARN
    writer(level, json)
end

--- request ID 追踪中间件工厂函数
-- 在 ngx.ctx 注入 request_id，供访问日志和业务代码关联使用。
-- 跨服务传播：on_request 同时向 ngx.ctx.yar_trace_headers 写入 X-Request-Id，
-- new_client() 从此 ctx 字段读取并合并到出向请求 headers（HTTP 传输层）。
-- 不碰 YAR 协议 provider/token 字段（保持与 PHP Yar 互操作）。
-- @param opts table|nil { id_generator = fn() -> string }，默认多熵源生成器
-- @return table hooks 表
function _M.trace_middleware(opts)
    opts = opts or {}
    local id_gen = opts.id_generator or gen_request_id
    local header_name = opts.header or "X-Request-Id"

    return {
        on_request = function(_method, _params)
            local ctx = ngx.ctx
            if not ctx.request_id then
                ctx.request_id = id_gen()
            end
            -- 注入 trace header 供 new_client() 合并到出向 RPC 请求
            if not ctx.yar_trace_headers then
                ctx.yar_trace_headers = {}
            end
            if not ctx.yar_trace_headers[header_name] then
                ctx.yar_trace_headers[header_name] = ctx.request_id
            end
        end,
        on_response = function(_method, _retval, _err_obj)
            -- request_id 已在 on_request 注入，此处无需操作
        end,
    }
end

--- 获取当前请求的 request ID（供业务代码或日志格式化使用）
-- @return string request ID
function _M.get_request_id()
    return get_or_create_request_id()
end

--- 导出 Prometheus 文本格式（exposition format）
-- 从已知 method 列表构造 metric key 并查询 shdict，输出排序的 Prometheus exposition format。
-- 从 metrics_recorder 闭包提取为模块级纯函数，metrics_recorder 通过 export = function() 委托调用。
-- @param dict table ngx.shared.dict 实例
-- @param known_methods table 已注册的 method 集合（method -> true）
-- @param prefix string metric 名前缀
-- @param keys table key 生成函数集 { counter_key, bucket_key, sum_key, count_key, inf_bucket_key }
-- @return string Prometheus exposition format
local function export_metrics(dict, known_methods, prefix, keys)
    local counters = {}
    local histograms = {} -- method -> { buckets={{le,val,raw}}, sum, count }
    -- 对齐 lua-yar Error 码体系（error_status() 输出小写 Error 码）
    local status_kinds = {
        "total",
        "ok",
        "transport",
        "timeout",
        "protocol",
        "not_found",
        "exception",
        "unknown",
    }

    for method in pairs(known_methods) do
        -- 计数器：只输出已记录的 status kind（val > 0）
        for _, kind in ipairs(status_kinds) do
            local key = keys.counter_key(method, kind)
            local val = dict:get(key)
            if val and val > 0 then
                counters[#counters + 1] = { key = key, val = val }
            end
        end
        -- 直方图 buckets
        local h = { buckets = {}, sum = 0, count = 0 }
        for i = 1, #LATENCY_BUCKETS do
            local key = keys.bucket_key(method, i)
            local val = dict:get(key)
            if val and val > 0 then
                h.buckets[#h.buckets + 1] = { le = tostring(LATENCY_BUCKETS[i]), val = val, raw = key }
            end
        end
        -- +Inf bucket
        local inf_key = keys.inf_bucket_key(method)
        local inf_val = dict:get(inf_key)
        if inf_val and inf_val > 0 then
            h.buckets[#h.buckets + 1] = { le = "+Inf", val = inf_val, raw = inf_key }
        end
        h.sum = dict:get(keys.sum_key(method)) or 0
        h.count = dict:get(keys.count_key(method)) or 0
        histograms[method] = h
    end

    local lines = {}

    -- 计数器（key 字母序排序）
    table.sort(counters, function(a, b)
        return a.key < b.key
    end)
    if #counters > 0 then
        lines[#lines + 1] = "# HELP " .. prefix .. "_calls_total Total RPC calls by method and status"
        lines[#lines + 1] = "# TYPE " .. prefix .. "_calls_total counter"
        for i = 1, #counters do
            lines[#lines + 1] = counters[i].key .. " " .. tostring(counters[i].val)
        end
    end

    -- 直方图（method 字母序，bucket 按数值 le 升序）
    -- HELP/TYPE 每 metric 名只输出一次（Prometheus exposition format 规范）
    local methods = {}
    for m in pairs(histograms) do
        methods[#methods + 1] = m
    end
    table.sort(methods)

    if #methods > 0 then
        lines[#lines + 1] = "# HELP " .. prefix .. "_duration RPC call latency in milliseconds"
        lines[#lines + 1] = "# TYPE " .. prefix .. "_duration histogram"
    end

    for i = 1, #methods do
        local m = methods[i]
        local h = histograms[m]

        -- bucket 按 le 排序：数值升序，+Inf 在末尾
        table.sort(h.buckets, function(a, b)
            if a.le == "+Inf" then
                return false
            end
            if b.le == "+Inf" then
                return true
            end
            return tonumber(a.le) < tonumber(b.le)
        end)

        for j = 1, #h.buckets do
            lines[#lines + 1] = h.buckets[j].raw .. " " .. tostring(h.buckets[j].val)
        end
        lines[#lines + 1] = keys.sum_key(m) .. " " .. tostring(h.sum)
        lines[#lines + 1] = keys.count_key(m) .. " " .. tostring(h.count)
    end

    if #lines == 0 then
        return ""
    end
    return table.concat(lines, "\n") .. "\n"
end

--- RPC metrics 记录器工厂函数
-- 调用计数（total/success/error/timeout，按 method 分组）+ 延迟直方图（bucket 分桶）
-- 存储在 ngx.shared.dict（worker 间共享），导出 Prometheus 文本格式
--
-- buffer 模式（可选启用）：
--   enabled = true 时，record() 累加到 worker-local _buffer（纯 Lua table 无锁），
--   on_init_worker 钩子通过 ngx.timer.every 定期 flush 到 shdict。
--   默认禁用（direct incr 模式）。worker crash 丢 ≤flush_interval 秒数据，对标 nginx access_log buffer。
--
-- @param opts table|nil { dict_name = "yar_metrics", prefix = "yar_rpc", buffer_enabled = false, flush_interval = 1 }
-- @return table hooks 表 + export() 函数
function _M.metrics_recorder(opts)
    opts = opts or {}
    local dict_name = opts.dict_name or "yar_metrics"
    local prefix = opts.prefix or "yar_rpc"
    local buffer_enabled = opts.buffer_enabled or false
    local flush_interval = opts.flush_interval or 1

    local dict = ngx.shared[dict_name]
    if not dict then
        ngx.log(
            ngx.WARN,
            "[resty.yar observability] shared dict '"
                .. dict_name
                .. "' not found, metrics disabled. Add 'lua_shared_dict "
                .. dict_name
                .. " 1m;' to nginx.conf"
        )
        return {
            on_request = function() end,
            on_response = function() end,
            export = function()
                return ""
            end,
        }
    end

    -- key 缓存：method×kind 组合预计算，消除热路径字符串拼接
    -- per-worker（闭包级），无锁竞争
    local _key_cache = {}
    -- 已知 method 列表：record() 首次注册，export() 遍历此表替代 get_keys(0)
    local _known_methods = {}
    -- worker-local buffer（buffer 模式用）：key -> accumulated value
    local _buffer = {}

    --- incr 分发：buffer 模式累加到 _buffer，direct 模式直接 dict:incr
    local function incr(key, val)
        if buffer_enabled then
            _buffer[key] = (_buffer[key] or 0) + val
        else
            dict:incr(key, val, 0)
        end
    end

    local function counter_key(method, kind)
        local ck = method .. "\0" .. kind
        local k = _key_cache[ck]
        if not k then
            k = prefix .. '_calls_total{method="' .. method .. '",status="' .. kind .. '"}'
            _key_cache[ck] = k
        end
        return k
    end

    local function bucket_key(method, bucket_idx)
        local ck = method .. "\0b" .. bucket_idx
        local k = _key_cache[ck]
        if not k then
            k = prefix .. '_duration_bucket{method="' .. method .. '",le="' .. LATENCY_BUCKETS[bucket_idx] .. '"}'
            _key_cache[ck] = k
        end
        return k
    end

    local function sum_key(method)
        local ck = method .. "\0sum"
        local k = _key_cache[ck]
        if not k then
            k = prefix .. '_duration_sum{method="' .. method .. '"}'
            _key_cache[ck] = k
        end
        return k
    end

    local function count_key(method)
        local ck = method .. "\0count"
        local k = _key_cache[ck]
        if not k then
            k = prefix .. '_duration_count{method="' .. method .. '"}'
            _key_cache[ck] = k
        end
        return k
    end

    local function inf_bucket_key(method)
        local ck = method .. "\0binf"
        local k = _key_cache[ck]
        if not k then
            k = prefix .. '_duration_bucket{method="' .. method .. '",le="+Inf"}'
            _key_cache[ck] = k
        end
        return k
    end

    local function record(method, _retval, err_obj)
        -- 注册 method（供 export 遍历，替代 get_keys(0)）
        _known_methods[method] = true

        local start = ngx.ctx[CTX_START_TIME] or ngx.now()
        local duration_ms = (ngx.now() - start) * 1000
        local status = error_status(err_obj)

        -- 计数器（incr 分发：buffer 模式累加到 _buffer，direct 模式 dict:incr）
        incr(counter_key(method, "total"), 1)
        incr(counter_key(method, status), 1)

        -- 直方图：找到对应 bucket 并 incr
        local bucket_idx = #LATENCY_BUCKETS
        for i = 1, #LATENCY_BUCKETS do
            if duration_ms <= LATENCY_BUCKETS[i] then
                bucket_idx = i
                break
            end
        end
        -- 累积直方图（Prometheus cumulative semantics）：
        -- duration <= LATENCY_BUCKETS[bucket_idx] 意味着也 <= 所有更大的 bucket
        -- 因此递增 bucket_idx 到末尾的所有 bucket（le=X bucket 包含所有 ≤ X 的观测）
        for i = bucket_idx, #LATENCY_BUCKETS do
            incr(bucket_key(method, i), 1)
        end
        -- +Inf bucket
        incr(inf_bucket_key(method), 1)

        -- sum 和 count
        incr(sum_key(method), duration_ms)
        incr(count_key(method), 1)
    end

    local metrics = {
        on_request = function(_method, _params)
            ngx.ctx[CTX_START_TIME] = ngx.now()
        end,
        on_response = function(method, retval, err_obj)
            record(method, retval, err_obj)
        end,
        --- 导出 Prometheus 文本格式，委托模块级 export_metrics
        -- @return string Prometheus exposition format
        export = function()
            return export_metrics(dict, _known_methods, prefix, {
                counter_key = counter_key,
                bucket_key = bucket_key,
                sum_key = sum_key,
                count_key = count_key,
                inf_bucket_key = inf_bucket_key,
            })
        end,
    }

    -- buffer 模式：注册 on_init_worker 钩子启动 timer flush
    -- on_init_worker 经 registry compose + hooks.adapt 传递，由 init.lua init_worker() 调用
    if buffer_enabled then
        metrics.on_init_worker = function()
            local ok, err = ngx.timer.every(flush_interval, function()
                for key, val in pairs(_buffer) do
                    dict:incr(key, val, 0)
                    _buffer[key] = nil
                end
            end)
            if not ok then
                ngx.log(ngx.WARN, "[resty.yar observability] failed to start metrics flush timer: " .. tostring(err))
            end
        end
    end

    return metrics
end

--- 组合多个 hooks 表为一个（按顺序执行 on_request，按顺序执行 on_response）
-- 每个 hook 用 pcall 隔离，单个 hook 报错不影响其他 hook 执行。
-- 对标 lua-yar 服务端 handler pcall 隔离模式（copas coroutine.resume 捕获不崩溃）。
-- @param ... table hooks 表列表
-- @return table 组合后的 hooks 表
function _M.compose(...)
    local hooks_list = {}
    for i = 1, select("#", ...) do
        local h = select(i, ...)
        if h then
            hooks_list[#hooks_list + 1] = h
        end
    end

    -- 委托 compose_named，确保全 hook 类型转发（on_error/on_timeout/on_connect/on_init_worker）
    -- 对标 DRY 原则：compose() 与 compose_named() 行为一致，避免 hook 丢失陷阱
    local list = {}
    for i = 1, #hooks_list do
        list[#list + 1] = { name = tostring(i), priority = i, hooks = hooks_list[i] }
    end
    return _M.compose_named(list)
end

--- 组合命名 hooks 列表（registry 用）
-- 输入 list = { { name="metrics", hooks={...}, priority=N }, ... }
-- 组合 on_request / on_response / on_error / on_timeout / on_connect / on_init_worker（按 hook 类型分别遍历）。
-- 错误日志显示插件 name 而非 index。pcall 隔离每个 hook。
-- @param list table 命名 hooks 列表
-- @return table 组合后的 hooks 表（含已存在的全部 hook 类型）
function _M.compose_named(list)
    -- 所有支持的 hook 类型
    local hook_types = { "on_request", "on_response", "on_error", "on_timeout", "on_connect", "on_init_worker" }
    local composed = {}

    for _, ht in ipairs(hook_types) do
        -- 收集此 hook 类型有值的插件
        local fns = {}
        for i = 1, #list do
            local fn = list[i].hooks[ht]
            if fn then
                fns[#fns + 1] = { name = list[i].name, fn = fn }
            end
        end

        if #fns > 0 then
            composed[ht] = function(...)
                for i = 1, #fns do
                    local ok, err = pcall(fns[i].fn, ...)
                    if not ok then
                        ngx.log(
                            ngx.WARN,
                            "[resty.yar] " .. ht .. " hook '" .. fns[i].name .. "' error: " .. tostring(err)
                        )
                    end
                end
            end
        end
    end

    return composed
end

--- 一键启用可观测性三件套（access_logger + trace_middleware + metrics_recorder）
-- 返回组合后的 hooks 表，等价于手动 compose 三件套。
-- @param opts table|nil { access_log = {...}, trace = {...}, metrics = {...} }
-- @return table hooks 表
function _M.defaults(opts)
    opts = opts or {}
    return _M.compose_named({
        { name = "trace", priority = 50, hooks = _M.trace_middleware(opts.trace) },
        { name = "access-log", priority = 100, hooks = _M.access_logger(opts.access_log) },
        { name = "metrics", priority = 200, hooks = _M.metrics_recorder(opts.metrics) },
    })
end

_M._LATENCY_BUCKETS = LATENCY_BUCKETS

return _M

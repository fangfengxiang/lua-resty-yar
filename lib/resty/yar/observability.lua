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
-- @param t table 待序列化的表
-- @return string JSON 字符串
local function to_json(t)
    local parts = {}
    for k, v in pairs(t) do
        local val
        local tv = type(v)
        if tv == "string" then
            local s = string.gsub(v, '\\', '\\\\')
            s = string.gsub(s, '"', '\\"')
            s = string.gsub(s, '\n', '\\n')
            s = string.gsub(s, '\r', '\\r')
            s = string.gsub(s, '\t', '\\t')
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
    if v == nil then return 0 end
    local tv = type(v)
    if tv == "table" then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
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
    if not err_obj then return "ok" end
    local code = err_obj.code or "unknown"
    return string.lower(code)
end

-- 请求级时间戳和参数大小存储 key（ngx.ctx 中的字段名）
-- 注意：access_logger 和 metrics_recorder 共享 CTX_START_TIME。
-- compose 组合时后执行的 on_request 会覆盖前者写入的值，但两次 ngx.now() 间隔在微秒级，影响可忽略。
local CTX_START_TIME = "yar_obs_start_time"
local CTX_PARAMS_SIZE = "yar_obs_params_size"

--- 结构化 JSON 访问日志工厂函数
-- 返回 hooks 表 { on_request, on_response }，注入 setup({ hooks = ... })
-- on_request 记录开始时间和参数大小，on_response 计算 duration 并输出 JSON 日志
-- @param opts table|nil { writer = fn(level, msg) }，默认 ngx.log(ngx.INFO, ...)
-- @return table hooks 表
function _M.access_logger(opts)
    opts = opts or {}
    local writer = opts.writer or function(level, msg)
        ngx.log(ngx.INFO, msg)
    end

    return {
        on_request = function(method, params)
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
                ts           = ngx.localtime(),
                level        = (status == "ok") and "info" or "warn",
                module       = "yar.rpc",
                method       = method or "unknown",
                params_size  = ngx.ctx[CTX_PARAMS_SIZE] or 0,
                status       = status,
                duration_ms  = math.floor(duration_ms * 1000) / 1000,
                request_id   = request_id,
            }
            if err_obj then
                entry.error = err_obj.message or ""
            else
                entry.retval_size = estimate_size(retval)
            end
            local json = to_json(entry)
            local level = (status == "ok") and ngx.INFO or ngx.WARN
            writer(level, json)
        end,
    }
end

--- request ID 追踪中间件工厂函数
-- 在 ngx.ctx 注入 request_id，供访问日志和业务代码关联使用。
-- trace context 跨服务传播：客户端通过 new_client opts.headers 注入 X-Request-Id，
-- 或通过 YAR 协议 provider/token 字段传播（lua-yar Client:set_options({ protocol = { provider = ..., token = ... } })）。
-- @param opts table|nil { id_generator = fn() -> string }，默认多熵源生成器
-- @return table hooks 表
function _M.trace_middleware(opts)
    opts = opts or {}
    local id_gen = opts.id_generator or gen_request_id

    return {
        on_request = function(method, params)
            local ctx = ngx.ctx
            if not ctx.request_id then
                ctx.request_id = id_gen()
            end
        end,
        on_response = function(method, retval, err_obj)
            -- request_id 已在 on_request 注入，此处无需操作
            -- trace context 传播通过 Client 的 provider/token 选项配置
        end,
    }
end

--- 获取当前请求的 request ID（供业务代码或日志格式化使用）
-- @return string request ID
function _M.get_request_id()
    return get_or_create_request_id()
end

--- RPC metrics 记录器工厂函数
-- 调用计数（total/success/error/timeout，按 method 分组）+ 延迟直方图（bucket 分桶）
-- 存储在 ngx.shared.dict（worker 间共享），导出 Prometheus 文本格式
-- @param opts table|nil { dict_name = "yar_metrics", prefix = "yar_rpc" }
-- @return table hooks 表 + export() 函数
function _M.metrics_recorder(opts)
    opts = opts or {}
    local dict_name = opts.dict_name or "yar_metrics"
    local prefix = opts.prefix or "yar_rpc"

    local dict = ngx.shared[dict_name]
    if not dict then
        ngx.log(ngx.WARN, "[resty.yar observability] shared dict '" .. dict_name
            .. "' not found, metrics disabled. Add 'lua_shared_dict " .. dict_name
            .. " 1m;' to nginx.conf")
        return {
            on_request = function() end,
            on_response = function() end,
            export = function() return "" end,
        }
    end

    local function counter_key(method, kind)
        return prefix .. "_calls_total{method=\"" .. method .. "\",status=\"" .. kind .. "\"}"
    end

    local function bucket_key(method, bucket_idx)
        return prefix .. "_duration_bucket{method=\"" .. method .. "\",le=\"" .. LATENCY_BUCKETS[bucket_idx] .. "\"}"
    end

    local function sum_key(method)
        return prefix .. "_duration_sum{method=\"" .. method .. "\"}"
    end

    local function count_key(method)
        return prefix .. "_duration_count{method=\"" .. method .. "\"}"
    end

    local function record(method, retval, err_obj)
        local start = ngx.ctx[CTX_START_TIME] or ngx.now()
        local duration_ms = (ngx.now() - start) * 1000
        local status = error_status(err_obj)

        -- 计数器（incr，原子操作），检查返回值防止静默失败
        local _, err = dict:incr(counter_key(method, "total"), 1, 0)
        if err then ngx.log(ngx.WARN, "[resty.yar observability] incr error: " .. err) end
        dict:incr(counter_key(method, status), 1, 0)

        -- 直方图：找到对应 bucket 并 incr
        local bucket_idx = #LATENCY_BUCKETS
        for i = 1, #LATENCY_BUCKETS do
            if duration_ms <= LATENCY_BUCKETS[i] then
                bucket_idx = i
                break
            end
        end
        -- 累积直方图：bucket[i] 包含所有 <= LATENCY_BUCKETS[i] 的计数
        for i = 1, bucket_idx do
            dict:incr(bucket_key(method, i), 1, 0)
        end
        -- +Inf bucket（不在 LATENCY_BUCKETS 数组中，单独构造 key）
        dict:incr(prefix .. "_duration_bucket{method=\"" .. method .. "\",le=\"+Inf\"}", 1, 0)

        -- sum 和 count
        dict:incr(sum_key(method), duration_ms, 0)
        dict:incr(count_key(method), 1, 0)
    end

    local metrics = {
        on_request = function(method, params)
            ngx.ctx[CTX_START_TIME] = ngx.now()
        end,
        on_response = function(method, retval, err_obj)
            record(method, retval, err_obj)
        end,
        --- 导出 Prometheus 文本格式
        -- 仅导出以 prefix 开头的 key，过滤共享 dict 中其他模块的数据
        -- @return string Prometheus exposition format
        export = function()
            local keys = dict:get_keys(0)
            local lines = {}

            for _, key in ipairs(keys) do
                if type(key) == "string" and #key > 0
                   and string.sub(key, 1, #prefix) == prefix then
                    local val = dict:get(key) or 0
                    lines[#lines + 1] = key .. " " .. tostring(val)
                end
            end

            return table.concat(lines, "\n") .. "\n"
        end,
    }

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

    return {
        on_request = function(method, params)
            for i = 1, #hooks_list do
                local fn = hooks_list[i].on_request
                if fn then
                    local ok, err = pcall(fn, method, params)
                    if not ok then
                        ngx.log(ngx.WARN, "[resty.yar observability] on_request hook "
                            .. i .. " error: " .. tostring(err))
                    end
                end
            end
        end,
        on_response = function(method, retval, err_obj)
            for i = 1, #hooks_list do
                local fn = hooks_list[i].on_response
                if fn then
                    local ok, err = pcall(fn, method, retval, err_obj)
                    if not ok then
                        ngx.log(ngx.WARN, "[resty.yar observability] on_response hook "
                            .. i .. " error: " .. tostring(err))
                    end
                end
            end
        end,
    }
end

_M._LATENCY_BUCKETS = LATENCY_BUCKETS

return _M

-- lib/resty/yar/registry.lua
-- 插件注册体系：register(name, factory, opts) + 优先级排序 + named compose。
--
-- 插件 factory 是无参函数，返回 hooks 表 { on_request=fn, on_response=fn, ... }。
-- 注册后在 setup() 时自动调 factory() 收集 hooks，按 priority 升序排序后 compose。
-- 向后兼容：setup({ hooks = { on_request=fn } }) 直传 inline hooks 当匿名插件 priority=50。
--
-- 用法：
--   local yar = require("resty.yar")
--   yar.register("access-log", function() return yar.observability.access_logger() end, { priority = 100 })
--   yar.register("trace", function() return yar.observability.trace_middleware() end, { priority = 50 })
--   yar.register("metrics", function() return yar.observability.metrics_recorder() end, { priority = 200 })
--   yar.setup({ service = { ... } })  -- 不再手动 compose hooks

local pairs = pairs
local table = table
local type = type
local tostring = tostring
local pcall = pcall
local ngx = ngx

local observability = require("resty.yar.observability")

local _M = {}

-- 已注册插件表：name -> { name, factory, priority, version }
-- Plugin registry: name -> { name, factory, priority, version }
local _plugins = {}

--- 注册插件（链式 API）
-- Plugin registry factory pattern: factory() -> hooks table
-- @param name string 插件名（用于错误日志定位）
-- @param factory function 无参函数，返回 hooks 表
-- @param opts table|nil { priority = number (default 100), version = string (default "1.0") }
-- @return _M（链式调用）
function _M.register(name, factory, opts)
    if type(name) ~= "string" or name == "" then
        error("register: name must be a non-empty string", 2)
    end
    if type(factory) ~= "function" then
        error("register: factory must be a function", 2)
    end
    opts = opts or {}
    _plugins[name] = {
        name = name,
        factory = factory,
        priority = opts.priority or 100,
        version = opts.version or "1.0",
    }
    return _M
end

--- 收集所有已注册插件的 hooks，排序后 compose
-- 1. 遍历 _plugins 调 factory() 收集 hooks
-- 2. user_hooks（inline hooks 直传）当匿名插件 priority=50 处理
-- 3. 按 priority 升序排序，相同 priority 按 name 排序保证确定性
-- 4. 调 observability.compose_named 组合（错误日志显示 name）
-- @param user_hooks table|nil inline hooks 直传（向后兼容）
-- @return table|nil 组合后的 hooks 表（无插件且无 user_hooks 时返回 nil）
function _M.get_hooks(user_hooks)
    local list = {}

    for _, p in pairs(_plugins) do
        local ok, h = pcall(p.factory)
        if ok and h then
            list[#list + 1] = { name = p.name, priority = p.priority, hooks = h }
        elseif not ok then
            ngx.log(ngx.WARN, "[resty.yar registry] plugin '" .. p.name .. "' factory error: " .. tostring(h))
        end
    end

    -- inline hooks 直传当匿名插件
    if user_hooks then
        list[#list + 1] = { name = "user", priority = 50, hooks = user_hooks }
    end

    if #list == 0 then
        return nil
    end

    -- 优先级升序（数字小先执行），相同 priority 按 name 排序
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.name < b.name
    end)

    return observability.compose_named(list)
end

--- 清空已注册插件（测试用）
-- @return _M（链式调用）
function _M.clear()
    _plugins = {}
    return _M
end

--- 获取已注册插件列表（调试/自省用，按 priority 升序排序）
-- @return table 有序数组，每项 { name, priority, version }
function _M.list()
    local result = {}
    for _, p in pairs(_plugins) do
        result[#result + 1] = { name = p.name, priority = p.priority, version = p.version }
    end
    -- 按 priority 升序，相同 priority 按 name 排序（与 get_hooks 一致，保证确定性）
    table.sort(result, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.name < b.name
    end)
    return result
end

return _M

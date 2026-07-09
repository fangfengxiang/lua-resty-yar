-- lib/resty/yar/hooks.lua
-- 框架生命周期钩子适配。
--
-- lua-yar 协议层只有 on_request(method, params) / on_response(method, retval, err_obj)。
-- 本模块从 on_response 派生 on_error / on_timeout，不改 lua-yar 协议层。
-- on_connect / on_init_worker 不走 lua-yar hooks 通道，由 init.lua 框架层直接调用。
--
-- 用法（init.lua setup 内部调用）：
--   local hooks = registry.get_hooks(opts.hooks)  -- 收集 + compose
--   local adapted = hooks_module.adapt(hooks)     -- 派生 on_error/on_timeout
--   server_opts.hooks = { on_request = adapted.on_request, on_response = adapted.on_response }
--   _on_connect = adapted.on_connect              -- new_client 中调用
--   _on_init_worker = adapted.on_init_worker      -- init_worker 中调用

local type = type

-- init.lua 加载时已 pcall(require, "yar") 并在失败时 error 中止，
-- hooks.lua 由 init.lua require（加载顺序保证 lua-yar 已存在），此处直接 require 无需守卫。
local Yar = require("yar")
local Error = Yar.error

local _M = {}

--- 将框架钩子适配为 lua-yar 的 on_request/on_response 协议
-- 从 on_response 派生：
--   1. 先调原始 on_response
--   2. err_obj 非 nil 时派生 on_error
--   3. err_obj.code == Error.TIMEOUT 时派生 on_timeout
-- on_connect / on_init_worker 透传（由 init.lua 直接调用）
-- @param framework_hooks table 组合后的 hooks 表（含 on_request/on_response/on_error/on_timeout/...）
-- @return table 适配后的 hooks 表（on_request/on_response 为 lua-yar 协议格式，on_connect/on_init_worker 透传）
function _M.adapt(framework_hooks)
    if not framework_hooks then
        return nil
    end

    local adapted = {
        on_request = framework_hooks.on_request,
        on_connect = framework_hooks.on_connect,
        on_init_worker = framework_hooks.on_init_worker,
    }

    local orig_on_response = framework_hooks.on_response
    local on_error_fn = framework_hooks.on_error
    local on_timeout_fn = framework_hooks.on_timeout

    if not orig_on_response and not on_error_fn and not on_timeout_fn then
        adapted.on_response = nil
    else
        adapted.on_response = function(method, retval, err_obj)
            -- 1. 先调原始 on_response
            if orig_on_response then
                orig_on_response(method, retval, err_obj)
            end
            -- 2. 派生 on_error（err_obj 存在时）
            if err_obj and on_error_fn then
                on_error_fn(method, err_obj)
            end
            -- 3. 派生 on_timeout（err_obj.code == TIMEOUT 时）
            if err_obj and on_timeout_fn then
                local code = err_obj.code
                if type(code) == "string" and code == Error.TIMEOUT then
                    on_timeout_fn(method)
                end
            end
        end
    end

    return adapted
end

return _M

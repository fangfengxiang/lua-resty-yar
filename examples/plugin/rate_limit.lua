-- Example plugin: rate limiting per RPC method.
--
-- Usage:
--   1. Require this file in init_by_lua_block before setup()
--   2. Declare lua_shared_dict rate_limit_dict in nginx http block
--   3. The plugin tracks a max-requests-per-second limit per method
--
-- Note: observability hooks (on_request/on_response) are wrapped in pcall by
-- compose_named — error() inside on_request is silently swallowed and cannot
-- abort the request. To enforce limits, use ngx.ctx markers checked by the
-- service layer or a gateway middleware. This example demonstrates the plugin
-- registration + priority ordering mechanism.

local yar = require("resty.yar")

local MAX_REQUESTS = 100  -- Max calls per second per method

yar.register("rate-limit", function()
    local dict = ngx.shared.rate_limit_dict

    return {
        on_request = function(method, _params)
            local key = method .. ":" .. os.date("%Y%m%d%H%M%S")
            local count = dict:incr(key, 1, 0)
            if count > MAX_REQUESTS then
                -- error() 在 compose_named 的 pcall 中被静默吞掉，无法中断请求。
                -- 改用 ngx.ctx 标记，service 层或 log 阶段可据此拒绝或告警。
                ngx.ctx.yar_rate_limited = true
                ngx.ctx.yar_rate_limit_count = count
            end
        end,

        on_response = function(method, _retval, err_obj)
            if ngx.ctx.yar_rate_limited then
                ngx.log(ngx.WARN, "[rate-limit] " .. method .. " exceeded limit (count="
                    .. tostring(ngx.ctx.yar_rate_limit_count) .. ")")
            elseif not err_obj then
                ngx.log(ngx.DEBUG, "[rate-limit] " .. method .. " ok")
            end
        end,
    }
end, { priority = 75 })  -- Between trace (50) and access-log (100)

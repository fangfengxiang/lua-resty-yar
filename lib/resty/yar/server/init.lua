-- lib/resty/yar/server/init.lua
-- 通用服务端入口：自动检测 HTTP / stream 上下文并分发到对应 handler。
--
--   http  server { location /api { content_by_lua_block { require("resty.yar.server").serve() } } }
--   stream server { listen 9999;   content_by_lua_block { require("resty.yar.server").serve() } }
--
-- 检测原理：HTTP 上下文有 ngx.req.get_method()，stream 上下文没有。
-- http/tcp 模块也可直接 require 调用，不强制走统一入口。

local ngx = ngx
local pcall = pcall
local require = require

local _M = {}

--- 服务端入口：检测上下文并分发
-- 便捷入口：自动检测 HTTP/stream 上下文。
-- 生产环境热路径建议直接调用：
--   HTTP:  require("resty.yar.server.http").serve()
--   TCP:   require("resty.yar.server.tcp").serve()
-- 以避免每请求 pcall 的上下文检测开销。
function _M.serve()
    local ok = pcall(ngx.req.get_method)
    if ok then
        ---@diagnostic disable-next-line: different-requires
        return require("resty.yar.server.http").serve()
    else
        ---@diagnostic disable-next-line: different-requires
        return require("resty.yar.server.tcp").serve()
    end
end

return _M

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

-- 上下文类型缓存（nil=未检测, "http"/"tcp"）
-- OpenResty 中 HTTP server 和 stream server 是不同 nginx 上下文，不会在同一 worker 内混用。
-- 首次请求 pcall 检测后缓存，后续该 worker 所有请求直接走缓存分支，零开销。
local _ctx_type

--- 服务端入口：检测上下文并分发
-- 便捷入口：自动检测 HTTP/stream 上下文，首次检测后缓存到模块级变量。
-- 也可直接调用：
--   HTTP:  require("resty.yar.server.http").serve()
--   TCP:   require("resty.yar.server.tcp").serve()
function _M.serve()
    if not _ctx_type then
        local ok = pcall(ngx.req.get_method)
        _ctx_type = ok and "http" or "tcp"
    end
    if _ctx_type == "http" then
        ---@diagnostic disable-next-line: different-requires
        return require("resty.yar.server.http").serve()
    end
    ---@diagnostic disable-next-line: different-requires
    return require("resty.yar.server.tcp").serve()
end

return _M

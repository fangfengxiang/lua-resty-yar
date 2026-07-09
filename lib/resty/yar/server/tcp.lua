-- lib/resty/yar/server/tcp.lua
-- OpenResty stream 模块 TCP 服务端 handler（连接保活）。
--
-- 并发模型：OpenResty stream 每连接一协程，ngx.req.socket() 返回下游 cosocket。
-- 直接调 lua-yar 的 handle_connection(sock, {keepalive=true})，复用内置帧读取 + 保活循环。
--
--   stream {
--       lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";
--       init_by_lua_block { require("resty.yar").setup() }
--       server {
--           listen 9999;
--           content_by_lua_block { require("resty.yar.server.tcp").serve() }
--       }
--   }

local ngx = ngx
local tostring = tostring
local pcall = pcall

local init = require("resty.yar")

local _M = {}

--- stream content_by_lua 入口
function _M.serve()
    local sock, err = ngx.req.socket()
    if not sock then
        ngx.log(ngx.ERR, "[resty.yar tcp] failed to get downstream socket: " .. tostring(err))
        return
    end

    -- 连接级超时：从 config 读，设三段超时到 cosocket
    local config = init.get_config()
    sock:settimeouts(config.connect_timeout, config.send_timeout, config.read_timeout)

    -- 委托 lua-yar 的 handle_connection，keepalive 循环模式
    local tcp_server = init.get_tcp_server()
    local ok, handler_err = pcall(tcp_server.handle_connection, tcp_server, sock, { keepalive = true })
    if not ok then
        ngx.log(ngx.ERR, "[resty.yar tcp] handler error: " .. tostring(handler_err))
    end

    -- 优雅关闭：shutdown("send") 进行 lingering close，避免内核发 RST
    -- shutdown 可能因连接已关闭而失败，pcall 包裹忽略错误
    pcall(sock.shutdown, sock, "send")

    -- stream 下游 socket 不支持 close（由 nginx 管理连接生命周期）
    pcall(sock.close, sock)
end

return _M

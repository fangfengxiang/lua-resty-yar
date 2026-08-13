-- lib/resty/yar/server/tcp.lua
-- OpenResty stream 模块 TCP 服务端 handler（连接保活）。
--
-- 委托 lua-yar Server Facade 的 socket 模式：
--   server:handle({ socket=sock, keepalive=true })
-- Facade 根据 self.protocol（宿主模式默认 "tcp"）分发到 TcpTransport.serve()，
-- TcpTransport.serve 内部处理 keepalive 循环（一个 TCP 连接处理多条 YAR 消息）。
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

-- 模块级缓存 Server 实例（避免每连接调用 get_server）
local _server

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

    -- 委托统一 Server Facade（TCP 模式 + keepalive 循环）
    if not _server then
        _server = init.get_server()
    end
    _server:handle({ socket = sock, keepalive = true })

    -- 优雅关闭：shutdown("send") 进行 lingering close，避免内核发 RST
    -- shutdown 可能因连接已关闭而失败，pcall 包裹忽略错误
    pcall(sock.shutdown, sock, "send")

    -- stream 下游 socket 不支持 close（由 nginx 管理连接生命周期）
    pcall(sock.close, sock)
end

return _M

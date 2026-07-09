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
    -- worker 退出时不再接受新连接，已有连接由 nginx worker_shutdown_timeout 处理
    if ngx.worker.exiting() then
        ngx.log(ngx.INFO, "[resty.yar tcp] worker exiting, skip new connection")
        return
    end

    local sock, err = ngx.req.socket()
    if not sock then
        ngx.log(ngx.ERR, "[resty.yar tcp] failed to get downstream socket: " .. tostring(err))
        return
    end

    -- 连接级超时：从 config.server 域读（服务端语义，非出向客户端超时）
    -- send_timeout = 发送响应超时；read_timeout = 等待客户端下一条消息超时（keepalive 即空闲超时）
    -- connect_timeout 对下游已建立连接无意义，沿用 server.timeout 保持一致性
    local config = init.get_config()
    local server_cfg = config.server
    sock:settimeouts(
        server_cfg.timeout,
        server_cfg.send_timeout or server_cfg.timeout,
        server_cfg.read_timeout or server_cfg.timeout
    )

    -- 委托统一 Server Facade（TCP 模式 + keepalive 循环）
    if not _server then
        _server = init.get_server()
    end
    _server:handle({ socket = sock, keepalive = true })

    -- 优雅关闭：shutdown("send") 进行 lingering close，避免内核发 RST
    -- shutdown 可能因连接已关闭而失败，pcall 包裹忽略错误
    pcall(sock.shutdown, sock, "send")

    -- stream 下游 socket 由 nginx 管理连接生命周期，不主动 close
    -- （ngx.req.socket() 返回的 cosocket close 行为未文档化，主动调用无意义）
end

return _M

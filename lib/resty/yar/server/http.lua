-- lib/resty/yar/server/http.lua
-- OpenResty HTTP 服务端 handler。
--
-- 并发模型：OpenResty 每请求一协程，handle_message 是纯协议函数无 I/O，
-- 天然 reentrant，N 个并发请求 = N 个协程并行。
-- Server 实例进程级复用（方法表 memoize）。
--
--   http {
--       init_by_lua_block { require("resty.yar").setup() }
--       server {
--           listen 8888;
--           location /api {
--               content_by_lua_block { require("resty.yar.server.http").serve() }
--           }
--       }
--   }

local ngx = ngx
local io = io
local pcall = pcall
local tostring = tostring

local init = require("resty.yar")
local Yar  = init.Yar
local Packager = Yar.Packager

-- HTTP 状态码常量
-- 优先使用 ngx.HTTP_* 常量；某些 OpenResty 版本/构建中可能为 nil，回退到数值。
local HTTP_METHOD_NOT_ALLOWED     = ngx.HTTP_METHOD_NOT_ALLOWED     or 405
local HTTP_BAD_REQUEST            = ngx.HTTP_BAD_REQUEST            or 400
local HTTP_INTERNAL_SERVER_ERROR  = ngx.HTTP_INTERNAL_SERVER_ERROR  or 500

local _M = {}

-- 模块级缓存 Server 实例（避免每请求调用 get_http_server()）
local _http_server

--- content_by_lua 入口：读 body -> handle_message -> 写响应
function _M.serve()
    if not _http_server then
        _http_server = init.get_http_server()
    end
    local server = _http_server
    local method = ngx.req.get_method()

    -- GET：内省，返回方法列表
    if method == "GET" then
        ngx.header["Content-Type"] = "application/json"
        local packager = Packager.get(Packager.JSON)
        ngx.print(packager.pack(server:list_methods()))
        return
    end

    -- 非 POST/GET 拒绝
    if method ~= "POST" then
        ngx.status = HTTP_METHOD_NOT_ALLOWED
        ngx.header["Content-Type"] = "text/plain"
        ngx.say("method not allowed")
        return
    end

    -- POST：读请求体（大 body 回退临时文件）
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if not data then
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "rb")
            if f then
                data = f:read("*a")
                f:close()
            else
                ngx.log(ngx.ERR, "[resty.yar http] failed to open body file: " .. file)
            end
        end
    end

    -- 空请求体
    if not data or data == "" then
        ngx.status = HTTP_BAD_REQUEST
        ngx.header["Content-Type"] = "text/plain"
        ngx.say("empty body")
        return
    end

    -- 核心：调用 lua-yar 的 handle_message（纯协议函数，无 I/O，reentrant）
    -- pcall 保护：RPC 方法抛错时返回 500，避免未处理异常
    local ok, resp, err = pcall(server.handle_message, server, data)
    if not ok then
        ngx.log(ngx.ERR, "[resty.yar http] handle_message panic: " .. tostring(resp))
        ngx.status = HTTP_INTERNAL_SERVER_ERROR
        ngx.header["Content-Type"] = "text/plain"
        ngx.say("internal error")
        return
    end
    -- handle_message 渲染失败时返回 nil, err（非异常），pcall 的 ok=true 但 resp=nil
    if not resp then
        ngx.log(ngx.ERR, "[resty.yar http] handle_message returned nil: " .. tostring(err))
        ngx.status = HTTP_INTERNAL_SERVER_ERROR
        ngx.header["Content-Type"] = "text/plain"
        ngx.say("internal error")
        return
    end

    ngx.header["Content-Type"] = "application/octet-stream"
    ngx.print(resp)
end

return _M

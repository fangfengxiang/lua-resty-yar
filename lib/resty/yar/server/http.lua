-- lib/resty/yar/server/http.lua
-- OpenResty HTTP 服务端 handler。
--
-- 委托 lua-yar Server Facade 的 serve_callback 模式：
--   server:handle({ method=..., data=..., writer=... })
-- serve_callback 内部封装 GET 内观 / 405 / 400 / 413 / handle_message / 响应写入全部逻辑。
-- writer 回调桥接 serve_callback 输出到 OpenResty ngx.status / ngx.header / ngx.print。
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
local pairs = pairs

local init = require("resty.yar")

local _M = {}

-- 模块级缓存 Server 实例（避免每请求调用 get_server）
local _server

--- content_by_lua 入口：读 body -> 委托 serve_callback -> writer 输出
function _M.serve()
    if not _server then
        _server = init.get_server()
    end

    -- 读请求体（大 body 回退临时文件，serve_callback 不处理此场景）
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

    -- writer 回调：serve_callback(status, headers, body) → ngx 输出
    -- 参数顺序 = HTTP 线序 = 回调执行序：status → headers → body
    local function writer(status, headers, body)
        ngx.status = status
        for k, v in pairs(headers) do
            ngx.header[k] = v
        end
        ngx.print(body)
    end

    -- 委托 lua-yar serve_callback（处理 GET/POST/405/400/413/handle_message）
    _server:handle({
        method = ngx.req.get_method(),
        data   = data or "",
        writer = writer,
    })
end

return _M

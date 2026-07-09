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

    -- 读请求体
    -- 若 body 超过 client_body_buffer_size，nginx 会回退到临时文件，get_body_data() 返回 nil。
    -- 热路径不做阻塞 I/O（io.open）：直接返回 413 拒绝处理。
    -- 生产环境应调大 client_body_buffer_size >= 预期 max_body_len，使 fallback 永不触发。
    -- 对标 lua-resty-http httpc:read_body() 在 cosocket 上分块读、热路径禁阻塞 I/O 的惯例。
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if not data then
        local file = ngx.req.get_body_file()
        if file then
            ngx.log(
                ngx.ERR,
                "[resty.yar http] request body in temp file (exceeds client_body_buffer_size), "
                    .. "rejected. Tune nginx client_body_buffer_size >= expected max_body_len. file: "
                    .. file
            )
            ngx.status = 413
            ngx.header["Content-Type"] = "text/plain"
            ngx.print("413 Request Entity Too Large")
            return
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
    -- 检查返回值，handle 失败时记录 ERR 日志，避免错误被静默吞掉导致无法诊断。
    -- 不强行设 500：writer 可能已部分写入响应，强行覆盖会产生叠加输出。
    local ok, err = _server:handle({
        method = ngx.req.get_method(),
        data = data or "",
        writer = writer,
    })
    if not ok then
        ngx.log(ngx.ERR, "[resty.yar http] handle error: " .. tostring(err))
        return
    end
end

return _M

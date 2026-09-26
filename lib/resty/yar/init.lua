-- lib/resty/yar/init.lua
-- lua-resty-yar: OpenResty Yar RPC 适配层主入口。
--
-- 在 init_by_lua_block 阶段调用 setup(opts) 一次，完成：
--   1. cosocket 注入（出向 RPC 走 OpenResty 非阻塞 I/O）
--   2. ngx.log writer 注入（lua-yar 日志重定向到 nginx error log）
--   3. 进程级 Server Facade 实例创建（HTTP/TCP 统一，worker 内共享）
--   4. 配置合并（连接级超时、保活、SSL 等参数）
--
--   http {
--       lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";
--       init_by_lua_block { require("resty.yar").setup() }
--   }

local ngx = ngx
local pcall = pcall
local require = require
local pairs = pairs
local error = error
local setmetatable = setmetatable

---@diagnostic disable: different-requires
local ok_yar, Yar = pcall(require, "yar")
if not ok_yar then
    error("lua-yar not found. Install it first: luarocks install lua-yar")
end
---@diagnostic enable: different-requires

local config = require("resty.yar.config")
local registry = require("resty.yar.registry")
local hooks_module = require("resty.yar.hooks")

local _M = {}
_M.Yar = Yar
_M.VERSION = "0.5.0"
-- 导出常用符号，用户无需直接 require lua-yar
_M.Error = Yar.error -- 结构化错误（err.code 程序化匹配）
_M.PACKAGER_JSON = Yar.PACKAGER_JSON -- "JSON" 打包器名称
_M.PACKAGER_MSGPACK = Yar.PACKAGER_MSGPACK -- "MSGPACK" 打包器名称
_M.observability = require("resty.yar.observability")

-- 插件注册入口（链式 API）
_M.register = function(name, factory, opts)
    return registry.register(name, factory, opts)
end

-- lua-yar Facade 引用缓存（减少热路径表查找）
local Server = Yar.server
local Client = Yar.client
local Log = Yar.log

-- 模块级缓存
local _server
local _on_worker_init
local _on_connect
local _on_init_worker
local _client_cache = {} -- uri -> Yar.Client（persistent 模式 worker 内复用）
setmetatable(_client_cache, { __mode = "v" }) -- 弱值表，允许 GC 回收未引用的客户端包装器

-- 日志级别映射：lua-yar Log 级别 → nginx 日志级别
local LOG_LEVEL_MAP = {
    [Log.DEBUG] = ngx.DEBUG,
    [Log.INFO] = ngx.INFO,
    [Log.WARN] = ngx.WARN,
    [Log.ERROR] = ngx.ERR,
}

--- 初始化：注入 cosocket + 注入 log writer + 创建 Server Facade + 合并配置
-- 在 init_by_lua 阶段调用一次，worker 内全局生效
-- @param opts table|nil 用户配置
-- @usage
--   require("resty.yar").setup {
--       server = {
--           service   = { add = function(a, b) return a + b end },
--           packager  = "Msgpack",
--           hooks     = { on_request = fn, on_response = fn },
--           json_max_depth = 100,
--       },
--       client = { connect_timeout = 2000 },
--       log_level      = Yar.log.DEBUG,
--       on_worker_init = function() ... end,
--   }
function _M.setup(opts)
    opts = opts or {}

    -- 合并用户配置到嵌套分域 DEFAULTS（flat 兼容 + deep_merge + 类型校验）
    local merged = config.merge(opts)
    local server_cfg = merged.server

    -- 1. 注入 cosocket（出向客户端路径用）
    Client.set_socket(ngx.socket)

    -- 2. 注入 ngx.log writer（将 lua-yar 日志重定向到 nginx error log）
    Log.set_writer(function(lvl, msg)
        ngx.log(LOG_LEVEL_MAP[lvl] or ngx.ERR, "[yar] " .. msg)
    end)

    -- 3. 日志级别配置（可选，范围 Log.DEBUG=1 ~ Log.ERROR=4）
    -- tonumber() 守卫：非 number 值（如字符串 "debug"）降级为 WARN 日志，不中止启动
    if merged.log_level then
        local lvl = tonumber(merged.log_level)
        if lvl and lvl >= Log.DEBUG and lvl <= Log.ERROR then
            Log.set_level(lvl)
        else
            ngx.log(
                ngx.WARN,
                "[resty.yar] invalid log_level: "
                    .. tostring(merged.log_level)
                    .. ", expected number "
                    .. Log.DEBUG
                    .. "-"
                    .. Log.ERROR
            )
        end
    end

    -- 4. RPC 服务定义
    local service = server_cfg.service
        or {
            add = function(a, b)
                return a + b
            end,
            sub = function(a, b)
                return a - b
            end,
            greet = function(name)
                return "hello, " .. name
            end,
        }

    -- 5. 创建进程级 Server Facade 实例（从 server 域读取配置）
    local server_opts = {
        packager = server_cfg.packager,
        timeout = server_cfg.timeout,
        max_body_len = server_cfg.max_body_len,
    }

    -- hooks 收集 + 适配：registry.get_hooks 收集已注册插件 + inline hooks，
    -- hooks.adapt 从 on_response 派生 on_error/on_timeout，返回 lua-yar 协议格式。
    -- 向后兼容：无注册插件且无 inline hooks 时 hooks 为 nil，不传 hooks。
    local composed_hooks = registry.get_hooks(server_cfg.hooks)
    local adapted_hooks = hooks_module.adapt(composed_hooks)
    if adapted_hooks then
        if adapted_hooks.on_request or adapted_hooks.on_response then
            server_opts.hooks = {
                on_request = adapted_hooks.on_request,
                on_response = adapted_hooks.on_response,
            }
        end
        _on_connect = adapted_hooks.on_connect
        _on_init_worker = adapted_hooks.on_init_worker
    end
    if server_cfg.json_max_depth then
        server_opts.json_max_depth = server_cfg.json_max_depth
    end
    if server_cfg.msgpack_max_depth then
        server_opts.msgpack_max_depth = server_cfg.msgpack_max_depth
    end
    _server = Server.new(service, server_opts)

    -- 6. 缓存 worker init 回调
    _on_worker_init = merged.on_worker_init

    -- 7. 可选：注册 cjson C 扩展加速器（替代纯 Lua JSON 编解码）
    if merged.extensions.use_cjson then
        local ok_cjson, cjson = pcall(require, "cjson")
        if ok_cjson then
            Yar.register_packager(Yar.PACKAGER_JSON, cjson)
        else
            ngx.log(ngx.WARN, "[resty.yar] use_cjson=true but cjson not available: " .. tostring(cjson))
        end
    end

    -- 8. 可选：注册 cmsgpack C 扩展加速器（替代纯 Lua Msgpack 编解码）
    if merged.extensions.use_cmsgpack then
        local ok_cmp, cmsgpack = pcall(require, "cmsgpack")
        if ok_cmp then
            Yar.register_packager(Yar.PACKAGER_MSGPACK, cmsgpack)
        else
            ngx.log(ngx.WARN, "[resty.yar] use_cmsgpack=true but cmsgpack not available: " .. tostring(cmsgpack))
        end
    end

    -- 9. 可选：注入 lua-resty-http provider（替代默认 cosocket 手动 HTTP 实现）
    -- 注意：request_uri 不原生支持 proxy/resolve，启用时这些选项被忽略并记录 WARN
    if merged.extensions.use_resty_http then
        local ok_http, http = pcall(require, "resty.http")
        if ok_http then
            Client.set_http_provider(function(url, prov_opts)
                if prov_opts.proxy and prov_opts.proxy ~= "" then
                    ngx.log(ngx.WARN, "[resty.yar] proxy option not supported in resty-http provider mode")
                end
                if prov_opts.resolve and prov_opts.resolve ~= "" then
                    ngx.log(ngx.WARN, "[resty.yar] resolve option not supported in resty-http provider mode")
                end
                local httpc = http.new()
                local ka = prov_opts.keepalive or {}
                local res, err = httpc:request_uri(url, {
                    method = prov_opts.method or "POST",
                    body = prov_opts.body,
                    headers = prov_opts.headers,
                    ssl_verify = prov_opts.ssl_verify ~= false,
                    connect_timeout = prov_opts.connect_timeout,
                    send_timeout = prov_opts.timeout,
                    read_timeout = prov_opts.timeout,
                    timeout = prov_opts.timeout,
                    keepalive_timeout = ka.idle_timeout,
                    keepalive_pool = ka.pool_size,
                })
                if not res then
                    return nil, err
                end
                if res.status ~= 200 then
                    return nil, "http status: " .. res.status
                end
                if not res.body then
                    return nil, "empty response body (status " .. res.status .. ")"
                end
                return res.body
            end)
        else
            ngx.log(ngx.WARN, "[resty.yar] use_resty_http=true but resty.http not available: " .. tostring(http))
        end
    end

    return _M
end

--- 获取进程级复用的 Server Facade 实例（HTTP/TCP 统一）
function _M.get_server()
    if not _server then
        error("resty.yar not initialized: call setup() in init_by_lua first")
    end
    return _server
end

--- 获取合并后的配置（handler 用来读连接级参数）
function _M.get_config()
    return config.get()
end

--- worker 进程初始化钩子（CHILD_INIT 映射）
-- 在 init_worker_by_lua_block 中调用：
--   1. 执行用户传入的 on_worker_init 回调（旧 API）
--   2. 调用框架 on_init_worker 钩子（插件可在此启动 timer）
function _M.init_worker()
    if _on_worker_init then
        _on_worker_init()
    end
    if _on_init_worker then
        _on_init_worker()
    end
end

--- 构造新的 Server Facade 实例（需要自定义 service / opts 时用）
-- @param svc table RPC 服务对象
-- @param opts table|nil Server 选项（packager/timeout/max_body_len/hooks 等）
-- @return Yar.Server 实例
function _M.new_server(svc, opts)
    return Server.new(svc, opts)
end

--- 创建客户端实例（每次新建，配置从 setup() 预填）
-- @param uri string 服务地址，如 http://host/api 或 tcp://host:port
-- @param opts table|nil per-client 选项覆盖（timeout/packager/ssl_verify/headers/resolve/proxy/hooks 等）
-- @return Yar.Client 实例
function _M.new_client(uri, opts)
    if not _server then
        error("resty.yar not initialized: call setup() in init_by_lua first")
    end
    opts = opts or {}
    local cfg = config.get()
    local client_cfg = cfg.client
    local client = Client.new(uri)
    -- ssl_verify 需正确处理 false 值（Lua and/or 短路将 false 视为 falsy）
    local ssl_verify = opts.ssl_verify
    if ssl_verify == nil then
        ssl_verify = client_cfg.ssl_verify
    end
    -- trace header 传播：从 ngx.ctx.yar_trace_headers 读取（trace_middleware 注入），
    -- 合并到出向请求 headers，不覆盖用户显式设置的 header。
    -- 创建新表合并，避免 mutation 调用方的 opts.headers（side-effect-free）
    local headers = opts.headers
    local trace_headers = ngx.ctx and ngx.ctx.yar_trace_headers
    if trace_headers then
        local merged = {}
        if headers then
            for k, v in pairs(headers) do
                merged[k] = v
            end
        end
        for k, v in pairs(trace_headers) do
            if not merged[k] then
                merged[k] = v
            end
        end
        headers = merged
    end
    local client_opts = {
        transport = {
            timeout = opts.timeout or client_cfg.timeout,
            connect_timeout = opts.connect_timeout or client_cfg.connect_timeout,
            max_body_len = opts.max_body_len or client_cfg.max_body_len,
            ssl_verify = ssl_verify,
            headers = headers,
            persistent = opts.persistent,
            resolve = opts.resolve or client_cfg.resolve,
            proxy = opts.proxy or client_cfg.proxy,
            keepalive = {
                idle_timeout = opts.keepalive_idle or client_cfg.keepalive_idle,
                pool_size = opts.pool_size or client_cfg.pool_size,
            },
        },
        protocol = {
            packager = opts.packager or cfg.server.packager,
        },
    }
    -- hooks 条件传递：仅当非 nil 时传入
    if opts.hooks then
        client_opts.hooks = opts.hooks
    end
    client:set_options(client_opts)

    -- on_connect 钩子（框架层，不走 lua-yar hooks 通道）
    if _on_connect then
        _on_connect(uri)
    end

    return client
end

--- 获取缓存的 persistent 客户端实例（同 uri worker 内复用）
-- 默认 persistent=true，socket 跨 call 复用，配合 cosocket 连接池实现 keepalive。
-- Per-request trace header 刷新：cached client 跨请求复用时，每次调用刷新 trace headers。
-- OpenResty 协作调度：set_options 不 yield，headers 在 client:call 发送前读取，无竞态。
-- @param uri string 服务地址
-- @param opts table|nil per-client 选项（仅首次创建时生效）
-- @return Yar.Client 实例
function _M.get_client(uri, opts)
    if not _server then
        error("resty.yar not initialized: call setup() in init_by_lua first")
    end
    local cached = _client_cache[uri]
    if cached then
        local client = cached.client
        -- 刷新 per-request trace headers（cached client 跨请求复用，需清除上次的 stale headers）
        -- trace_headers 为 nil 时也用 base_headers 重建，避免 stale trace header 跨请求泄漏
        local trace_headers = ngx.ctx and ngx.ctx.yar_trace_headers
        if trace_headers or cached.base_headers then
            local headers = {}
            if cached.base_headers then
                for k, v in pairs(cached.base_headers) do
                    headers[k] = v
                end
            end
            if trace_headers then
                for k, v in pairs(trace_headers) do
                    if not headers[k] then
                        headers[k] = v
                    end
                end
            end
            client:set_options({ transport = { headers = headers } })
        end
        return client
    end
    opts = opts or {}
    opts.persistent = true -- persistent 模式，socket 跨 call 复用
    local base_headers = opts.headers
    local client = _M.new_client(uri, opts)
    _client_cache[uri] = { client = client, base_headers = base_headers }
    return client
end

return _M

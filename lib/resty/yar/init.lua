-- lib/resty/yar/init.lua
-- lua-resty-yar: OpenResty Yar RPC 适配层主入口。
--
-- 在 init_by_lua_block 阶段调用 setup(opts) 一次，完成：
--   1. cosocket 注入（出向 RPC 走 OpenResty 非阻塞 I/O）
--   2. ngx.log writer 注入（lua-yar 日志重定向到 nginx error log）
--   3. 进程级 Server 实例创建（方法表 memoize，worker 内共享）
--   4. 配置合并（连接级超时、保活、SSL 等参数）
--   TcpServer 按需延迟加载，纯 HTTP 场景不加载 TCP 模块。
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

local _M = {}
_M.Yar = Yar
_M.VERSION = "0.1.0"

-- lua-yar 模块引用缓存（减少热路径表查找）
local Server = Yar.Server
local Client = Yar.Client
local Log = Yar.Log

-- 默认配置
local default_config = {
    -- 连接级（OPM 层管，cosocket 上设）
    connect_timeout  = 1000,    -- 连接超时（ms）
    send_timeout     = 5000,    -- 发送超时（ms）
    read_timeout     = 5000,    -- 读取超时（ms）
    keepalive_idle   = 60000,   -- TCP 保活空闲超时（ms）

    -- 服务端级（透传给 lua-yar Server/TcpServer 实例）
    packager         = Yar.PACKAGER_JSON,
    timeout          = 5000,    -- standalone run() 模式的 per-message 超时

    -- 客户端级默认（出向调用，可被 per-client setopt 覆盖）
    client_timeout   = 3000,    -- 出向 RPC 默认超时（ms）
    pool_size        = 30,      -- cosocket 连接池容量
    max_body_len     = 10 * 1024 * 1024,  -- 最大请求体长度（bytes，10MB）
    ssl_verify       = true,              -- HTTPS 证书验证（生产环境必须开启）
}

local config = {}
for k, v in pairs(default_config) do
    config[k] = v
end

-- 模块级缓存
local _server
local _tcp_server
local _tcp_service  -- 供 get_tcp_server() 延迟创建
local _on_worker_init
local _client_cache = {}   -- uri -> Yar.Client（persistent 模式 worker 内复用）
setmetatable(_client_cache, {__mode = "v"})  -- 弱值表，允许 GC 回收未引用的客户端包装器

-- lua-yar Log 级别 → ngx.log 级别映射
local LOG_LEVEL_MAP = {
    [Log.DEBUG] = ngx.DEBUG,
    [Log.INFO]  = ngx.INFO,
    [Log.WARN]  = ngx.WARN,
    [Log.ERROR] = ngx.ERR,
}

--- 初始化：注入 cosocket + 注入 log writer + 创建实例 + 合并配置
-- 在 init_by_lua 阶段调用一次，worker 内全局生效
-- @param opts table|nil 用户配置
-- @usage
--   require("resty.yar").setup {
--       service         = { add = function(a, b) return a + b end },
--       packager        = "Msgpack",
--       connect_timeout = 2000,
--       log_level       = Yar.Log.DEBUG,
--       on_worker_init  = function() ... end,
--   }
function _M.setup(opts)
    opts = opts or {}

    -- 合并用户配置（service/on_worker_init/log_level 不混入 config）
    for k, v in pairs(opts) do
        if k ~= "service" and k ~= "on_worker_init" and k ~= "log_level" then
            config[k] = v
        end
    end

    -- 1. 注入 cosocket（出向客户端路径用）
    Client.set_socket(ngx.socket)

    -- 2. 注入 ngx.log writer（将 lua-yar 日志重定向到 nginx error log）
    Log.set_writer(function(lvl, msg)
        ngx.log(LOG_LEVEL_MAP[lvl] or ngx.ERR, "[yar] " .. msg)
    end)

    -- 3. 日志级别配置（可选，范围 Log.DEBUG=1 ~ Log.ERROR=4）
    if opts.log_level and opts.log_level >= Log.DEBUG and opts.log_level <= Log.ERROR then
        Log.set_level(opts.log_level)
    end

    -- 4. RPC 服务定义
    local service = opts.service or {
        add   = function(a, b) return a + b end,
        sub   = function(a, b) return a - b end,
        greet = function(name) return "hello, " .. name end,
    }

    -- 5. 创建进程级 Server 实例
    _server = Server.new(service)
    _server:set_options({ packager = config.packager, timeout = config.timeout })

    -- 6. 缓存 service 供 TcpServer 延迟创建（纯 HTTP 场景不加载 TCP 模块）
    _tcp_service = service

    -- 7. 缓存 worker init 回调
    _on_worker_init = opts.on_worker_init

    return _M
end

--- 获取进程级复用的 Server 实例（HTTP 场景）
function _M.get_http_server()
    if not _server then
        error("resty.yar not initialized: call setup() in init_by_lua first")
    end
    return _server
end

--- 获取进程级复用的 TcpServer 实例（TCP stream 场景）
-- 延迟加载：纯 HTTP 场景不 require yar.server.tcp 模块
function _M.get_tcp_server()
    if not _tcp_server then
        if not _server then
            error("resty.yar not initialized: call setup() in init_by_lua first")
        end
        ---@diagnostic disable: different-requires
        local TcpServer = require("yar.server.tcp")
        ---@diagnostic enable: different-requires
        _tcp_server = TcpServer.new(_tcp_service)
        _tcp_server:set_options({ packager = config.packager, timeout = config.timeout })
    end
    return _tcp_server
end

--- 获取合并后的配置（handler 用来读连接级参数）
function _M.get_config()
    return config
end

--- worker 进程初始化钩子（CHILD_INIT 映射）
-- 在 init_worker_by_lua_block 中调用，执行用户传入的 on_worker_init 回调
function _M.init_worker()
    if _on_worker_init then
        _on_worker_init()
    end
end

--- 构造新的 Server 实例（需要自定义 service 时用）
function _M.new_server(svc)
    return Server.new(svc)
end

--- 创建客户端实例（每次新建，配置从 setup() 预填）
-- @param uri string 服务地址，如 http://host/api 或 tcp://host:port
-- @param opts table|nil per-client 选项覆盖（timeout/packager/ssl_verify/headers 等）
-- @return Yar.Client 实例
function _M.new_client(uri, opts)
    if not _server then
        error("resty.yar not initialized: call setup() in init_by_lua first")
    end
    opts = opts or {}
    local client = Client.new(uri)
    -- ssl_verify 需正确处理 false 值（Lua and/or 短路将 false 视为 falsy）
    local ssl_verify = opts.ssl_verify
    if ssl_verify == nil then
        ssl_verify = config.ssl_verify
    end
    client:set_options({
        transport = {
            timeout         = opts.timeout          or config.client_timeout,
            connect_timeout = opts.connect_timeout  or config.connect_timeout,
            max_body_len    = opts.max_body_len     or config.max_body_len,
            ssl_verify      = ssl_verify,
            headers         = opts.headers,
            persistent      = opts.persistent,
            keepalive = {
                idle_timeout = opts.keepalive_idle or config.keepalive_idle,
                pool_size    = opts.pool_size      or config.pool_size,
            },
        },
        protocol = {
            packager = opts.packager or config.packager,
        },
    })
    return client
end

--- 获取缓存的 persistent 客户端实例（同 uri worker 内复用）
-- 默认 persistent=true，socket 跨 call 复用，配合 cosocket 连接池实现 keepalive。
-- @param uri string 服务地址
-- @param opts table|nil per-client 选项（仅首次创建时生效）
-- @return Yar.Client 实例
function _M.get_client(uri, opts)
    if not _server then
        error("resty.yar not initialized: call setup() in init_by_lua first")
    end
    if _client_cache[uri] then
        return _client_cache[uri]
    end
    opts = opts or {}
    opts.persistent = true  -- persistent 模式，socket 跨 call 复用
    local client = _M.new_client(uri, opts)
    _client_cache[uri] = client
    return client
end

return _M

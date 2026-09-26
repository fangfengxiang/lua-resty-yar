-- lib/resty/yar/config.lua
-- 结构化配置：嵌套分域 DEFAULTS + deep_merge + flat 向后兼容 + 类型校验。
-- Structured config: nested domain DEFAULTS + deep_merge + flat compat + type validation.
--
-- 四域对应 OpenResty 配置层级：
--   server        → handler 层（packager/timeout/max_body_len/service/hooks）
--   client        → cosocket 层（timeout/connect_timeout/pool_size/ssl_verify 等）
--   observability → log/shdict 层（metrics_dict/metrics_prefix/access_log/trace）
--   extensions    → C 扩展加速器开关（use_cjson/use_cmsgpack/use_resty_http）
--
-- 在 init_by_lua 阶段由 setup() 调用 merge() 一次，类型校验失败则 error() 中止启动。

local ngx = ngx
local type = type
local pairs = pairs
local error = error

local _M = {}

-- 默认最大请求体长度（10 MiB）
local DEFAULT_MAX_BODY_LEN = 10 * 1024 * 1024

-- 嵌套分域默认配置
-- Nested domain defaults, merged with user opts via deep_merge
local DEFAULTS = {
    log_level = 2,
    server = {
        packager = "JSON",
        timeout = 5000,
        max_body_len = DEFAULT_MAX_BODY_LEN,
    },
    client = {
        timeout = 3000,
        connect_timeout = 1000,
        send_timeout = 5000,
        read_timeout = 5000,
        keepalive_idle = 60000,
        pool_size = 30,
        max_body_len = DEFAULT_MAX_BODY_LEN,
        ssl_verify = true,
        resolve = "",
        proxy = "",
    },
    observability = {
        metrics_dict = "yar_metrics",
        metrics_prefix = "yar",
        metrics_buffer = { enabled = false, flush_interval = 1 },
        access_log = { defer = false },
        trace = { header = "X-Request-Id" },
    },
    extensions = {
        use_cjson = false,
        use_cmsgpack = false,
        use_resty_http = false,
    },
}

-- flat key → domain 映射
-- 值为字符串时 domain key = flat key；值为 table 时 { domain, key } 用于重命名
-- max_body_len 特殊：映射到 server 域，同时复制到 client 域
local FLAT_MAP = {
    -- server domain
    packager = "server",
    timeout = "server",
    service = "server",
    hooks = "server",
    json_max_depth = "server",
    msgpack_max_depth = "server",
    max_body_len = "server",
    -- client domain
    connect_timeout = "client",
    send_timeout = "client",
    read_timeout = "client",
    keepalive_idle = "client",
    pool_size = "client",
    ssl_verify = "client",
    resolve = "client",
    proxy = "client",
    -- client domain (renamed: client_timeout → client.timeout)
    client_timeout = { "client", "timeout" },
    -- extensions domain
    use_cjson = "extensions",
    use_cmsgpack = "extensions",
    use_resty_http = "extensions",
}

-- 类型校验规范（域 → 键 → 期望类型）
-- Type validation spec (domain → key → expected type)
local TYPE_SPEC = {
    server = {
        packager = "string",
        timeout = "number",
        max_body_len = "number",
    },
    client = {
        timeout = "number",
        connect_timeout = "number",
        send_timeout = "number",
        read_timeout = "number",
        keepalive_idle = "number",
        pool_size = "number",
        max_body_len = "number",
        ssl_verify = "boolean",
        resolve = "string",
        proxy = "string",
    },
    observability = {
        metrics_dict = "string",
        metrics_prefix = "string",
        metrics_buffer = "table",
        access_log = "table",
        trace = "table",
    },
    extensions = {
        use_cjson = "boolean",
        use_cmsgpack = "boolean",
        use_resty_http = "boolean",
        json_max_depth = "number",
        msgpack_max_depth = "number",
    },
}

-- 合并后的配置（merge() 设置，get() 读取）
-- Merged config (set by merge(), retrieved by get())
local _merged

--- 递归深合并 overrides 到 defaults
-- table 值递归合并，标量值直接覆盖
-- 深度保护：递归超过 100 层时返回 overrides（对标 lua-yar client.lua deep_merge）
-- @param defaults table 默认配置
-- @param overrides table 用户覆盖
-- @param depth number|nil 当前递归深度（内部用，调用方不传）
-- @return table 合并后的新表（不修改入参）
local function deep_merge(defaults, overrides, depth)
    depth = depth or 0
    if depth > 100 then
        return overrides
    end
    local result = {}
    -- 深拷贝 defaults 的 table 值，避免共享引用污染 DEFAULTS
    -- （用户修改返回的 config 会污染模块级默认配置，导致重复 setup() 使用被污染的默认值）
    for k, v in pairs(defaults) do
        result[k] = type(v) == "table" and deep_merge({}, v, depth + 1) or v
    end
    for k, v in pairs(overrides) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = deep_merge(result[k], v, depth + 1)
        else
            result[k] = v
        end
    end
    return result
end

--- flat 格式 → nested 格式转换
-- 检测顶层 flat key，映射到对应域。nested 优先，flat 仅在 nested 未设置时填充。
-- @param opts table 用户配置（可能含 flat 和/或 nested key）
-- @return table 转换后的 nested 配置
local function convert_flat(opts)
    local nested = {}
    local flat_part = {}
    local has_flat = false

    for k, v in pairs(opts) do
        if FLAT_MAP[k] then
            has_flat = true
            flat_part[k] = v
        else
            nested[k] = v
        end
    end

    if has_flat then
        for flat_key, value in pairs(flat_part) do
            local mapping = FLAT_MAP[flat_key]
            local domain, key
            if type(mapping) == "table" then
                domain = mapping[1]
                key = mapping[2]
            else
                domain = mapping
                key = flat_key
            end
            if not nested[domain] then
                nested[domain] = {}
            end
            if nested[domain][key] == nil then
                nested[domain][key] = value
            else
                ngx.log(
                    ngx.WARN,
                    "[resty.yar] both flat '"
                        .. flat_key
                        .. "' and nested '"
                        .. domain
                        .. "."
                        .. key
                        .. "' provided, using nested value"
                )
            end
            -- max_body_len 特殊：同时复制到 client 域
            if flat_key == "max_body_len" then
                if not nested.client then
                    nested.client = {}
                end
                if nested.client.max_body_len == nil then
                    nested.client.max_body_len = value
                end
            end
        end
        ngx.log(
            ngx.WARN,
            "[resty.yar] flat config format is deprecated, "
                .. "use nested format: setup({ server = {...}, client = {...}, ... })"
        )
    end

    return nested
end

--- 类型校验（init_by_lua 阶段 fail-fast）
-- 域必须为 table，域内标量键类型必须匹配 TYPE_SPEC
-- @param config table 合并后的配置
-- @error 类型不匹配时 error(msg, 2) 指向调用方
local function validate(config)
    for domain, specs in pairs(TYPE_SPEC) do
        local d = config[domain]
        if d ~= nil then
            if type(d) ~= "table" then
                error(domain .. " must be a table, got " .. type(d), 2)
            end
            for key, expected in pairs(specs) do
                local val = d[key]
                if val ~= nil and type(val) ~= expected then
                    error(domain .. "." .. key .. " must be a " .. expected .. ", got " .. type(val), 2)
                end
            end
        end
    end
    -- service 特殊校验：若提供则必须为 table
    if
        config.server
        and type(config.server) == "table"
        and config.server.service ~= nil
        and type(config.server.service) ~= "table"
    then
        error("server.service must be a table, got " .. type(config.server.service), 2)
    end
end

--- 合并用户配置到 DEFAULTS（flat 兼容 + deep_merge + 校验）
-- 在 init_by_lua 阶段由 setup() 调用一次
-- @param user_opts table|nil 用户配置（支持 flat 和 nested 两种格式）
-- @return table 合并后的完整嵌套配置
function _M.merge(user_opts)
    user_opts = user_opts or {}
    local nested = convert_flat(user_opts)
    _merged = deep_merge(DEFAULTS, nested)
    validate(_merged)
    return _merged
end

--- 获取合并后的配置
-- @return table 嵌套配置表（四域 + 顶层参数）
function _M.get()
    return _merged
end

_M.DEFAULTS = DEFAULTS

return _M

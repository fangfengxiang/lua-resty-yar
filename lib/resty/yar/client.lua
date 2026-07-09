-- lib/resty/yar/client.lua
-- OpenResty Yar 客户端便捷封装。
--
-- 薄封装层：委托 init.new_client / init.get_client 创建预配置的 Yar.Client 实例，
-- 不重新实现协议逻辑。使用方式：
--
--   local client = require("resty.yar.client").new("http://host/api")
--   local result = client:call("add", {1, 2})
--
--   local pclient = require("resty.yar.client").get("tcp://host:9999")
--   local r1 = pclient:call("add", {1, 2})  -- persistent，连接复用
--   local r2 = pclient:call("add", {3, 4})

local init = require("resty.yar")

local _M = {}

--- 创建客户端实例（每次新建，配置从 setup() 预填）
-- @param uri string 服务地址，如 http://host/api 或 tcp://host:port
-- @param opts table|nil per-client 选项覆盖
-- @return Yar.Client 实例
function _M.new(uri, opts)
    return init.new_client(uri, opts)
end

--- 获取缓存的 persistent 客户端实例（同 uri worker 内复用）
-- @param uri string 服务地址
-- @param opts table|nil per-client 选项（仅首次创建时生效）
-- @return Yar.Client 实例
function _M.get(uri, opts)
    return init.get_client(uri, opts)
end

return _M

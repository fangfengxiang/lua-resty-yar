# 认证示例

lua-resty-yar 框架不内置认证中间件，但提供 `on_request` hook 扩展点。以下示例展示如何通过 hooks 实现 Token 认证。

## 方式一：YAR 协议 Token 认证

Yar 协议头中有 `token` 字段，客户端可在调用时传入，服务端在 `on_request` hook 中校验。

```lua
local yar = require("resty.yar")

local VALID_TOKEN = os.getenv("YAR_AUTH_TOKEN")

yar.setup({
    server = {
        service = MyApp,
        hooks = {
            on_request = function(req)
                if req.token ~= VALID_TOKEN then
                    return nil, "unauthorized: invalid token"
                end
                return true
            end,
        },
    },
})
```

客户端侧配置 token：
```lua
local client = yar.new_client({
    packager = "json",
    token = os.getenv("YAR_AUTH_TOKEN"),
})
```

## 方式二：HTTP Header Bearer Token 认证

适合 HTTP 模式下的 API Key / Bearer Token 认证。TCP 模式下不可用。

```lua
local yar = require("resty.yar")

yar.setup({
    server = {
        service = MyApp,
        hooks = {
            on_request = function(req)
                local auth = ngx.req.get_headers()["Authorization"]
                if not auth then
                    return nil, "unauthorized: missing Authorization header"
                end
                local token = auth:match("^Bearer%s+(.+)$")
                if not token then
                    return nil, "unauthorized: invalid format"
                end
                -- 实际应用 HMAC 验签或 JWT 验证
                if token ~= os.getenv("API_BEARER_TOKEN") then
                    return nil, "unauthorized: invalid token"
                end
                return true
            end,
        },
    },
})
```

## 方式三：HMAC 签名认证

客户端用密钥对请求内容签名，服务端验签。适合防篡改场景。

```lua
local yar = require("resty.yar")
local hmac = require("resty.hmac")

local SECRET = os.getenv("YAR_HMAC_SECRET")

yar.setup({
    server = {
        service = MyApp,
        hooks = {
            on_request = function(req)
                local method = req.method or ""
                local req_id = req.id or ""
                local signature = req.token or ""
                local mac = hmac:new(SECRET, hmac.ALG.SHA256)
                mac:update(method .. req_id)
                if mac:final() ~= signature then
                    return nil, "unauthorized: signature mismatch"
                end
                return true
            end,
        },
    },
})
```

## 方式四：通过 registry 注册认证插件

适合多认证方案组合场景。

```lua
local yar = require("resty.yar")
local registry = require("resty.yar.registry")

registry.register("auth-token", function(opts)
    local valid = opts.token
    return {
        on_request = function(req)
            if req.token ~= valid then
                return nil, "unauthorized"
            end
            return true
        end,
    }
end, { token = os.getenv("YAR_AUTH_TOKEN") })

yar.setup({ server = { service = MyApp } })
```

## 注意事项

- **TCP vs HTTP**：YAR 协议 token 字段两种模式均可用；HTTP header 认证仅 HTTP 模式可用。
- **on_request 返回值**：返回 `nil, err` 拒绝请求（hooks.lua 自动派生 `on_error` 记录日志），返回 `true` 继续。
- **密钥管理**：不要硬编码密钥，用环境变量或配置中心。HMAC 验签用常量时间比较防侧信道攻击。

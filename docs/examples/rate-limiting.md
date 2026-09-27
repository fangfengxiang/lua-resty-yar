# 限流示例

lua-resty-yar 框架不内置限流中间件，但提供 `on_request` hook 扩展点。以下示例展示如何通过 hooks 实现令牌桶限流。

## 方式一：通过 setup 配置 hooks

最简单的方式——直接在 `setup()` 中配置 `on_request` 钩子。

```lua
-- init.lua
local yar = require("resty.yar")

-- 令牌桶（worker 级，每个 worker 独立限流）
local tokens = 100        -- 当前令牌数
local max_tokens = 100   -- 桶容量
local rate = 10           -- 补充速率（令牌/秒）
local last_refill = ngx.now()

local function acquire()
    -- 补充令牌
    local now = ngx.now()
    local elapsed = now - last_refill
    tokens = math.min(max_tokens, tokens + elapsed * rate)
    last_refill = now

    if tokens >= 1 then
        tokens = tokens - 1
        return true
    end
    return false
end

yar.setup({
    server = {
        service = MyApp,
        hooks = {
            on_request = function(req)
                if not acquire() then
                    -- 返回 nil, err 拒绝请求，框架编码为 YAR 错误响应
                    return nil, "rate limit exceeded"
                end
                return true
            end,
        },
    },
})
```

## 方式二：通过 registry 注册插件

适合需要复用和配置化的场景。

```lua
local yar = require("resty.yar")
local registry = require("resty.yar.registry")

-- 注册限流插件
registry.register("rate-limit", function(opts)
    local tokens = opts.burst or 100
    local max_tokens = opts.burst or 100
    local rate = opts.rate or 10
    local last_refill = ngx.now()

    return {
        on_request = function(req)
            local now = ngx.now()
            local elapsed = now - last_refill
            tokens = math.min(max_tokens, tokens + elapsed * rate)
            last_refill = now

            if tokens < 1 then
                return nil, "rate limit exceeded"
            end
            tokens = tokens - 1
            return true
        end,
    }
end, { rate = 10, burst = 100 })  -- 默认配置

yar.setup({
    server = {
        service = MyApp,
    },
})
```

## 方式三：集成 lua-resty-limit-traffic

适合需要精确限流（leaky bucket / sliding window）的场景。

```lua
local yar = require("resty.yar")
local limit_req = require("resty.limit.req")

-- 漏桶限流：200 QPS，突发 400
local lim = limit_req.new("my_limit_req_store", 200, 400)

yar.setup({
    server = {
        service = MyApp,
        hooks = {
            on_request = function(req)
                -- 用客户端 IP 或请求 ID 做 key
                local key = ngx.var.remote_addr
                local delay, err = lim:incoming(key, true)
                if not delay then
                    if err == "rejected" then
                        return nil, "rate limit exceeded"
                    end
                    return nil, "limiter error: " .. err
                end
                -- delay > 0 时，可以 ngx.sleep(delay) 实现延迟排队
                if delay > 0 then
                    ngx.sleep(delay)
                end
                return true
            end,
        },
    },
})
```

**注意**：需在 nginx.conf 中声明 shared dict：
```nginx
lua_shared_dict my_limit_req_store 1m;
```

## 注意事项

- **worker 级限流**：每个 worker 独立计数，实际 QPS 上限 = `worker_processes` x `rate`。如需全局限流，用 shared dict 存储计数。
- **令牌桶 vs 漏桶**：令牌桶允许突发（burst），漏桶平滑流量。RPC 场景通常用令牌桶。
- **on_request 返回值**：返回 `nil, err` 拒绝请求（框架编码为 YAR 错误响应），返回 `true` 继续。
- **不要在 hook 中做重 I/O**：hook 在 RPC 处理主路径上执行，阻塞会拖慢所有请求。

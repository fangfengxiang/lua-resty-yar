# 性能调优指南

lua-resty-yar 是轻量 RPC 框架，性能优化主要在序列化加速、连接池调参、超时配置、metrics flush 策略四个方面。

## 1. C 扩展加速

lua-yar 默认用纯 Lua 实现的 JSON/Msgpack 编解码。在高频 RPC 或大 payload 场景下，切换到 C 扩展可显著降低序列化延迟。

```lua
require("resty.yar").setup({
    extensions = {
        use_cjson = true,       -- 用 cjson 替代纯 Lua JSON 编解码
        use_cmsgpack = true,     -- 用 cmsgpack 替代纯 Lua Msgpack 编解码
    },
})
```

| 场景 | 纯 Lua | C 扩展 | 加速比 | 建议阈值 |
|------|--------|--------|--------|----------|
| JSON encode 1KB | ~50us | ~5us | ~10x | payload > 512B 或 QPS > 1000 |
| JSON decode 1KB | ~80us | ~8us | ~10x | 同上 |
| Msgpack encode 1KB | ~40us | ~3us | ~13x | 同上 |
| Msgpack decode 1KB | ~60us | ~5us | ~12x | 同上 |

**注意事项**：
- C 扩展是可选依赖，`use_cjson = true` 但未安装 cjson 时会 fallback 到纯 Lua（不报错）
- cjson 不支持循环引用和 function 类型，编码时会 error()（由 `Protocol.render` 的 pcall 捕获）
- 生产环境推荐开启 C 扩展，开发环境可关闭以便调试

## 2. 连接池调参

cosocket 的 `setkeepalive(idle_timeout, pool_size)` 控制连接复用。

```lua
require("resty.yar").setup({
    client = {
        keepalive = {
            idle_timeout = 60000,   -- 空闲连接保持时间（ms）
            pool_size = 100,        -- 连接池大小
        },
    },
})
```

| 参数 | 推荐值 | 过小的影响 | 过大的影响 |
|------|--------|-----------|-----------|
| `idle_timeout` | 60000ms | 连接频繁重建（TCP 握手开销 ~1ms/次） | idle 连接占用 fd 和内存 |
| `pool_size` | 100 | 高并发时连接不够用，新建连接 | 每个 worker 占用 100 个 fd |

**与 nginx `worker_connections` 的关系**：
- 每个 worker 的 cosocket 连接池独立
- 总 fd 消耗 ≈ `worker_processes` × `pool_size` × 后端服务数
- 建议 `worker_connections` ≥ `pool_size` × 2 + 预留客户端连接数

**调优原则**：
- 低频调用（< 100 QPS/worker）：`idle_timeout=30000, pool_size=10`
- 中频调用（100-1000 QPS/worker）：`idle_timeout=60000, pool_size=50`
- 高频调用（> 1000 QPS/worker）：`idle_timeout=60000, pool_size=100`

## 3. 超时配置

```lua
require("resty.yar").setup({
    client = {
        connect_timeout = 1000,   -- 连接建立超时（ms）
        send_timeout = 5000,     -- 发送超时（ms）
        read_timeout = 5000,     -- 读取响应超时（ms）
    },
    server = {
        timeout = 5000,          -- 服务端处理超时（ms）
    },
})
```

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| `connect_timeout` | 1000ms | TCP 握手通常 < 100ms，1s 足够覆盖网络抖动 |
| `send_timeout` | 5000ms | 请求体通常 < 1KB，5s 足够覆盖慢网络 |
| `read_timeout` | 5000ms | RPC 处理通常 < 1s，5s 足够覆盖慢方法 |
| `server.timeout` | 5000ms | 服务端 handler 超时，防止协程泄漏 |

**调优原则**：
- 内网调用：`connect_timeout=500, send_timeout=3000, read_timeout=3000`
- 跨网段调用：`connect_timeout=2000, send_timeout=10000, read_timeout=10000`
- 超时应满足 `connect_timeout < read_timeout < server.timeout`

## 4. buffer 模式 Metrics

默认 metrics 每次记录直接写入 `ngx.shared.dict`，高 QPS 时 shared dict 写入成为瓶颈。buffer 模式在 worker 内累积后批量 flush。

```lua
require("resty.yar").setup({
    observability = {
        metrics_buffer = {
            enabled = true,
            flush_interval = 5,   -- flush 间隔（秒）
            max_entries = 10000,  -- buffer 容量上限
        },
    },
})
```

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| `flush_interval` | 5s | 1s 太频繁（shared dict 写入未显著减少），10s 太长（指标延迟） |
| `max_entries` | 10000 | 超过时触发降级（丢弃新指标，记录 drop count） |

**降级行为**：
- buffer 溢出时丢弃新指标，在 shared dict 中记录 `metrics_dropped_total` counter
- worker exit 时自动 flush 剩余 buffer
- `flush_interval=0` 等价于禁用 buffer（每次直接写 shared dict）

## 5. 推荐值参考表

| 配置项 | 低频 (< 100 QPS) | 中频 (100-1000) | 高频 (> 1000) |
|--------|-------------------|-----------------|---------------|
| `use_cjson` | false（可选） | true | true |
| `use_cmsgpack` | false（可选） | true | true |
| `keepalive.idle_timeout` | 30000 | 60000 | 60000 |
| `keepalive.pool_size` | 10 | 50 | 100 |
| `connect_timeout` | 1000 | 1000 | 500 |
| `send_timeout` | 5000 | 5000 | 3000 |
| `read_timeout` | 5000 | 5000 | 3000 |
| `server.timeout` | 5000 | 5000 | 5000 |
| `metrics_buffer.enabled` | false | true | true |
| `metrics_buffer.flush_interval` | - | 5 | 3 |
| `max_body_len` | 8388608 (8MB) | 8388608 | 1048576 (1MB) |

**注意**：以上推荐值基于内网 RPC 场景。跨网段调用需适当增大超时。具体值应根据业务特点和压测结果调整。

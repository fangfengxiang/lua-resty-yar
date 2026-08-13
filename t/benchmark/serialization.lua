-- t/benchmark/serialization.lua
-- 性能基准测试：纯 Lua 序列化/反序列化 vs C 扩展（cjson/cmsgpack）
-- 运行方式: resty --lua-path 'path/to/lua-yar/src/?.lua;;' t/benchmark/serialization.lua

local ngx_now = ngx.now

local function bench(name, fn, iterations)
    -- warmup
    fn()
    -- bench
    local start = ngx_now()
    for _ = 1, iterations do
        fn()
    end
    local elapsed = ngx_now() - start
    local per_op = elapsed / iterations * 1e6  -- us/op
    print(string.format("  %-30s %8.2f us/op  (%d iters, %.3f ms total)",
        name, per_op, iterations, elapsed * 1000))
    return per_op
end

local function gen_payload(n)
    local t = {}
    for i = 1, n do
        t["key_" .. i] = "value_" .. string.rep("x", 32)
    end
    return t
end

local payload = gen_payload(50)
local iterations = 10000

print("=== Yar Serialization Benchmark ===")
print(string.format("Payload: %d fields, iterations: %d\n", 50, iterations))

-- JSON
print("[JSON]")
local Json = require("yar.packager.json")
local json_packed = Json.pack(payload)

local json_pure_enc = bench("pure-Lua Json.pack", function()
    Json.pack(payload)
end)

local ok_cjson, cjson = pcall(require, "cjson")
if ok_cjson then
    local cjson_packed = cjson.encode(payload)
    local json_c_enc = bench("cjson.encode", function()
        cjson.encode(payload)
    end)
    print(string.format("  encode speedup: %.2fx\n", json_pure_enc / json_c_enc))

    -- decode benchmarks
    local json_pure_dec = bench("pure-Lua Json.unpack", function()
        Json.unpack(json_packed)
    end)
    local json_c_dec = bench("cjson.decode", function()
        cjson.decode(cjson_packed)
    end)
    print(string.format("  decode speedup: %.2fx\n", json_pure_dec / json_c_dec))
else
    print("  cjson not available, skipping\n")
end

-- Msgpack
print("[Msgpack]")
local Msgpack = require("yar.packager.msgpack")
local msgpack_packed = Msgpack.pack(payload)

local msgpack_pure_enc = bench("pure-Lua Msgpack.pack", function()
    Msgpack.pack(payload)
end)

local ok_cmp, cmsgpack = pcall(require, "cmsgpack")
if ok_cmp then
    local cmp_packed = cmsgpack.pack(payload)
    local msgpack_c_enc = bench("cmsgpack.pack", function()
        cmsgpack.pack(payload)
    end)
    print(string.format("  encode speedup: %.2fx\n", msgpack_pure_enc / msgpack_c_enc))

    -- decode benchmarks
    local msgpack_pure_dec = bench("pure-Lua Msgpack.unpack", function()
        Msgpack.unpack(msgpack_packed)
    end)
    local msgpack_c_dec = bench("cmsgpack.unpack", function()
        cmsgpack.unpack(cmp_packed)
    end)
    print(string.format("  decode speedup: %.2fx\n", msgpack_pure_dec / msgpack_c_dec))
else
    print("  cmsgpack not available, skipping\n")
end

print("=== Done ===")

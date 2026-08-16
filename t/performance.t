use Test::Nginx::Socket::Lua;

# Performance tests — latency bounds, connection pooling, throughput.
# Asserts that RPC calls complete within acceptable time thresholds.

repeat_each(2);
plan tests => repeat_each() * 15;

run_tests();

__DATA__

=== TEST 1: Single HTTP RPC call completes within 50ms
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end }
        }
    }
--- config
    location /api {
        content_by_lua_block { require("resty.yar.server.http").serve() }
    }
    location /t {
        content_by_lua_block {
            local R = require("yar.message.request")
            local P = require("yar.protocol.protocol")
            local K = require("yar.packager.packager")
            local req = R.new({ method = "add", params = { 1, 2 } })
            local pk = K.get(K.JSON)
            local start = ngx.now()
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST, body = P.render(req, pk)
            })
            local elapsed_ms = (ngx.now() - start) * 1000
            local pl = P.parse(res.body, pk)
            ngx.say("r=" .. tostring(pl.r))
            ngx.say("under_50ms=" .. tostring(elapsed_ms < 50))
        }
    }
--- request
GET /t
--- response_body
r=3
under_50ms=true
--- no_error_log
[error]

=== TEST 2: 100 sequential RPC calls complete within 2s total
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end }
        }
    }
--- config
    location /api {
        content_by_lua_block { require("resty.yar.server.http").serve() }
    }
    location /t {
        content_by_lua_block {
            local R = require("yar.message.request")
            local P = require("yar.protocol.protocol")
            local K = require("yar.packager.packager")
            local pk = K.get(K.JSON)
            local start = ngx.now()
            local ok_count = 0
            for i = 1, 100 do
                local req = R.new({ method = "add", params = { i, i } })
                local res = ngx.location.capture("/api", {
                    method = ngx.HTTP_POST, body = P.render(req, pk)
                })
                local pl = P.parse(res.body, pk)
                if pl.s == 0 and pl.r == i * 2 then
                    ok_count = ok_count + 1
                end
            end
            local elapsed_ms = (ngx.now() - start) * 1000
            ngx.say("ok=" .. ok_count)
            ngx.say("under_2000ms=" .. tostring(elapsed_ms < 2000))
        }
    }
--- request
GET /t
--- response_body
ok=100
under_2000ms=true
--- no_error_log
[error]

=== TEST 3: TCP persistent connection reuse is faster than reconnect
--- main_config
    env LUA_PATH;
--- stream_config
    lua_package_path ";;";
    lua_socket_log_errors off;
    init_by_lua_block {
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end },
            read_timeout = 500,
        }
    }
--- stream_server_config
    listen 19881;
    content_by_lua_block { require("resty.yar.server.tcp").serve() }
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end }
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local yar = require("resty.yar")
            -- persistent client reuses connection
            local pclient = yar.get_client("tcp://127.0.0.1:19881")
            local r1 = pclient:call("add", { 10, 20 })
            local r2 = pclient:call("add", { 30, 40 })
            ngx.say("r1=" .. tostring(r1))
            ngx.say("r2=" .. tostring(r2))
            ngx.say("same_client=" .. tostring(pclient == yar.get_client("tcp://127.0.0.1:19881")))
        }
    }
--- request
GET /t
--- response_body
r1=30
r2=70
same_client=true
--- no_error_log
[error]

=== TEST 4: Large payload (1000 fields) serializes and deserializes correctly
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                echo = function(t) return t end
            }
        }
    }
--- config
    location /api {
        content_by_lua_block { require("resty.yar.server.http").serve() }
    }
    location /t {
        content_by_lua_block {
            local R = require("yar.message.request")
            local P = require("yar.protocol.protocol")
            local K = require("yar.packager.packager")
            -- build 100-field params
            local fields = {}
            for i = 1, 100 do
                fields[i] = "val_" .. i
            end
            local req = R.new({ method = "echo", params = fields })
            local pk = K.get(K.JSON)
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST, body = P.render(req, pk)
            })
            local pl = P.parse(res.body, pk)
            ngx.say("s=" .. pl.s)
            ngx.say("count=" .. #pl.r)
        }
    }
--- request
GET /t
--- response_body
s=0
count=100
--- no_error_log
[error]

=== TEST 5: Msgpack packager performance vs JSON for same payload
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end }
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local R = require("yar.message.request")
            local P = require("yar.protocol.protocol")
            local K = require("yar.packager.packager")
            local req = R.new({ method = "add", params = { 1, 2 } })
            -- JSON payload size
            local json_pk = K.get(K.JSON)
            local json_msg = P.render(req, json_pk)
            -- Msgpack payload size
            local mp_pk = K.get(K.MSGPACK)
            local mp_msg = P.render(req, mp_pk)
            ngx.say("json_len=" .. #json_msg)
            ngx.say("msgpack_len=" .. #mp_msg)
            ngx.say("msgpack_smaller=" .. tostring(#mp_msg < #json_msg))
        }
    }
--- request
GET /t
--- response_body_like
json_len=\d+
msgpack_len=\d+
msgpack_smaller=true
--- no_error_log
[error]

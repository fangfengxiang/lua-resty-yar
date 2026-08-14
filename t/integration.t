use Test::Nginx::Socket::Lua::Stream;

# Integration tests — multiple components working together.
# HTTP client+server, TCP client+server, hooks, packager switching.

repeat_each(2);
plan tests => repeat_each() * 6;

run_tests();

__DATA__

=== TEST 1: HTTP client calls HTTP server (full round trip)
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
                greet = function(n) return "hello, " .. n end,
            }
        }
    }
--- config
    location /api {
        content_by_lua_block { require("resty.yar.server.http").serve() }
    }
    location /t {
        content_by_lua_block {
            local yar = require("resty.yar")
            local c = yar.new_client("http://127.0.0.1:1984/api")
            local r1, e1 = c:call("add", { 10, 20 })
            local r2, e2 = c:call("greet", { "yar" })
            ngx.say("r1=" .. tostring(r1))
            ngx.say("e1=" .. tostring(e1))
            ngx.say("r2=" .. tostring(r2))
            ngx.say("e2=" .. tostring(e2))
        }
    }
--- request
GET /t
--- response_body
r1=30
e1=nil
r2=hello, yar
e2=nil
--- no_error_log
[error]

=== TEST 2: TCP client calls TCP server (full round trip)
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
    listen 19891;
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
            local c = yar.new_client("tcp://127.0.0.1:19891")
            local r, e = c:call("add", { 5, 7 })
            ngx.say("r=" .. tostring(r))
            ngx.say("e=" .. tostring(e))
        }
    }
--- request
GET /t
--- response_body
r=12
e=nil
--- no_error_log
[error]

=== TEST 3: Hooks fire on both request and response phases
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local yar = require("resty.yar")
        yar._hooks = {}
        yar.setup {
            service = { add = function(a, b) return a + b end },
            hooks = {
                on_request = function(method, params)
                    yar._hooks.req = method
                    yar._hooks.pcount = #params
                end,
                on_response = function(method, retval, err)
                    yar._hooks.resp = method
                    yar._hooks.retval = retval
                end,
            },
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
            ngx.location.capture("/api", {
                method = ngx.HTTP_POST, body = P.render(req, pk)
            })
            local h = require("resty.yar")._hooks
            ngx.say("req=" .. tostring(h.req))
            ngx.say("pcount=" .. tostring(h.pcount))
            ngx.say("resp=" .. tostring(h.resp))
            ngx.say("retval=" .. tostring(h.retval))
        }
    }
--- request
GET /t
--- response_body
req=add
pcount=2
resp=add
retval=3
--- no_error_log
[error]

=== TEST 4: Msgpack packager integration (client and server agree)
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end },
            packager = "Msgpack",
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
            local req = R.new({ method = "add", params = { 7, 8 } })
            local pk = K.get(K.MSGPACK)
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST, body = P.render(req, pk)
            })
            local pl = P.parse(res.body, pk)
            ngx.say("s=" .. pl.s)
            ngx.say("r=" .. tostring(pl.r))
        }
    }
--- request
GET /t
--- response_body
s=0
r=15
--- no_error_log
[error]

=== TEST 5: Composed hooks (trace + logger + metrics) all fire
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    lua_shared_dict yar_metrics 1m;
    init_by_lua_block {
        local yar = require("resty.yar")
        local obs = require("resty.yar.observability")
        yar._logs = {}
        yar._metrics = obs.metrics_recorder({ dict_name = "yar_metrics" })
        yar.setup {
            service = { add = function(a, b) return a + b end },
            hooks = obs.compose(
                obs.trace_middleware(),
                obs.access_logger({
                    writer = function(lvl, msg) table.insert(yar._logs, msg) end,
                }),
                yar._metrics
            ),
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
            ngx.location.capture("/api", {
                method = ngx.HTTP_POST, body = P.render(req, pk)
            })
            local yar = require("resty.yar")
            local log = yar._logs[1]
            local export = yar._metrics.export()
            ngx.say("has_log=" .. tostring(log ~= nil))
            ngx.say("has_rid=" .. tostring(string.find(log, '"request_id"') ~= nil))
            ngx.say("has_metrics=" .. tostring(string.find(export, "yar_rpc_calls_total") ~= nil))
        }
    }
--- request
GET /t
--- response_body
has_log=true
has_rid=true
has_metrics=true
--- no_error_log
[error]

=== TEST 6: TCP keepalive — multiple methods on same connection
--- main_config
    env LUA_PATH;
--- stream_config
    lua_package_path ";;";
    lua_socket_log_errors off;
    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
                greet = function(n) return "hi, " .. n end,
            },
            read_timeout = 500,
        }
    }
--- stream_server_config
    listen 19892;
    content_by_lua_block { require("resty.yar.server.tcp").serve() }
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
                greet = function(n) return "hi, " .. n end,
            }
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local yar = require("resty.yar")
            local c = yar.get_client("tcp://127.0.0.1:19892")
            local r1 = c:call("add", { 1, 2 })
            local r2 = c:call("greet", { "yar" })
            ngx.say("r1=" .. tostring(r1))
            ngx.say("r2=" .. tostring(r2))
        }
    }
--- request
GET /t
--- response_body
r1=3
r2=hi, yar
--- no_error_log
[error]

use Test::Nginx::Socket::Lua;

# BDD-style behavior tests — Given/When/Then scenarios
# Focus on observable behavior from the user's perspective.

repeat_each(2);
plan tests => repeat_each() * 7;

run_tests();

__DATA__

=== TEST 1: Given add service, When called with {1,2}, Then returns 3
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
r=3
--- no_error_log
[error]

=== TEST 2: Given greet service, When called with {"world"}, Then returns greeting
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = { greet = function(n) return "hello, " .. n end }
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
            local req = R.new({ method = "greet", params = { "world" } })
            local pk = K.get(K.JSON)
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
r=hello, world
--- no_error_log
[error]

=== TEST 3: Given unknown method, When called, Then returns YAR error (s=1)
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
            local req = R.new({ method = "unknown", params = {} })
            local pk = K.get(K.JSON)
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST, body = P.render(req, pk)
            })
            local pl = P.parse(res.body, pk)
            ngx.say("s=" .. pl.s)
            ngx.say("has_e=" .. tostring(pl.e ~= nil))
        }
    }
--- request
GET /t
--- response_body
s=1
has_e=true
--- no_error_log
[error]

=== TEST 4: Given method that throws, When called, Then YAR error not HTTP 500
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = { boom = function() error("crash") end }
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
            local req = R.new({ method = "boom", params = {} })
            local pk = K.get(K.JSON)
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST, body = P.render(req, pk)
            })
            local pl = P.parse(res.body, pk)
            ngx.say("http=" .. res.status)
            ngx.say("yar=" .. pl.s)
        }
    }
--- request
GET /t
--- response_body
http=200
yar=1
--- no_error_log
[error]

=== TEST 5: Given observability hooks, When RPC completes, Then JSON log emitted
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local yar = require("resty.yar")
        local obs = require("resty.yar.observability")
        yar._logs = {}
        yar.setup {
            service = { add = function(a, b) return a + b end },
            hooks = obs.access_logger({
                writer = function(lvl, msg) table.insert(yar._logs, msg) end,
            }),
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
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST, body = P.render(req, pk)
            })
            local log = require("resty.yar")._logs[1]
            ngx.say("has_log=" .. tostring(log ~= nil))
            ngx.say("ok=" .. tostring(string.find(log, '"status":"ok"') ~= nil))
        }
    }
--- request
GET /t
--- response_body
has_log=true
ok=true
--- no_error_log
[error]

=== TEST 6: Given trace middleware, When request arrives, Then request_id injected
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local yar = require("resty.yar")
        local obs = require("resty.yar.observability")
        yar.setup {
            service = { add = function(a, b) return a + b end },
            hooks = obs.trace_middleware(),
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
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST, body = P.render(req, pk)
            })
            local obs = require("resty.yar.observability")
            local rid = obs.get_request_id()
            ngx.say("has_rid=" .. tostring(rid ~= nil and #rid > 0))
        }
    }
--- request
GET /t
--- response_body
has_rid=true
--- no_error_log
[error]

=== TEST 7: Given GET request, When introspection, Then returns method list
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
                sub = function(a, b) return a - b end,
            }
        }
    }
--- config
    location /api {
        content_by_lua_block { require("resty.yar.server.http").serve() }
    }
--- request
GET /api
--- response_headers
Content-Type: application/json
--- response_body_like
add|sub
--- no_error_log
[error]

use Test::Nginx::Socket::Lua;

# Chaos tests — fault injection, edge cases, error conditions.
# Tests malformed data, oversized payloads, wrong HTTP methods,
# connection issues, and boundary conditions.

repeat_each(2);
plan tests => repeat_each() * 23;

run_tests();

__DATA__

=== TEST 1: Empty POST body returns 400
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block { require("resty.yar").setup() }
--- config
    location /api {
        content_by_lua_block { require("resty.yar.server.http").serve() }
    }
--- request
POST /api
--- error_code: 400
--- response_body eval
"empty body"
--- no_error_log
[error]

=== TEST 2: PUT method returns 405
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block { require("resty.yar").setup() }
--- config
    location /api {
        content_by_lua_block { require("resty.yar.server.http").serve() }
    }
--- request
PUT /api
--- error_code: 405
--- response_body eval
"method not allowed"
--- no_error_log
[error]

=== TEST 3: Oversized body returns 413
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end },
            max_body_len = 100,
        }
    }
--- config
    location /api {
        content_by_lua_block { require("resty.yar.server.http").serve() }
    }
    location /t {
        content_by_lua_block {
            local big = string.rep("x", 200)
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST, body = big
            })
            ngx.say("status=" .. res.status)
        }
    }
--- request
GET /t
--- response_body
status=413
--- no_error_log
[error]

=== TEST 4: Malformed YAR body returns YAR error (s=1), HTTP 200
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
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST, body = "this is not yar data"
            })
            ngx.say("status=" .. res.status)
        }
    }
--- request
GET /t
--- response_body
status=200
--- no_error_log
[error]

=== TEST 5: Body at exact threshold boundary is accepted (not 413)
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end },
            max_body_len = 100,
        }
    }
--- config
    location /api {
        content_by_lua_block { require("resty.yar.server.http").serve() }
    }
    location /t {
        content_by_lua_block {
            local body = string.rep("x", 100)
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST, body = body
            })
            ngx.say("status=" .. res.status)
        }
    }
--- request
GET /t
--- response_body
status=200
--- no_error_log
[error]

=== TEST 6: DELETE method returns 405
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block { require("resty.yar").setup() }
--- config
    location /api {
        content_by_lua_block { require("resty.yar.server.http").serve() }
    }
--- request
DELETE /api
--- error_code: 405
--- no_error_log
[error]

=== TEST 7: Method that returns nil produces YAR response with r=null
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = { noop = function() return nil end }
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
            local req = R.new({ method = "noop", params = {} })
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
r=nil
--- no_error_log
[error]

=== TEST 8: Hook that throws does not crash the server
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local yar = require("resty.yar")
        local obs = require("resty.yar.observability")
        yar.setup {
            service = { add = function(a, b) return a + b end },
            hooks = obs.compose({
                on_request = function(method, params)
                    error("chaos: hook failure")
                end,
                on_response = function() end,
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
--- error_log eval
qr/chaos: hook failure/

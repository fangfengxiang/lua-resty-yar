use Test::Nginx::Socket::Lua::Stream;

# End-to-end tests — full RPC call flow from client to server and back.
# Tests real network connections, multiple methods, error propagation,
# large payloads, and concurrent requests.

repeat_each(2);
plan tests => repeat_each() * 18;

run_tests();

__DATA__

=== TEST 1: E2E HTTP — client to server full RPC round trip
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
                sub = function(a, b) return a - b end,
                mul = function(a, b) return a * b end,
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
            local r1 = c:call("add", { 100, 200 })
            local r2 = c:call("sub", { 300, 100 })
            local r3 = c:call("mul", { 7, 8 })
            ngx.say("add=" .. tostring(r1))
            ngx.say("sub=" .. tostring(r2))
            ngx.say("mul=" .. tostring(r3))
        }
    }
--- request
GET /t
--- response_body
add=300
sub=200
mul=56
--- no_error_log
[error]

=== TEST 2: E2E TCP — client to server full RPC round trip
--- main_config
    env LUA_PATH;
--- stream_config
    lua_package_path ";;";
    lua_socket_log_errors off;
    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
                greet = function(n) return "hello, " .. n end,
            },
            read_timeout = 500,
        }
    }
--- stream_server_config
    listen 19901;
    content_by_lua_block { require("resty.yar.server.tcp").serve() }
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
    location /yartest {
        content_by_lua_block {
            local yar = require("resty.yar")
            local c = yar.new_client("tcp://127.0.0.1:19901")
            local r1 = c:call("add", { 42, 58 })
            local r2 = c:call("greet", { "e2e" })
            ngx.say("add=" .. tostring(r1))
            ngx.say("greet=" .. tostring(r2))
        }
    }
--- request
GET /yartest
--- response_body
add=100
greet=hello, e2e
--- no_error_log
[error]

=== TEST 3: E2E — error propagation from server method to client
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                boom = function() error("server-side failure") end,
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
            local r, e = c:call("boom", {})
            ngx.say("r=" .. tostring(r))
            ngx.say("has_err=" .. tostring(e ~= nil))
        }
    }
--- request
GET /t
--- response_body
r=nil
has_err=true
--- no_error_log
[error]

=== TEST 4: E2E — method not found returns structured error to client
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
            local yar = require("resty.yar")
            local c = yar.new_client("http://127.0.0.1:1984/api")
            local r, e = c:call("nonexistent", {})
            ngx.say("r=" .. tostring(r))
            ngx.say("has_err=" .. tostring(e ~= nil))
        }
    }
--- request
GET /t
--- response_body
r=nil
has_err=true
--- no_error_log
[error]

=== TEST 5: E2E — large array payload round trips correctly
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                sum_all = function(arr)
                    local s = 0
                    for _, v in ipairs(arr) do s = s + v end
                    return s
                end
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
            local nums = {}
            for i = 1, 500 do nums[i] = i end
            local r = c:call("sum_all", { nums })
            ngx.say("sum=" .. tostring(r))
        }
    }
--- request
GET /t
--- response_body
sum=125250
--- no_error_log
[error]

=== TEST 6: E2E — concurrent requests via ngx.location.capture multi
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
            local reqs = {}
            for i = 1, 5 do
                local req = R.new({ method = "add", params = { i, i * 10 } })
                reqs[i] = { "/api", { method = ngx.HTTP_POST,
                    body = P.render(req, pk) } }
            end
            local results = { ngx.location.capture_multi(reqs) }
            local all_ok = true
            for i = 1, 5 do
                local pl = P.parse(results[i].body, pk)
                if pl.s ~= 0 or pl.r ~= i + i * 10 then
                    all_ok = false
                end
            end
            ngx.say("all_ok=" .. tostring(all_ok))
        }
    }
--- request
GET /t
--- response_body
all_ok=true
--- no_error_log
[error]

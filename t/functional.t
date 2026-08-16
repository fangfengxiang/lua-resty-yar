use Test::Nginx::Socket::Lua;

# Functional tests — unit-level testing of individual module functions.
# Tests observability helpers, client creation, config merging, Error objects.

repeat_each(2);
plan tests => repeat_each() * 21;

run_tests();

__DATA__

=== TEST 1: observability.get_request_id returns non-empty hex string
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block { require("resty.yar").setup() }
--- config
    location /t {
        content_by_lua_block {
            local obs = require("resty.yar.observability")
            local id = obs.get_request_id()
            ngx.say("len=" .. #id)
            ngx.say("is_hex=" .. tostring(string.match(id, "^[0-9a-f]+$") ~= nil))
        }
    }
--- request
GET /t
--- response_body
len=8
is_hex=true
--- no_error_log
[error]

=== TEST 2: observability.compose isolates hook failures via pcall
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
            hooks = obs.compose(
                {
                    on_request = function(method, params)
                        error("boom in hook 1")
                    end,
                    on_response = function() end,
                },
                obs.access_logger({
                    writer = function(lvl, msg) table.insert(yar._logs, msg) end,
                })
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
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST, body = P.render(req, pk)
            })
            local yar = require("resty.yar")
            -- hook 1 failed but hook 2 (access_logger) still ran
            ngx.say("log_count=" .. #yar._logs)
            ngx.say("has_log=" .. tostring(yar._logs[1] ~= nil))
        }
    }
--- request
GET /t
--- response_body
log_count=1
has_log=true
--- error_log eval
qr/boom in hook 1/

=== TEST 3: observability.metrics_recorder gracefully degrades without shared dict
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local yar = require("resty.yar")
        local obs = require("resty.yar.observability")
        yar._metrics = obs.metrics_recorder({ dict_name = "nonexistent_dict" })
        yar.setup {
            service = { add = function(a, b) return a + b end },
            hooks = yar._metrics,
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
            local yar = require("resty.yar")
            local export = yar._metrics.export()
            ngx.say("empty_export=" .. tostring(export == ""))
        }
    }
--- request
GET /t
--- response_body
empty_export=true
--- no_error_log
[error]

=== TEST 4: Error.new creates structured error with code and message
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block { require("resty.yar").setup() }
--- config
    location /t {
        content_by_lua_block {
            local yar = require("resty.yar")
            local e = yar.Error.new(yar.Error.TIMEOUT, "request timed out")
            ngx.say("code=" .. tostring(e.code))
            ngx.say("msg=" .. e.message)
        }
    }
--- request
GET /t
--- response_body
code=TIMEOUT
msg=request timed out
--- no_error_log
[error]

=== TEST 5: new_client per-instance opts do not leak into global config
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
            local yar = require("resty.yar")
            local c1 = yar.new_client("http://127.0.0.1:1984/api", { timeout = 999 })
            local c2 = yar.new_client("http://127.0.0.1:1984/api", { timeout = 111 })
            local cfg = yar.get_config()
            ngx.say("c1_timeout=" .. c1.options.transport.timeout)
            ngx.say("c2_timeout=" .. c2.options.transport.timeout)
            ngx.say("global=" .. cfg.client_timeout)
        }
    }
--- request
GET /t
--- response_body
c1_timeout=999
c2_timeout=111
global=3000
--- no_error_log
[error]

=== TEST 6: PACKAGER constants are correct string values
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block { require("resty.yar").setup() }
--- config
    location /t {
        content_by_lua_block {
            local yar = require("resty.yar")
            ngx.say("json=" .. yar.PACKAGER_JSON)
            ngx.say("msgpack=" .. yar.PACKAGER_MSGPACK)
        }
    }
--- request
GET /t
--- response_body
json=JSON
msgpack=MSGPACK
--- no_error_log
[error]

=== TEST 7: Error codes cover all 5 categories
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block { require("resty.yar").setup() }
--- config
    location /t {
        content_by_lua_block {
            local yar = require("resty.yar")
            local E = yar.Error
            ngx.say("transport=" .. tostring(E.TRANSPORT))
            ngx.say("timeout=" .. tostring(E.TIMEOUT))
            ngx.say("protocol=" .. tostring(E.PROTOCOL))
            ngx.say("not_found=" .. tostring(E.NOT_FOUND))
            ngx.say("exception=" .. tostring(E.EXCEPTION))
        }
    }
--- request
GET /t
--- response_body
transport=TRANSPORT
timeout=TIMEOUT
protocol=PROTOCOL
not_found=NOT_FOUND
exception=EXCEPTION
--- no_error_log
[error]

use Test::Nginx::Socket::Lua;

repeat_each(2);
plan tests => repeat_each() * 18;

run_tests();

__DATA__

=== TEST 1: access_logger emits JSON log on RPC call
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    lua_shared_dict yar_metrics 1m;
    init_by_lua_block {
        local yar = require("resty.yar")
        local obs = require("resty.yar.observability")
        yar._test_logs = {}
        yar.setup {
            service = { add = function(a, b) return a + b end },
            hooks = obs.access_logger({
                writer = function(level, msg)
                    table.insert(yar._test_logs, msg)
                end,
            }),
        }
    }
--- config
    location /api {
        content_by_lua_block {
            require("resty.yar.server.http").serve()
        }
    }
    location /t {
        content_by_lua_block {
            local Request  = require("yar.message.request")
            local Protocol = require("yar.protocol.protocol")
            local Packager = require("yar.packager.packager")
            local req = Request.new({ method = "add", params = { 1, 2 } })
            local pk = Packager.get(Packager.JSON)
            local msg = Protocol.render(req, pk)
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST,
                body = msg,
            })
            local yar = require("resty.yar")
            local log = yar._test_logs[1]
            ngx.say("has_log=" .. tostring(log ~= nil))
            ngx.say("has_method=" .. tostring(string.find(log, '"method":"add"') ~= nil))
            ngx.say("has_status=" .. tostring(string.find(log, '"status":"ok"') ~= nil))
            ngx.say("has_duration=" .. tostring(string.find(log, '"duration_ms"') ~= nil))
            ngx.say("has_request_id=" .. tostring(string.find(log, '"request_id"') ~= nil))
        }
    }
--- request
GET /t
--- response_body
has_log=true
has_method=true
has_status=true
has_duration=true
has_request_id=true
--- no_error_log
[error]

=== TEST 2: trace_middleware injects request_id into ngx.ctx
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
        content_by_lua_block {
            require("resty.yar.server.http").serve()
        }
    }
    location /t {
        content_by_lua_block {
            local Request  = require("yar.message.request")
            local Protocol = require("yar.protocol.protocol")
            local Packager = require("yar.packager.packager")
            local req = Request.new({ method = "add", params = { 1, 2 } })
            local pk = Packager.get(Packager.JSON)
            local msg = Protocol.render(req, pk)
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST,
                body = msg,
            })
            local obs = require("resty.yar.observability")
            local rid = obs.get_request_id()
            ngx.say("has_request_id=" .. tostring(rid ~= nil and #rid > 0))
        }
    }
--- request
GET /t
--- response_body
has_request_id=true
--- no_error_log
[error]

=== TEST 3: metrics_recorder counts RPC calls
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    lua_shared_dict yar_metrics 1m;
    init_by_lua_block {
        local yar = require("resty.yar")
        local obs = require("resty.yar.observability")
        yar._test_metrics = obs.metrics_recorder({ dict_name = "yar_metrics" })
        yar.setup {
            service = { add = function(a, b) return a + b end },
            hooks = yar._test_metrics,
        }
    }
--- config
    location /api {
        content_by_lua_block {
            require("resty.yar.server.http").serve()
        }
    }
    location /t {
        content_by_lua_block {
            local Request  = require("yar.message.request")
            local Protocol = require("yar.protocol.protocol")
            local Packager = require("yar.packager.packager")
            local req = Request.new({ method = "add", params = { 1, 2 } })
            local pk = Packager.get(Packager.JSON)
            local msg = Protocol.render(req, pk)
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST,
                body = msg,
            })
            local yar = require("resty.yar")
            local export = yar._test_metrics.export()
            ngx.say("has_total=" .. tostring(string.find(export, "yar_rpc_calls_total") ~= nil))
            ngx.say("has_ok=" .. tostring(string.find(export, 'status="ok"') ~= nil))
            ngx.say("has_bucket=" .. tostring(string.find(export, "yar_rpc_duration_bucket") ~= nil))
        }
    }
--- request
GET /t
--- response_body
has_total=true
has_ok=true
has_bucket=true
--- no_error_log
[error]

=== TEST 4: compose combines multiple hooks
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    lua_shared_dict yar_metrics 1m;
    init_by_lua_block {
        local yar = require("resty.yar")
        local obs = require("resty.yar.observability")
        yar._test_logs = {}
        yar._test_metrics = obs.metrics_recorder({ dict_name = "yar_metrics" })
        yar.setup {
            service = { add = function(a, b) return a + b end },
            hooks = obs.compose(
                obs.trace_middleware(),
                obs.access_logger({
                    writer = function(level, msg)
                        table.insert(yar._test_logs, msg)
                    end,
                }),
                yar._test_metrics
            ),
        }
    }
--- config
    location /api {
        content_by_lua_block {
            require("resty.yar.server.http").serve()
        }
    }
    location /t {
        content_by_lua_block {
            local Request  = require("yar.message.request")
            local Protocol = require("yar.protocol.protocol")
            local Packager = require("yar.packager.packager")
            local req = Request.new({ method = "add", params = { 1, 2 } })
            local pk = Packager.get(Packager.JSON)
            local msg = Protocol.render(req, pk)
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST,
                body = msg,
            })
            local yar = require("resty.yar")
            local log = yar._test_logs[1]
            local export = yar._test_metrics.export()
            ngx.say("has_log=" .. tostring(log ~= nil))
            ngx.say("has_metrics=" .. tostring(string.find(export, "yar_rpc_calls_total") ~= nil))
            ngx.say("log_has_request_id=" .. tostring(string.find(log, '"request_id"') ~= nil))
        }
    }
--- request
GET /t
--- response_body
has_log=true
has_metrics=true
log_has_request_id=true
--- no_error_log
[error]

=== TEST 5: flush_logs outputs deferred entry from ngx.ctx
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local yar = require("resty.yar")
        local obs = require("resty.yar.observability")
        yar._test_logs = {}
        yar.setup {
            service = { add = function(a, b) return a + b end },
            hooks = obs.access_logger({
                defer = true,
                writer = function(level, msg)
                    table.insert(yar._test_logs, msg)
                end,
            }),
        }
    }
--- config
    location /api {
        content_by_lua_block {
            require("resty.yar.server.http").serve()
            -- 模拟 log phase：serve 完成后 on_response 已将 entry 存到 ngx.ctx，
            -- 此处调用 flush_logs 从 ngx.ctx 读取并输出
            local obs = require("resty.yar.observability")
            obs.flush_logs({
                writer = function(level, msg)
                    local yar = require("resty.yar")
                    table.insert(yar._test_logs, msg)
                end,
            })
        }
    }
    location /t {
        content_by_lua_block {
            local Request  = require("yar.message.request")
            local Protocol = require("yar.protocol.protocol")
            local Packager = require("yar.packager.packager")
            local req = Request.new({ method = "add", params = { 1, 2 } })
            local pk = Packager.get(Packager.JSON)
            local msg = Protocol.render(req, pk)
            ngx.location.capture("/api", { method = ngx.HTTP_POST, body = msg })

            local yar = require("resty.yar")
            local log = yar._test_logs[1]
            ngx.say("has_log=" .. tostring(log ~= nil))
            ngx.say("has_method=" .. tostring(log and string.find(log, '"method":"add"') ~= nil))
            ngx.say("has_status=" .. tostring(log and string.find(log, '"status":"ok"') ~= nil))
            ngx.say("has_duration=" .. tostring(log and string.find(log, '"duration_ms"') ~= nil))
            ngx.say("has_request_id=" .. tostring(log and string.find(log, '"request_id"') ~= nil))
        }
    }
--- request
GET /t
--- response_body
has_log=true
has_method=true
has_status=true
has_duration=true
has_request_id=true
--- no_error_log
[error]

=== TEST 6: defer mode does not output in on_response (in-request)
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local yar = require("resty.yar")
        local obs = require("resty.yar.observability")
        yar._test_logs = {}
        yar.setup {
            service = { add = function(a, b) return a + b end },
            hooks = obs.access_logger({
                defer = true,
                writer = function(level, msg)
                    table.insert(yar._test_logs, msg)
                end,
            }),
        }
    }
--- config
    location /api {
        content_by_lua_block {
            require("resty.yar.server.http").serve()
        }
    }
    location /t {
        content_by_lua_block {
            local Request  = require("yar.message.request")
            local Protocol = require("yar.protocol.protocol")
            local Packager = require("yar.packager.packager")
            local req = Request.new({ method = "add", params = { 1, 2 } })
            local pk = Packager.get(Packager.JSON)
            local msg = Protocol.render(req, pk)
            ngx.location.capture("/api", { method = ngx.HTTP_POST, body = msg })

            local yar = require("resty.yar")
            ngx.say("no_in_request_log=" .. tostring(#yar._test_logs == 0))
        }
    }
--- request
GET /t
--- response_body
no_in_request_log=true
--- no_error_log
[error]

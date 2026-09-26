use Test::Nginx::Socket::Lua;

repeat_each(2);
plan tests => repeat_each() * 40;

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

=== TEST 7: trace_middleware propagates X-Request-Id to outgoing client headers
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    lua_shared_dict yar_metrics 1m;
    init_by_lua_block {
        local yar = require("resty.yar")
        local obs = require("resty.yar.observability")
        yar.setup {
            service = { add = function(a, b) return a + b end },
            hooks = obs.trace_middleware(),
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local obs = require("resty.yar.observability")
            local yar = require("resty.yar")

            -- 直接调用 trace_middleware 的 on_request hook（在当前请求 ctx 中执行）
            local hook = obs.trace_middleware()
            hook.on_request("test_method", { 1, 2 })

            -- 验证 trace headers 已注入 ngx.ctx
            local trace_headers = ngx.ctx.yar_trace_headers
            ngx.say("has_trace_headers=" .. tostring(trace_headers ~= nil))
            ngx.say("has_x_request_id=" .. tostring(trace_headers and trace_headers["X-Request-Id"] ~= nil))
            -- 验证 X-Request-Id 与 request_id 一致
            ngx.say("request_id_matches=" .. tostring(
                trace_headers and trace_headers["X-Request-Id"] == ngx.ctx.request_id
            ))
            -- 验证 new_client trace header 合并不 mutation 调用方的 opts.headers
            local user_headers = { ["X-Custom"] = "my-value" }
            pcall(yar.new_client, "http://127.0.0.1:1/api", { headers = user_headers })
            ngx.say("no_mutation=" .. tostring(user_headers["X-Request-Id"] == nil))
        }
    }
--- request
GET /t
--- response_body
has_trace_headers=true
has_x_request_id=true
request_id_matches=true
no_mutation=true
--- no_error_log
[error]

=== TEST 8: metrics export in Prometheus exposition format
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
            ngx.location.capture("/api", { method = ngx.HTTP_POST, body = msg })

            local yar = require("resty.yar")
            local export = yar._test_metrics.export()
            -- 验证 Prometheus exposition format：含 # HELP / # TYPE 元数据行
            ngx.say("has_help=" .. tostring(string.find(export, "# HELP") ~= nil))
            ngx.say("has_type=" .. tostring(string.find(export, "# TYPE") ~= nil))
            ngx.say("has_counter_type=" .. tostring(string.find(export, "# TYPE yar_rpc_calls_total counter") ~= nil))
            ngx.say("has_histogram_type=" .. tostring(string.find(export, "# TYPE yar_rpc_duration histogram") ~= nil))
            -- 验证 counter 在 histogram 之前（字母序）
            local c_pos = string.find(export, "yar_rpc_calls_total")
            local h_pos = string.find(export, "yar_rpc_duration_bucket")
            ngx.say("counter_before_histogram=" .. tostring(c_pos ~= nil and h_pos ~= nil and c_pos < h_pos))
            -- 验证 HELP/TYPE 每 metric 名只出现一次（Prometheus exposition format 规范）
            local _, help_count = string.gsub(export, "# HELP yar_rpc_duration", "")
            local _, type_count = string.gsub(export, "# TYPE yar_rpc_duration histogram", "")
            ngx.say("help_once=" .. tostring(help_count == 1))
            ngx.say("type_once=" .. tostring(type_count == 1))
        }
    }
--- request
GET /t
--- response_body
has_help=true
has_type=true
has_counter_type=true
has_histogram_type=true
counter_before_histogram=true
help_once=true
type_once=true
--- no_error_log
[error]

=== TEST 9: export only includes known methods, not other dict keys
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
            server = {
                service = { add = function(a, b) return a + b end },
                hooks = yar._test_metrics,
            },
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
            local dict = ngx.shared["yar_metrics"]
            dict:set("other_module_metric", 42)
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
            ngx.say("has_yar_total=" .. tostring(string.find(export, "yar_rpc_calls_total") ~= nil))
            ngx.say("no_other_key=" .. tostring(string.find(export, "other_module_metric") == nil))
        }
    }
--- request
GET /t
--- response_body
has_yar_total=true
no_other_key=true
--- no_error_log
[error]

=== TEST 10: export output includes histogram sum/count/inf
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
            server = {
                service = { add = function(a, b) return a + b end },
                hooks = yar._test_metrics,
            },
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
            ngx.say("has_inf=" .. tostring(string.find(export, "%+Inf") ~= nil))
            ngx.say("has_sum=" .. tostring(string.find(export, "yar_rpc_duration_sum") ~= nil))
            ngx.say("has_count=" .. tostring(string.find(export, "yar_rpc_duration_count") ~= nil))
        }
    }
--- request
GET /t
--- response_body
has_inf=true
has_sum=true
has_count=true
--- no_error_log
[error]

=== TEST 11: named compose error log shows plugin name
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local observability = require("resty.yar.observability")
            local hooks = observability.compose_named({
                { name = "myplugin", priority = 100, hooks = {
                    on_response = function() error("boom") end,
                } },
            })
            hooks.on_response("test", 42, nil)
            ngx.say("done=true")
        }
    }
--- request
GET /t
--- response_body
done=true
--- error_log
myplugin
--- no_error_log
[error]

=== TEST 12: buffer mode adds on_init_worker hook
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    lua_shared_dict yar_metrics 1m;
--- config
    location /t {
        content_by_lua_block {
            local obs = require("resty.yar.observability")
            local m_buffered = obs.metrics_recorder({
                dict_name = "yar_metrics",
                buffer_enabled = true,
                flush_interval = 1,
            })
            local m_direct = obs.metrics_recorder({
                dict_name = "yar_metrics",
            })
            ngx.say("buffered_has_init=" .. tostring(m_buffered.on_init_worker ~= nil))
            ngx.say("direct_has_init=" .. tostring(m_direct.on_init_worker ~= nil))
        }
    }
--- request
GET /t
--- response_body
buffered_has_init=true
direct_has_init=false
--- no_error_log
[error]

=== TEST 13: buffer mode accumulates then flushes to shdict
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    lua_shared_dict yar_metrics 1m;
--- config
    location /t {
        content_by_lua_block {
            local obs = require("resty.yar.observability")
            -- clear shdict to ensure repeat_each determinism
            ngx.shared["yar_metrics"]:flush_all()
            local m = obs.metrics_recorder({
                dict_name = "yar_metrics",
                buffer_enabled = true,
                flush_interval = 1,
            })
            -- record a metric (accumulates to buffer, not shdict)
            m.on_request("add", {})
            m.on_response("add", 42, nil)
            -- before flush: shdict should not have total counter
            local dict = ngx.shared["yar_metrics"]
            local before = dict:get("yar_rpc_calls_total{method=\"add\",status=\"total\"}")
            ngx.say("before_flush=" .. tostring(before))
            -- start flush timer and wait
            m.on_init_worker()
            ngx.sleep(1.2)
            -- after flush: shdict should have total counter
            local after = dict:get("yar_rpc_calls_total{method=\"add\",status=\"total\"}")
            ngx.say("after_flush=" .. tostring(after))
        }
    }
--- request
GET /t
--- response_body
before_flush=nil
after_flush=1
--- no_error_log
[error]

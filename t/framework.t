use Test::Nginx::Socket::Lua;

repeat_each(2);
plan tests => repeat_each() * 36;

run_tests();

__DATA__

=== TEST 1: nested config setup with four domains
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            server = {
                service   = { add = function(a, b) return a + b end },
                packager  = "Msgpack",
            },
            client = { connect_timeout = 2000 },
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local yar = require("resty.yar")
            local cfg = yar.get_config()
            ngx.say("server_packager=" .. cfg.server.packager)
            ngx.say("server_timeout=" .. cfg.server.timeout)
            ngx.say("client_connect_timeout=" .. cfg.client.connect_timeout)
            ngx.say("client_timeout=" .. cfg.client.timeout)
            ngx.say("obs_metrics_dict=" .. cfg.observability.metrics_dict)
            ngx.say("ext_use_cjson=" .. tostring(cfg.extensions.use_cjson))
        }
    }
--- request
GET /t
--- response_body
server_packager=Msgpack
server_timeout=5000
client_connect_timeout=2000
client_timeout=3000
obs_metrics_dict=yar_metrics
ext_use_cjson=false
--- no_error_log
[error]

=== TEST 2: flat format backward compatibility
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service         = { add = function(a, b) return a + b end },
            packager        = "Msgpack",
            connect_timeout = 2000,
            client_timeout  = 5000,
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local yar = require("resty.yar")
            local cfg = yar.get_config()
            ngx.say("server_packager=" .. cfg.server.packager)
            ngx.say("client_connect_timeout=" .. cfg.client.connect_timeout)
            ngx.say("client_timeout=" .. cfg.client.timeout)
        }
    }
--- request
GET /t
--- response_body
server_packager=Msgpack
client_connect_timeout=2000
client_timeout=5000
--- no_error_log
[error]

=== TEST 3: config type validation fail-fast
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local config = require("resty.yar.config")
            local ok, err = pcall(config.merge, { server = { timeout = "abc" } })
            ngx.say("error_thrown=" .. tostring(not ok))
            ngx.say("has_msg=" .. tostring(string.find(tostring(err), "must be a number") ~= nil))
        }
    }
--- request
GET /t
--- response_body
error_thrown=true
has_msg=true
--- no_error_log
[error]

=== TEST 4: mixed format — nested takes priority over flat
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            client_timeout = 2000,
            client = { timeout = 5000 },
            service = { add = function(a, b) return a + b end },
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local yar = require("resty.yar")
            local cfg = yar.get_config()
            ngx.say("client_timeout=" .. cfg.client.timeout)
        }
    }
--- request
GET /t
--- response_body
client_timeout=5000
--- no_error_log
[error]

=== TEST 5: plugin registration with priority sorting
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local registry = require("resty.yar.registry")
            registry:clear()
            local order = {}
            registry.register("zebra", function()
                return { on_request = function() order[#order + 1] = "zebra" end }
            end, { priority = 200 })
            registry.register("alpha", function()
                return { on_request = function() order[#order + 1] = "alpha" end }
            end, { priority = 50 })
            registry.register("mid", function()
                return { on_request = function() order[#order + 1] = "mid" end }
            end, { priority = 100 })
            local hooks = registry.get_hooks()
            hooks.on_request("test", {})
            ngx.say("order=" .. table.concat(order, ","))
        }
    }
--- request
GET /t
--- response_body
order=alpha,mid,zebra
--- no_error_log
[error]

=== TEST 6: same priority sorted by name
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local registry = require("resty.yar.registry")
            registry:clear()
            local order = {}
            registry.register("zebra", function()
                return { on_request = function() order[#order + 1] = "zebra" end }
            end, { priority = 100 })
            registry.register("alpha", function()
                return { on_request = function() order[#order + 1] = "alpha" end }
            end, { priority = 100 })
            local hooks = registry.get_hooks()
            hooks.on_request("test", {})
            ngx.say("order=" .. table.concat(order, ","))
        }
    }
--- request
GET /t
--- response_body
order=alpha,zebra
--- no_error_log
[error]

=== TEST 7: inline hooks direct pass (backward compat)
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local registry = require("resty.yar.registry")
            registry:clear()
            local called = false
            local hooks = registry.get_hooks({
                on_request = function() called = true end,
            })
            hooks.on_request("test", {})
            ngx.say("called=" .. tostring(called))
        }
    }
--- request
GET /t
--- response_body
called=true
--- no_error_log
[error]

=== TEST 8: on_error derived from on_response
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local hooks_mod = require("resty.yar.hooks")
            local err_obj = { code = "TRANSPORT", message = "fail" }
            local error_called = false
            local response_called = false
            local adapted = hooks_mod.adapt({
                on_response = function(_m, _r, _e)
                    response_called = true
                end,
                on_error = function(_m, e)
                    error_called = true
                end,
            })
            adapted.on_response("test", nil, err_obj)
            ngx.say("response=" .. tostring(response_called))
            ngx.say("error=" .. tostring(error_called))
        }
    }
--- request
GET /t
--- response_body
response=true
error=true
--- no_error_log
[error]

=== TEST 9: on_timeout derived from on_error
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local hooks_mod = require("resty.yar.hooks")
            local err_obj = { code = "TIMEOUT", message = "timed out" }
            local timeout_called = false
            local adapted = hooks_mod.adapt({
                on_timeout = function(_m)
                    timeout_called = true
                end,
            })
            adapted.on_response("test", nil, err_obj)
            ngx.say("timeout=" .. tostring(timeout_called))
        }
    }
--- request
GET /t
--- response_body
timeout=true
--- no_error_log
[error]

=== TEST 10: on_error not triggered on success
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local hooks_mod = require("resty.yar.hooks")
            local error_called = false
            local adapted = hooks_mod.adapt({
                on_error = function()
                    error_called = true
                end,
            })
            adapted.on_response("test", 42, nil)
            ngx.say("error=" .. tostring(error_called))
        }
    }
--- request
GET /t
--- response_body
error=false
--- no_error_log
[error]

=== TEST 11: observability.defaults() returns complete hooks
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    lua_shared_dict yar_metrics 1m;
    init_by_lua_block {
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end },
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local obs = require("resty.yar.observability")
            local hooks = obs.defaults()
            ngx.say("has_request=" .. tostring(hooks.on_request ~= nil))
            ngx.say("has_response=" .. tostring(hooks.on_response ~= nil))
        }
    }
--- request
GET /t
--- response_body
has_request=true
has_response=true
--- no_error_log
[error]

=== TEST 12: setup with inline hooks backward compat
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    lua_shared_dict yar_metrics 1m;
    init_by_lua_block {
        local yar = require("resty.yar")
        yar.setup {
            server = {
                service = { add = function(a, b) return a + b end },
                hooks = {
                    on_request = function() end,
                    on_response = function() end,
                },
            },
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local yar = require("resty.yar")
            local server = yar.get_server()
            ngx.say("server_ready=" .. tostring(server ~= nil))
        }
    }
--- request
GET /t
--- response_body
server_ready=true
--- no_error_log
[error]

use Test::Nginx::Socket::Lua;

repeat_each(2);
plan tests => repeat_each() * blocks() * 3;

run_tests();

__DATA__

=== TEST 1: register a plugin and verify it appears in list
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local yar = require("resty.yar")
            local registry = require("resty.yar.registry")

            registry.clear()
            registry.register("trace", function() return {} end, { priority = 50 })

            local list = registry.list()
            ngx.say("count=" .. #list)
            ngx.say("name=" .. list[1].name)
            ngx.say("priority=" .. tostring(list[1].priority))
        }
    }
--- request
GET /t
--- response_body
count=1
name=trace
priority=50
--- no_error_log
[error]

=== TEST 2: register multiple plugins and verify priority ordering
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local registry = require("resty.yar.registry")

            registry.clear()
            -- Register in non-sorted order
            registry.register("metrics", function() return {} end, { priority = 200 })
            registry.register("trace", function() return {} end, { priority = 50 })
            registry.register("access-log", function() return {} end, { priority = 100 })

            local list = registry.list()
            ngx.say("order=" .. list[1].name .. "," .. list[2].name .. "," .. list[3].name)
        }
    }
--- request
GET /t
--- response_body
order=trace,access-log,metrics
--- no_error_log
[error]

=== TEST 3: register duplicate name overwrites previous
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local registry = require("resty.yar.registry")

            registry.clear()
            registry.register("trace", function() return {} end, { priority = 50 })
            registry.register("trace", function() return {} end, { priority = 99 })

            local list = registry.list()
            ngx.say("count=" .. #list)
            ngx.say("priority=" .. tostring(list[1].priority))
        }
    }
--- request
GET /t
--- response_body
count=1
priority=99
--- no_error_log
[error]

=== TEST 4: clear removes all registered plugins
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local registry = require("resty.yar.registry")

            registry.register("a", function() return {} end, { priority = 10 })
            registry.register("b", function() return {} end, { priority = 20 })
            registry.clear()

            local list = registry.list()
            ngx.say("count=" .. #list)
        }
    }
--- request
GET /t
--- response_body
count=0
--- no_error_log
[error]

=== TEST 5: get_hooks composes registered plugins and inline hooks
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    lua_shared_dict test_dict 1m;
--- config
    location /t {
        content_by_lua_block {
            local registry = require("resty.yar.registry")
            local hooks = require("resty.yar.hooks")

            registry.clear()

            -- Register a named plugin
            registry.register("trace", function()
                return {
                    on_request = function(method, params)
                        ngx.shared.test_dict:set("trace_called", "yes")
                    end,
                }
            end, { priority = 50 })

            -- get_hooks composes all registered plugins
            -- Passing inline hooks as the user_hooks argument
            local composed = registry.get_hooks({
                on_request = function(method, params)
                    ngx.shared.test_dict:set("inline_called", "yes")
                end,
            })

            -- Adapt to lua-yar format
            local adapted = hooks.adapt(composed)

            -- Call the composed on_request hook
            adapted.on_request("add", { 1, 2 })

            ngx.say("trace=" .. ngx.shared.test_dict:get("trace_called"))
            ngx.say("inline=" .. ngx.shared.test_dict:get("inline_called"))
        }
    }
--- request
GET /t
--- response_body
trace=yes
inline=yes
--- no_error_log
[error]

=== TEST 6: get_hooks returns nil when no plugins and no inline hooks
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local registry = require("resty.yar.registry")

            registry.clear()
            local composed = registry.get_hooks(nil)
            ngx.say("composed=" .. tostring(composed))
        }
    }
--- request
GET /t
--- response_body
composed=nil
--- no_error_log
[error]

=== TEST 7: priority ties broken by name alphabetical order
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local registry = require("resty.yar.registry")

            registry.clear()
            -- Same priority 50 — order by name
            registry.register("zebra", function() return {} end, { priority = 50 })
            registry.register("alpha", function() return {} end, { priority = 50 })
            registry.register("mango", function() return {} end, { priority = 50 })

            local list = registry.list()
            ngx.say("order=" .. list[1].name .. "," .. list[2].name .. "," .. list[3].name)
        }
    }
--- request
GET /t
--- response_body
order=alpha,mango,zebra
--- no_error_log
[error]

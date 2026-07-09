use Test::Nginx::Socket::Lua;

repeat_each(2);
plan tests => repeat_each() * blocks() * 3;

run_tests();

__DATA__

=== TEST 1: on_response derivation calls on_error when err_obj is not nil
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local hooks = require("resty.yar.hooks")

            local calls = {}
            local adapted = hooks.adapt({
                on_response = function(method, retval, err_obj)
                    table.insert(calls, "on_response:" .. method)
                end,
                on_error = function(method, err_obj)
                    table.insert(calls, "on_error:" .. method)
                end,
            })

            -- Simulate error response
            adapted.on_response("add", nil, { code = "SOME_ERROR", message = "fail" })

            ngx.say(table.concat(calls, ","))
        }
    }
--- request
GET /t
--- response_body
on_response:add,on_error:add
--- no_error_log
[error]

=== TEST 2: on_response derivation calls on_timeout when err_obj.code == TIMEOUT
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local hooks = require("resty.yar.hooks")
            local Yar = require("yar")
            local Error = Yar.error

            local calls = {}
            local adapted = hooks.adapt({
                on_response = function(method, retval, err_obj)
                    table.insert(calls, "on_response:" .. method)
                end,
                on_error = function(method, err_obj)
                    table.insert(calls, "on_error:" .. method)
                end,
                on_timeout = function(method)
                    table.insert(calls, "on_timeout:" .. method)
                end,
            })

            -- Simulate timeout error
            adapted.on_response("add", nil, { code = Error.TIMEOUT, message = "timeout" })

            ngx.say(table.concat(calls, ","))
        }
    }
--- request
GET /t
--- response_body
on_response:add,on_error:add,on_timeout:add
--- no_error_log
[error]

=== TEST 3: on_response with nil err_obj does not derive on_error
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local hooks = require("resty.yar.hooks")

            local error_called = false
            local adapted = hooks.adapt({
                on_response = function(method, retval, err_obj)
                    -- nil err_obj = success
                end,
                on_error = function(method, err_obj)
                    error_called = true
                end,
            })

            -- Simulate success response
            adapted.on_response("add", 3, nil)

            ngx.say("error_called=" .. tostring(error_called))
        }
    }
--- request
GET /t
--- response_body
error_called=false
--- no_error_log
[error]

=== TEST 4: adapt returns nil when input is nil
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local hooks = require("resty.yar.hooks")
            local result = hooks.adapt(nil)
            ngx.say("adapt_nil=" .. tostring(result))
        }
    }
--- request
GET /t
--- response_body
adapt_nil=nil
--- no_error_log
[error]

=== TEST 5: adapted hooks preserve on_request and on_connect passthrough
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local hooks = require("resty.yar.hooks")

            local req_called = false
            local connect_called = false

            local adapted = hooks.adapt({
                on_request = function(method, params)
                    req_called = true
                end,
                on_connect = function()
                    connect_called = true
                end,
                on_response = function() end,
            })

            -- Call passthrough hooks
            adapted.on_request("add", { 1, 2 })
            if adapted.on_connect then
                adapted.on_connect()
            end

            ngx.say("on_request=" .. tostring(req_called))
            ngx.say("on_connect=" .. tostring(connect_called))
        }
    }
--- request
GET /t
--- response_body
on_request=true
on_connect=true
--- no_error_log
[error]

=== TEST 6: composed hooks are pcall-isolated per hook
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local obs = require("resty.yar.observability")

            local second_called = false
            local composed = obs.compose(
                {
                    on_request = function(method, params)
                        error("plugin1 crash")
                    end,
                },
                {
                    on_request = function(method, params)
                        second_called = true
                    end,
                }
            )

            -- First hook crashes, second should still run (pcall isolation)
            composed.on_request("add", { 1, 2 })
            ngx.say("second_called=" .. tostring(second_called))
        }
    }
--- request
GET /t
--- response_body
second_called=true
--- no_error_log
[error]

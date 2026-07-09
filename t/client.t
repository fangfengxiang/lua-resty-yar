use Test::Nginx::Socket::Lua::Stream;

repeat_each(2);
plan tests => repeat_each() * 15;

run_tests();

__DATA__

=== TEST 1: HTTP client RPC call
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
        content_by_lua_block {
            require("resty.yar.server.http").serve()
        }
    }
    location /yartest {
        content_by_lua_block {
            local yar = require("resty.yar")
            local client = yar.new_client("http://127.0.0.1:1984/api")
            local result, err = client:call("add", { 1, 2 })
            ngx.say("result=" .. tostring(result))
            ngx.say("err=" .. tostring(err))
        }
    }
--- request
GET /yartest
--- response_body
result=3
err=nil
--- no_error_log
[error]

=== TEST 2: TCP client RPC call
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
    listen 19861;
    content_by_lua_block {
        require("resty.yar.server.tcp").serve()
    }
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end }
        }
    }
--- config
    location /yartest {
        content_by_lua_block {
            local yar = require("resty.yar")
            local client = yar.new_client("tcp://127.0.0.1:19861")
            local result, err = client:call("add", { 3, 4 })
            ngx.say("result=" .. tostring(result))
            ngx.say("err=" .. tostring(err))
        }
    }
--- request
GET /yartest
--- response_body
result=7
err=nil
--- no_error_log
[error]

=== TEST 3: get_client returns same instance for same URI
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
    location /yartest {
        content_by_lua_block {
            local yar = require("resty.yar")
            local c1 = yar.get_client("http://127.0.0.1:1984/api")
            local c2 = yar.get_client("http://127.0.0.1:1984/api")
            ngx.say("same=" .. tostring(c1 == c2))
        }
    }
--- request
GET /yartest
--- response_body
same=true
--- no_error_log
[error]

=== TEST 4: persistent TCP connection reuse
--- main_config
    env LUA_PATH;
--- stream_config
    lua_package_path ";;";
    lua_socket_log_errors off;
    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
                greet = function(name) return "hello, " .. name end,
            },
            read_timeout = 500,
        }
    }
--- stream_server_config
    listen 19862;
    content_by_lua_block {
        require("resty.yar.server.tcp").serve()
    }
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
                greet = function(name) return "hello, " .. name end,
            }
        }
    }
--- config
    location /yartest {
        content_by_lua_block {
            local yar = require("resty.yar")
            local client = yar.get_client("tcp://127.0.0.1:19862")
            local r1, e1 = client:call("add", { 10, 20 })
            local r2, e2 = client:call("greet", { "yar" })
            ngx.say("r1=" .. tostring(r1))
            ngx.say("e1=" .. tostring(e1))
            ngx.say("r2=" .. tostring(r2))
            ngx.say("e2=" .. tostring(e2))
        }
    }
--- request
GET /yartest
--- response_body
r1=30
e1=nil
r2=hello, yar
e2=nil
--- no_error_log
[error]

=== TEST 5: per-client opts override does not affect global config
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
    location /yartest {
        content_by_lua_block {
            local yar = require("resty.yar")
            local client = yar.new_client("http://127.0.0.1:1984/api", { timeout = 10000 })
            local cfg = yar.get_config()
            ngx.say("client_timeout=" .. tostring(client.options.timeout))
            ngx.say("global_client_timeout=" .. tostring(cfg.client_timeout))
        }
    }
--- request
GET /yartest
--- response_body
client_timeout=10000
global_client_timeout=3000
--- no_error_log
[error]

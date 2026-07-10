use Test::Nginx::Socket::Lua;

repeat_each(2);
plan tests => repeat_each() * 18;

run_tests();

__DATA__

=== TEST 1: POST RPC call (add)
--- main_config
    env LUA_PATH;
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
            ngx.say("status=" .. res.status)
            local payload = Protocol.parse(res.body, pk)
            ngx.say("s=" .. payload.s)
            ngx.say("r=" .. tostring(payload.r))
        }
    }
--- request
GET /t
--- response_body
status=200
s=0
r=3
--- no_error_log
[error]

=== TEST 2: GET introspection returns method list
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
        content_by_lua_block {
            require("resty.yar.server.http").serve()
        }
    }
--- request
GET /api
--- response_headers
Content-Type: application/json
--- response_body_like
add|sub
--- no_error_log
[error]

=== TEST 3: empty body returns 400
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup()
    }
--- config
    location /api {
        content_by_lua_block {
            require("resty.yar.server.http").serve()
        }
    }
--- request
POST /api
--- error_code: 400
--- response_body
empty body
--- no_error_log
[error]

=== TEST 4: PUT returns 405
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup()
    }
--- config
    location /api {
        content_by_lua_block {
            require("resty.yar.server.http").serve()
        }
    }
--- request
PUT /api
--- error_code: 405
--- response_body
method not allowed
--- no_error_log
[error]

=== TEST 5: POST response Content-Type is application/octet-stream
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
    location /t {
        content_by_lua_block {
            local Request  = require("yar.message.request")
            local Protocol = require("yar.protocol.protocol")
            local Packager = require("yar.packager.packager")
            local req = Request.new({ method = "add", params = { 10, 20 } })
            local pk = Packager.get(Packager.JSON)
            local msg = Protocol.render(req, pk)
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST,
                body = msg,
            })
            ngx.say("ct=" .. res.header["Content-Type"])
        }
    }
--- request
GET /t
--- response_body
ct=application/octet-stream
--- no_error_log
[error]

=== TEST 6: RPC method error returns YAR error response
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                boom = function() error("intentional crash") end,
            }
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
            local req = Request.new({ method = "boom", params = {} })
            local pk = Packager.get(Packager.JSON)
            local msg = Protocol.render(req, pk)
            local res = ngx.location.capture("/api", {
                method = ngx.HTTP_POST,
                body = msg,
            })
            ngx.say("status=" .. res.status)
            -- lua-yar 的 handle_message 内部 pcall 用户方法，
            -- 返回 YAR 错误响应 (s=1) 而非抛出异常，HTTP 层为 200。
            local payload = Protocol.parse(res.body, pk)
            ngx.say("s=" .. payload.s)
        }
    }
--- request
GET /t
--- response_body
status=200
s=1
--- no_error_log
[error]


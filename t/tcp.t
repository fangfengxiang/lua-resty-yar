use Test::Nginx::Socket::Lua::Stream;

repeat_each(2);
plan tests => repeat_each() * 6;

run_tests();

__DATA__

=== TEST 1: single message over TCP
--- main_config
    env LUA_PATH;
--- stream_config
    lua_package_path ";;";
    lua_socket_log_errors off;
    init_by_lua_block {
        require("resty.yar").setup {
            service = {
                add = function(a, b) return a + b end,
            },
            read_timeout = 500,
        }
    }
--- stream_server_config
    listen 19851;
    content_by_lua_block {
        require("resty.yar.server.tcp").serve()
    }
--- config
    location /yartest {
        content_by_lua_block {
            local Request  = require("yar.message.request")
            local Protocol = require("yar.protocol.protocol")
            local Packager = require("yar.packager.packager")
            local sock = ngx.socket.tcp()
            sock:connect("127.0.0.1", 19851)
            local req = Request.new({ method = "add", params = { 3, 4 } })
            local pk = Packager.get(Packager.JSON)
            local msg = Protocol.render(req, pk)
            sock:send(msg)
            local Framing = require("yar.protocol.framing")
            local resp = Framing.receive_message(sock)
            local payload = Protocol.parse(resp, pk)
            ngx.say("s=" .. payload.s)
            ngx.say("r=" .. tostring(payload.r))
            sock:close()
        }
    }
--- request
GET /yartest
--- response_body
s=0
r=7
--- no_error_log
[error]

=== TEST 2: multiple messages on keepalive connection
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
    listen 19852;
    content_by_lua_block {
        require("resty.yar.server.tcp").serve()
    }
--- config
    location /yartest {
        content_by_lua_block {
            local Request  = require("yar.message.request")
            local Protocol = require("yar.protocol.protocol")
            local Packager = require("yar.packager.packager")
            local Framing  = require("yar.protocol.framing")
            local sock = ngx.socket.tcp()
            sock:connect("127.0.0.1", 19852)
            local pk = Packager.get(Packager.JSON)
            local req1 = Request.new({ method = "add", params = { 1, 2 } })
            sock:send(Protocol.render(req1, pk))
            local r1 = Protocol.parse(Framing.receive_message(sock), pk)
            local req2 = Request.new({ method = "greet", params = { "yar" } })
            sock:send(Protocol.render(req2, pk))
            local r2 = Protocol.parse(Framing.receive_message(sock), pk)
            ngx.say("r1=" .. tostring(r1.r))
            ngx.say("r2=" .. tostring(r2.r))
            sock:close()
        }
    }
--- request
GET /yartest
--- response_body
r1=3
r2=hello, yar
--- no_error_log
[error]


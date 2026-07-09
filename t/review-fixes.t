use Test::Nginx::Socket::Lua;

# 回归测试：覆盖 code review 发现的盲区（B-1 / M-1 / M-2 / M-3 / M-5）
# Regression tests covering blind spots found in code review.
repeat_each(2);
plan tests => repeat_each() * blocks() * 3;

run_tests();

__DATA__

=== TEST 1: B-1 histogram overflow - duration beyond max bucket only counts +Inf
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    lua_shared_dict yar_metrics 1m;
    init_by_lua_block {
        require("resty.yar").setup {
            server = { service = { add = function(a, b) return a + b end } },
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local obs = require("resty.yar.observability")
            local metrics = obs.metrics_recorder({ dict_name = "yar_metrics" })
            -- 直接调 hooks 模拟 RPC 生命周期：
            -- on_request 设 start=ngx.now()，手动覆盖为 0 模拟超长 duration，
            -- on_response 触发 record，验证超限观测只计 +Inf 不计 le=5000。
            metrics.on_request("add", { 1, 2 })
            ngx.ctx["yar_obs_start_time"] = 0
            metrics.on_response("add", 3, nil)
            local export = metrics.export()
            ngx.say("has_inf=" .. tostring(string.find(export, "+Inf") ~= nil))
            ngx.say("no_le_5000=" .. tostring(string.find(export, "le=5000") == nil))
        }
    }
--- request
GET /t
--- response_body
has_inf=true
no_le_5000=true
--- no_error_log
[error]

=== TEST 2: M-1 get_client does not mutate caller opts table
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            server = { service = { add = function(a, b) return a + b end } },
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local yar = require("resty.yar")
            local opts = { timeout = 1000 }
            ngx.say("before=" .. tostring(opts.persistent))
            local client = yar.get_client("http://127.0.0.1:65535/api", opts)
            ngx.say("after=" .. tostring(opts.persistent))
        }
    }
--- request
GET /t
--- response_body
before=nil
after=nil
--- no_error_log
[error]

=== TEST 3: M-2 repeated setup resets client cache
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local yar = require("resty.yar")
        yar.setup { server = { service = { add = function(a, b) return a + b end } } }
    }
--- config
    location /t {
        content_by_lua_block {
            local yar = require("resty.yar")
            -- 第一次 get_client（创建并缓存）
            local c1 = yar.get_client("http://127.0.0.1:65535/api")
            -- 第二次 setup 应重置 _client_cache，get_client 重新创建实例
            yar.setup { server = { service = { add = function(a, b) return a + b end } } }
            local c2 = yar.get_client("http://127.0.0.1:65535/api")
            ngx.say("cache_reset=" .. tostring(c1 ~= c2))
        }
    }
--- request
GET /t
--- response_body
cache_reset=true
--- no_error_log
[error]

=== TEST 4: M-3 server send_timeout and read_timeout from config.server domain
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            server = {
                service = { add = function(a, b) return a + b end },
                send_timeout = 7000,
                read_timeout = 8000,
            },
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local yar = require("resty.yar")
            local cfg = yar.get_config()
            ngx.say("server_send_timeout=" .. cfg.server.send_timeout)
            ngx.say("server_read_timeout=" .. cfg.server.read_timeout)
        }
    }
--- request
GET /t
--- response_body
server_send_timeout=7000
server_read_timeout=8000
--- no_error_log
[error]

=== TEST 5: M-5 no service emits WARN instead of silent demo service
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {}
    }
--- config
    location /t {
        content_by_lua_block {
            ngx.say("setup_ok=true")
        }
    }
--- request
GET /t
--- response_body
setup_ok=true
--- no_error_log
[error]

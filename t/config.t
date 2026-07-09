use Test::Nginx::Socket::Lua;

repeat_each(2);
plan tests => repeat_each() * blocks() * 3;

run_tests();

__DATA__

=== TEST 1: deep merge preserves defaults for unspecified keys
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            server = {
                service = { add = function(a, b) return a + b end },
                packager = "JSON",
            },
            client = { connect_timeout = 2000 },
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local cfg = require("resty.yar").get_config()
            -- server: specified keys overridden, defaults preserved
            ngx.say("server_packager=" .. cfg.server.packager)
            ngx.say("server_timeout=" .. cfg.server.timeout)
            ngx.say("server_max_body_len=" .. cfg.server.max_body_len)
            -- client: specified key overridden, defaults preserved
            ngx.say("client_connect_timeout=" .. cfg.client.connect_timeout)
            ngx.say("client_timeout=" .. cfg.client.timeout)
            ngx.say("client_pool_size=" .. cfg.client.pool_size)
            -- observability: entirely default
            ngx.say("obs_metrics_dict=" .. cfg.observability.metrics_dict)
            ngx.say("obs_metrics_prefix=" .. cfg.observability.metrics_prefix)
        }
    }
--- request
GET /t
--- response_body
server_packager=JSON
server_timeout=5000
server_max_body_len=10485760
client_connect_timeout=2000
client_timeout=3000
client_pool_size=30
obs_metrics_dict=yar_metrics
obs_metrics_prefix=yar
--- no_error_log
[error]

=== TEST 2: deep merge nested observability config
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            server = { service = { add = function(a, b) return a + b end } },
            observability = {
                metrics_dict = "custom_metrics",
                metrics_buffer = { enabled = true, flush_interval = 5 },
            },
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local cfg = require("resty.yar").get_config()
            ngx.say("metrics_dict=" .. cfg.observability.metrics_dict)
            ngx.say("metrics_prefix=" .. cfg.observability.metrics_prefix)
            ngx.say("buffer_enabled=" .. tostring(cfg.observability.metrics_buffer.enabled))
            ngx.say("buffer_flush=" .. tostring(cfg.observability.metrics_buffer.flush_interval))
            ngx.say("trace_header=" .. cfg.observability.trace.header)
        }
    }
--- request
GET /t
--- response_body
metrics_dict=custom_metrics
metrics_prefix=yar
buffer_enabled=true
buffer_flush=5
trace_header=X-Request-Id
--- no_error_log
[error]

=== TEST 3: flat format routes all keys to correct domain
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end },
            packager = "Msgpack",
            timeout = 8000,
            client_timeout = 4000,
            connect_timeout = 1500,
            pool_size = 50,
            ssl_verify = false,
            use_cjson = true,
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local cfg = require("resty.yar").get_config()
            ngx.say("server_packager=" .. cfg.server.packager)
            ngx.say("server_timeout=" .. cfg.server.timeout)
            ngx.say("client_timeout=" .. cfg.client.timeout)
            ngx.say("client_connect_timeout=" .. cfg.client.connect_timeout)
            ngx.say("client_pool_size=" .. cfg.client.pool_size)
            ngx.say("client_ssl_verify=" .. tostring(cfg.client.ssl_verify))
            ngx.say("ext_use_cjson=" .. tostring(cfg.extensions.use_cjson))
        }
    }
--- request
GET /t
--- response_body
server_packager=Msgpack
server_timeout=8000
client_timeout=4000
client_connect_timeout=1500
client_pool_size=50
client_ssl_verify=false
ext_use_cjson=true
--- no_error_log
[error]

=== TEST 4: mixed flat and nested format
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        require("resty.yar").setup {
            service = { add = function(a, b) return a + b end },
            packager = "JSON",
            client = { timeout = 6000 },
            connect_timeout = 3000,
            use_cmsgpack = true,
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local cfg = require("resty.yar").get_config()
            -- nested client.timeout takes precedence
            ngx.say("client_timeout=" .. cfg.client.timeout)
            -- flat connect_timeout routes to client.connect_timeout
            ngx.say("client_connect_timeout=" .. cfg.client.connect_timeout)
            -- flat use_cmsgpack routes to extensions.use_cmsgpack
            ngx.say("ext_use_cmsgpack=" .. tostring(cfg.extensions.use_cmsgpack))
            -- default preserved
            ngx.say("client_pool_size=" .. cfg.client.pool_size)
        }
    }
--- request
GET /t
--- response_body
client_timeout=6000
client_connect_timeout=3000
ext_use_cmsgpack=true
client_pool_size=30
--- no_error_log
[error]

=== TEST 5: type validation rejects wrong packager type
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local ok, err = pcall(function()
                require("resty.yar").setup {
                    server = {
                        service = { add = function(a, b) return a + b end },
                        packager = 12345,
                    },
                }
            end)
            if ok then
                ngx.say("setup_succeeded")
            else
                ngx.say("setup_failed: " .. tostring(tostring(err):match("must be a string") ~= nil))
            end
        }
    }
--- request
GET /t
--- response_body
setup_failed: true
--- no_error_log
[error]

=== TEST 6: type validation rejects wrong timeout type
--- main_config
    env LUA_PATH;
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local ok, err = pcall(function()
                require("resty.yar").setup {
                    server = {
                        service = { add = function(a, b) return a + b end },
                        timeout = "not_a_number",
                    },
                }
            end)
            if ok then
                ngx.say("setup_succeeded")
            else
                ngx.say("setup_failed: " .. tostring(tostring(err):match("must be a number") ~= nil))
            end
        }
    }
--- request
GET /t
--- response_body
setup_failed: true
--- no_error_log
[error]

=== TEST 7: default config when no user config provided for a domain
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
            local cfg = require("resty.yar").get_config()
            -- All client defaults
            ngx.say("client_timeout=" .. cfg.client.timeout)
            ngx.say("client_connect_timeout=" .. cfg.client.connect_timeout)
            ngx.say("client_keepalive_idle=" .. cfg.client.keepalive_idle)
            ngx.say("client_pool_size=" .. cfg.client.pool_size)
            ngx.say("client_ssl_verify=" .. tostring(cfg.client.ssl_verify))
            -- All extensions defaults
            ngx.say("ext_use_cjson=" .. tostring(cfg.extensions.use_cjson))
            ngx.say("ext_use_cmsgpack=" .. tostring(cfg.extensions.use_cmsgpack))
            ngx.say("ext_use_resty_http=" .. tostring(cfg.extensions.use_resty_http))
            -- Log level default
            ngx.say("log_level=" .. tostring(cfg.log_level))
        }
    }
--- request
GET /t
--- response_body
client_timeout=3000
client_connect_timeout=1000
client_keepalive_idle=60000
client_pool_size=30
client_ssl_verify=true
ext_use_cjson=false
ext_use_cmsgpack=false
ext_use_resty_http=false
log_level=2
--- no_error_log
[error]

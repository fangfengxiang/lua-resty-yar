# Examples

Complete, runnable examples for lua-resty-yar.

## Prerequisites

```bash
# Install OpenResty
# See: https://openresty.org/en/installation.html

# Install lua-yar (protocol library)
git clone https://github.com/fangfengxiang/lua-yar.git

# Install lua-resty-yar (framework)
git clone https://github.com/fangfengxiang/lua-resty-yar.git
```

## Examples

| Example | Description | How to Run |
|---------|-------------|------------|
| [http-server](http-server/) | HTTP server with math service | `nginx -p . -c nginx.conf` then call from PHP/Lua |
| [tcp-server](tcp-server/) | TCP stream server (raw Yar protocol) | `nginx -p . -c nginx.conf` then call with TCP client |
| [client](client/) | RPC client with keepalive and error handling | `nginx -p . -c nginx.conf` |
| [observability](observability/) | Full observability: trace + access-log + metrics | `nginx -p . -c nginx.conf` then `curl /metrics` |
| [plugin](plugin/) | Custom rate-limit plugin | `nginx -p . -c nginx.conf` |

## Running Examples

All examples assume lua-yar and lua-resty-yar are sibling directories:

```
parent-dir/
├── lua-yar/          (protocol library)
│   └── src/
│       └── yar/
├── lua-resty-yar/    (framework)
│   └── lib/
│       └── resty/
│           └── yar/
```

Adjust `lua_package_path` in each `nginx.conf` if your layout differs.

```bash
cd examples/http-server
nginx -p . -c nginx.conf
curl http://127.0.0.1:8080/health   # Health check
# Now call /rpc from PHP or Lua client
```

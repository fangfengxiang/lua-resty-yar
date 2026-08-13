# Contributing to lua-resty-yar

## Development Setup

### Prerequisites

- **OpenResty** >= 1.19.3.1
- **lua-yar** (install via LuaRocks: `luarocks install lua-yar`)
- **Perl** (for test-nginx)
- **luacheck** (for linting: `luarocks install luacheck`)

### Clone & Test

```bash
git clone https://github.com/fangfengxiang/lua-resty-yar.git
cd lua-resty-yar

# Set LUA_PATH to include lua-yar source
export LUA_PATH="/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;"

# Run tests
make test

# Run linter
make lint
```

## Code Style

lua-resty-yar follows Lua industry conventions, aligned with OpenResty official `lua-resty-*` libraries and lua-yar.

### Naming Conventions

| Category | Style | Example | Reference |
|----------|-------|---------|-----------|
| Module table variable | `_M` | `local _M = {}` | lua-resty-http, lua-resty-redis |
| Local variables | lowercase | `sock`, `timeout`, `config` | Lua stdlib |
| Constants | UPPER_SNAKE | `LOG_LEVEL_MAP`, `EXCLUDE_FROM_CONFIG` | lua-resty-http `http_const` |
| Function names | snake_case | `set_options`, `handle_message` | lua-resty-http, dkjson |
| Method call syntax | `:` instance / `.` static | `client:call()` / `_M.new()` | Lua stdlib (`io.open` vs `f:read`) |
| Private names | `_` prefix | `_server`, `_client_cache` | lua-resty-core, dkjson |

### Static Factory Methods

Static factory methods use dot notation `Class.new()`, not colon `:new()`. Colon call would pass the class table as `self`, breaking the factory method signature. All factory methods (`_M.new()`, `Server.new()`) use dot notation, consistent with lua-resty-http `http.new()`, lua-cjson `cjson.new()`.

### Standard Library Localization

All used standard library functions are bound as upvalues at the top of each source file, eliminating global table lookup overhead. This is Roberto Ierusalimschy's #1 performance advice.

```lua
local ngx = ngx
local pcall = pcall
local pairs = pairs

local _M = {}
```

### Indentation & Format

- 4 spaces indentation, no tabs
- Line width limit 120 characters (consistent with `.luacheckrc`)
- String concatenation in loops: use `table.insert` / `#t + 1` + `table.concat`, no `..` in loops

### Error Handling

lua-resty-yar is an adapter layer — it delegates all protocol logic to lua-yar. Error handling follows the lua-yar layered strategy:

- **Internal modules** (init.lua, server/http.lua, server/tcp.lua): `return nil, err_string` (Lua convention)
- **Programming errors** (e.g., `setup()` not called): `error(msg, 2)` (points to caller)
- **Third-party API calls** (cjson, cmsgpack, resty.http): `pcall` wrapped

### Module Structure

```lua
-- lib/resty/yar/module.lua
-- Module summary (one-line responsibility description)
-- Dependencies, design decision notes

local ngx = ngx
local pcall = pcall

local init = require("resty.yar")

local _M = {}

-- Public functions

return _M
```

## Testing

### test-nginx Suite

Tests use [test-nginx](https://github.com/openresty/test-nginx) framework. Test files are in `t/`:

- `t/http.t` — HTTP server handler tests (POST RPC, GET introspection, 400/405/413, hooks)
- `t/tcp.t` — TCP stream server handler tests
- `t/client.t` — Client API tests

```bash
# Run all tests
make test

# Run specific test file
prove -I../test-nginx/lib -r t/http.t
```

### OPM Build Validation

```bash
opm build
```

This validates the `dist.ini` metadata and package structure.

## Commit Convention

- Format: `<type>: <description>`
- Types: `feat` / `fix` / `refactor` / `docs` / `test` / `chore`
- Example: `feat: add use_resty_http provider injection option`

## Release Process

The release process is automated via GitHub Actions (`.github/workflows/release.yml`), tag-driven:

1. Update `CHANGELOG.md` — move `[Unreleased]` items to a new version section
2. Update `dist.ini` version field
3. Commit: `git commit -am "release: v0.2.0"`
4. Tag: `git tag v0.2.0 && git push origin v0.2.0`
5. CI auto-triggers: OPM build validation → GitHub Release creation

**Prerequisites:**
- GitHub repo Settings → Secrets configured (if OPM upload token needed)

**Rollback:**
- Delete tag: `git tag -d v0.2.0 && git push origin :refs/tags/v0.2.0`
- Delete GitHub Release (Web UI or `gh release delete v0.2.0`)

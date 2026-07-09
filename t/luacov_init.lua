-- luacov initialization helper for test-nginx coverage collection.
-- CI injects require("luacov_init") at the start of each test's init_by_lua_block.
-- Local dev: run `make coverage` which handles this automatically.
local ok, runner = pcall(require, "luacov.runner")
if ok then
    runner.init()
end

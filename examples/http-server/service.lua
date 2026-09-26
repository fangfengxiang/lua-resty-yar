-- Example service: a simple math and string service.
-- Loaded by init_by_lua_block in nginx.conf.

local M = {}

function M.add(a, b)
    return a + b
end

function M.subtract(a, b)
    return a - b
end

function M.multiply(a, b)
    return a * b
end

function M.divide(a, b)
    if b == 0 then
        error("division by zero")
    end
    return a / b
end

function M.echo(msg)
    return msg
end

function M.greet(name)
    return "Hello, " .. name .. "!"
end

return M

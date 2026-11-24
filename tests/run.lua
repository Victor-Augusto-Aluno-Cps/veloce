package.path = "./?.lua;./?/init.lua;" .. package.path

local json = require("veloce.utils.json")
local path = require("veloce.utils.path")
local status = require("veloce.utils.status")
local middleware = require("veloce.core.functions")
local App = require("veloce")

local function assertFails(callback, message)
    local ok = pcall(callback)
    assert(not ok, message or "expected the operation to fail")
end

local function newResponse()
    local response = { statuscode = 200, finished = false }

    function response.status(code)
        response.statuscode = code
        return response
    end

    function response.send(body)
        response.body = body
        response.finished = true
        return response
    end

    return response
end

assert(path.decodeUrl("a+b%20c") == "a b c")
assert(path.decodeUrl("%2F%zz") == "/%zz")
assert(path.normalize("a//b/") == "/a/b")
assert(path.normalize("") == "/")
local query = path.parseQuery("q=a+b", { query = {} })
assert(query.q == "a b")
query = path.parseQuery("q=one&q=two", { query = {} })
assert(query.q[1] == "one" and query.q[2] == "two")

local app = App.new()
assert(app._workers == 4)
assert(app.workers(2) == app and app._workers == 2)
assertFails(function() app.workers(65) end, "worker count must be capped")
assertFails(function() app.workers(1.5) end, "worker count must be an integer")
app.workerRequires("socket", "socket", "test.native")
assert(#app._workerRequires == 3)
assertFails(function() app.workerRequires("") end, "worker module cannot be empty")
assertFails(function() app.use("not a function") end, "middleware must be callable")
local handler = function() end
app.get("/normalized/", handler)
app.get("/normalized", function() end)
assert(path.findRoute(app, { method = "GET", path = "/normalized" }).funcs[1] == handler)
assert(path.findRoute(app, { method = "POST", path = "/normalized" }) == nil)
assertFails(function() app.get(42, handler) end, "route path must be a string")
assertFails(function() app.get("/invalid", "not a function") end,
    "route handler must be callable")

assert(json.decode("0") == 0)
assert(json.decode("-12.5e+2") == -1250)
local decoded = json.decode(json.encode({
    ok = true,
    values = { 1, 2, 3 },
    text = "line\n" .. string.char(0)
}))
assert(decoded.ok and decoded.values[2] == 2)
assert(decoded.text == "line\n" .. string.char(0))
assertFails(function() json.decode("01") end, "leading zero must be rejected")
assertFails(function() json.decode("1.") end, "empty fraction must be rejected")
assertFails(function() json.decode("1e") end, "empty exponent must be rejected")
assertFails(function() json.decode('"' .. string.char(1) .. '"') end,
    "unescaped control characters must be rejected")
assertFails(function() json.decode("[1,]") end, "trailing commas must be rejected")
assertFails(function() json.decode('{"key":}') end, "missing values must be rejected")
assertFails(function() json.encode(0 / 0) end, "NaN must not be encoded")

assert(status.code(499) == "Unknown Status")
assert(status.code(200) == "OK")

local request = {}
local response = newResponse()
local sequence = {}
middleware.exe({
    function(req, res, next)
        sequence[#sequence + 1] = "first"
        next()
    end,
    function(req, res, next)
        sequence[#sequence + 1] = "second"
        next()
    end,
    function(req, res)
        res.send("handled")
    end
}, request, response)
assert(table.concat(sequence, ",") == "first,second")
assert(response.finished and response.body == "handled")

response = newResponse()
middleware.exe({}, {}, response)
assert(response.statuscode == 404 and response.body == "Not Found")

local wasSkipped = false
response = newResponse()
middleware.exe({
    function(req, res)
        res.status(403).send("blocked")
    end,
    function()
        wasSkipped = true
    end
}, {}, response)
assert(response.statuscode == 403 and not wasSkipped)

local previousStderr = io.stderr
local logged = {}
io.stderr = {
    write = function(_, ...)
        for index = 1, select("#", ...) do
            logged[#logged + 1] = tostring(select(index, ...))
        end
    end
}
response = newResponse()
local errorCallbackCalled = false
response.onError = function()
    errorCallbackCalled = true
end
local ok, middlewareErr = pcall(function()
    middleware.exe({
        function()
            error("handler failed")
        end
    }, {}, response)
end)
io.stderr = previousStderr
assert(ok, middlewareErr)
assert(response.statuscode == 500 and response.body == "Internal Server Error")
assert(errorCallbackCalled and table.concat(logged):find("handler failed", 1, true))

print("Veloce tests passed")

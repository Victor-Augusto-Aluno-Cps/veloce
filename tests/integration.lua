package.path = "./?.lua;./?/init.lua;" .. package.path

local App = require("veloce")
local lanesModule = require("lanes")
local lanes = lanesModule.gen and lanesModule or lanesModule.configure()
local socket = lanes.require("socket")
local json = require("veloce.utils.json")

local host = "127.0.0.1"
local port = 38081
local workerCount = tonumber(os.getenv("VELOCE_TEST_WORKERS")) or 4

local function connect()
    local lastError
    for _ = 1, 50 do
        local client = assert(socket.tcp())
        client:settimeout(2)
        local connected, err = client:connect(host, port)
        if connected then
            return client
        end

        lastError = err
        client:close()
        socket.sleep(0.1)
    end

    error("Test server did not start: " .. tostring(lastError))
end

local function sendRaw(raw, quiet)
    local start = socket.gettime()
    local client = connect()
    local sent, err, partial = client:send(raw)
    assert(sent or partial, err)

    local response, receiveErr, received = client:receive("*a")
    client:close()
    response = response or received
    assert(response and #response > 0, receiveErr or "empty HTTP response")

    local statusEnd = assert(response:find("\r\n", 1, true))
    local headerEnd = assert(response:find("\r\n\r\n", 1, true))
    local statusLine = response:sub(1, statusEnd - 1)
    local statusCode = tonumber(statusLine:match("^HTTP/1%.1 (%d%d%d)"))
    assert(statusCode, "invalid response status line: " .. statusLine)

    local headers = {}
    local headerBlock = response:sub(statusEnd + 2, headerEnd - 1)
    for line in headerBlock:gmatch("[^\r\n]+") do
        local name, value = line:match("^([^:]+):%s*(.*)$")
        assert(name, "invalid response header: " .. line)
        headers[name:lower()] = value
    end

    local parsedResponse = {
        status = statusCode,
        headers = headers,
        body = response:sub(headerEnd + 4),
        raw = response
    }

    local requestLine = raw:match("^([^\r\n]+)") or "raw request"
    if #requestLine > 70 then
        requestLine = requestLine:sub(1, 67) .. "..."
    end

    local bodyLog = parsedResponse.body:gsub("\r", "\\r"):gsub("\n", "\\n")
    if #bodyLog > 120 then
        bodyLog = bodyLog:sub(1, 117) .. "..."
    end

    local responseDetails = ""
    if headers.location then
        responseDetails = responseDetails .. " location=" .. headers.location
    end
    if headers["content-type"] then
        responseDetails = responseDetails .. " type=" .. headers["content-type"]
    end

    if not quiet then
        print(("%3d %6.1f ms %s%s body=%q"):format(
            statusCode,
            (socket.gettime() - start) * 1000,
            requestLine,
            responseDetails,
            bodyLog
        ))
    end

    return parsedResponse
end

local function request(method, path, headers, body, quiet)
    headers = headers or {}
    local lines = {
        method .. " " .. path .. " HTTP/1.1",
        "Host: localhost"
    }

    for name, value in pairs(headers) do
        lines[#lines + 1] = name .. ": " .. value
    end

    if body ~= nil and headers["Content-Length"] == nil then
        lines[#lines + 1] = "Content-Length: " .. #body
    end

    return sendRaw(
        table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or ""),
        quiet
    )
end

local response = request("GET", "/")
assert(response.status == 200 and json.decode(response.body).ok)
assert(response.headers["x-powered-by"] == "veloce-test")

response = request("GET", "/json")
local data = json.decode(response.body)
assert(response.status == 200 and data.ok and data.count == 3)
assert(data.values[1] == 1 and data.values[3] == 3)
assert(response.headers["content-type"] == "application/json; charset=utf-8")

response = request("GET", "/query?tag=one+two&tag=three")
data = json.decode(response.body)
assert(data.tag[1] == "one two" and data.tag[2] == "three")

response = request("GET", "/header", { ["X-Test"] = "value" })
assert(response.status == 200 and response.body == "value")

response = request("GET", "/middleware")
assert(response.body == "first,second")

response = request("GET", "/blocked")
assert(response.status == 403 and response.body == "blocked")

response = request("GET", "/normalized")
assert(response.status == 200 and response.body == "normalized")

response = request("GET", "/missing")
assert(response.status == 404 and response.body == "Cannot GET /missing")

response = request("GET", "/empty")
assert(response.status == 404 and response.body == "Not Found")

response = request("GET", "/status")
assert(response.status == 499 and response.body == "custom status")
assert(response.raw:find("HTTP/1.1 499 Unknown Status", 1, true))

response = request("GET", "/invalid-status")
assert(response.status == 500 and response.body == "Internal Server Error")

response = request("GET", "/typed")
assert(response.headers["content-type"] == "text/html; charset=utf-8")
assert(response.body == "<p>typed response</p>")

response = request("GET", "/redirect")
assert(response.status == 302 and response.headers.location == "/json")

response = request("GET", "/redirect-301")
assert(response.status == 301 and response.headers.location == "/json")

response = request("GET", "/error")
assert(response.status == 500 and response.body == "Internal Server Error")

response = request("GET", "/bad-header")
assert(response.status == 500 and not response.raw:find("Injected: yes", 1, true))

response = request("POST", "/echo", nil, "request body")
assert(response.status == 201 and response.body == "request body")

response = request("PUT", "/echo", nil, "updated")
assert(response.status == 202 and response.body == "updated")

response = request("DELETE", "/resource")
assert(response.status == 204 and response.body == "")

response = sendRaw("not an HTTP request\r\n\r\n")
assert(response.status == 400)

response = request("POST", "/echo", { ["Content-Length"] = "nope" }, "")
assert(response.status == 400)

response = sendRaw(
    "POST /echo HTTP/1.1\r\nHost: localhost\r\n"
        .. "Content-Length: 1\r\nContent-Length: 1\r\n\r\nx"
)
assert(response.status == 400)

response = sendRaw(
    "POST /echo HTTP/1.1\r\nHost: localhost\r\n"
        .. "Transfer-Encoding: chunked\r\n\r\n"
)
assert(response.status == 501)

response = sendRaw(
    "POST /echo HTTP/1.1\r\nHost: localhost\r\n"
        .. "Content-Length: 1048577\r\n\r\n"
)
assert(response.status == 413)

response = sendRaw(
    "GET / HTTP/1.1\r\nHost: localhost\r\nX-Large: "
        .. string.rep("a", 17000)
        .. "\r\n\r\n"
)
assert(response.status == 431)

local burstWorker = lanes.gen(
    "*",
    { required = { "socket", "socket.core" } },
    function(targetHost, targetPort, requestPath)
        local clientSocket = require("socket")
        local client = assert(clientSocket.tcp())
        client:settimeout(5)
        assert(client:connect(targetHost, targetPort))
        assert(client:send(
            "GET " .. requestPath .. " HTTP/1.1\r\nHost: localhost\r\n\r\n"
        ))
        local rawResponse, err, partial = client:receive("*a")
        client:close()
        rawResponse = rawResponse or partial
        assert(rawResponse and #rawResponse > 0, err)
        return rawResponse
    end
)

for attempt = 1, 2 do
    local burst = {}
    for index = 1, 64 do
        burst[index] = burstWorker(
            host, port, "/fast?id=" .. tostring(index)
        )
    end
    for index, clientLane in ipairs(burst) do
        local rawResponse = clientLane[1]
        local statusCode = tonumber(rawResponse:match("^HTTP/1%.1 (%d%d%d)"))
        local headerEnd = assert(rawResponse:find("\r\n\r\n", 1, true))
        local body = rawResponse:sub(headerEnd + 4)
        assert(statusCode == 200 and body == tostring(index),
            ("wake-up burst #%d returned an incorrect response for request #%d")
                :format(attempt, index))
    end
end

local abandonedClient = connect()
assert(abandonedClient:send(
    "GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n"
))
abandonedClient:close()
socket.sleep(0.3)
response = request("GET", "/", nil, nil, true)
assert(response.status == 200 and json.decode(response.body).ok)

local clientWorker = lanes.gen(
    "*",
    { required = { "socket", "socket.core" } },
    function(targetHost, targetPort)
        local clientSocket = require("socket")
        local started = clientSocket.gettime()
        local client = assert(clientSocket.tcp())
        client:settimeout(5)
        assert(client:connect(targetHost, targetPort))
        assert(client:send(
            "GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n"
        ))
        local response, err, partial = client:receive("*a")
        client:close()
        response = response or partial
        assert(response and response:find("slow response", 1, true), err)
        return response, clientSocket.gettime() - started
    end
)

local start = socket.gettime()
local requests = {}
for index = 1, 8 do
    requests[index] = clientWorker(host, port)
end
for index, worker in ipairs(requests) do
    local rawResponse = worker[1]
    local elapsedSeconds = worker[2]
    local statusCode = tonumber(rawResponse:match("^HTTP/1%.1 (%d%d%d)"))
    local headerEnd = assert(rawResponse:find("\r\n\r\n", 1, true))
    local body = rawResponse:sub(headerEnd + 4)

    assert(statusCode == 200 and body == "slow response")
    print(("%3d %6.1f ms parallel request #%d body=%q"):format(
        statusCode,
        elapsedSeconds * 1000,
        index,
        body
    ))
end
local elapsed = socket.gettime() - start
local expectedBatches = math.ceil(8 / workerCount)
local maxElapsed = expectedBatches * 0.25 + 0.75
assert(elapsed < maxElapsed,
    ("8 x 250 ms requests took %.2f seconds with %d workers; expected under %.2f seconds")
        :format(elapsed, workerCount, maxElapsed))

print(("Veloce integration tests passed (8 parallel requests in %.2fs)"):format(elapsed))

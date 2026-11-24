local lanesModule = require("lanes")
local lanes = lanesModule.gen and lanesModule or lanesModule.configure()
local functions_ = require("veloce.core.functions")
local path_ = require("veloce.utils.path")
local status_ = require("veloce.utils.status")
local json_ = require("veloce.utils.json")
local socket = lanes.require("socket")

local mimeTypes = {
    html = "text/html; charset=utf-8",
    json = "application/json; charset=utf-8",
    txt = "text/plain; charset=utf-8",
    css = "text/css; charset=utf-8",
    js = "application/javascript; charset=utf-8"
}

local MAX_HEADER_SIZE = 16384
local MAX_BODY_SIZE = 1048576
local MAX_CLIENTS = 256
local CLIENT_TIMEOUT = 30
local READ_SIZE = 8192
local WORKER_WAKE_SIGNAL = "w"

local function closeClient(clients, client)
    clients[client] = nil
    client:close()
end

local function newResponse()
    local res = {
        statuscode = 200,
        headers = {},
        finished = false
    }

    function res.status(code)
        if type(code) ~= "number" or code % 1 ~= 0 or code < 100 or code > 599 then
            error("O status code precisa ser um inteiro entre 100 e 599")
        end

        res.statuscode = code
        return res
    end

    function res.type(typeStr)
        res.headers["content-type"] = mimeTypes[typeStr] or typeStr
        return res
    end

    function res.json(data)
        res.type("json")
        return res.send(json_.encode(data))
    end

    function res.redirect(url, code)
        res.headers.location = url
        return res.status(code or 302).send("")
    end

    function res.send(body)
        if res.finished then
            return res
        end

        body = tostring(body or "")
        res.headers["content-type"] =
            res.headers["content-type"] or "text/plain; charset=utf-8"
        res.headers["content-length"] = #body
        res.headers.connection = "close"

        local statusMessage = status_.code(res.statuscode) or "Unknown Status"
        local response = {
            ("HTTP/1.1 %d %s\r\n"):format(res.statuscode, statusMessage)
        }
        local headers = {}

        for name, value in pairs(res.headers) do
            name = tostring(name)
            value = tostring(value)
            local normalizedName = name:lower()

            if not name:match("^[%w!#$%%&'*+.^_`|~-]+$")
                or value:find("[%z\1-\8\10-\31\127]")
            then
                error("Nome ou valor de header HTTP inválido")
            end

            if headers[normalizedName] ~= nil then
                error("Header HTTP duplicado: " .. normalizedName)
            end
            headers[normalizedName] = value
        end

        for name, value in pairs(headers) do
            response[#response + 1] = name .. ": " .. value .. "\r\n"
        end

        response[#response + 1] = "\r\n"
        response[#response + 1] = body
        res.output = table.concat(response)
        res.finished = true

        return res
    end

    return res
end

local function prepareRequest(client, buffer)
    local headerEnd = buffer:find("\r\n\r\n", 1, true)

    if not headerEnd then
        if #buffer > MAX_HEADER_SIZE then
            return nil, 431, "Request Header Fields Too Large"
        end
        return nil
    end

    if headerEnd - 1 > MAX_HEADER_SIZE then
        return nil, 431, "Request Header Fields Too Large"
    end

    local headerBlock = buffer:sub(1, headerEnd - 1)
    local requestLine, headerLines = headerBlock:match("^([^\r\n]+)\r\n(.*)$")
    if not requestLine then
        requestLine = headerBlock
        headerLines = ""
    end

    local method, requestTarget, version =
        requestLine:match("^(%S+)%s+(%S+)%s+(HTTP/%d%.%d)$")

    if not method then
        return nil, 400, "Bad Request"
    end

    local headers = {}
    for line in (headerLines .. "\r\n"):gmatch("(.-)\r\n") do
        if line ~= "" then
            local key, value = line:match("^([%w!#$%%&'*+.^_`|~-]+):%s*(.*)$")
            if not key or value:find("[\r\n]") then
                return nil, 400, "Bad Request"
            end

            key = key:lower()
            if headers[key] and key == "content-length" then
                return nil, 400, "Bad Request"
            end
            headers[key] = headers[key] and (headers[key] .. ", " .. value) or value
        end
    end

    if headers["transfer-encoding"] then
        return nil, 501, "Not Implemented"
    end

    local contentLength = 0
    if headers["content-length"] then
        if not headers["content-length"]:match("^%d+$") then
            return nil, 400, "Bad Request"
        end

        contentLength = tonumber(headers["content-length"])
        if not contentLength then
            return nil, 400, "Bad Request"
        elseif contentLength > MAX_BODY_SIZE then
            return nil, 413, "Content Too Large"
        end
    end

    local bodyStart = headerEnd + 4
    if #buffer - bodyStart + 1 < contentLength then
        return nil
    end

    local req = {
        method = method,
        path = requestTarget,
        version = version,
        headers = headers,
        query = {},
        params = {},
        body = buffer:sub(bodyStart, bodyStart + contentLength - 1),
        ip = client:getpeername()
    }

    local routePath, queryString = req.path:match("^([^?]*)%?(.*)$")
    if routePath then
        req.path = routePath
        path_.parseQuery(queryString, req)
    end

    req.path = path_.normalize(req.path)
    req.hostname = headers.host or ""
    return req
end

local function processRequest(app, req)
    function req.get(name)
        if type(name) ~= "string" then
            error("O nome do header precisa ser uma string")
        end
        return req.headers[name:lower()]
    end

    local res = newResponse()
    local route = path_.findRoute(app, req)

    if not route then
        res.status(404).send("Cannot " .. req.method .. " " .. req.path)
    else
        local chain = {}
        for _, handler in ipairs(app._middlewares) do
            chain[#chain + 1] = handler
        end
        for _, handler in ipairs(route.funcs) do
            chain[#chain + 1] = handler
        end
        functions_.exe(chain, req, res)
    end

    return res.output
end

local function workerLoop(linda, app, wakeHost, wakePort)
    local workerSocket = require("socket")
    local wakeSender, socketErr = workerSocket.udp()
    if not wakeSender then
        linda:send("startupErrors", tostring(socketErr))
        return nil
    end
    wakeSender:settimeout(0)

    local connected, connectErr = wakeSender:setpeername(wakeHost, wakePort)
    if not connected then
        wakeSender:close()
        linda:send("startupErrors", tostring(connectErr))
        return nil
    end

    linda:send("ready", true)

    while true do
        local key, job = linda:receive("jobs", "stop")
        if key == "stop" then
            wakeSender:close()
            return true
        end

        local ok, output = pcall(processRequest, app, job.request)
        if not ok then
            io.stderr:write("Veloce worker error:\n", tostring(output), "\n")
            local res = newResponse()
            res.status(500).send("Internal Server Error")
            output = res.output
        end

        local sent, sendErr = linda:send("results", {
            id = job.id,
            output = output
        })
        if not sent then
            wakeSender:close()
            error("Não foi possível retornar a resposta do worker: " .. tostring(sendErr))
        end

        local notified, notifyErr = wakeSender:send(WORKER_WAKE_SIGNAL)
        if not notified and notifyErr ~= "timeout" then
            wakeSender:close()
            error("Não foi possível acordar o event loop: " .. tostring(notifyErr))
        end
        -- Notifications can coalesce; the main loop drains the entire result queue per wake.
    end
end

local function listen(app, port, ...)
    local args = { ... }
    local host

    if type(args[1]) == "string" then
        host = table.remove(args, 1)
    end

    if not host then
        local udp = socket.udp()
        local peerOk = udp:setpeername("8.8.8.8", 80)
        if peerOk then
            host = udp:getsockname()
        end
        udp:close()
        host = host or "*"
    end

    for index, callback in ipairs(args) do
        if type(callback) ~= "function" then
            error(("Argumento #%d precisa ser uma function"):format(index))
        end
    end

    local server, err = socket.bind(host, port)
    if not server then
        error(("Não foi possível iniciar o servidor em %s:%s: %s")
            :format(host, tostring(port), tostring(err)))
    end

    server:setoption("reuseaddr", true)
    server:settimeout(0)

    local wakeReceiver, udpErr = socket.udp()
    if not wakeReceiver then
        server:close()
        error("Não foi possível criar o socket de wake-up: " .. tostring(udpErr))
    end
    local wakeBound, wakeErr = wakeReceiver:setsockname("127.0.0.1", 0)
    if not wakeBound then
        wakeReceiver:close()
        server:close()
        error("Não foi possível criar o socket de wake-up: " .. tostring(wakeErr))
    end
    wakeReceiver:settimeout(0)
    local wakeHost, wakePort = wakeReceiver:getsockname()
    if not wakeHost or not wakePort then
        wakeReceiver:close()
        server:close()
        error("Não foi possível consultar o socket de wake-up")
    end

    for _, moduleName in ipairs(app._workerRequires) do
        local ok, moduleErr = pcall(lanes.require, moduleName)
        if not ok then
            wakeReceiver:close()
            server:close()
            error(("Não foi possível registrar o módulo worker '%s': %s")
                :format(moduleName, tostring(moduleErr)))
        end
    end

    local linda = lanes.linda("veloce-http")
    linda:limit("jobs", MAX_CLIENTS)
    linda:limit("results", MAX_CLIENTS)

    local workerGenerator = lanes.gen(
        "*",
        { required = app._workerRequires },
        workerLoop
    )
    local workerApp = {
        _middlewares = app._middlewares,
        _routes = app._routes,
        _routeLookup = app._routeLookup
    }
    local workers = {}
    for index = 1, app._workers do
        local ok, worker = pcall(
            workerGenerator, linda, workerApp, wakeHost, wakePort
        )
        if not ok then
            for _ = 1, #workers do
                linda:send("stop", true)
            end
            wakeReceiver:close()
            server:close()
            error(("Não foi possível iniciar o worker #%d: %s")
                :format(index, tostring(worker)))
        end
        workers[#workers + 1] = worker
    end

    for _ = 1, #workers do
        local key, startupErr = linda:receive(
            10, "ready", "startupErrors"
        )
        if key ~= "ready" then
            for _ = 1, #workers do
                linda:send("stop", true)
            end
            wakeReceiver:close()
            server:close()
            if key == "startupErrors" then
                error("Não foi possível iniciar o wake-up dos workers: "
                    .. tostring(startupErr))
            end
            error("Timeout ao iniciar os workers do servidor")
        end
    end

    local clients = {}
    local requestClients = {}
    local nextRequestId = 0
    local pendingRequests = 0

    local function failServer(message)
        for client in pairs(clients) do
            closeClient(clients, client)
        end
        wakeReceiver:close()
        server:close()

        for _ = 1, #workers do
            local stopped, stopErr = linda:send("stop", true)
            if not stopped then
                io.stderr:write(
                    "Veloce could not stop a worker: ",
                    tostring(stopErr),
                    "\n"
                )
            end
        end

        error(message, 0)
    end

    local function collectResults()
        while true do
            local key, result = linda:receive(0, "results")
            if key ~= "results" then
                break
            end

            local client = requestClients[result.id]
            requestClients[result.id] = nil
            pendingRequests = pendingRequests - 1
            local state = client and clients[client]
            if state then
                state.pending = nil
                state.output = result.output
                state.offset = 1
                state.lastActivity = socket.gettime()
            end
        end
    end

    local function drainWakeSignals()
        while true do
            local signal, receiveErr = wakeReceiver:receivefrom(1)
            if signal then
                -- Wake signals are coalesced; the Linda results queue is authoritative.
            elseif receiveErr == "timeout" then
                break
            else
                failServer("Falha ao receber sinal de wake-up: "
                    .. tostring(receiveErr))
            end
        end
    end

    for _, callback in ipairs(args) do
        local ok, callbackErr = pcall(callback, port, host)
        if not ok then
            failServer("Falha no callback de inicialização: "
                .. tostring(callbackErr))
        end
    end

    while true do
        collectResults()

        local readable = { server }
        local writable = {}

        readable[#readable + 1] = wakeReceiver
        for client, state in pairs(clients) do
            if state.output then
                writable[#writable + 1] = client
            elseif not state.pending then
                readable[#readable + 1] = client
            end
        end

        local selectTimeout
        local now = socket.gettime()
        for _, state in pairs(clients) do
            if not state.pending then
                local untilTimeout =
                    CLIENT_TIMEOUT - (now - state.lastActivity)
                if selectTimeout == nil or untilTimeout < selectTimeout then
                    selectTimeout = math.max(0, untilTimeout)
                end
            end
        end

        local readyRead, readyWrite, selectErr =
            socket.select(readable, writable, selectTimeout)
        if not readyRead then
            if selectErr ~= "timeout" then
                failServer("Falha no loop de I/O: " .. tostring(selectErr))
            end
        else
            for _, ready in ipairs(readyRead) do
                if ready == server then
                    local clientCount = 0
                    for _ in pairs(clients) do
                        clientCount = clientCount + 1
                    end

                    while true do
                        local client, acceptErr = server:accept()
                        if not client then
                            if acceptErr ~= "timeout" then
                                failServer("Falha ao aceitar conexão: "
                                    .. tostring(acceptErr))
                            end
                            break
                        end

                        client:settimeout(0)
                        if clientCount >= MAX_CLIENTS then
                            local res = newResponse()
                            res.status(503).send("Service Unavailable")
                            client:send(res.output)
                            client:close()
                        else
                            clients[client] = {
                                input = "",
                                lastActivity = socket.gettime()
                            }
                            clientCount = clientCount + 1
                        end
                    end
                elseif ready == wakeReceiver then
                    drainWakeSignals()
                else
                    local state = clients[ready]
                    if state then
                        local data, receiveErr, partial = ready:receive(READ_SIZE)
                        local chunk = data or partial

                        if chunk and #chunk > 0 then
                            state.lastActivity = socket.gettime()
                            state.input = state.input .. chunk
                            local ok, requestOrErrorCode, errorCode, errorMessage = pcall(
                                prepareRequest, ready, state.input
                            )

                            if not ok then
                                io.stderr:write(
                                    "Veloce request processing error:\n",
                                    tostring(requestOrErrorCode),
                                    "\n"
                                )
                                local res = newResponse()
                                res.status(500).send("Internal Server Error")
                                state.output = res.output
                                state.offset = 1
                            elseif requestOrErrorCode then
                                nextRequestId = nextRequestId + 1
                                local requestId = nextRequestId
                                local queued = linda:send(0, "jobs", {
                                    id = requestId,
                                    request = requestOrErrorCode
                                })

                                if queued then
                                    requestClients[requestId] = ready
                                    state.pending = true
                                    pendingRequests = pendingRequests + 1
                                else
                                    local res = newResponse()
                                    res.status(503).send("Server Busy")
                                    state.output = res.output
                                    state.offset = 1
                                end
                            elseif errorCode then
                                local res = newResponse()
                                res.status(errorCode).send(errorMessage)
                                state.output = res.output
                                state.offset = 1
                            end
                        elseif receiveErr ~= "timeout" then
                            closeClient(clients, ready)
                        end
                    end
                end
            end

            collectResults()

            for _, client in ipairs(readyWrite) do
                local state = clients[client]
                if state then
                    local lastSent, sendErr, partial =
                        client:send(state.output, state.offset)
                    lastSent = lastSent or partial

                    if lastSent then
                        state.offset = lastSent + 1
                        state.lastActivity = socket.gettime()
                    end

                    if state.offset > #state.output then
                        closeClient(clients, client)
                    elseif sendErr and sendErr ~= "timeout" then
                        closeClient(clients, client)
                    end
                end
            end

        end

        local now = socket.gettime()
        for client, state in pairs(clients) do
            if not state.pending and now - state.lastActivity > CLIENT_TIMEOUT then
                closeClient(clients, client)
            end
        end
    end
end

return listen

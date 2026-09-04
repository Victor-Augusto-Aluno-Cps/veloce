local functions_ = require("veloce.core.functions")
local path_ = require("veloce.utils.path")
local status_ = require("veloce.utils.status")
local json_ = require("veloce.utils.json")
local socket = require("socket")

local mimeTypes = {
    html = "text/html; charset=utf-8",
    json = "application/json; charset=utf-8",
    txt  = "text/plain; charset=utf-8",
    css  = "text/css; charset=utf-8",
    js   = "application/javascript; charset=utf-8"
}





local listen = function (app, port, ...)
    local args = {...}

    local host = nil

    if type(args[1]) == "string" then
        host = args[1]
        table.remove(args, 1)
    end

    if not host then
        local udp = socket.udp()
        udp:setpeername("8.8.8.8", 80)
        host = udp:getsockname()
        udp:close()
    end

    local callbacks = {}

    for i, callback in ipairs(args) do

        if type(callback) ~= "function" then
            error(
                ("Argumento #%d precisa ser uma function"):format(i)
            )
        end

        callbacks[#callbacks + 1] = callback
    end
    
    local server = assert(socket.bind(host, port))

    for i, func in ipairs(args) do
        func(port, host)
    end

    while true do
        local client, err = server:accept()

        if client then
            client:settimeout(10)

            local req = {
                method = "",
                path = "",
                headers = {},
                query = {},
                params = {},
                body = "",
                ip = client:getpeername()
            }

            local requestLine = client:receive("*l")
            
            if requestLine then
                req.method, req.path, req.version = requestLine:match("^(%S+)%s+(%S+)%s+(%S+)$")
            end
            
            local path, queryString = req.path:match("^([^?]*)%?(.*)$")

            if path then
                req.path = path
                path_.parseQuery(queryString, req)
            end

            req.path = path_.normalize(req.path)

            while true do
                local line = client:receive("*l")

                if not line or line == "" then
                    break
                end

                local key, value = line:match("^([^:]+):%s*(.*)$")

                if key then
                    req.headers[key:lower()] = value
                end
            end

            function req.get(name)
                return req.headers[name:lower()]
            end

            req.hostname = req.get("host") or ""

            local contentLength = tonumber(req.headers["content-length"])

            if contentLength and contentLength > 0 then
                req.body = client:receive(contentLength)
            end

            local res = {
                statuscode = 200,
                headers = {},
                finished = false
            }

            function res.status(code)

                if type(code) ~= "number" then
                    error("Erro: O status code precisa ser um número. Tipo recebido: " .. type(code))
                end

                res.statuscode = code

                return res
            end

            function res.type(typeStr)

                local contentType =
                    mimeTypes[typeStr] or typeStr

                res.headers["content-type"] =
                    contentType

                return res

            end

            function res.json(data)
                local body = json_.encode(data)
                res.type("json")
                res.send(body)
                return res
            end

            function res.redirect(url)
                res.headers["location"] = url
                return res.send("")
            end

            function res.send(body)
                if res.finished then
                    return res
                end

                body = tostring(body or "")

                if not res.headers["content-type"] then
                    res.headers["content-type"] = "text/plain; charset=utf-8"
                end

                res.headers["content-length"] = #body

                local statusMessage = status_.code(res.statuscode)

                local response = ("HTTP/1.1 %d %s\r\n"):format(res.statuscode, statusMessage)

                for name, value in pairs(res.headers) do

                    response =
                        response
                        .. name
                        .. ": "
                        .. value
                        .. "\r\n"

                end

                response = response .. "\r\n" .. body

                client:send(response)

                res.finished = true

                return res
            end

            local route = path_.findRoute(app, req)

            if route then
                local chain = {}

                for _, func in ipairs(app._middlewares) do
                    table.insert(chain, func)
                end

                for _, func in ipairs(route.funcs) do
                    table.insert(chain, func)
                end
                
                functions_.exe(chain, req, res)

            else
                res.status(404).send("Cannot " .. req.method .. " " .. req.path)
            end

            client:close()
        end
    end
end



return listen
-- core
local listen = require("veloce.core.aplication")
local path_ = require("veloce.utils.path")




local App = {}


function App.new()

    local app = {}

    app._middlewares = {}
    app._workers = 4
    app._workerRequires = { "socket", "socket.core" }

    app._routes = {
        GET = {},
        POST = {},
        PUT = {},
        DELETE = {},
    }
    app._routeLookup = {
        GET = {},
        POST = {},
        PUT = {},
        DELETE = {},
    }

    function app.use(...)
        local args = { ... }

        for i, func in ipairs(args) do

            if type(func) ~= "function" then
                error(
                    ("Middleware #%d precisa ser uma function"):format(i)
                )
            end

            table.insert(app._middlewares, func)

        end
    end

    function app.workers(count)
        if type(count) ~= "number"
            or count % 1 ~= 0
            or count < 1
            or count > 64
        then
            error("A quantidade de workers precisa ser um inteiro entre 1 e 64")
        end

        app._workers = count
        return app
    end

    function app.workerRequires(...)
        for index, moduleName in ipairs({ ... }) do
            if type(moduleName) ~= "string" or moduleName == "" then
                error(("Módulo worker #%d precisa ser um nome não vazio"):format(index))
            end

            local alreadyRequired = false
            for _, requiredModule in ipairs(app._workerRequires) do
                if requiredModule == moduleName then
                    alreadyRequired = true
                    break
                end
            end

            if not alreadyRequired then
                app._workerRequires[#app._workerRequires + 1] = moduleName
            end
        end

        return app
    end

    local function register(method, path, ...)
        if type(path) ~= "string" then
            error("Path precisa ser uma string")
        end

        local args = { ... }

        local normalizedPath = path_.normalize(path)
        local route = {
            method = method,
            path = normalizedPath,
            funcs = {}
        }

        for i, func in ipairs(args) do
            if type(func) ~= "function" then
                error(
                    ("Middleware/handler #%d precisa ser uma function"):format(i)
                )
            end

            table.insert(route.funcs, func)
        end

        table.insert(app._routes[method], route)
        if not app._routeLookup[method][normalizedPath] then
            app._routeLookup[method][normalizedPath] = route
        end
    end

    function app.get(path, ...)
        register("GET", path, ...)
    end

    function app.post(path, ...)
        register("POST", path, ...)
    end

    function app.put(path, ...)
        register("PUT", path, ...)
    end

    function app.delete(path, ...)
        register("DELETE", path, ...)
    end

    function app.listen(port, ...)
        return listen(app, port, ...)
    end


    return app
end


return App

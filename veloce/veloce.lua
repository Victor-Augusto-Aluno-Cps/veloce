-- core
local listen = require("veloce.core.aplication")




local App = {}


function App.new()

    local app = {}

    app._middlewares = {}

    app._routes = {
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

    local function register(method, path, ...)
        if type(path) ~= "string" then
            error("Path precisa ser uma string")
        end

        local args = { ... }

        local route = {
            method = method,
            path = path,
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

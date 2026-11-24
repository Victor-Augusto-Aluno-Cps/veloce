local path = {}

function path.decodeUrl(str)
    if str == nil then
        return nil
    end

    str = tostring(str)
    str = str:gsub("%+", " ")
    str = str:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)

    return str
end

function path.findRoute(app, req)
    local routeLookup = app._routeLookup and app._routeLookup[req.method]
    if routeLookup then
        local route = routeLookup[path.normalize(req.path)]
        if route then
            return route
        end
    end

    local routes = app._routes[req.method]

    if not routes then
        return nil
    end

    for _, route in ipairs(routes) do
        if path.normalize(route.path) == path.normalize(req.path) then
            return route
        end
    end

    return nil
end

function path.normalize(value)
    if value == nil or value == "" then
        return "/"
    end

    value = tostring(value)

    value = value:gsub("[?#].*$", "")

    if value:sub(1, 1) ~= "/" then
        value = "/" .. value
    end

    value = value:gsub("/+", "/")

    if value ~= "/" then
        value = value:gsub("/+$", "")
    end

    return value ~= "" and value or "/"
end

function path.parseQuery(queryString, req)
    if not req then
        error("path.parseQuery: request object is required")
    end

    req.query = {}

    if not queryString or queryString == "" then
        return req.query
    end

    queryString = queryString:gsub("^%?", "")

    for parameter in queryString:gmatch("[^&]+") do
        local key, value = parameter:match("^([^=]*)=(.*)$")

        if key == nil then
            key = parameter
            value = ""
        end

        key = path.decodeUrl(key)
        value = path.decodeUrl(value)

        if key ~= "" then
            local current = req.query[key]

            if current == nil then
                req.query[key] = value

            elseif type(current) == "table" then
                table.insert(current, value)

            else
                req.query[key] = {
                    current,
                    value
                }
            end
        end
    end

    return req.query
end


return path

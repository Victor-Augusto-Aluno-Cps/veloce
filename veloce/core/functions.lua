local functions = {}

function functions.exe(stack, req, res)
    local index = 0
    local ended = false

    local function next()
        if ended or res.finished then
            return
        end

        index = index + 1

        local handler = stack[index]

        if not handler then
            ended = true

            if not res.finished then
                res.status(404)
                res.send("Not Found")
            end

            return
        end

        local ok, err = xpcall(
            function()
                handler(req, res, next)
            end,
            debug.traceback
        )

        if not ok then
            ended = true

            io.stderr:write("Veloce handler error:\n", tostring(err), "\n")

            if not res.finished then
                res.status(500)
                res.send("Internal Server Error")
            end

            if res.onError then
                local callbackOk, callbackErr = pcall(res.onError, err)
                if not callbackOk then
                    io.stderr:write(
                        "Veloce error callback failed:\n",
                        tostring(callbackErr),
                        "\n"
                    )
                end
            end
        end
    end

    next()

    if not res.finished then
        res.status(404)
        res.send("Not Found")
    end
end

return functions
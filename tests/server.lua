package.path = "./?.lua;./?/init.lua;" .. package.path

local App = require("veloce")
local socket = require("socket")

local app = App.new()
app.workers(tonumber(os.getenv("VELOCE_TEST_WORKERS")) or 4)

app.use(function(req, res, next)
    req.trace = "first"
    res.headers["x-powered-by"] = "veloce-test"

    if req.path == "/blocked" then
        return res.status(403).send("blocked")
    end

    next()
end)

app.use(function(req, res, next)
    req.trace = req.trace .. ",second"
    next()
end)

app.get("/", function(req, res)
    res.json({ ok = true, trace = req.trace })
end)

app.get("/json", function(req, res)
    res.json({ ok = true, count = 3, values = { 1, 2, 3 } })
end)

app.get("/query", function(req, res)
    res.json(req.query)
end)

app.get("/header", function(req, res)
    res.send(req.get("x-test") or "missing")
end)

app.get("/middleware", function(req, res)
    res.send(req.trace)
end)

app.get("/blocked", function()
    error("blocked route should not execute")
end)

app.get("/normalized/", function(req, res)
    res.send("normalized")
end)

app.get("/empty", function()
end)

app.get("/status", function(req, res)
    res.status(499).send("custom status")
end)

app.get("/invalid-status", function(req, res)
    res.status(700).send("invalid")
end)

app.get("/typed", function(req, res)
    res.type("html").send("<p>typed response</p>")
end)

app.get("/redirect", function(req, res)
    res.redirect("/json")
end)

app.get("/redirect-301", function(req, res)
    res.redirect("/json", 301)
end)

app.get("/error", function()
    error("expected test error")
end)

app.get("/bad-header", function(req, res)
    res.headers["x-invalid"] = "ok\r\nInjected: yes"
    res.send("should not be sent")
end)

app.get("/slow", function(req, res)
    socket.sleep(0.25)
    res.send("slow response")
end)

app.get("/fast", function(req, res)
    res.send(req.query.id or "missing")
end)

app.post("/echo", function(req, res)
    res.status(201).send(req.body)
end)

app.put("/echo", function(req, res)
    res.status(202).send(req.body)
end)

app.delete("/resource", function(req, res)
    res.status(204).send("")
end)

app.listen(38081, "127.0.0.1")

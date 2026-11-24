local App = require("veloce.init")

local app = App.new()

app.use(function(req, res, next)
    res.headers["x-powered-by"] = "veloce"
    next()
end)

app.get("/", function(req, res)
    return res.status(200).json({
        message = "teste"
    })
end)

app.get("/json", function(req, res)
    res.json({ ok = true, n = 42, list = { 1, 2, 3 } })
end)

app.get("/search", function(req, res)
    res.json(req.query)
end)

app.get("/rota/com/barra/", function(req, res)
    res.send("barra final registrada, deve casar sem a barra tambem")
end)

app.post("/echo", function(req, res)
    res.type("txt")
    res.status(201)
    res.json({message = "teste"})
end)

app.get("/quebra", function(req, res)
    error("falha proposital para testar handler de erro")
end)

app.get("/redireciona", function(req, res)
    res.redirect("/destino")
end)

app.get("/redireciona-301", function(req, res)
    res.redirect("/destino", 301)
end)

app.get("/sem-resposta", function(req, res, next)
    -- handler que nao chama res.send/json/redirect: deve cair no 404 do functions.exe
end)

app.get("/status-desconhecido", function(req, res)
    res.status(499).send("codigo fora da tabela padrao")
end)

app.get("/header", function(req, res)
    res.send("header: " .. (req.get("x-teste") or "ausente"))
end)

app.listen(3000, "0.0.0.0",  function(port, host)
    print("Sever is running -> http://localhost:".. port)
    print("HOST : " .. host.. " PORT : " .. port)
end)
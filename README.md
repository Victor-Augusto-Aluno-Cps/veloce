# Veloce

Veloce is a small HTTP server framework for Lua 5.1+, LuaSocket and Lua Lanes.

## Concurrency

The server uses a pool of four OS threads by default, so up to four request
handlers execute at once. Additional requests wait in the bounded queue. Each
worker handles a request independently, so CPU-heavy handlers can run in
parallel. Change the pool size before starting the server with `app.workers(8)`
(valid range: 1–64).
Lua Lanes copies the routes, middleware and Lua handler closures into each
worker; mutable Lua state is therefore worker-local, not shared between threads.
Load Veloce before native modules used by handlers, then register those modules
with `app.workerRequires("module-name")` so Lanes can load them in each worker.

Workers publish responses to a bounded Lua Lanes Linda queue and signal the
event loop through a non-blocking UDP socket bound to loopback. The event loop
monitors that socket alongside client sockets with `socket.select`; each wake
drains all available results, so notifications may be coalesced without losing
responses. There is no timed polling for worker results, and the loop can sleep
until a socket event or the next client-idle deadline.

Request headers are limited to 16 KiB, request bodies to 1 MiB, and the server
keeps at most 256 clients active at a time. Connections idle for more than 30
seconds are closed.

The app's routes and middleware must be registered before calling `listen`.

## Tests

Run the unit and HTTP integration tests from the project root:

```sh
sh tests/run.sh
```

The integration suite runs with 1, 4 and 8 workers. It includes concurrent
response bursts, disconnects before a worker finishes, and the slow-handler
parallelism check.

For manual requests in VS Code's REST Client, start the example app with
`lua main.lua` and run the requests in [`tests/.http`](./tests/.http).

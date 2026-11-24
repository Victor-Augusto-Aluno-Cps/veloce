#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

lua tests/run.lua

server_log=
server_pid=

cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if [ -n "$server_log" ]; then
        rm -f "$server_log"
    fi
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

for workers in 1 4 8; do
    server_log=$(mktemp)
    VELOCE_TEST_WORKERS=$workers lua tests/server.lua >"$server_log" 2>&1 &
    server_pid=$!

    if ! VELOCE_TEST_WORKERS=$workers lua tests/integration.lua; then
        cat "$server_log" >&2
        exit 1
    fi

    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=
    rm -f "$server_log"
    server_log=

    printf 'Integration tests passed with %s worker(s).\n' "$workers"
done

printf '%s\n' "All Veloce tests passed."

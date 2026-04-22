# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**gleam_mcp** is a native MCP (Model Context Protocol) client library for Gleam — the first MCP client in the Gleam/BEAM ecosystem. It lets Gleam applications connect to MCP servers, discover tools, and invoke them via JSON-RPC 2.0 over STDIO.

## Commands

```sh
gleam build        # compile
gleam test         # run all tests (uses gleeunit + Python mock servers)
gleam docs build   # generate HexDocs
gleam clean        # remove build artifacts
```

To run a single test module, there is no built-in flag — filter by running `gleam test` and checking output; gleeunit runs all `*_test` functions discovered in the `test/` directory.

## Architecture

Three layers with clean contracts, allowing future transport swaps (HTTP/SSE) without touching manager logic:

### 1. Facade — `src/gleam_mcp.gleam`
Public API. Thin wrappers over the manager: `new()`, `register()`, `unregister()`, `servers()`, `tools()`, `call()`, `stop()`. Re-exports key types.

### 2. Manager — `src/gleam_mcp/manager.gleam`
OTP actor (gen_server semantics) that owns all server connections. Responsibilities:
- Maintains `Dict(name, ServerConnection)` and `Dict(qualified_name, Tool)`.
- Performs the MCP `initialize` handshake and validates protocol version (`2024-11-05`).
- Runs `tools/list` discovery on `register()`.
- Routes `tools/call` with monotonically-increasing request-id sequencing.
- Auto-evicts dead servers when the port actor crashes.

Key types: `ServerConfig`, `ToolSpec`, `Tool`, `McpManager` (an OTP `Subject`).

### 3. Transport — `src/gleam_mcp/transport.gleam`
STDIO transport actor. Spawns external processes via an Erlang port and speaks newline-delimited JSON-RPC 2.0. Uses a 1 MB line buffer to handle large responses without truncation. Intentionally does **not** capture stderr to avoid JSON parse failures from server log noise.

### 4. FFI — `src/gleam_mcp_ffi.erl`
Erlang code implementing the actual port operations: `open_port/3`, `send_and_receive/3`, `send_data/2`, `close_port/1`. Resolves executables from PATH via `os:find_executable/1`. Contains JSON string-escape utilities used by the transport layer.

## Tests

Tests live in `test/` and rely on Python mock MCP servers:
- `mock_mcp_server.py` — full server with `echo`, `list`, etc. tools
- `mock_mcp_server_crash.py` — exits after handshake (tests crash/eviction detection)
- `mock_mcp_server_old_version.py` — returns wrong protocol version (tests validation)

Test modules: `gleam_mcp_test.gleam` (facade), `manager_test.gleam` (manager + multi-server + crash), `transport_test.gleam` (raw JSON-RPC).

Python 3 must be available on PATH for tests to pass.

## Key design decisions

- **Qualified tool names** (`server_name/tool_name`) prevent collisions when multiple servers expose the same tool name.
- **Dead-server eviction**: when a port actor crashes, the manager removes that server and continues running.
- **Strict protocol version validation**: servers responding with a version other than `2024-11-05` are rejected at registration time.

## Roadmap (v0.2.0)

Planned features tracked in `PRD.md`: `resources/*` and `prompts/*` MCP primitives, auto-reconnection with exponential backoff, HTTP+SSE transport, full `///` doc comments on all public functions.

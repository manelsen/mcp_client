# gleam_mcp

[![Package Version](https://img.shields.io/hexpm/v/gleam_mcp)](https://hex.pm/packages/gleam_mcp)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/gleam_mcp/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![Target](https://img.shields.io/badge/target-erlang-red)](https://gleam.run)

**MCP (Model Context Protocol) client for Gleam — connect to any MCP server via JSON-RPC 2.0 over STDIO.**

---

## What is MCP?

The [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) is an open standard, introduced by Anthropic in late 2024, that defines how AI applications connect to external tools and data sources. It establishes a client–server architecture: a *host* (e.g. an LLM application) runs one or more *clients*, each connected to an *MCP server* that exposes capabilities (tools, resources, prompts) over a well-defined JSON-RPC 2.0 interface. Servers can be local processes launched over STDIO, or remote services reachable over HTTP/SSE. `gleam_mcp` implements the STDIO transport, which covers the vast majority of real-world MCP servers available today.

---

## Why gleam_mcp?

Before this package, there was **no MCP client library in the Gleam or BEAM ecosystem**. Developers who wanted to integrate MCP servers into a Gleam application had three unsatisfying choices:

1. Write raw JSON-RPC 2.0 strings and manage Erlang ports by hand — error-prone, not reusable.
2. Shell out to a Node.js or Python MCP SDK wrapper — adds runtime overhead and a process-management burden.
3. Skip MCP entirely and implement proprietary tool APIs — loses the growing ecosystem of ready-made MCP servers (GitHub, filesystem, search, databases, …).

`gleam_mcp` fills this gap with a pure-Gleam/BEAM solution: lightweight, OTP-supervised actors, no Node.js runtime required, and a three-layer architecture that keeps each concern cleanly separated.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Application code                                               │
│                                                                 │
│    import gleam_mcp                                             │
│    gleam_mcp.new() / .register() / .call() / .stop()           │
└──────────────────────────┬──────────────────────────────────────┘
                           │  thin wrappers
┌──────────────────────────▼──────────────────────────────────────┐
│  Facade  —  gleam_mcp.gleam                                     │
│                                                                 │
│  Exports:  Client  ServerConfig  Tool  ToolSpec                 │
│  Wraps:    manager.start / register / unregister                │
│            manager.list_servers / list_tools / execute_tool     │
└──────────────────────────┬──────────────────────────────────────┘
                           │  OTP actor (gen_server semantics)
┌──────────────────────────▼──────────────────────────────────────┐
│  Manager  —  gleam_mcp/manager.gleam                            │
│                                                                 │
│  • Maintains Dict(name, ServerConnection)                       │
│  • Maintains Dict(qualified_name, Tool)                         │
│  • MCP initialize handshake + protocol version validation       │
│  • tools/list discovery on registration                         │
│  • tools/call routing + request-id sequencing                   │
│  • Dead-server eviction on port crash                           │
└──────────────────────────┬──────────────────────────────────────┘
                           │  one StdioTransport actor per server
┌──────────────────────────▼──────────────────────────────────────┐
│  Transport  —  gleam_mcp/transport.gleam                        │
│                                                                 │
│  • Erlang port (spawn_executable + {line, 1 MB} + exit_status)  │
│  • send_and_receive / send_only (fire-and-forget notifications) │
│  • Controlled by gleam_mcp_ffi.erl (Erlang FFI)                │
└─────────────────────────────────────────────────────────────────┘
```

Each layer has a single responsibility. The transport knows nothing about MCP semantics — it only moves bytes. The manager speaks MCP but knows nothing about how the application uses the tools. The facade hides internal types and presents a stable public API.

---

## Quick start

Add the dependency to `gleam.toml`:

```toml
[dependencies]
gleam_mcp = ">= 0.1.0 and < 2.0.0"
```

Then:

```gleam
import gleam_mcp
import gleam/io
import gleam/list

pub fn main() {
  // 1. Create a client
  let assert Ok(client) = gleam_mcp.new()

  // 2. Register one or more MCP servers
  let assert Ok(Nil) = gleam_mcp.register(client, gleam_mcp.ServerConfig(
    name: "filesystem",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
    env: [],
  ))

  let assert Ok(Nil) = gleam_mcp.register(client, gleam_mcp.ServerConfig(
    name: "github",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-github"],
    env: [#("GITHUB_PERSONAL_ACCESS_TOKEN", "ghp_...")],
  ))

  // 3. Discover available tools (qualified as "server_name/tool_name")
  let tools = gleam_mcp.tools(client)
  let names = list.map(tools, fn(t) { t.spec.name })
  io.println("Available tools: " <> string.join(names, ", "))

  // 4. Call a tool
  let assert Ok(result) = gleam_mcp.call(
    client,
    "filesystem/list_directory",
    "{\"path\":\"/tmp\"}",
  )
  io.println(result)

  // 5. Clean up
  gleam_mcp.stop(client)
}
```

---

## API reference

### Types

| Type | Description |
|------|-------------|
| `Client` | Opaque handle to a running MCP client (alias for `McpManager` actor subject) |
| `ServerConfig` | Configuration for one MCP server (`name`, `command`, `args`, `env`) |
| `ToolSpec` | Tool name + description (`name: String`, `description: String`) |
| `Tool` | Discovered tool: `spec: ToolSpec`, `server_name: String`, `original_name: String` |

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `new` | `() -> Result(Client, actor.StartError)` | Start a new MCP client |
| `register` | `(Client, ServerConfig) -> Result(Nil, String)` | Connect to a server, handshake, discover tools |
| `unregister` | `(Client, String) -> Result(Nil, String)` | Disconnect from a server and remove its tools |
| `servers` | `(Client) -> List(String)` | Names of all registered servers (sorted) |
| `tools` | `(Client) -> List(Tool)` | All discovered tools across all servers |
| `call` | `(Client, String, String) -> Result(String, String)` | Execute a tool by qualified name with JSON args |
| `stop` | `(Client) -> Nil` | Shutdown client and all server processes |

**Tool name convention:** after `register/2`, every tool name is qualified as `"server_name/tool_name"`. This avoids collisions when multiple servers expose tools with the same bare name (e.g. both a filesystem and a GitHub server might offer a `"list"` tool). The `original_name` field on `Tool` holds the bare name as declared by the server.

### Lower-level modules

The `gleam_mcp/transport` and `gleam_mcp/manager` modules are also public if you need direct access to the transport or manager actors — for example, to build a custom routing layer.

---

## Protocol compliance

`gleam_mcp` implements the **MCP 2024-11-05** specification.

| Feature | Status |
|---------|--------|
| Transport | STDIO (newline-delimited JSON-RPC 2.0) |
| `initialize` request | Implemented — sends `protocolVersion`, `capabilities`, `clientInfo` |
| Protocol version validation | Strict — rejects servers that advertise unsupported versions |
| `notifications/initialized` | Sent after successful initialize |
| `tools/list` | Implemented — called automatically on registration |
| `tools/call` | Implemented — routes by qualified name, increments request-id |
| `resources/*` | Not implemented (planned) |
| `prompts/*` | Not implemented (planned) |
| HTTP/SSE transport | Not implemented (planned) |
| Server-sent notifications | Not implemented |

The client sends `clientInfo: {name: "gleam_mcp", version: "0.1.0"}` during the initialize handshake.

---

## Design decisions

### 1. Qualified tool names (`server_name/tool_name`)
Multiple MCP servers frequently expose tools with identical bare names (`read_file`, `search`, `list`). Qualifying every name with the server prefix at discovery time — rather than at call time — means the caller never has to think about which server a tool came from. The `original_name` field is preserved so the manager can use it when sending `tools/call` to the correct server.

### 2. Isolated stderr
Erlang ports opened with `spawn_executable` only capture stdout. MCP servers commonly write log messages and debug output to stderr. By not capturing stderr, those messages go directly to the OS process's stderr without polluting the JSON-RPC response stream. This was the cause of intermittent parse failures in early prototypes when servers emitted startup logs.

### 3. 1 MB line buffer (`{line, 1048576}`)
The MCP protocol sends each JSON-RPC message as a single newline-terminated line. Real-world tool responses (especially from filesystem and search servers) can exceed tens of kilobytes. Erlang's default `{line, N}` buffer of 1024 bytes would silently truncate these responses, producing parse errors. A 1 MB buffer safely handles all observed payloads; the `big_data` integration test verifies 8 KB responses are not truncated.

### 4. Dead-server eviction on port crash
If an MCP server process dies unexpectedly, the next `tools/call` returns an error containing "exited" or "Port not open". The manager detects this, removes the server and all its tools from state, and continues running. The client remains fully functional for other registered servers. This is tested with `mock_mcp_server_crash.py`, which exits immediately after the `tools/list` handshake.

### 5. Protocol version validation
The `initialize` response must contain `protocolVersion: "2024-11-05"`. Any other value causes `register/2` to return `Error(...)` and the transport is stopped. This prevents silently operating against incompatible servers that might behave differently. New versions can be supported by updating `supported_protocol_versions/0` in `manager.gleam`.

### 6. Three-layer separation
Transport, manager, and facade are separate modules with clear contracts. This makes it possible to swap the transport (e.g. add HTTP/SSE) without touching the manager, and to change the public API without touching protocol logic. It also simplifies testing: transport tests use raw JSON-RPC strings; manager tests use the full MCP handshake; facade tests verify delegation only.

---

## Tested against real MCP servers

The following production MCP servers have been used with this client:

| Server | Package | Notes |
|--------|---------|-------|
| GitHub MCP | `@modelcontextprotocol/server-github` | Tool discovery + `search_repositories`, `create_issue` |
| Filesystem MCP | `@modelcontextprotocol/server-filesystem` | `read_file`, `list_directory`, `write_file` |
| Shell Server (fastmcp) | `mcp-server-shell` via `fastmcp` | Custom tool execution via shell commands |
| Brave Search MCP | `@modelcontextprotocol/server-brave-search` | `brave_web_search` with API key via env |

All servers were registered, tools discovered, and tools invoked successfully with `gleam_mcp 0.1.0`.

---

## Extraction origin

`gleam_mcp` was extracted from [Supernova](https://github.com/manelsen/supernova), a Gleam-based AI assistant runtime. The MCP client layer was originally written as `supernova/adapters/mcp/stdio`, `supernova/adapters/mcp_manager`, and `supernova_mcp_ffi.erl`. It was promoted to a standalone package to make it reusable by any Gleam project that needs MCP connectivity.

---

## License

Apache-2.0. See [LICENSE](LICENSE).

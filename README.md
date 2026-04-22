# mcp_client

[![Package Version](https://img.shields.io/hexpm/v/mcp_client)](https://hex.pm/packages/mcp_client)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/mcp_client/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![Target](https://img.shields.io/badge/target-erlang-red)](https://gleam.run)

**MCP (Model Context Protocol) client for Gleam — connect to any MCP server via JSON-RPC 2.0 over STDIO.**

---

## What is MCP?

The [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) is an open standard introduced by Anthropic in late 2024 that defines how AI applications connect to external tools and data sources. A *host* (e.g. an LLM application) runs one or more *clients*, each connected to an *MCP server* that exposes capabilities — tools, resources, and prompts — over a JSON-RPC 2.0 interface. Servers can be local processes launched over STDIO, or remote services reachable over HTTP/SSE. `mcp_client` implements the STDIO transport, which covers the vast majority of real-world MCP servers available today.

---

## Why mcp_client?

Before this package, there was **no MCP client library in the Gleam or BEAM ecosystem**. Developers who wanted to integrate MCP servers into a Gleam application had three unsatisfying choices:

1. Write raw JSON-RPC 2.0 strings and manage Erlang ports by hand — error-prone, not reusable.
2. Shell out to a Node.js or Python MCP SDK wrapper — adds runtime overhead and a process-management burden.
3. Skip MCP entirely and implement proprietary tool APIs — loses the growing ecosystem of ready-made MCP servers (GitHub, filesystem, search, databases, …).

`mcp_client` fills this gap with a pure-Gleam/BEAM solution: lightweight OTP-supervised actors, no Node.js runtime required, and a three-layer architecture that keeps each concern cleanly separated.

---

## Quick start

Add the dependency to `gleam.toml`:

```toml
[dependencies]
mcp_client = ">= 0.1.0 and < 2.0.0"
```

Then:

```gleam
import mcp_client
import gleam/dict
import gleam/io

pub fn main() {
  let assert Ok(client) = mcp_client.new()

  let assert Ok(Nil) = mcp_client.register(client, mcp_client.ServerConfig(
    name: "filesystem",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
    env: [],
    retry: mcp_client.retry(max_attempts: 3, base_delay_ms: 500),
  ))

  // Call a tool
  let assert Ok(result) = mcp_client.call(
    client, "filesystem/list_directory", "{\"path\":\"/tmp\"}",
  )
  io.println(result)

  // Read a resource
  let assert Ok(content) = mcp_client.read(client, "filesystem", "file:///tmp/hello.txt")
  io.println(content)

  mcp_client.stop(client)
}
```

---

## API reference

### Types

| Type | Description |
|------|-------------|
| `Client` | Opaque handle to a running MCP client |
| `ServerConfig` | Server config: `name`, `command`, `args`, `env`, `retry` |
| `RetryPolicy` | `NoRetry` or `Retry(max_attempts, base_delay_ms)` |
| `ToolSpec` | Tool name + description |
| `Tool` | Discovered tool: `spec`, `server_name`, `original_name` |
| `Resource` | Discovered resource: `uri`, `name`, `description`, `server_name` |
| `PromptArg` | Prompt argument definition: `name`, `description`, `required` |
| `Prompt` | Discovered prompt template: `name`, `description`, `server_name`, `arguments` |

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `new` | `() -> Result(Client, _)` | Start a new MCP client |
| `stop` | `(Client) -> Nil` | Shutdown client and all server processes |
| `register` | `(Client, ServerConfig) -> Result(Nil, String)` | Connect to a server; discovers tools, resources, and prompts |
| `unregister` | `(Client, String) -> Result(Nil, String)` | Disconnect from a server; removes all its capabilities |
| `servers` | `(Client) -> List(String)` | Names of all registered servers |
| `tools` | `(Client) -> List(Tool)` | All discovered tools across all servers |
| `call` | `(Client, String, String) -> Result(String, String)` | Execute a tool by qualified name (`"server/tool"`) with JSON args |
| `resources` | `(Client) -> List(Resource)` | All discovered resources across all servers |
| `read` | `(Client, String, String) -> Result(String, String)` | Read a resource by server name + URI |
| `prompts` | `(Client) -> List(Prompt)` | All discovered prompt templates across all servers |
| `prompt` | `(Client, String, String, Dict(String,String)) -> Result(String, String)` | Render a prompt by server name + prompt name + args |
| `no_retry` | `RetryPolicy` | Constant — evict server on crash, no reconnection |
| `retry` | `(Int, Int) -> RetryPolicy` | Retry with exponential backoff: `retry(max_attempts, base_delay_ms)` |

### Return values

All three call functions (`call`, `read`, `prompt`) return `Result(String, String)` where the `Ok` value is the raw JSON string of the `result` field from the JSON-RPC 2.0 response. Callers parse it however they need; `gleam_json` is the natural choice.

### Tool name convention

After `register`, every tool name is qualified as `"server_name/tool_name"`. This prevents collisions when multiple servers expose tools with the same bare name. The `original_name` field on `Tool` holds the bare name as declared by the server.

---

## Retry and reconnection

When an MCP server crashes, the default behaviour (`NoRetry`) is to evict it from state — subsequent calls to its tools return `Error`. With a `Retry` policy, the manager automatically tries to reconnect with exponential backoff before evicting:

```gleam
// Retry up to 3 times: sleeps 500ms, 1000ms, 2000ms between attempts
retry: mcp_client.retry(max_attempts: 3, base_delay_ms: 500)

// No reconnection — evict immediately on crash
retry: mcp_client.no_retry
```

The specific call that triggered the crash still returns `Error` (the response was lost). Subsequent calls on the same server succeed once reconnection completes. If all attempts fail, the server is evicted and the manager remains operational for other servers.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Application code                                               │
│    mcp_client.new() / register() / call() / read() / prompt()   │
└──────────────────────────┬──────────────────────────────────────┘
                           │  thin wrappers
┌──────────────────────────▼──────────────────────────────────────┐
│  Facade  —  mcp_client.gleam                                     │
│  Exports: Client  ServerConfig  RetryPolicy                     │
│           Tool  Resource  Prompt  PromptArg                     │
└──────────────────────────┬──────────────────────────────────────┘
                           │  OTP actor (gen_server semantics)
┌──────────────────────────▼──────────────────────────────────────┐
│  Manager  —  mcp_client/manager.gleam                            │
│  • Dict(name, ServerConnection) + Dict(qualified, Tool)         │
│  • List(Resource) + List(Prompt) per registered server          │
│  • MCP initialize handshake + protocol version validation       │
│  • tools/list · resources/list · prompts/list on registration   │
│  • tools/call · resources/read · prompts/get routing            │
│  • Crash detection → eviction or exponential-backoff reconnect  │
└──────────────────────────┬──────────────────────────────────────┘
                           │  one StdioTransport actor per server
┌──────────────────────────▼──────────────────────────────────────┐
│  Transport  —  mcp_client/transport.gleam                        │
│  • Erlang port (spawn_executable + {line, 1 MB} + exit_status)  │
│  • send_and_receive / send_only                                 │
│  • Backed by mcp_client_ffi.erl                                  │
└─────────────────────────────────────────────────────────────────┘
```

Each layer has a single responsibility. The transport knows nothing about MCP semantics — it only moves bytes. The manager speaks MCP but knows nothing about how the application uses the results. The facade hides internal types and presents a stable public API.

---

## Protocol compliance

`mcp_client` implements the **MCP 2024-11-05** specification.

| Feature | Status |
|---------|--------|
| Transport | STDIO (newline-delimited JSON-RPC 2.0) |
| `initialize` / `notifications/initialized` | ✅ |
| Protocol version validation | ✅ Strict — rejects unsupported versions |
| `tools/list` + `tools/call` | ✅ |
| `resources/list` + `resources/read` | ✅ |
| `prompts/list` + `prompts/get` | ✅ |
| Auto-reconnection with exponential backoff | ✅ |
| HTTP/SSE transport (MCP 2025-03-26) | Not implemented — planned for v0.3.0 |
| Server-sent notifications | Not implemented |

---

## Design decisions

### Qualified tool names (`server_name/tool_name`)
Multiple MCP servers frequently expose tools with identical bare names (`read_file`, `search`, `list`). Qualifying every name with the server prefix at discovery time means the caller never has to think about which server a tool came from. `original_name` is preserved so the manager can use it in `tools/call`.

### Isolated stderr
Erlang ports opened with `spawn_executable` only capture stdout. MCP servers commonly write logs to stderr. By not capturing stderr, those messages reach the OS without polluting the JSON-RPC response stream — the root cause of intermittent parse failures in early prototypes.

### 1 MB line buffer (`{line, 1048576}`)
The MCP protocol sends each JSON-RPC message as a single newline-terminated line. Real-world tool responses (filesystem listings, search results) can exceed tens of kilobytes. Erlang's default `{line, 1024}` would silently truncate them. The `big_data` integration test verifies 8 KB responses are not truncated.

### Dead-server eviction / reconnection
If a server process dies, the next call returns an error containing "exited" or equivalent. With `NoRetry` the server is evicted immediately; with `Retry` the manager sleeps and re-runs the full connection sequence (initialize → tools/list → resources/list → prompts/list). Reconnection is synchronous inside the manager actor, so the client is briefly paused during backoff. The specific call that triggered the crash still returns `Error`; subsequent calls succeed on the restored connection.

### `attempt_connection` as the single connection entry point
Both initial registration and reconnection go through `attempt_connection/1`, which starts the transport, runs the initialize handshake, and discovers all three capability types. This guarantees consistent state after reconnection — tools, resources, and prompts are always re-fetched together.

### Three-layer separation
Transport, manager, and facade are separate modules with clear contracts. Adding HTTP/SSE transport in v0.3.0 will not require touching manager or facade code. Transport tests use raw JSON-RPC strings; manager tests run the full MCP handshake; facade tests verify delegation only.

---

## Tested against real MCP servers

The following production MCP servers have been used with this client:

| Server | Package | Notes |
|--------|---------|-------|
| GitHub MCP | `@modelcontextprotocol/server-github` | Tool discovery + `search_repositories`, `create_issue` |
| Filesystem MCP | `@modelcontextprotocol/server-filesystem` | `read_file`, `list_directory`, `write_file` |
| Shell Server (fastmcp) | `mcp-server-shell` via `fastmcp` | Custom tool execution via shell commands |
| Brave Search MCP | `@modelcontextprotocol/server-brave-search` | `brave_web_search` with API key via env |

---

## Extraction origin

`mcp_client` was extracted from [Supernova](https://github.com/manelsen/supernova), a Gleam-based AI assistant runtime. The MCP client layer was originally written as `supernova/adapters/mcp/stdio`, `supernova/adapters/mcp_manager`, and `supernova_mcp_ffi.erl`. It was promoted to a standalone package to make it reusable by any Gleam project that needs MCP connectivity.

---

## License

Apache-2.0. See [LICENSE](LICENSE).

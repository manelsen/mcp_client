//// gleam_mcp — MCP (Model Context Protocol) client for Gleam.
////
//// This is the public facade for the gleam_mcp package.
//// It provides a simple, ergonomic API for connecting to MCP servers,
//// discovering tools, and invoking them via JSON-RPC 2.0 over STDIO.
////
//// ## Quick start
////
//// ```gleam
//// import gleam_mcp
////
//// pub fn main() {
////   // Start a client
////   let assert Ok(client) = gleam_mcp.new()
////
////   // Register an MCP server
////   let config = gleam_mcp.ServerConfig(
////     name: "filesystem",
////     command: "npx",
////     args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
////     env: [],
////   )
////   let assert Ok(Nil) = gleam_mcp.register(client, config)
////
////   // Discover available tools
////   let tools = gleam_mcp.tools(client)
////
////   // Call a tool
////   let assert Ok(result) = gleam_mcp.call(client, "filesystem/list_directory", "{\"path\":\"/tmp\"}")
////
////   // Clean up
////   gleam_mcp.stop(client)
//// }
//// ```

import gleam/otp/actor
import gleam_mcp/manager

// ============================================================================
// Re-exported types
// ============================================================================

/// Configuration for an MCP server connection.
pub type ServerConfig =
  manager.ServerConfig

/// A minimal tool specification (name + description).
pub type ToolSpec =
  manager.ToolSpec

/// A discovered tool from an MCP server.
/// `tool.spec.name` is the qualified name: `"server_name/tool_name"`.
/// `tool.original_name` is the bare name as declared by the server.
pub type Tool =
  manager.Tool

/// An MCP client handle (opaque actor subject).
pub type Client =
  manager.McpManager

// ============================================================================
// Public API
// ============================================================================

/// Create a new MCP client.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(client) = gleam_mcp.new()
/// ```
pub fn new() -> Result(Client, actor.StartError) {
  manager.start()
}

/// Register an MCP server and perform the initialize handshake.
///
/// Starts the server process, runs the MCP initialize sequence,
/// and discovers all available tools. The tools become addressable
/// as `"server_name/tool_name"`.
///
/// ## Example
///
/// ```gleam
/// let config = gleam_mcp.ServerConfig(
///   name: "github",
///   command: "npx",
///   args: ["-y", "@modelcontextprotocol/server-github"],
///   env: [#("GITHUB_PERSONAL_ACCESS_TOKEN", "ghp_...")],
/// )
/// let assert Ok(Nil) = gleam_mcp.register(client, config)
/// ```
pub fn register(client: Client, config: ServerConfig) -> Result(Nil, String) {
  manager.register(client, config)
}

/// Unregister an MCP server and stop its process.
///
/// Also removes all tools discovered from that server.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(Nil) = gleam_mcp.unregister(client, "github")
/// ```
pub fn unregister(client: Client, name: String) -> Result(Nil, String) {
  manager.unregister(client, name)
}

/// List the names of all currently registered servers.
///
/// ## Example
///
/// ```gleam
/// let names = gleam_mcp.servers(client)
/// // ["filesystem", "github"]
/// ```
pub fn servers(client: Client) -> List(String) {
  manager.list_servers(client)
}

/// List all tools discovered across all registered servers.
///
/// Tool names are qualified: `"server_name/tool_name"`.
///
/// ## Example
///
/// ```gleam
/// let tools = gleam_mcp.tools(client)
/// let tool_names = list.map(tools, fn(t) { t.spec.name })
/// ```
pub fn tools(client: Client) -> List(Tool) {
  manager.list_tools(client)
}

/// Call a tool by its qualified name with JSON-encoded arguments.
///
/// The `tool` argument must match the qualified name returned by `tools/0`,
/// i.e. `"server_name/tool_name"`. The `args` parameter is a JSON object
/// string matching the tool's input schema.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(result) = gleam_mcp.call(
///   client,
///   "filesystem/read_file",
///   "{\"path\":\"/etc/hostname\"}",
/// )
/// ```
pub fn call(
  client: Client,
  tool: String,
  args: String,
) -> Result(String, String) {
  manager.execute_tool(client, tool, args)
}

/// Stop the client and all server connections.
///
/// ## Example
///
/// ```gleam
/// gleam_mcp.stop(client)
/// ```
pub fn stop(client: Client) -> Nil {
  manager.stop(client)
}

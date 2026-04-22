//// gleam_mcp — MCP (Model Context Protocol) client for Gleam.
////
//// Public facade for the gleam_mcp package. Provides an ergonomic API for
//// connecting to MCP servers, discovering tools/resources/prompts, and
//// invoking them via JSON-RPC 2.0 over STDIO.
////
//// ## Quick start
////
//// ```gleam
//// import mcp_client
//// import gleam/dict
////
//// pub fn main() {
////   let assert Ok(client) = gleam_mcp.new()
////
////   let config = gleam_mcp.ServerConfig(
////     name: "filesystem",
////     command: "npx",
////     args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
////     env: [],
////     retry: gleam_mcp.no_retry,
////   )
////   let assert Ok(Nil) = gleam_mcp.register(client, config)
////
////   let tools = gleam_mcp.tools(client)
////   let assert Ok(result) = gleam_mcp.call(client, "filesystem/list_directory", "{\"path\":\"/tmp\"}")
////
////   gleam_mcp.stop(client)
//// }
//// ```

import gleam/dict
import gleam/otp/actor
import mcp_client/manager

// ============================================================================
// Re-exported types
// ============================================================================

/// Configuration for an MCP server connection.
pub type ServerConfig =
  manager.ServerConfig

/// Retry policy applied when a server process crashes.
pub type RetryPolicy =
  manager.RetryPolicy

/// A minimal tool specification (name + description).
pub type ToolSpec =
  manager.ToolSpec

/// A discovered tool from an MCP server.
/// `tool.spec.name` is the qualified name: `"server_name/tool_name"`.
/// `tool.original_name` is the bare name as declared by the server.
pub type Tool =
  manager.Tool

/// A discovered resource from an MCP server.
pub type Resource =
  manager.Resource

/// An argument definition for an MCP prompt.
pub type PromptArg =
  manager.PromptArg

/// A discovered prompt template from an MCP server.
pub type Prompt =
  manager.Prompt

/// An MCP client handle (opaque actor subject).
pub type Client =
  manager.McpManager

// ============================================================================
// RetryPolicy constructors
// ============================================================================

/// Do not retry on server crash — remove the server from state immediately.
pub const no_retry: RetryPolicy = manager.NoRetry

/// Retry on server crash with exponential backoff.
///
/// ## Example
///
/// ```gleam
/// gleam_mcp.retry(max_attempts: 3, base_delay_ms: 500)
/// ```
pub fn retry(max_attempts: Int, base_delay_ms: Int) -> RetryPolicy {
  manager.Retry(max_attempts: max_attempts, base_delay_ms: base_delay_ms)
}

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
/// Starts the server process, runs the MCP initialize sequence, and discovers
/// all available tools, resources, and prompts.
///
/// ## Example
///
/// ```gleam
/// let config = gleam_mcp.ServerConfig(
///   name: "github",
///   command: "npx",
///   args: ["-y", "@modelcontextprotocol/server-github"],
///   env: [#("GITHUB_PERSONAL_ACCESS_TOKEN", "ghp_...")],
///   retry: gleam_mcp.retry(3, 500),
/// )
/// let assert Ok(Nil) = gleam_mcp.register(client, config)
/// ```
pub fn register(client: Client, config: ServerConfig) -> Result(Nil, String) {
  manager.register(client, config)
}

/// Unregister an MCP server and stop its process.
///
/// Also removes all tools, resources, and prompts discovered from that server.
pub fn unregister(client: Client, name: String) -> Result(Nil, String) {
  manager.unregister(client, name)
}

/// List the names of all currently registered servers.
pub fn servers(client: Client) -> List(String) {
  manager.list_servers(client)
}

/// List all tools discovered across all registered servers.
///
/// Tool names are qualified: `"server_name/tool_name"`.
pub fn tools(client: Client) -> List(Tool) {
  manager.list_tools(client)
}

/// Call a tool by its qualified name with JSON-encoded arguments.
///
/// The `tool` argument must be `"server_name/tool_name"`. The `args` parameter
/// is a JSON object string matching the tool's input schema. Returns the raw
/// JSON result string.
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

/// List all resources discovered across all registered servers.
pub fn resources(client: Client) -> List(Resource) {
  manager.list_resources(client)
}

/// Read a resource by URI from a named server.
///
/// Returns the raw JSON result string from the `resources/read` response.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(result) = gleam_mcp.read(client, "filesystem", "file:///etc/hostname")
/// ```
pub fn read(
  client: Client,
  server: String,
  uri: String,
) -> Result(String, String) {
  manager.read_resource(client, server, uri)
}

/// List all prompt templates discovered across all registered servers.
pub fn prompts(client: Client) -> List(Prompt) {
  manager.list_prompts(client)
}

/// Get a rendered prompt from a named server.
///
/// `args` is a `Dict(String, String)` of argument name → value pairs.
/// Returns the raw JSON result string from the `prompts/get` response.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(result) = gleam_mcp.prompt(
///   client, "myserver", "summarize",
///   dict.from_list([#("text", "Hello world")]),
/// )
/// ```
pub fn prompt(
  client: Client,
  server: String,
  name: String,
  args: dict.Dict(String, String),
) -> Result(String, String) {
  manager.get_prompt(client, server, name, args)
}

/// Stop the client and all server connections.
pub fn stop(client: Client) -> Nil {
  manager.stop(client)
}

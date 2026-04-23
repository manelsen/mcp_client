//// MCP Manager — manages multiple MCP server connections.
////
//// Provides unified tool, resource, and prompt discovery and execution
//// across multiple MCP servers. Each server is configured with a command
//// and args; the manager handles lifecycle, discovery, and routing via
//// JSON-RPC 2.0 over STDIO.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(mgr) = manager.start()
//// let config = manager.ServerConfig(name: "fs", command: "npx", args: [...], env: [], retry: manager.NoRetry)
//// manager.register(mgr, config)
//// ```

import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import mcp_client/transport.{type StdioTransport}

// ============================================================================
// Types
// ============================================================================

/// Retry policy applied when a server process crashes.
pub type RetryPolicy {
  /// Remove the server from state immediately on crash.
  NoRetry
  /// Retry up to `max_attempts` times with exponential backoff starting at
  /// `base_delay_ms` milliseconds.
  Retry(max_attempts: Int, base_delay_ms: Int)
}

/// Configuration for an MCP server connection.
pub type ServerConfig {
  ServerConfig(
    /// Unique name for this server.
    name: String,
    /// Command to execute (e.g. "npx", "node", "python3").
    command: String,
    /// Command arguments.
    args: List(String),
    /// Environment variables.
    env: List(#(String, String)),
    /// What to do if the server process crashes.
    retry: RetryPolicy,
  )
}

/// Minimal tool specification (name + description).
pub type ToolSpec {
  ToolSpec(name: String, description: String)
}

/// A discovered tool from an MCP server.
pub type Tool {
  Tool(
    /// Qualified name: "server_name/tool_name".
    spec: ToolSpec,
    /// Which server provides this tool.
    server_name: String,
    /// Original tool name as declared by the MCP server.
    original_name: String,
  )
}

/// A discovered resource from an MCP server.
pub type Resource {
  Resource(
    /// Resource URI (e.g. "file:///path/to/file").
    uri: String,
    /// Human-readable name.
    name: String,
    /// Human-readable description.
    description: String,
    /// Which server provides this resource.
    server_name: String,
  )
}

/// An argument definition for an MCP prompt.
pub type PromptArg {
  PromptArg(name: String, description: String, required: Bool)
}

/// A discovered prompt template from an MCP server.
pub type Prompt {
  Prompt(
    /// Prompt name.
    name: String,
    /// Human-readable description.
    description: String,
    /// Which server provides this prompt.
    server_name: String,
    /// Argument definitions.
    arguments: List(PromptArg),
  )
}

/// An active MCP server connection.
type ServerConnection {
  ServerConnection(
    config: ServerConfig,
    transport: StdioTransport,
    initialized: Bool,
    request_id: Int,
    manager: McpManager,
  )
}

/// Messages for the manager actor.
pub type ManagerMessage {
  RegisterServer(
    reply_to: Subject(Result(Nil, String)),
    config: ServerConfig,
    manager: McpManager,
  )
  UnregisterServer(reply_to: Subject(Result(Nil, String)), name: String)
  ListServers(reply_to: Subject(List(String)))
  GetServerConfig(reply_to: Subject(Result(ServerConfig, String)), name: String)
  ListTools(reply_to: Subject(List(Tool)))
  ExecuteTool(
    reply_to: Subject(Result(String, String)),
    tool_name: String,
    args: String,
  )
  ListResources(reply_to: Subject(List(Resource)))
  ReadResource(
    reply_to: Subject(Result(String, String)),
    server_name: String,
    uri: String,
  )
  ListPrompts(reply_to: Subject(List(Prompt)))
  GetPrompt(
    reply_to: Subject(Result(String, String)),
    server_name: String,
    name: String,
    args: Dict(String, String),
  )
  SubscribeResource(
    reply_to: Subject(Result(Nil, String)),
    server_name: String,
    uri: String,
  )
  UnsubscribeResource(
    reply_to: Subject(Result(Nil, String)),
    server_name: String,
    uri: String,
  )
  /// Internal: a server-sent notification was received from a transport.
  ServerNotification(server_name: String, raw_json: String)
  Stop(reply_to: Subject(Nil))
}

/// Manager state.
type ManagerState {
  ManagerState(
    servers: Dict(String, ServerConnection),
    tools: Dict(String, Tool),
    resources: List(Resource),
    prompts: List(Prompt),
  )
}

/// The manager handle.
pub type McpManager =
  Subject(ManagerMessage)

// ============================================================================
// JSON-RPC 2.0 Helpers
// ============================================================================

fn jsonrpc_request(id: Int, method: String, params: json.Json) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(id)),
    #("method", json.string(method)),
    #("params", params),
  ])
  |> json.to_string
}

fn jsonrpc_notification(method: String, params: json.Json) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string(method)),
    #("params", params),
  ])
  |> json.to_string
}

// ============================================================================
// MCP Protocol: Initialize
// ============================================================================

fn initialize_params() -> json.Json {
  json.object([
    #("protocolVersion", json.string("2024-11-05")),
    #("capabilities", json.object([])),
    #(
      "clientInfo",
      json.object([
        #("name", json.string("mcp_client")),
        #("version", json.string("0.1.0")),
      ]),
    ),
  ])
}

fn supported_protocol_versions() -> List(String) {
  ["2024-11-05"]
}

fn protocol_version_decoder() -> decode.Decoder(String) {
  use version <- decode.field("protocolVersion", decode.string)
  decode.success(version)
}

fn validate_protocol_version(result_json: String) -> Result(Nil, String) {
  case json.parse(result_json, protocol_version_decoder()) {
    Ok(version) ->
      case list.contains(supported_protocol_versions(), version) {
        True -> Ok(Nil)
        False -> Error("Unsupported MCP protocol version: " <> version)
      }
    Error(_) -> Error("Missing protocolVersion in initialize response")
  }
}

fn send_initialize(t: StdioTransport, id: Int) -> Result(Nil, String) {
  let request = jsonrpc_request(id, "initialize", initialize_params())
  case transport.send_and_receive(t, request, 10_000) {
    Ok(response) ->
      case parse_jsonrpc_result(response) {
        Ok(result_json) ->
          case validate_protocol_version(result_json) {
            Error(e) -> Error(e)
            Ok(_) -> {
              let notification =
                jsonrpc_notification(
                  "notifications/initialized",
                  json.object([]),
                )
              case transport.send_only(t, notification) {
                Ok(_) -> Ok(Nil)
                Error(e) -> Error("Failed to send initialized: " <> e)
              }
            }
          }
        Error(e) -> Error("Initialize failed: " <> e)
      }
    Error(e) -> Error("Initialize timeout/error: " <> e)
  }
}

// ============================================================================
// MCP Protocol: Tools
// ============================================================================

fn send_tools_list(
  t: StdioTransport,
  id: Int,
  server_name: String,
) -> Result(List(Tool), String) {
  let request = jsonrpc_request(id, "tools/list", json.object([]))
  case transport.send_and_receive(t, request, 10_000) {
    Ok(response) ->
      case parse_jsonrpc_result(response) {
        Ok(result_json) -> parse_tools_response(result_json, server_name)
        Error(e) -> Error("tools/list failed: " <> e)
      }
    Error(e) -> Error("tools/list timeout/error: " <> e)
  }
}

fn parse_tools_response(
  raw: String,
  server_name: String,
) -> Result(List(Tool), String) {
  case json.parse(raw, tools_list_decoder(server_name)) {
    Ok(tools) -> Ok(tools)
    Error(_) -> Ok([])
  }
}

fn tools_list_decoder(server_name: String) -> decode.Decoder(List(Tool)) {
  use tools <- decode.field("tools", decode.list(tool_decoder(server_name)))
  decode.success(tools)
}

fn tool_decoder(server_name: String) -> decode.Decoder(Tool) {
  use name <- decode.field("name", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  let qualified_name = server_name <> "/" <> name
  let spec = ToolSpec(name: qualified_name, description: description)
  decode.success(Tool(spec: spec, server_name: server_name, original_name: name))
}

fn send_tools_call(
  t: StdioTransport,
  id: Int,
  tool_name: String,
  args: String,
) -> Result(String, String) {
  // `args` is caller-supplied pre-serialized JSON; embed it raw.
  let request =
    "{\"jsonrpc\":\"2.0\",\"id\":"
    <> int.to_string(id)
    <> ",\"method\":\"tools/call\",\"params\":{\"name\":"
    <> json.to_string(json.string(tool_name))
    <> ",\"arguments\":"
    <> args
    <> "}}"
  case transport.send_and_receive(t, request, 30_000) {
    Ok(response) ->
      case parse_jsonrpc_result(response) {
        Ok(result_json) -> Ok(result_json)
        Error(e) -> Error("tools/call failed: " <> e)
      }
    Error(e) -> Error("tools/call timeout/error: " <> e)
  }
}

// ============================================================================
// MCP Protocol: Resources
// ============================================================================

fn send_resources_list(
  t: StdioTransport,
  id: Int,
  server_name: String,
) -> Result(List(Resource), String) {
  let request = jsonrpc_request(id, "resources/list", json.object([]))
  case transport.send_and_receive(t, request, 10_000) {
    Ok(response) ->
      case parse_jsonrpc_result(response) {
        Ok(result_json) -> parse_resources_response(result_json, server_name)
        Error(e) -> Error("resources/list failed: " <> e)
      }
    Error(e) -> Error("resources/list timeout/error: " <> e)
  }
}

fn parse_resources_response(
  raw: String,
  server_name: String,
) -> Result(List(Resource), String) {
  case json.parse(raw, resources_list_decoder(server_name)) {
    Ok(resources) -> Ok(resources)
    Error(_) -> Ok([])
  }
}

fn resources_list_decoder(server_name: String) -> decode.Decoder(List(Resource)) {
  use resources <- decode.field(
    "resources",
    decode.list(resource_decoder(server_name)),
  )
  decode.success(resources)
}

fn resource_decoder(server_name: String) -> decode.Decoder(Resource) {
  use uri <- decode.field("uri", decode.string)
  use name <- decode.optional_field("name", uri, decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  decode.success(Resource(
    uri: uri,
    name: name,
    description: description,
    server_name: server_name,
  ))
}

fn send_resources_read(
  t: StdioTransport,
  id: Int,
  uri: String,
) -> Result(String, String) {
  let params = json.object([#("uri", json.string(uri))])
  let request = jsonrpc_request(id, "resources/read", params)
  case transport.send_and_receive(t, request, 30_000) {
    Ok(response) ->
      case parse_jsonrpc_result(response) {
        Ok(result_json) -> Ok(result_json)
        Error(e) -> Error("resources/read failed: " <> e)
      }
    Error(e) -> Error("resources/read timeout/error: " <> e)
  }
}

// ============================================================================
// MCP Protocol: Prompts
// ============================================================================

fn send_prompts_list(
  t: StdioTransport,
  id: Int,
  server_name: String,
) -> Result(List(Prompt), String) {
  let request = jsonrpc_request(id, "prompts/list", json.object([]))
  case transport.send_and_receive(t, request, 10_000) {
    Ok(response) ->
      case parse_jsonrpc_result(response) {
        Ok(result_json) -> parse_prompts_response(result_json, server_name)
        Error(e) -> Error("prompts/list failed: " <> e)
      }
    Error(e) -> Error("prompts/list timeout/error: " <> e)
  }
}

fn parse_prompts_response(
  raw: String,
  server_name: String,
) -> Result(List(Prompt), String) {
  case json.parse(raw, prompts_list_decoder(server_name)) {
    Ok(prompts) -> Ok(prompts)
    Error(_) -> Ok([])
  }
}

fn prompts_list_decoder(server_name: String) -> decode.Decoder(List(Prompt)) {
  use prompts <- decode.field(
    "prompts",
    decode.list(prompt_decoder(server_name)),
  )
  decode.success(prompts)
}

fn prompt_arg_decoder() -> decode.Decoder(PromptArg) {
  use name <- decode.field("name", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use required <- decode.optional_field("required", False, decode.bool)
  decode.success(PromptArg(
    name: name,
    description: description,
    required: required,
  ))
}

fn prompt_decoder(server_name: String) -> decode.Decoder(Prompt) {
  use name <- decode.field("name", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use arguments <- decode.optional_field(
    "arguments",
    [],
    decode.list(prompt_arg_decoder()),
  )
  decode.success(Prompt(
    name: name,
    description: description,
    server_name: server_name,
    arguments: arguments,
  ))
}

fn send_prompts_get(
  t: StdioTransport,
  id: Int,
  name: String,
  args: Dict(String, String),
) -> Result(String, String) {
  let params =
    json.object([
      #("name", json.string(name)),
      #(
        "arguments",
        json.object(
          dict.to_list(args) |> list.map(fn(kv) { #(kv.0, json.string(kv.1)) }),
        ),
      ),
    ])
  let request = jsonrpc_request(id, "prompts/get", params)
  case transport.send_and_receive(t, request, 30_000) {
    Ok(response) ->
      case parse_jsonrpc_result(response) {
        Ok(result_json) -> Ok(result_json)
        Error(e) -> Error("prompts/get failed: " <> e)
      }
    Error(e) -> Error("prompts/get timeout/error: " <> e)
  }
}

// ============================================================================
// Connection lifecycle
// ============================================================================

/// Start a transport with notification forwarding, run the MCP initialize
/// handshake, and discover all tools, resources, and prompts.
/// Returns the live transport, forwarder, and discovered items.
/// On failure, the transport is stopped before returning Error.
fn attempt_connection(
  config: ServerConfig,
  manager_subject: McpManager,
) -> Result(
  #(StdioTransport, Subject(String), List(Tool), List(Resource), List(Prompt)),
  String,
) {
  let forwarder = start_notification_forwarder(manager_subject, config.name)
  case
    transport.start_with_notifications(
      config.command,
      config.args,
      config.env,
      forwarder,
    )
  {
    Ok(t) ->
      case send_initialize(t, 1) {
        Ok(_) -> {
          let tools =
            send_tools_list(t, 2, config.name)
            |> result.unwrap([])
          let resources =
            send_resources_list(t, 3, config.name)
            |> result.unwrap([])
          let prompts =
            send_prompts_list(t, 4, config.name)
            |> result.unwrap([])
          Ok(#(t, forwarder, tools, resources, prompts))
        }
        Error(e) -> {
          transport.stop(t)
          Error(e)
        }
      }
    Error(e) -> Error(e)
  }
}

// ============================================================================
// Notification forwarding
// ============================================================================

/// Spawn a minimal actor that receives raw JSON notification strings and
/// forwards them as ServerNotification messages to the manager.
fn start_notification_forwarder(
  manager: McpManager,
  server_name: String,
) -> Subject(String) {
  let assert Ok(forwarder) =
    actor.new(Nil)
    |> actor.on_message(fn(_state, json: String) {
      actor.send(manager, ServerNotification(server_name, json))
      actor.continue(Nil)
    })
    |> actor.start
  forwarder.data
}

// ============================================================================
// Notification method parsing
// ============================================================================

fn notification_method_decoder() -> decode.Decoder(String) {
  use method <- decode.field("method", decode.string)
  decode.success(method)
}

fn parse_notification_method(raw: String) -> Result(String, String) {
  case json.parse(raw, notification_method_decoder()) {
    Ok(method) -> Ok(method)
    Error(_) -> Error("Failed to parse notification method")
  }
}

// ============================================================================
// JSON-RPC Response Parsing
// ============================================================================

fn parse_jsonrpc_result(response: String) -> Result(String, String) {
  case json.parse(response, has_error_decoder()) {
    Ok(True) ->
      case json.parse(response, error_message_decoder()) {
        Ok(msg) -> Error(msg)
        Error(_) -> Error("JSON-RPC error in response")
      }
    _ ->
      case json.parse(response, result_decoder()) {
        Ok(result_str) -> Ok(result_str)
        Error(_) -> Error("Invalid JSON-RPC response: " <> response)
      }
  }
}

fn has_error_decoder() -> decode.Decoder(Bool) {
  use has_error <- decode.optional_field("error", False, decode.success(True))
  decode.success(has_error)
}

fn error_message_decoder() -> decode.Decoder(String) {
  use error <- decode.field("error", error_obj_decoder())
  decode.success(error)
}

fn error_obj_decoder() -> decode.Decoder(String) {
  use message <- decode.field("message", decode.string)
  decode.success(message)
}

@external(erlang, "mcp_client_ffi", "dynamic_to_json")
fn dynamic_to_json(value: dynamic.Dynamic) -> Result(String, String)

fn result_decoder() -> decode.Decoder(String) {
  use result_val <- decode.field("result", decode.dynamic)
  case dynamic_to_json(result_val) {
    Ok(json_str) -> decode.success(json_str)
    Error(e) -> decode.failure("result", "Could not encode to JSON: " <> e)
  }
}

// ============================================================================
// Dead server detection and reconnection
// ============================================================================

fn is_process_dead_error(e: String) -> Bool {
  string.contains(e, "exited")
  || string.contains(e, "Port not open")
  || string.contains(e, "Send/receive failed: badarg")
}

fn evict_dead_server(state: ManagerState, server_name: String) -> ManagerState {
  let new_servers = dict.delete(state.servers, server_name)
  let new_tools =
    dict.filter(state.tools, fn(_k, t) { t.server_name != server_name })
  let new_resources =
    list.filter(state.resources, fn(r) { r.server_name != server_name })
  let new_prompts =
    list.filter(state.prompts, fn(p) { p.server_name != server_name })
  ManagerState(
    servers: new_servers,
    tools: new_tools,
    resources: new_resources,
    prompts: new_prompts,
  )
}

fn try_reconnect(state: ManagerState, server_name: String) -> ManagerState {
  case dict.get(state.servers, server_name) {
    Error(_) -> state
    Ok(connection) ->
      do_reconnect(state, server_name, connection.config, connection.manager, 0)
  }
}

fn int_pow(base: Int, exp: Int) -> Int {
  case exp <= 0 {
    True -> 1
    False -> base * int_pow(base, exp - 1)
  }
}

fn do_reconnect(
  state: ManagerState,
  server_name: String,
  config: ServerConfig,
  manager: McpManager,
  attempt: Int,
) -> ManagerState {
  case config.retry {
    NoRetry -> evict_dead_server(state, server_name)
    Retry(max_attempts, base_delay_ms) ->
      case attempt >= max_attempts {
        True -> evict_dead_server(state, server_name)
        False -> {
          let delay = int.min(base_delay_ms * int_pow(2, attempt), 30_000)
          process.sleep(delay)
          case attempt_connection(config, manager) {
            Ok(#(t, _forwarder, tools, resources, prompts)) -> {
              let new_conn =
                ServerConnection(
                  config: config,
                  transport: t,
                  initialized: True,
                  request_id: 5,
                  manager: manager,
                )
              let clean = evict_dead_server(state, server_name)
              let new_servers =
                dict.insert(clean.servers, server_name, new_conn)
              let new_tools =
                list.fold(tools, clean.tools, fn(acc, tool) {
                  dict.insert(acc, tool.spec.name, tool)
                })
              let new_resources = list.append(clean.resources, resources)
              let new_prompts = list.append(clean.prompts, prompts)
              ManagerState(
                servers: new_servers,
                tools: new_tools,
                resources: new_resources,
                prompts: new_prompts,
              )
            }
            Error(_) ->
              do_reconnect(state, server_name, config, manager, attempt + 1)
          }
        }
      }
  }
}

// ============================================================================
// Server notification handling
// ============================================================================

/// Handle a server-sent notification by dispatching to the appropriate refresh.
fn handle_server_notification(
  state: ManagerState,
  server_name: String,
  method: String,
) -> ManagerState {
  case method {
    "notifications/tools/list_changed" -> refresh_tools(state, server_name)
    "notifications/resources/list_changed" ->
      refresh_resources(state, server_name)
    "notifications/prompts/list_changed" -> refresh_prompts(state, server_name)
    _ -> state
  }
}

/// Re-fetch tools/list for a server and update state.
fn refresh_tools(state: ManagerState, server_name: String) -> ManagerState {
  case dict.get(state.servers, server_name) {
    Ok(connection) -> {
      let id = connection.request_id
      let new_tools = case
        send_tools_list(connection.transport, id, server_name)
      {
        Ok(tools) -> {
          // Remove old tools from this server, insert new ones.
          let filtered =
            dict.filter(state.tools, fn(_k, t) { t.server_name != server_name })
          list.fold(tools, filtered, fn(acc, tool) {
            dict.insert(acc, tool.spec.name, tool)
          })
        }
        Error(_) -> state.tools
      }
      let updated = ServerConnection(..connection, request_id: id + 1)
      ManagerState(
        ..state,
        servers: dict.insert(state.servers, server_name, updated),
        tools: new_tools,
      )
    }
    Error(_) -> state
  }
}

/// Re-fetch resources/list for a server and update state.
fn refresh_resources(state: ManagerState, server_name: String) -> ManagerState {
  case dict.get(state.servers, server_name) {
    Ok(connection) -> {
      let id = connection.request_id
      let new_resources = case
        send_resources_list(connection.transport, id, server_name)
      {
        Ok(resources) -> {
          let filtered =
            list.filter(state.resources, fn(r) { r.server_name != server_name })
          list.append(filtered, resources)
        }
        Error(_) -> state.resources
      }
      let updated = ServerConnection(..connection, request_id: id + 1)
      ManagerState(
        ..state,
        servers: dict.insert(state.servers, server_name, updated),
        resources: new_resources,
      )
    }
    Error(_) -> state
  }
}

/// Re-fetch prompts/list for a server and update state.
fn refresh_prompts(state: ManagerState, server_name: String) -> ManagerState {
  case dict.get(state.servers, server_name) {
    Ok(connection) -> {
      let id = connection.request_id
      let new_prompts = case
        send_prompts_list(connection.transport, id, server_name)
      {
        Ok(prompts) -> {
          let filtered =
            list.filter(state.prompts, fn(p) { p.server_name != server_name })
          list.append(filtered, prompts)
        }
        Error(_) -> state.prompts
      }
      let updated = ServerConnection(..connection, request_id: id + 1)
      ManagerState(
        ..state,
        servers: dict.insert(state.servers, server_name, updated),
        prompts: new_prompts,
      )
    }
    Error(_) -> state
  }
}

// ============================================================================
// MCP Protocol: Resource subscriptions
// ============================================================================

fn send_resources_subscribe(
  t: StdioTransport,
  id: Int,
  uri: String,
) -> Result(Nil, String) {
  let params = json.object([#("uri", json.string(uri))])
  let request = jsonrpc_request(id, "resources/subscribe", params)
  case transport.send_and_receive(t, request, 10_000) {
    Ok(response) ->
      case parse_jsonrpc_result(response) {
        Ok(_) -> Ok(Nil)
        Error(e) -> Error("resources/subscribe failed: " <> e)
      }
    Error(e) -> Error("resources/subscribe timeout/error: " <> e)
  }
}

fn send_resources_unsubscribe(
  t: StdioTransport,
  id: Int,
  uri: String,
) -> Result(Nil, String) {
  let params = json.object([#("uri", json.string(uri))])
  let request = jsonrpc_request(id, "resources/unsubscribe", params)
  case transport.send_and_receive(t, request, 10_000) {
    Ok(response) ->
      case parse_jsonrpc_result(response) {
        Ok(_) -> Ok(Nil)
        Error(e) -> Error("resources/unsubscribe failed: " <> e)
      }
    Error(e) -> Error("resources/unsubscribe timeout/error: " <> e)
  }
}

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  state: ManagerState,
  message: ManagerMessage,
) -> actor.Next(ManagerState, ManagerMessage) {
  case message {
    RegisterServer(reply_to, config, manager) ->
      case dict.get(state.servers, config.name) {
        Ok(_) -> {
          actor.send(
            reply_to,
            Error("Server already registered: " <> config.name),
          )
          actor.continue(state)
        }
        Error(_) ->
          case attempt_connection(config, manager) {
            Ok(#(t, _forwarder, tools, resources, prompts)) -> {
              let connection =
                ServerConnection(
                  config: config,
                  transport: t,
                  initialized: True,
                  request_id: 5,
                  manager: manager,
                )
              let new_servers =
                dict.insert(state.servers, config.name, connection)
              let new_tools =
                list.fold(tools, state.tools, fn(acc, tool) {
                  dict.insert(acc, tool.spec.name, tool)
                })
              let new_resources = list.append(state.resources, resources)
              let new_prompts = list.append(state.prompts, prompts)
              actor.send(reply_to, Ok(Nil))
              actor.continue(ManagerState(
                servers: new_servers,
                tools: new_tools,
                resources: new_resources,
                prompts: new_prompts,
              ))
            }
            Error(e) -> {
              actor.send(
                reply_to,
                Error("Failed to initialize " <> config.name <> ": " <> e),
              )
              actor.continue(state)
            }
          }
      }

    UnregisterServer(reply_to, name) ->
      case dict.get(state.servers, name) {
        Ok(connection) -> {
          transport.stop(connection.transport)
          let new_servers = dict.delete(state.servers, name)
          let new_tools =
            dict.filter(state.tools, fn(_key, tool) { tool.server_name != name })
          let new_resources =
            list.filter(state.resources, fn(r) { r.server_name != name })
          let new_prompts =
            list.filter(state.prompts, fn(p) { p.server_name != name })
          actor.send(reply_to, Ok(Nil))
          actor.continue(ManagerState(
            servers: new_servers,
            tools: new_tools,
            resources: new_resources,
            prompts: new_prompts,
          ))
        }
        Error(_) -> {
          actor.send(reply_to, Error("Server not found: " <> name))
          actor.continue(state)
        }
      }

    ListServers(reply_to) -> {
      let names =
        state.servers
        |> dict.keys
        |> list.sort(string.compare)
      actor.send(reply_to, names)
      actor.continue(state)
    }

    GetServerConfig(reply_to, name) ->
      case dict.get(state.servers, name) {
        Ok(connection) -> {
          actor.send(reply_to, Ok(connection.config))
          actor.continue(state)
        }
        Error(_) -> {
          actor.send(reply_to, Error("Server not found: " <> name))
          actor.continue(state)
        }
      }

    ListTools(reply_to) -> {
      actor.send(reply_to, dict.values(state.tools))
      actor.continue(state)
    }

    ExecuteTool(reply_to, tool_name, args) ->
      case dict.get(state.tools, tool_name) {
        Ok(mcp_tool) ->
          case dict.get(state.servers, mcp_tool.server_name) {
            Ok(connection) -> {
              let id = connection.request_id
              let result =
                send_tools_call(
                  connection.transport,
                  id,
                  mcp_tool.original_name,
                  args,
                )
              case result {
                Ok(_) -> {
                  let updated =
                    ServerConnection(..connection, request_id: id + 1)
                  let new_servers =
                    dict.insert(state.servers, mcp_tool.server_name, updated)
                  actor.send(reply_to, result)
                  actor.continue(ManagerState(..state, servers: new_servers))
                }
                Error(e) -> {
                  let new_state = case is_process_dead_error(e) {
                    True -> try_reconnect(state, mcp_tool.server_name)
                    False -> state
                  }
                  actor.send(reply_to, Error(e))
                  actor.continue(new_state)
                }
              }
            }
            Error(_) -> {
              actor.send(
                reply_to,
                Error("Server not found for tool: " <> mcp_tool.server_name),
              )
              actor.continue(state)
            }
          }
        Error(_) -> {
          actor.send(reply_to, Error("Tool not found: " <> tool_name))
          actor.continue(state)
        }
      }

    ListResources(reply_to) -> {
      actor.send(reply_to, state.resources)
      actor.continue(state)
    }

    ReadResource(reply_to, server_name, uri) ->
      case dict.get(state.servers, server_name) {
        Ok(connection) -> {
          let id = connection.request_id
          let result = send_resources_read(connection.transport, id, uri)
          case result {
            Ok(_) -> {
              let updated = ServerConnection(..connection, request_id: id + 1)
              let new_servers = dict.insert(state.servers, server_name, updated)
              actor.send(reply_to, result)
              actor.continue(ManagerState(..state, servers: new_servers))
            }
            Error(e) -> {
              let new_state = case is_process_dead_error(e) {
                True -> try_reconnect(state, server_name)
                False -> state
              }
              actor.send(reply_to, Error(e))
              actor.continue(new_state)
            }
          }
        }
        Error(_) -> {
          actor.send(reply_to, Error("Server not found: " <> server_name))
          actor.continue(state)
        }
      }

    ListPrompts(reply_to) -> {
      actor.send(reply_to, state.prompts)
      actor.continue(state)
    }

    GetPrompt(reply_to, server_name, name, args) ->
      case dict.get(state.servers, server_name) {
        Ok(connection) -> {
          let id = connection.request_id
          let result = send_prompts_get(connection.transport, id, name, args)
          case result {
            Ok(_) -> {
              let updated = ServerConnection(..connection, request_id: id + 1)
              let new_servers = dict.insert(state.servers, server_name, updated)
              actor.send(reply_to, result)
              actor.continue(ManagerState(..state, servers: new_servers))
            }
            Error(e) -> {
              let new_state = case is_process_dead_error(e) {
                True -> try_reconnect(state, server_name)
                False -> state
              }
              actor.send(reply_to, Error(e))
              actor.continue(new_state)
            }
          }
        }
        Error(_) -> {
          actor.send(reply_to, Error("Server not found: " <> server_name))
          actor.continue(state)
        }
      }

    ServerNotification(server_name, raw_json) -> {
      let new_state = case parse_notification_method(raw_json) {
        Ok(method) -> handle_server_notification(state, server_name, method)
        Error(_) -> state
      }
      actor.continue(new_state)
    }

    SubscribeResource(reply_to, server_name, uri) ->
      case dict.get(state.servers, server_name) {
        Ok(connection) -> {
          let id = connection.request_id
          let result = send_resources_subscribe(connection.transport, id, uri)
          let updated = ServerConnection(..connection, request_id: id + 1)
          let new_servers = dict.insert(state.servers, server_name, updated)
          actor.send(reply_to, result)
          actor.continue(ManagerState(..state, servers: new_servers))
        }
        Error(_) -> {
          actor.send(reply_to, Error("Server not found: " <> server_name))
          actor.continue(state)
        }
      }

    UnsubscribeResource(reply_to, server_name, uri) ->
      case dict.get(state.servers, server_name) {
        Ok(connection) -> {
          let id = connection.request_id
          let result = send_resources_unsubscribe(connection.transport, id, uri)
          let updated = ServerConnection(..connection, request_id: id + 1)
          let new_servers = dict.insert(state.servers, server_name, updated)
          actor.send(reply_to, result)
          actor.continue(ManagerState(..state, servers: new_servers))
        }
        Error(_) -> {
          actor.send(reply_to, Error("Server not found: " <> server_name))
          actor.continue(state)
        }
      }

    Stop(reply_to) -> {
      dict.each(state.servers, fn(_key, connection) {
        transport.stop(connection.transport)
      })
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start a new MCP manager.
pub fn start() -> Result(McpManager, actor.StartError) {
  let initial_state =
    ManagerState(
      servers: dict.new(),
      tools: dict.new(),
      resources: [],
      prompts: [],
    )
  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(reason) -> Error(reason)
  }
}

/// Register an MCP server. Starts the process, performs the MCP initialize
/// handshake, and discovers all tools, resources, and prompts.
pub fn register(
  manager: McpManager,
  config: ServerConfig,
) -> Result(Nil, String) {
  actor.call(manager, waiting: 30_000, sending: RegisterServer(
    _,
    config,
    manager,
  ))
}

/// Unregister an MCP server and stop its process.
pub fn unregister(manager: McpManager, name: String) -> Result(Nil, String) {
  actor.call(manager, waiting: 10_000, sending: UnregisterServer(_, name))
}

/// List all registered server names.
pub fn list_servers(manager: McpManager) -> List(String) {
  actor.call(manager, waiting: 5000, sending: ListServers)
}

/// Get a server's configuration by name.
pub fn get_server(
  manager: McpManager,
  name: String,
) -> Result(ServerConfig, String) {
  actor.call(manager, waiting: 5000, sending: GetServerConfig(_, name))
}

/// List all discovered tools across all servers.
pub fn list_tools(manager: McpManager) -> List(Tool) {
  actor.call(manager, waiting: 5000, sending: ListTools)
}

/// Execute a tool by qualified name (`"server/tool"`) with JSON arguments.
pub fn execute_tool(
  manager: McpManager,
  tool_name: String,
  args: String,
) -> Result(String, String) {
  actor.call(manager, waiting: 30_000, sending: ExecuteTool(_, tool_name, args))
}

/// List all resources discovered across all servers.
pub fn list_resources(manager: McpManager) -> List(Resource) {
  actor.call(manager, waiting: 5000, sending: ListResources)
}

/// Read a resource by URI from a named server. Returns the raw JSON result.
pub fn read_resource(
  manager: McpManager,
  server_name: String,
  uri: String,
) -> Result(String, String) {
  actor.call(manager, waiting: 30_000, sending: ReadResource(
    _,
    server_name,
    uri,
  ))
}

/// List all prompts discovered across all servers.
pub fn list_prompts(manager: McpManager) -> List(Prompt) {
  actor.call(manager, waiting: 5000, sending: ListPrompts)
}

/// Get a rendered prompt by name from a named server. Returns the raw JSON result.
pub fn get_prompt(
  manager: McpManager,
  server_name: String,
  name: String,
  args: Dict(String, String),
) -> Result(String, String) {
  actor.call(manager, waiting: 30_000, sending: GetPrompt(
    _,
    server_name,
    name,
    args,
  ))
}

/// Stop the manager and all server connections.
pub fn stop(manager: McpManager) -> Nil {
  actor.call(manager, waiting: 10_000, sending: Stop)
}

/// Subscribe to updates for a specific resource URI on a server.
/// Sends a `resources/subscribe` JSON-RPC request.
pub fn subscribe_resource(
  manager: McpManager,
  server_name: String,
  uri: String,
) -> Result(Nil, String) {
  actor.call(manager, waiting: 10_000, sending: SubscribeResource(
    _,
    server_name,
    uri,
  ))
}

/// Unsubscribe from updates for a specific resource URI on a server.
/// Sends a `resources/unsubscribe` JSON-RPC request.
pub fn unsubscribe_resource(
  manager: McpManager,
  server_name: String,
  uri: String,
) -> Result(Nil, String) {
  actor.call(manager, waiting: 10_000, sending: UnsubscribeResource(
    _,
    server_name,
    uri,
  ))
}

//// MCP STDIO Transport — real communication with MCP servers via stdin/stdout.
////
//// Spawns an external process via Erlang port and communicates via
//// newline-delimited JSON-RPC 2.0 over STDIO.
//// This is the primary transport for local MCP servers.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(transport) = transport.start("npx", ["-y", "server"], [])
//// let assert Ok(response) = transport.send_and_receive(transport, "{\"jsonrpc\":\"2.0\",...}", 5000)
//// transport.stop(transport)
//// ```

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string

// ============================================================================
// FFI Bindings
// ============================================================================

@external(erlang, "mcp_client_ffi", "open_port")
fn do_open_port(
  command: String,
  args: List(String),
  env: List(#(String, String)),
) -> Result(Dynamic, String)

@external(erlang, "mcp_client_ffi", "send_and_receive")
fn do_send_and_receive(
  port: Dynamic,
  data: String,
  timeout_ms: Int,
) -> Result(String, String)

@external(erlang, "mcp_client_ffi", "send_data")
fn do_send_data(port: Dynamic, data: String) -> Result(Nil, String)

@external(erlang, "mcp_client_ffi", "close_port")
fn do_close_port(port: Dynamic) -> Nil

/// Opaque type for Erlang port references.
pub type Dynamic

// ============================================================================
// Types
// ============================================================================

/// Messages for the STDIO transport actor.
pub type StdioMessage {
  /// Send a JSON-RPC message and wait for response
  SendReceive(
    reply_to: Subject(Result(String, String)),
    data: String,
    timeout_ms: Int,
  )
  /// Send a JSON-RPC message without waiting (for notifications)
  SendOnly(reply_to: Subject(Result(Nil, String)), data: String)
  /// Stop the transport and kill the process
  Stop(reply_to: Subject(Nil))
}

/// The transport handle.
pub type StdioTransport =
  Subject(StdioMessage)

/// Internal state.
type StdioState {
  StdioState(
    port: Option(Dynamic),
    command: String,
    args: List(String),
    env: List(#(String, String)),
    connected: Bool,
  )
}

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  state: StdioState,
  message: StdioMessage,
) -> actor.Next(StdioState, StdioMessage) {
  case message {
    SendReceive(reply_to, data, timeout_ms) -> {
      case state.port {
        Some(port) -> {
          let result = do_send_and_receive(port, data, timeout_ms)
          actor.send(reply_to, result)
          actor.continue(state)
        }
        None -> {
          actor.send(reply_to, Error("Port not open"))
          actor.continue(state)
        }
      }
    }

    SendOnly(reply_to, data) -> {
      case state.port {
        Some(port) -> {
          let result = do_send_data(port, data)
          actor.send(reply_to, result)
          actor.continue(state)
        }
        None -> {
          actor.send(reply_to, Error("Port not open"))
          actor.continue(state)
        }
      }
    }

    Stop(reply_to) -> {
      case state.port {
        Some(port) -> do_close_port(port)
        None -> Nil
      }
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start a STDIO transport to an MCP server.
/// Opens an Erlang port to the external process.
pub fn start(
  command: String,
  args: List(String),
  env: List(#(String, String)),
) -> Result(StdioTransport, String) {
  case do_open_port(command, args, env) {
    Ok(port) -> {
      let initial_state =
        StdioState(
          port: Some(port),
          command: command,
          args: args,
          env: env,
          connected: True,
        )

      case
        actor.new(initial_state)
        |> actor.on_message(handle_message)
        |> actor.start
      {
        Ok(started) -> Ok(started.data)
        Error(reason) -> {
          // Clean up port if actor fails to start
          do_close_port(port)
          Error("Failed to start actor: " <> string.inspect(reason))
        }
      }
    }
    Error(reason) -> Error(reason)
  }
}

/// Send a JSON-RPC message and wait for a response.
/// The timeout_ms parameter controls how long to wait for the response.
pub fn send_and_receive(
  transport: StdioTransport,
  data: String,
  timeout_ms: Int,
) -> Result(String, String) {
  actor.call(transport, waiting: timeout_ms + 1000, sending: SendReceive(
    _,
    data,
    timeout_ms,
  ))
}

/// Send a JSON-RPC notification (no response expected).
pub fn send_only(transport: StdioTransport, data: String) -> Result(Nil, String) {
  actor.call(transport, waiting: 5000, sending: SendOnly(_, data))
}

/// Stop the transport and kill the server process.
pub fn stop(transport: StdioTransport) -> Nil {
  actor.call(transport, waiting: 5000, sending: Stop)
}

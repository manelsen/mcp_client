//// Tests for MCP STDIO Transport with real Erlang ports.
////
//// Tests the real STDIO transport using a mock MCP server.

import gleam/string
import gleeunit/should
import gleam_mcp/transport

// ============================================================================
// Basic Transport Tests
// ============================================================================

pub fn start_and_stop_transport_test() {
  let assert Ok(t) =
    transport.start("python3", ["test/mock_mcp_server.py"], [])
  transport.stop(t)
}

pub fn send_and_receive_test() {
  let assert Ok(t) =
    transport.start("python3", ["test/mock_mcp_server.py"], [])

  // Send initialize request
  let request =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0.0\"}}}"

  let assert Ok(response) = transport.send_and_receive(t, request, 5000)

  // Verify response contains expected fields
  response
  |> string.contains("protocolVersion")
  |> should.equal(True)

  response
  |> string.contains("2024-11-05")
  |> should.equal(True)

  transport.stop(t)
}

pub fn send_notification_test() {
  let assert Ok(t) =
    transport.start("python3", ["test/mock_mcp_server.py"], [])

  // Send initialized notification (no response expected)
  let notification =
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}"

  let assert Ok(Nil) = transport.send_only(t, notification)

  transport.stop(t)
}

pub fn multiple_requests_test() {
  let assert Ok(t) =
    transport.start("python3", ["test/mock_mcp_server.py"], [])

  // Initialize
  let init_request =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0.0\"}}}"
  let assert Ok(_) = transport.send_and_receive(t, init_request, 5000)

  // Send initialized notification
  let notification =
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}"
  let assert Ok(Nil) = transport.send_only(t, notification)

  // List tools
  let tools_request =
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}"
  let assert Ok(tools_response) =
    transport.send_and_receive(t, tools_request, 5000)

  tools_response
  |> string.contains("tools")
  |> should.equal(True)

  tools_response
  |> string.contains("echo")
  |> should.equal(True)

  transport.stop(t)
}

pub fn tools_call_test() {
  let assert Ok(t) =
    transport.start("python3", ["test/mock_mcp_server.py"], [])

  // Initialize
  let init_request =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0.0\"}}}"
  let assert Ok(_) = transport.send_and_receive(t, init_request, 5000)

  // Call echo tool
  let call_request =
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"message\":\"hello world\"}}}"
  let assert Ok(call_response) =
    transport.send_and_receive(t, call_request, 5000)

  call_response
  |> string.contains("hello world")
  |> should.equal(True)

  transport.stop(t)
}

pub fn invalid_command_returns_error_test() {
  let result = transport.start("nonexistent_command_xyz", [], [])
  result
  |> should.be_error
}

pub fn timeout_test() {
  let assert Ok(t) =
    transport.start("python3", ["test/mock_mcp_server.py"], [])

  // Send a request with a reasonable timeout
  // The mock server should respond quickly, so this should succeed
  let request =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
  let result = transport.send_and_receive(t, request, 5000)

  // Should succeed since mock server responds quickly
  result
  |> should.be_ok

  transport.stop(t)
}

//// Test entry point and facade tests for gleam_mcp.
////
//// This module serves as the gleeunit entry point (provides `main/0`)
//// and also tests the top-level public facade (`gleam_mcp.*`).

import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import gleam_mcp
import gleam_mcp/manager

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Client lifecycle
// ============================================================================

pub fn new_and_stop_test() {
  let assert Ok(client) = gleam_mcp.new()
  gleam_mcp.stop(client)
}

pub fn new_client_has_no_servers_test() {
  let assert Ok(client) = gleam_mcp.new()

  gleam_mcp.servers(client)
  |> should.equal([])

  gleam_mcp.tools(client)
  |> should.equal([])

  gleam_mcp.stop(client)
}

// ============================================================================
// Register / unregister
// ============================================================================

pub fn register_and_list_servers_test() {
  let assert Ok(client) = gleam_mcp.new()

  let config =
    manager.ServerConfig(
      name: "facade-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = gleam_mcp.register(client, config)

  gleam_mcp.servers(client)
  |> should.equal(["facade-server"])

  gleam_mcp.stop(client)
}

pub fn register_invalid_server_returns_error_test() {
  let assert Ok(client) = gleam_mcp.new()

  let config =
    manager.ServerConfig(
      name: "bad",
      command: "nonexistent_command_xyz",
      args: [],
      env: [],
    )

  gleam_mcp.register(client, config)
  |> should.be_error

  gleam_mcp.stop(client)
}

pub fn unregister_removes_server_and_tools_test() {
  let assert Ok(client) = gleam_mcp.new()

  let config =
    manager.ServerConfig(
      name: "temp",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = gleam_mcp.register(client, config)

  gleam_mcp.servers(client)
  |> should.equal(["temp"])

  let assert Ok(Nil) = gleam_mcp.unregister(client, "temp")

  gleam_mcp.servers(client)
  |> should.equal([])

  gleam_mcp.tools(client)
  |> should.equal([])

  gleam_mcp.stop(client)
}

pub fn unregister_nonexistent_returns_error_test() {
  let assert Ok(client) = gleam_mcp.new()

  gleam_mcp.unregister(client, "does-not-exist")
  |> should.be_error

  gleam_mcp.stop(client)
}

// ============================================================================
// Tool discovery
// ============================================================================

pub fn tools_returns_qualified_names_test() {
  let assert Ok(client) = gleam_mcp.new()

  let config =
    manager.ServerConfig(
      name: "tools-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = gleam_mcp.register(client, config)

  let discovered = gleam_mcp.tools(client)

  // All tool names must be qualified with the server name
  discovered
  |> list.all(fn(t) { string.starts_with(t.spec.name, "tools-server/") })
  |> should.equal(True)

  // original_name must be bare (no slash)
  discovered
  |> list.all(fn(t) { !string.contains(t.original_name, "/") })
  |> should.equal(True)

  gleam_mcp.stop(client)
}

// ============================================================================
// Tool invocation
// ============================================================================

pub fn call_echo_tool_test() {
  let assert Ok(client) = gleam_mcp.new()

  let config =
    manager.ServerConfig(
      name: "call-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = gleam_mcp.register(client, config)

  let assert Ok(result) =
    gleam_mcp.call(client, "call-server/echo", "{\"message\":\"gleam_mcp\"}")

  result
  |> string.contains("gleam_mcp")
  |> should.equal(True)

  gleam_mcp.stop(client)
}

pub fn call_nonexistent_tool_returns_error_test() {
  let assert Ok(client) = gleam_mcp.new()

  let config =
    manager.ServerConfig(
      name: "call-server2",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = gleam_mcp.register(client, config)

  gleam_mcp.call(client, "call-server2/not_a_real_tool", "{}")
  |> should.be_error

  gleam_mcp.stop(client)
}

pub fn call_without_server_prefix_returns_error_test() {
  let assert Ok(client) = gleam_mcp.new()

  let config =
    manager.ServerConfig(
      name: "call-server3",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = gleam_mcp.register(client, config)

  // Bare tool name (no server prefix) should not be found
  gleam_mcp.call(client, "echo", "{\"message\":\"oops\"}")
  |> should.be_error

  gleam_mcp.stop(client)
}

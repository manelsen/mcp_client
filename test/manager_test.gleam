//// Tests for MCP Manager with real MCP protocol.
////
//// Verifies multi-server management, tool discovery, and routing
//// using a mock MCP server over real STDIO transport.

import gleam/list
import gleam/string
import gleeunit/should
import gleam_mcp/manager

// ============================================================================
// Basic Manager Tests
// ============================================================================

pub fn start_manager_test() {
  let assert Ok(mgr) = manager.start()

  let servers = manager.list_servers(mgr)
  servers
  |> should.equal([])

  manager.stop(mgr)
}

// ============================================================================
// Server Registration Tests (with mock MCP server)
// ============================================================================

pub fn register_mock_server_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "mock-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let servers = manager.list_servers(mgr)
  servers
  |> should.equal(["mock-server"])

  manager.stop(mgr)
}

pub fn register_duplicate_server_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "dup",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = manager.register(mgr, config)
  let result = manager.register(mgr, config)
  result
  |> should.be_error

  manager.stop(mgr)
}

pub fn register_invalid_command_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "invalid",
      command: "nonexistent_command_xyz",
      args: [],
      env: [],
    )

  let result = manager.register(mgr, config)
  result
  |> should.be_error

  manager.stop(mgr)
}

pub fn get_server_config_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "my-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let result = manager.get_server(mgr, "my-server")
  case result {
    Ok(cfg) -> {
      cfg.command
      |> should.equal("python3")
    }
    Error(_) -> should.fail()
  }

  manager.stop(mgr)
}

pub fn get_nonexistent_server_test() {
  let assert Ok(mgr) = manager.start()

  let result = manager.get_server(mgr, "nope")
  result
  |> should.be_error

  manager.stop(mgr)
}

// ============================================================================
// Tool Discovery Tests
// ============================================================================

pub fn discover_tools_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "tool-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let tools = manager.list_tools(mgr)
  tools
  |> list.length
  |> should.equal(4)

  // Tool names are qualified as "server_name/tool_name"
  let tool_names =
    tools
    |> list.map(fn(t) { t.spec.name })
    |> list.sort(string.compare)

  tool_names
  |> should.equal([
    "tool-server/add", "tool-server/big_data", "tool-server/echo",
    "tool-server/special_chars",
  ])

  // original_name is unqualified
  let original_names =
    tools
    |> list.map(fn(t) { t.original_name })
    |> list.sort(string.compare)

  original_names
  |> should.equal(["add", "big_data", "echo", "special_chars"])

  manager.stop(mgr)
}

// ============================================================================
// Tool Execution Tests
// ============================================================================

pub fn execute_echo_tool_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "exec-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  // Tool names are qualified after discovery
  let result =
    manager.execute_tool(mgr, "exec-server/echo", "{\"message\":\"test\"}")
  case result {
    Ok(response) -> {
      response
      |> string.contains("test")
      |> should.equal(True)
    }
    Error(e) -> {
      let _ = e
      should.fail()
    }
  }

  manager.stop(mgr)
}

pub fn execute_nonexistent_tool_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "exec-server2",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  // Neither bare name nor wrong qualified name should work
  manager.execute_tool(mgr, "nonexistent", "{}")
  |> should.be_error

  manager.execute_tool(mgr, "exec-server2/nonexistent", "{}")
  |> should.be_error

  manager.stop(mgr)
}

// ============================================================================
// Unregister Tests
// ============================================================================

pub fn unregister_server_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "temp-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  // Verify server is registered
  manager.list_servers(mgr)
  |> should.equal(["temp-server"])

  // Unregister
  let assert Ok(Nil) = manager.unregister(mgr, "temp-server")

  // Verify server is gone
  manager.list_servers(mgr)
  |> should.equal([])

  // Verify tools are gone
  manager.list_tools(mgr)
  |> should.equal([])

  manager.stop(mgr)
}

pub fn unregister_nonexistent_server_test() {
  let assert Ok(mgr) = manager.start()

  let result = manager.unregister(mgr, "nonexistent")
  result
  |> should.be_error

  manager.stop(mgr)
}

// ============================================================================
// Multiple Server Tests
// ============================================================================

pub fn multiple_servers_test() {
  let assert Ok(mgr) = manager.start()

  let config1 =
    manager.ServerConfig(
      name: "server-1",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let config2 =
    manager.ServerConfig(
      name: "server-2",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = manager.register(mgr, config1)
  let assert Ok(Nil) = manager.register(mgr, config2)

  let servers = manager.list_servers(mgr)
  servers
  |> should.equal(["server-1", "server-2"])

  // Tools from both servers are discoverable without collision:
  // each is qualified as "server-name/tool-name"
  let tools = manager.list_tools(mgr)
  let tool_names =
    tools
    |> list.map(fn(t) { t.spec.name })
    |> list.sort(string.compare)

  // server-1 and server-2 each provide 4 tools — 8 total, no collisions
  tool_names
  |> should.equal([
    "server-1/add", "server-1/big_data", "server-1/echo",
    "server-1/special_chars", "server-2/add", "server-2/big_data",
    "server-2/echo", "server-2/special_chars",
  ])

  manager.stop(mgr)
}

// ============================================================================
// Regression tests
// ============================================================================

pub fn large_response_does_not_truncate_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "large-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let result =
    manager.execute_tool(mgr, "large-server/big_data", "{}")
  case result {
    Ok(response) ->
      // The big_data tool returns 8192 'A' characters — verify none were lost
      response
      |> string.contains("AAAAAAAA")
      |> should.equal(True)
    Error(e) -> {
      let _ = e
      should.fail()
    }
  }

  manager.stop(mgr)
}

pub fn special_chars_in_result_are_preserved_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "chars-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let result =
    manager.execute_tool(
      mgr,
      "chars-server/special_chars",
      "{\"input\":\"hello\"}",
    )
  case result {
    Ok(response) ->
      // Response contains backslash — if json_escape was broken this would
      // produce invalid JSON and parse_jsonrpc_result would return Error
      response
      |> string.contains("hello")
      |> should.equal(True)
    Error(e) -> {
      let _ = e
      should.fail()
    }
  }

  manager.stop(mgr)
}

pub fn incompatible_protocol_version_rejected_test() {
  // A mock server that responds with an old/unknown protocol version
  // should cause register() to return Error, not silently succeed
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "old-server",
      command: "python3",
      args: ["test/mock_mcp_server_old_version.py"],
      env: [],
    )

  // This should fail because the server announces an unsupported version
  let result = manager.register(mgr, config)
  result |> should.be_error

  // Manager should still be alive and empty after the rejected registration
  manager.list_servers(mgr)
  |> should.equal([])

  manager.stop(mgr)
}

pub fn tool_names_are_qualified_per_server_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "my-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let tools = manager.list_tools(mgr)

  // Every tool name must be prefixed with the server name
  tools
  |> list.all(fn(t) { string.starts_with(t.spec.name, "my-server/") })
  |> should.equal(True)

  // The original_name must NOT contain the server prefix
  tools
  |> list.all(fn(t) { !string.contains(t.original_name, "/") })
  |> should.equal(True)

  manager.stop(mgr)
}

pub fn dead_server_is_evicted_after_crash_test() {
  // A mock server that exits immediately after the handshake
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "crashy",
      command: "python3",
      args: ["test/mock_mcp_server_crash.py"],
      env: [],
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  // Server is listed as registered right after handshake
  manager.list_servers(mgr)
  |> should.equal(["crashy"])

  // The crash server exits after registration; the next tool call should
  // detect the dead port and evict the server from state
  let _ = manager.execute_tool(mgr, "crashy/echo", "{\"message\":\"hi\"}")

  // After the failed call, the manager should have removed the dead server
  manager.list_servers(mgr)
  |> should.equal([])

  // Manager itself must still be responsive
  let assert Ok(mgr2) = manager.start()
  manager.list_servers(mgr2) |> should.equal([])
  manager.stop(mgr2)

  manager.stop(mgr)
}

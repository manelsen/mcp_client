//// Tests for MCP Manager with real MCP protocol.
////
//// Verifies multi-server management, tool/resource/prompt discovery,
//// routing, and reconnection using mock MCP servers over real STDIO transport.

import gleam/dict
import gleam/list
import gleam/string
import gleeunit/should
import mcp_client/manager

@external(erlang, "mcp_client_ffi", "delete_file_if_exists")
fn delete_file_if_exists(path: String) -> Nil

// ============================================================================
// Basic Manager Tests
// ============================================================================

pub fn start_manager_test() {
  let assert Ok(mgr) = manager.start()
  manager.list_servers(mgr) |> should.equal([])
  manager.stop(mgr)
}

// ============================================================================
// Server Registration Tests
// ============================================================================

pub fn register_mock_server_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "mock-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)
  manager.list_servers(mgr) |> should.equal(["mock-server"])
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
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)
  manager.register(mgr, config) |> should.be_error
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
      retry: manager.NoRetry,
    )

  manager.register(mgr, config) |> should.be_error
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
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)
  let assert Ok(cfg) = manager.get_server(mgr, "my-server")
  cfg.command |> should.equal("python3")
  manager.stop(mgr)
}

pub fn get_nonexistent_server_test() {
  let assert Ok(mgr) = manager.start()
  manager.get_server(mgr, "nope") |> should.be_error
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
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let tools = manager.list_tools(mgr)
  tools |> list.length |> should.equal(4)

  let tool_names =
    tools
    |> list.map(fn(t) { t.spec.name })
    |> list.sort(string.compare)

  tool_names
  |> should.equal([
    "tool-server/add", "tool-server/big_data", "tool-server/echo",
    "tool-server/special_chars",
  ])

  let original_names =
    tools
    |> list.map(fn(t) { t.original_name })
    |> list.sort(string.compare)

  original_names |> should.equal(["add", "big_data", "echo", "special_chars"])
  manager.stop(mgr)
}

// ============================================================================
// Resource Discovery Tests
// ============================================================================

pub fn discover_resources_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "resource-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let resources = manager.list_resources(mgr)
  resources |> list.length |> should.equal(2)

  let uris =
    resources
    |> list.map(fn(r) { r.uri })
    |> list.sort(string.compare)

  uris |> should.equal(["file:///hello.txt", "file:///world.txt"])

  resources
  |> list.all(fn(r) { r.server_name == "resource-server" })
  |> should.equal(True)

  manager.stop(mgr)
}

pub fn read_resource_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "read-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let assert Ok(result) =
    manager.read_resource(mgr, "read-server", "file:///hello.txt")

  result |> string.contains("Hello") |> should.equal(True)
  manager.stop(mgr)
}

pub fn read_nonexistent_resource_returns_error_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "read-server2",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  manager.read_resource(mgr, "read-server2", "file:///does-not-exist.txt")
  |> should.be_error

  manager.stop(mgr)
}

pub fn unregister_removes_resources_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "temp-res",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)
  manager.list_resources(mgr) |> list.length |> should.equal(2)

  let assert Ok(Nil) = manager.unregister(mgr, "temp-res")
  manager.list_resources(mgr) |> should.equal([])
  manager.stop(mgr)
}

// ============================================================================
// Prompt Discovery Tests
// ============================================================================

pub fn discover_prompts_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "prompt-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let prompts = manager.list_prompts(mgr)
  prompts |> list.length |> should.equal(1)

  let names = prompts |> list.map(fn(p) { p.name })
  names |> should.equal(["greet"])

  prompts
  |> list.all(fn(p) { p.server_name == "prompt-server" })
  |> should.equal(True)

  manager.stop(mgr)
}

pub fn get_prompt_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "get-prompt-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let args = dict.from_list([#("name", "Alice")])
  let assert Ok(result) =
    manager.get_prompt(mgr, "get-prompt-server", "greet", args)

  result |> string.contains("Alice") |> should.equal(True)
  manager.stop(mgr)
}

pub fn get_nonexistent_prompt_returns_error_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "prompt-server2",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  manager.get_prompt(mgr, "prompt-server2", "no_such_prompt", dict.new())
  |> should.be_error

  manager.stop(mgr)
}

pub fn unregister_removes_prompts_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "temp-prompt",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)
  manager.list_prompts(mgr) |> list.length |> should.equal(1)

  let assert Ok(Nil) = manager.unregister(mgr, "temp-prompt")
  manager.list_prompts(mgr) |> should.equal([])
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
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let assert Ok(response) =
    manager.execute_tool(mgr, "exec-server/echo", "{\"message\":\"test\"}")

  response |> string.contains("test") |> should.equal(True)
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
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)
  manager.execute_tool(mgr, "nonexistent", "{}") |> should.be_error
  manager.execute_tool(mgr, "exec-server2/nonexistent", "{}") |> should.be_error
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
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)
  manager.list_servers(mgr) |> should.equal(["temp-server"])

  let assert Ok(Nil) = manager.unregister(mgr, "temp-server")
  manager.list_servers(mgr) |> should.equal([])
  manager.list_tools(mgr) |> should.equal([])
  manager.stop(mgr)
}

pub fn unregister_nonexistent_server_test() {
  let assert Ok(mgr) = manager.start()
  manager.unregister(mgr, "nonexistent") |> should.be_error
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
      retry: manager.NoRetry,
    )

  let config2 =
    manager.ServerConfig(
      name: "server-2",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config1)
  let assert Ok(Nil) = manager.register(mgr, config2)

  manager.list_servers(mgr) |> should.equal(["server-1", "server-2"])

  let tool_names =
    manager.list_tools(mgr)
    |> list.map(fn(t) { t.spec.name })
    |> list.sort(string.compare)

  tool_names
  |> should.equal([
    "server-1/add", "server-1/big_data", "server-1/echo",
    "server-1/special_chars", "server-2/add", "server-2/big_data",
    "server-2/echo", "server-2/special_chars",
  ])

  // 2 resources per server × 2 servers = 4 total
  manager.list_resources(mgr) |> list.length |> should.equal(4)

  // 1 prompt per server × 2 servers = 2 total
  manager.list_prompts(mgr) |> list.length |> should.equal(2)

  manager.stop(mgr)
}

// ============================================================================
// Reconnection Test
// ============================================================================

pub fn reconnect_after_crash_test() {
  let flag = "/tmp/gleam_mcp_crash_once_test_flag"
  // Ensure no stale flag from a previous failed run
  delete_file_if_exists(flag)

  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "reconnect-test",
      command: "python3",
      args: ["test/mock_mcp_server_crash_once.py", flag],
      env: [],
      retry: manager.Retry(max_attempts: 3, base_delay_ms: 10),
    )

  let assert Ok(Nil) = manager.register(mgr, config)
  manager.list_servers(mgr) |> should.equal(["reconnect-test"])
  manager.list_tools(mgr) |> list.length |> should.equal(1)

  // First call: server exits without responding → Error, reconnection triggered
  let _ =
    manager.execute_tool(
      mgr,
      "reconnect-test/echo",
      "{\"message\":\"crash\"}",
    )

  // After reconnection, server should still be registered
  manager.list_servers(mgr) |> should.equal(["reconnect-test"])

  // Second call: reconnected server responds normally
  manager.execute_tool(
    mgr,
    "reconnect-test/echo",
    "{\"message\":\"recovered\"}",
  )
  |> should.be_ok

  manager.stop(mgr)
}

pub fn no_retry_evicts_on_crash_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "crashy",
      command: "python3",
      args: ["test/mock_mcp_server_crash.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)
  manager.list_servers(mgr) |> should.equal(["crashy"])

  let _ = manager.execute_tool(mgr, "crashy/echo", "{\"message\":\"hi\"}")

  manager.list_servers(mgr) |> should.equal([])
  manager.stop(mgr)
}

// ============================================================================
// Regression Tests
// ============================================================================

pub fn large_response_does_not_truncate_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "large-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let assert Ok(response) =
    manager.execute_tool(mgr, "large-server/big_data", "{}")

  response |> string.contains("AAAAAAAA") |> should.equal(True)
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
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let assert Ok(response) =
    manager.execute_tool(
      mgr,
      "chars-server/special_chars",
      "{\"input\":\"hello\"}",
    )

  response |> string.contains("hello") |> should.equal(True)
  manager.stop(mgr)
}

pub fn incompatible_protocol_version_rejected_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "old-server",
      command: "python3",
      args: ["test/mock_mcp_server_old_version.py"],
      env: [],
      retry: manager.NoRetry,
    )

  manager.register(mgr, config) |> should.be_error
  manager.list_servers(mgr) |> should.equal([])
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
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)

  let tools = manager.list_tools(mgr)

  tools
  |> list.all(fn(t) { string.starts_with(t.spec.name, "my-server/") })
  |> should.equal(True)

  tools
  |> list.all(fn(t) { !string.contains(t.original_name, "/") })
  |> should.equal(True)

  manager.stop(mgr)
}

pub fn dead_server_is_evicted_after_crash_test() {
  let assert Ok(mgr) = manager.start()

  let config =
    manager.ServerConfig(
      name: "crashy2",
      command: "python3",
      args: ["test/mock_mcp_server_crash.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = manager.register(mgr, config)
  manager.list_servers(mgr) |> should.equal(["crashy2"])

  let _ = manager.execute_tool(mgr, "crashy2/echo", "{\"message\":\"hi\"}")

  manager.list_servers(mgr) |> should.equal([])

  let assert Ok(mgr2) = manager.start()
  manager.list_servers(mgr2) |> should.equal([])
  manager.stop(mgr2)

  manager.stop(mgr)
}

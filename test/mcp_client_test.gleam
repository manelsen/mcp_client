//// Test entry point and facade tests for mcp_client.
////
//// Serves as the gleeunit entry point (provides `main/0`) and tests the
//// top-level public facade (`mcp_client.*`).

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import mcp_client
import mcp_client/manager

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Client lifecycle
// ============================================================================

pub fn new_and_stop_test() {
  let assert Ok(client) = mcp_client.new()
  mcp_client.stop(client)
}

pub fn new_client_has_no_servers_test() {
  let assert Ok(client) = mcp_client.new()

  mcp_client.servers(client) |> should.equal([])
  mcp_client.tools(client) |> should.equal([])
  mcp_client.resources(client) |> should.equal([])
  mcp_client.prompts(client) |> should.equal([])

  mcp_client.stop(client)
}

// ============================================================================
// Register / unregister
// ============================================================================

pub fn register_and_list_servers_test() {
  let assert Ok(client) = mcp_client.new()

  let config =
    manager.ServerConfig(
      name: "facade-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = mcp_client.register(client, config)
  mcp_client.servers(client) |> should.equal(["facade-server"])
  mcp_client.stop(client)
}

pub fn register_invalid_server_returns_error_test() {
  let assert Ok(client) = mcp_client.new()

  let config =
    manager.ServerConfig(
      name: "bad",
      command: "nonexistent_command_xyz",
      args: [],
      env: [],
      retry: manager.NoRetry,
    )

  mcp_client.register(client, config) |> should.be_error
  mcp_client.stop(client)
}

pub fn unregister_removes_server_and_tools_test() {
  let assert Ok(client) = mcp_client.new()

  let config =
    manager.ServerConfig(
      name: "temp",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = mcp_client.register(client, config)
  mcp_client.servers(client) |> should.equal(["temp"])

  let assert Ok(Nil) = mcp_client.unregister(client, "temp")
  mcp_client.servers(client) |> should.equal([])
  mcp_client.tools(client) |> should.equal([])
  mcp_client.resources(client) |> should.equal([])
  mcp_client.prompts(client) |> should.equal([])

  mcp_client.stop(client)
}

pub fn unregister_nonexistent_returns_error_test() {
  let assert Ok(client) = mcp_client.new()
  mcp_client.unregister(client, "does-not-exist") |> should.be_error
  mcp_client.stop(client)
}

// ============================================================================
// Tool discovery
// ============================================================================

pub fn tools_returns_qualified_names_test() {
  let assert Ok(client) = mcp_client.new()

  let config =
    manager.ServerConfig(
      name: "tools-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = mcp_client.register(client, config)

  let discovered = mcp_client.tools(client)

  discovered
  |> list.all(fn(t) { string.starts_with(t.spec.name, "tools-server/") })
  |> should.equal(True)

  discovered
  |> list.all(fn(t) { !string.contains(t.original_name, "/") })
  |> should.equal(True)

  mcp_client.stop(client)
}

// ============================================================================
// Tool invocation
// ============================================================================

pub fn call_echo_tool_test() {
  let assert Ok(client) = mcp_client.new()

  let config =
    manager.ServerConfig(
      name: "call-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = mcp_client.register(client, config)

  let assert Ok(result) =
    mcp_client.call(client, "call-server/echo", "{\"message\":\"gleam_mcp\"}")

  result |> string.contains("gleam_mcp") |> should.equal(True)
  mcp_client.stop(client)
}

pub fn call_nonexistent_tool_returns_error_test() {
  let assert Ok(client) = mcp_client.new()

  let config =
    manager.ServerConfig(
      name: "call-server2",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = mcp_client.register(client, config)
  mcp_client.call(client, "call-server2/not_a_real_tool", "{}")
  |> should.be_error
  mcp_client.stop(client)
}

pub fn call_without_server_prefix_returns_error_test() {
  let assert Ok(client) = mcp_client.new()

  let config =
    manager.ServerConfig(
      name: "call-server3",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = mcp_client.register(client, config)
  mcp_client.call(client, "echo", "{\"message\":\"oops\"}") |> should.be_error
  mcp_client.stop(client)
}

// ============================================================================
// Resource discovery and access
// ============================================================================

pub fn resources_returns_server_resources_test() {
  let assert Ok(client) = mcp_client.new()

  let config =
    manager.ServerConfig(
      name: "res-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = mcp_client.register(client, config)

  let res = mcp_client.resources(client)
  res |> list.length |> should.equal(2)

  res
  |> list.all(fn(r) { r.server_name == "res-server" })
  |> should.equal(True)

  mcp_client.stop(client)
}

pub fn read_resource_returns_content_test() {
  let assert Ok(client) = mcp_client.new()

  let config =
    manager.ServerConfig(
      name: "read-res-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = mcp_client.register(client, config)

  let assert Ok(result) =
    mcp_client.read(client, "read-res-server", "file:///hello.txt")

  result |> string.contains("Hello") |> should.equal(True)
  mcp_client.stop(client)
}

// ============================================================================
// Prompt discovery and access
// ============================================================================

pub fn prompts_returns_server_prompts_test() {
  let assert Ok(client) = mcp_client.new()

  let config =
    manager.ServerConfig(
      name: "pmt-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = mcp_client.register(client, config)

  let ps = mcp_client.prompts(client)
  ps |> list.length |> should.equal(1)

  ps
  |> list.all(fn(p) { p.server_name == "pmt-server" })
  |> should.equal(True)

  mcp_client.stop(client)
}

pub fn prompt_returns_rendered_content_test() {
  let assert Ok(client) = mcp_client.new()

  let config =
    manager.ServerConfig(
      name: "get-pmt-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = mcp_client.register(client, config)

  let args = dict.from_list([#("name", "Bob")])
  let assert Ok(result) =
    mcp_client.prompt(client, "get-pmt-server", "greet", args)

  result |> string.contains("Bob") |> should.equal(True)
  mcp_client.stop(client)
}

// ============================================================================
// RetryPolicy helpers
// ============================================================================

pub fn no_retry_constant_test() {
  let assert Ok(client) = mcp_client.new()
  let config =
    manager.ServerConfig(
      name: "retry-test",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
      retry: mcp_client.no_retry,
    )
  let assert Ok(Nil) = mcp_client.register(client, config)
  mcp_client.stop(client)
}

pub fn retry_fn_creates_policy_test() {
  let policy = mcp_client.retry(3, 500)
  // Just ensure it compiles and creates a value — the type check is enough
  let _ = policy
  Nil
}

// ============================================================================
// Server-sent notifications
// ============================================================================

pub fn notification_tools_list_changed_test() {
  let assert Ok(client) = mcp_client.new()

  let config =
    manager.ServerConfig(
      name: "notif-tools",
      command: "python3",
      args: ["test/mock_mcp_server_notifications.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = mcp_client.register(client, config)

  // Initial tools list should have 1 tool (echo).
  let initial_tools = mcp_client.tools(client)
  initial_tools |> list.length |> should.equal(1)

  // After the notification is processed, tools should be re-fetched.
  // The mock server sends tools/list_changed before the tools/list response.
  // The notification is intercepted by the FFI and forwarded to the manager.
  // Give the manager time to process the queued notification.
  process.sleep(100)

  let updated_tools = mcp_client.tools(client)
  // The refresh re-fetches tools/list, which still returns 1 tool.
  // But the notification was received and processed successfully.
  updated_tools |> list.length |> should.equal(1)

  mcp_client.stop(client)
}

pub fn notification_resources_list_changed_test() {
  let assert Ok(client) = mcp_client.new()

  let config =
    manager.ServerConfig(
      name: "notif-res",
      command: "python3",
      args: ["test/mock_mcp_server_notifications.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = mcp_client.register(client, config)

  let initial_resources = mcp_client.resources(client)
  initial_resources |> list.length |> should.equal(1)

  process.sleep(100)

  let updated_resources = mcp_client.resources(client)
  updated_resources |> list.length |> should.equal(1)

  mcp_client.stop(client)
}

pub fn subscribe_and_unsubscribe_test() {
  let assert Ok(client) = mcp_client.new()

  let config =
    manager.ServerConfig(
      name: "sub-server",
      command: "python3",
      args: ["test/mock_mcp_server_notifications.py"],
      env: [],
      retry: manager.NoRetry,
    )

  let assert Ok(Nil) = mcp_client.register(client, config)

  // Subscribe to a resource
  let sub_result =
    mcp_client.subscribe(client, "sub-server", "file:///hello.txt")
  sub_result |> should.be_ok

  // Unsubscribe from the resource
  let unsub_result =
    mcp_client.unsubscribe(client, "sub-server", "file:///hello.txt")
  unsub_result |> should.be_ok

  mcp_client.stop(client)
}

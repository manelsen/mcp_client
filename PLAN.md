# MCP Server-Sent Notifications Implementation Plan

## Problem

The MCP spec allows servers to send notifications to clients at any time:
- `notifications/tools/list_changed` — tool list has changed, re-fetch
- `notifications/resources/list_changed` — resource list has changed, re-fetch
- `notifications/resources/updated` — a specific resource was updated
- `notifications/prompts/list_changed` — prompt list has changed, re-fetch
- `notifications/cancelled` — server cancelled an in-progress request

Currently, the FFI `send_and_receive` is synchronous: it writes to the port and blocks in `wait_for_line` until it gets the first complete line back. If a notification arrives mid-request, it would be treated as the response and cause a protocol error (no `id` match, wrong shape).

## Architecture: Dedicated Port Reader Process

The current flow:
```
Manager -> Transport actor -> FFI send_and_receive (blocks in receive loop)
```

The new flow:
```
Manager -> Transport actor -> FFI send_data (fire-and-forget)
                              Port Reader process -> continuously reads from port
                                -> response: sends to waiting caller
                                -> notification: sends to transport actor
```

The port reader is an Erlang process (not a Gleam actor — it lives in FFI land) that:
1. Owns the port and continuously reads lines
2. For each line, checks if it has an `"id"` field
3. Lines with `"id"` → response → send to the waiting caller's process
4. Lines without `"id"` → notification → send to the transport actor's subject
5. The transport actor forwards notifications to the manager actor

This avoids changing the fundamental actor model and keeps the FFI boundary clean.

## Detailed Changes

### Layer 1: FFI (`src/mcp_client_ffi.erl`)

**Replace `send_and_receive/3`** with a new architecture:

1. `open_port/3` — unchanged (still returns `{ok, Port}`)
2. **New** `start_reader/2` — spawns a reader process that:
   - Becomes the port's controlling process via `erlang:port_connect`
   - Loops reading lines from the port
   - For each complete JSON line:
     - Try to parse as JSON, check for `"id"` field
     - If has `"id"` → it's a response → send `{mcp_response, Ref, Line}` to the caller waiting on that Ref
     - If no `"id"` → it's a notification → send `{mcp_notification, Line}` to the transport subject
   - On port exit → send `{mcp_exit, Status}` to transport subject
3. **New** `send_request/4` — sends `{CallerPid, Ref, Data}` to port, returns immediately
   - The reader process will route the response back via `{mcp_response, Ref, Line}`
4. `send_data/2` — unchanged (fire-and-forget, used for client→server notifications)
5. `close_port/1` — kills the reader process and closes the port

**Remove**: `wait_for_line/2`, `collect_rest/3` — the reader process replaces these.

### Layer 2: Transport (`src/mcp_client/transport.gleam`)

**Add to `StdioMessage`:**
```gleam
/// Internal: notification received from server
NotificationReceived(data: String)
/// Internal: port reader process died
PortExit(status: Int)
```

**Add to `StdioState`:**
```gleam
StdioState(
  port: Option(Dynamic),       // the port (kept for close_port)
  reader_pid: Option(Dynamic), // the reader process pid
  command: String,
  args: List(String),
  env: List(#(String, String)),
  connected: Bool,
  notification_handler: Option(Subject(String)), // where to forward notifications
)
```

**New FFI bindings:**
- `do_start_reader(Port, TransportSubject) -> Result(Pid, String)`
- `do_send_request(Port, CallerPid, Ref, Data) -> Result(Nil, String)` (replaces `do_send_and_receive`)

**Modified `send_and_receive`:**
Now uses `actor.call` pattern but the response comes from the reader process, not directly from the FFI. The transport actor:
1. Generates a unique reference
2. Calls `do_send_request(port, self(), ref, data)`
3. Waits for `{mcp_response, ref, result}` with timeout
4. Returns the result

Actually, since `send_and_receive` is called via `actor.call` which already does a selective receive, we need to rethink. The transport actor receives the `SendReceive` message, but the response will come from the reader process. We need the transport actor to wait for the response from the reader.

**Simpler approach**: Keep `send_and_receive` synchronous in the FFI but add a separate notification-draining mechanism.

Wait — let me reconsider. The fundamental issue is that between `port ! {self(), {command, Data}}` and receiving the response, a notification could arrive. The current code would treat that notification as the response.

**Revised simpler approach**: Keep the request-response flow synchronous, but make `wait_for_line` notification-aware.

```
wait_for_line(Port, TimeoutMs, TransportPid) ->
  receive
    {Port, {data, {eol, Line}}} ->
      case is_notification(Line) of
        true ->
          TransportPid ! {mcp_notification, Line},
          wait_for_line(Port, remaining_timeout, TransportPid);
        false ->
          {ok, Line}
      end;
    ...
  end.
```

This is much simpler. No separate reader process. The `wait_for_line` loop already receives lines — we just add notification detection and recursion.

**But this only works during active requests.** Notifications arriving when no request is in-flight (between calls) would buffer in the port's message queue and only be drained on the next `send_and_receive`. That's actually fine for STDIO — the port message queue will hold them, and they'll be drained on the next call.

Actually, there's a deeper issue. The port sends messages to its controlling process. The transport actor IS the controlling process (it called `open_port`). But `send_and_receive` is called FROM the transport actor's message handler, which is inside `actor.call`. The port messages arrive in the transport actor's mailbox. The current `wait_for_line` works because it does a selective receive on `{Port, {data, _}}` messages.

**So the simplest correct approach is:**

1. Add `TransportPid` parameter to `wait_for_line` / `collect_rest`
2. When a line without `"id"` arrives during `wait_for_line`, send it as `{mcp_notification, Line}` to the transport process (self) and recurse
3. The transport actor's message handler gains a `NotificationReceived(data)` variant
4. When the transport actor receives `NotificationReceived`, it forwards to the manager

This handles notifications arriving during requests. For notifications between requests, they sit in the port message queue and get drained + routed on the next `send_and_receive` call. To handle notifications that arrive when there are NO pending requests, we add a periodic drain.

**Even simpler**: notifications between requests are low-frequency. We don't need to handle them instantly. The manager can poll by sending a `DrainNotifications` message to the transport, which calls a new FFI `drain_notifications/1` that does a zero-timeout receive on the port. But this adds complexity.

**Simplest viable**: just handle notifications that arrive during `send_and_receive`. If a notification arrives between requests, it will be drained on the next `send_and_receive`. For STDIO transport, this is acceptable — notifications are rare and the delay is bounded by the next request.

**Decision: Simplest approach.** Modify `wait_for_line` to be notification-aware. Add notification forwarding to transport and manager.

### Layer 2 (revised): Transport

**Modified FFI:**
- `send_and_receive(Port, Data, TimeoutMs, NotifyPid)` — new 4th param
  - When a notification is detected during `wait_for_line`, send `{mcp_notification, Line}` to `NotifyPid` and keep waiting for the real response
- `drain_notifications(Port, NotifyPid)` — non-blocking drain of any buffered port messages
  - Zero-timeout receive loop, forwards notifications to NotifyPid

**Modified `StdioMessage`:**
```gleam
NotificationReceived(data: String)
```

**Modified `StdioState`:**
- Add `manager_subject: Option(Subject(ManagerMessage))` — where to forward notifications

**Modified `handle_message`:**
- `NotificationReceived(data)` → forward to manager subject (if set)
- After each `SendReceive`, call `drain_notifications` to process any queued notifications

### Layer 3: Manager

**Add `ManagerMessage` variants:**
```gleam
ServerNotification(server_name: String, method: String, params: String)
```

**Add handler:**
```gleam
ServerNotification(server_name, method, params) -> {
  let new_state = case method {
    "notifications/tools/list_changed" -> refresh_tools(state, server_name)
    "notifications/resources/list_changed" -> refresh_resources(state, server_name)
    "notifications/prompts/list_changed" -> refresh_prompts(state, server_name)
    "notifications/resources/updated" -> state  // log, no action needed
    "notifications/cancelled" -> state  // log, no action needed
    _ -> state
  }
  actor.continue(new_state)
}
```

**Add refresh functions:**
- `refresh_tools(state, server_name)` — sends `tools/list` to the server, updates `state.tools`
- `refresh_resources(state, server_name)` — sends `resources/list`, updates `state.resources`
- `refresh_prompts(state, server_name)` — sends `prompts/list`, updates `state.prompts`

**Subscribe/Unsubscribe (new public API):**
```gleam
// ManagerMessage variants
SubscribeResource(reply_to: Subject(Result(Nil, String)), server_name: String, uri: String)
UnsubscribeResource(reply_to: Subject(Result(Nil, String)), server_name: String, uri: String)
```

These send `resources/subscribe` and `resources/unsubscribe` JSON-RPC requests.

### Layer 4: Facade (`src/mcp_client.gleam`)

```gleam
pub fn subscribe(client: Client, server: String, uri: String) -> Result(Nil, String)
pub fn unsubscribe(client: Client, server: String, uri: String) -> Result(Nil, String)
```

## File Change Summary

| File | Changes |
|------|---------|
| `src/mcp_client_ffi.erl` | Modify `send_and_receive` to accept NotifyPid, add notification detection in `wait_for_line`/`collect_rest`, add `drain_notifications/2` |
| `src/mcp_client/transport.gleam` | Add `NotificationReceived` variant, forward to manager, call drain after requests |
| `src/mcp_client/manager.gleam` | Add `ServerNotification` handler, refresh functions, subscribe/unsubscribe |
| `src/mcp_client.gleam` | Add `subscribe`/`unsubscribe` public API |
| `test/mock_mcp_server_notifications.py` | New mock server that sends notifications |
| `test/mcp_client_test.gleam` | Add notification integration tests |

## Testing Plan

1. Create `mock_mcp_server_notifications.py` that:
   - Responds to `initialize` normally
   - After `tools/list`, sends `notifications/tools/list_changed` with an updated tool list
   - After `resources/list`, sends `notifications/resources/list_changed`
   - Supports `resources/subscribe` and `resources/unsubscribe`
   - After subscribe, sends `notifications/resources/updated`

2. Tests:
   - `notifications_tools_list_changed_updates_state_test` — register server, verify initial tools, server sends list_changed, verify tools updated
   - `notifications_resources_list_changed_updates_state_test` — same for resources
   - `notifications_prompts_list_changed_updates_state_test` — same for prompts
   - `subscribe_and_unsubscribe_test` — subscribe/unsubscribe round-trip
   - All existing 50 tests must still pass

# Changelog

## 0.1.0 (2026-04-21)

Initial release.

- STDIO transport: spawns external process, communicates via newline-delimited JSON-RPC 2.0.
- Multi-server OTP actor manager with qualified tool names (`"server_name/tool_name"`).
- Full MCP initialize handshake: `initialize` → `notifications/initialized`.
- `tools/list` discovery and `tools/call` execution.
- `resources/list` discovery and `resources/read` access.
- `prompts/list` discovery and `prompts/get` rendering.
- `RetryPolicy` (`NoRetry` | `Retry(max_attempts, base_delay_ms)`) with exponential-backoff reconnection on server crash.
- Protocol version validation (rejects versions other than `2024-11-05`).
- Automatic dead-server eviction on port crash.
- 1 MB line buffer for large payloads.

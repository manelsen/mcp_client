#!/usr/bin/env python3
"""Mock MCP server that crashes on the first tools/call, then works normally.

Usage: python3 mock_mcp_server_crash_once.py <flag_file_path>

- First invocation (flag absent): responds to init + tools/list, then exits
  without responding to the first tools/call (simulates crash), and creates
  the flag file.
- Subsequent invocations (flag present): deletes the flag, works normally.
"""

import json
import os
import sys

flag_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/gleam_mcp_crash_once_flag"
is_recovered = os.path.exists(flag_file)


def handle_request(request):
    method = request.get("method", "")
    req_id = request.get("id")
    params = request.get("params", {})

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "crash-once-server", "version": "1.0.0"},
            },
        }

    elif method == "notifications/initialized":
        return None

    elif method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "tools": [
                    {
                        "name": "echo",
                        "description": "Echo back the message",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"message": {"type": "string"}},
                            "required": ["message"],
                        },
                    }
                ]
            },
        }

    elif method == "tools/call":
        if not is_recovered:
            # Create flag to signal "has crashed once" and exit without responding
            with open(flag_file, "w") as f:
                f.write("")
            sys.exit(1)
        else:
            # Recovered — delete flag so the test can re-run cleanly, then respond
            if os.path.exists(flag_file):
                os.remove(flag_file)
            tool_name = params.get("name", "")
            arguments = params.get("arguments", {})
            if tool_name == "echo":
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": arguments.get("message", "")}]
                    },
                }
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Tool not found: {tool_name}"},
            }

    else:
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Method not found: {method}"},
        }


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            response = handle_request(request)
            if response is not None:
                sys.stdout.write(json.dumps(response) + "\n")
                sys.stdout.flush()
        except Exception as e:
            sys.stdout.write(
                json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32603, "message": str(e)}})
                + "\n"
            )
            sys.stdout.flush()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Mock MCP server for testing JSON-RPC 2.0 over STDIO.

Responds to:
- initialize, notifications/initialized
- tools/list, tools/call (echo, add, big_data, special_chars)
- resources/list, resources/read
- prompts/list, prompts/get
"""

import json
import sys


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
                "capabilities": {"tools": {}, "resources": {}, "prompts": {}},
                "serverInfo": {"name": "mock-mcp-server", "version": "1.0.0"},
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
                        "description": "Echo back the input message",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"message": {"type": "string"}},
                            "required": ["message"],
                        },
                    },
                    {
                        "name": "add",
                        "description": "Add two numbers",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "a": {"type": "number"},
                                "b": {"type": "number"},
                            },
                            "required": ["a", "b"],
                        },
                    },
                    {
                        "name": "big_data",
                        "description": "Returns a large payload to test buffer handling",
                        "inputSchema": {"type": "object", "properties": {}, "required": []},
                    },
                    {
                        "name": "special_chars",
                        "description": "Returns text with JSON special characters",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"input": {"type": "string"}},
                            "required": ["input"],
                        },
                    },
                ]
            },
        }

    elif method == "tools/call":
        tool_name = params.get("name", "")
        arguments = params.get("arguments", {})

        if tool_name == "echo":
            message = arguments.get("message", "")
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"content": [{"type": "text", "text": message}]},
            }
        elif tool_name == "add":
            result = arguments.get("a", 0) + arguments.get("b", 0)
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"content": [{"type": "text", "text": str(result)}]},
            }
        elif tool_name == "big_data":
            text = "A" * 8192
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"content": [{"type": "text", "text": text}]},
            }
        elif tool_name == "special_chars":
            inp = arguments.get("input", "")
            text = f'Result: "{inp}" with backslash \\ and newline embedded'
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"content": [{"type": "text", "text": text}]},
            }
        else:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Tool not found: {tool_name}"},
            }

    elif method == "resources/list":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "resources": [
                    {
                        "uri": "file:///hello.txt",
                        "name": "hello.txt",
                        "description": "A greeting file",
                        "mimeType": "text/plain",
                    },
                    {
                        "uri": "file:///world.txt",
                        "name": "world.txt",
                        "description": "A world file",
                        "mimeType": "text/plain",
                    },
                ]
            },
        }

    elif method == "resources/read":
        uri = params.get("uri", "")
        contents = {
            "file:///hello.txt": "Hello, world!",
            "file:///world.txt": "The world is round.",
        }
        if uri in contents:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "contents": [{"uri": uri, "mimeType": "text/plain", "text": contents[uri]}]
                },
            }
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Resource not found: {uri}"},
        }

    elif method == "prompts/list":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "prompts": [
                    {
                        "name": "greet",
                        "description": "Generate a greeting",
                        "arguments": [
                            {"name": "name", "description": "Name to greet", "required": True}
                        ],
                    }
                ]
            },
        }

    elif method == "prompts/get":
        prompt_name = params.get("name", "")
        arguments = params.get("arguments", {})
        if prompt_name == "greet":
            name = arguments.get("name", "World")
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "description": "Greeting prompt",
                    "messages": [
                        {
                            "role": "user",
                            "content": {"type": "text", "text": f"Please greet {name} warmly."},
                        }
                    ],
                },
            }
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Prompt not found: {prompt_name}"},
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
        except json.JSONDecodeError:
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}) + "\n")
            sys.stdout.flush()
        except Exception as e:
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32603, "message": str(e)}}) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()

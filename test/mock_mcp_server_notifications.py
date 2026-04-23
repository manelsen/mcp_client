#!/usr/bin/env python3
"""Mock MCP server that automatically emits notifications.

After responding to tools/list, sends notifications/tools/list_changed.
After responding to resources/list, sends notifications/resources/list_changed.
After responding to prompts/list, sends notifications/prompts/list_changed.

Supports resources/subscribe and resources/unsubscribe.
The updated tools list includes an extra "added_tool" tool after the notification.
The updated resources list includes an extra "file:///updated.txt" resource.
"""

import json
import sys

# Track whether we've sent the initial list_changed notifications
sent_tools_changed = False
sent_resources_changed = False
sent_prompts_changed = False


def make_notification(method, params=None):
    if params is None:
        params = {}
    return {"jsonrpc": "2.0", "method": method, "params": params}


def handle_request(request):
    global sent_tools_changed, sent_resources_changed, sent_prompts_changed
    method = request.get("method", "")
    req_id = request.get("id")
    params = request.get("params", {})

    if method == "initialize":
        return [
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {
                        "tools": {"listChanged": True},
                        "resources": {"subscribe": True, "listChanged": True},
                        "prompts": {"listChanged": True},
                    },
                    "serverInfo": {
                        "name": "mock-mcp-auto-notifications",
                        "version": "1.0.0",
                    },
                },
            }
        ]

    elif method == "notifications/initialized":
        return []

    elif method == "tools/list":
        response = {
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
                ]
            },
        }
        # Send notification after response
        if not sent_tools_changed:
            sent_tools_changed = True
            notification = make_notification("notifications/tools/list_changed")
            return [notification, response]
        return [response]

    elif method == "tools/call":
        tool_name = params.get("name", "")
        arguments = params.get("arguments", {})
        if tool_name == "echo":
            return [
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": arguments.get("message", "")}]
                    },
                }
            ]
        if tool_name == "added_tool":
            return [
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": "added tool called"}]
                    },
                }
            ]
        return [
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Tool not found: {tool_name}"},
            }
        ]

    elif method == "resources/list":
        response = {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "resources": [
                    {
                        "uri": "file:///hello.txt",
                        "name": "hello.txt",
                        "description": "A greeting file",
                    },
                ]
            },
        }
        if not sent_resources_changed:
            sent_resources_changed = True
            notification = make_notification("notifications/resources/list_changed")
            return [notification, response]
        return [response]

    elif method == "resources/read":
        uri = params.get("uri", "")
        contents = {
            "file:///hello.txt": "Hello, world!",
            "file:///updated.txt": "Updated content!",
        }
        if uri in contents:
            return [
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "contents": [
                            {"uri": uri, "mimeType": "text/plain", "text": contents[uri]}
                        ]
                    },
                }
            ]
        return [
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Resource not found: {uri}"},
            }
        ]

    elif method == "resources/subscribe":
        return [
            {"jsonrpc": "2.0", "id": req_id, "result": {}},
        ]

    elif method == "resources/unsubscribe":
        return [
            {"jsonrpc": "2.0", "id": req_id, "result": {}},
        ]

    elif method == "prompts/list":
        response = {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "prompts": [
                    {
                        "name": "greet",
                        "description": "Generate a greeting",
                        "arguments": [
                            {
                                "name": "name",
                                "description": "Name to greet",
                                "required": True,
                            }
                        ],
                    }
                ]
            },
        }
        if not sent_prompts_changed:
            sent_prompts_changed = True
            notification = make_notification("notifications/prompts/list_changed")
            return [notification, response]
        return [response]

    elif method == "prompts/get":
        return [
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "description": "Greeting prompt",
                    "messages": [
                        {
                            "role": "user",
                            "content": {
                                "type": "text",
                                "text": f"Please greet {params.get('arguments', {}).get('name', 'World')} warmly.",
                            },
                        }
                    ],
                },
            }
        ]

    else:
        return [
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Method not found: {method}"},
            }
        ]


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            responses = handle_request(request)
            for response in responses:
                if response is not None:
                    sys.stdout.write(json.dumps(response) + "\n")
                    sys.stdout.flush()
        except json.JSONDecodeError:
            sys.stdout.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": None,
                        "error": {"code": -32700, "message": "Parse error"},
                    }
                )
                + "\n"
            )
            sys.stdout.flush()
        except Exception as e:
            sys.stdout.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": None,
                        "error": {"code": -32603, "message": str(e)},
                    }
                )
                + "\n"
            )
            sys.stdout.flush()


if __name__ == "__main__":
    main()

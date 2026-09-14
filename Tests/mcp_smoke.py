#!/usr/bin/env python3
"""Exercise every MCP tool over stdio and HTTP without provider credentials."""
import json
import select
import subprocess
import sys
import time
import urllib.error
import urllib.request

CLI = sys.argv[1]
PORT = 18765
URL = f"http://127.0.0.1:{PORT}/mcp"
INIT = {"protocolVersion": "2025-11-25", "capabilities": {},
        "clientInfo": {"name": "assistantctl-smoke", "version": "1"}}
CASES = [
    ("sources", {}),
    ("connection_status", {"provider": "gmail"}),
    ("conversations", {"provider": "gmail"}),
    ("messages_list", {"limit": 1}),
    ("messages_get", {"id": "smoke:missing"}),
    ("messages_search", {"query": "improbable-smoke-query", "limit": 1}),
    ("sync", {"provider": "invalid"}),
    ("backfill", {"provider": "invalid", "limit": 1}),
    ("login_start", {"provider": "invalid"}),
    ("login_complete", {"session_id": "missing", "value": "unused"}),
    ("login_status", {"session_id": "missing"}),
]


def payload(number, method, params):
    return {"jsonrpc": "2.0", "id": number, "method": method, "params": params}


def stdio():
    process = subprocess.Popen([CLI, "mcp", "stdio"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        def call(number, method, params):
            process.stdin.write(json.dumps(payload(number, method, params)) + "\n")
            process.stdin.flush()
            ready, _, _ = select.select([process.stdout], [], [], 10)
            assert ready, f"stdio timeout: {method}"
            return json.loads(process.stdout.readline())

        assert call(1, "initialize", INIT)["result"]["protocolVersion"] == "2025-11-25"
        assert len(call(2, "tools/list", {})["result"]["tools"]) == len(CASES)
        for number, (name, arguments) in enumerate(CASES, 3):
            result = call(number, "tools/call", {"name": name, "arguments": arguments})
            assert "result" in result, f"stdio tool dispatch failed: {name}"
        started = call(20, "tools/call", {"name": "login_start", "arguments": {
            "provider": "gmail", "oauth_config": "/nonexistent/assistantctl-smoke-oauth.json"}})
        session = started["result"]["structuredContent"]["sessionID"]
        for _ in range(20):
            state = call(21, "tools/call", {"name": "login_status", "arguments": {"session_id": session}})
            if state["result"]["structuredContent"]["state"] == "failed":
                break
            time.sleep(0.05)
        else:
            raise AssertionError("stdio login failure was not reported")
        rejected = call(22, "tools/call", {"name": "login_complete", "arguments": {
            "session_id": session, "value": "unused"}})
        assert rejected["result"]["isError"]
        process.stdin.close()
        assert process.wait(timeout=5) == 0, "stdio did not stop on EOF"
        assert not process.stdout.read(), "stdio emitted non-protocol output"
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)


def http():
    process = subprocess.Popen([CLI, "mcp", "serve", "--port", str(PORT)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    token = subprocess.check_output([CLI, "mcp", "token"], text=True).strip()

    def call(number, method, params, bearer=None, origin=None):
        headers = {"Content-Type": "application/json",
                   "Accept": "application/json, text/event-stream",
                   "MCP-Protocol-Version": "2025-11-25"}
        if bearer:
            headers["Authorization"] = "Bearer " + bearer
        if origin:
            headers["Origin"] = origin
        request = urllib.request.Request(URL, json.dumps(payload(number, method, params)).encode(), headers)
        try:
            with opener.open(request, timeout=10) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, None

    try:
        for _ in range(50):
            try:
                unauthorized = call(1, "initialize", INIT)
                break
            except (TimeoutError, urllib.error.URLError, ConnectionError):
                time.sleep(0.1)
        else:
            raise AssertionError("HTTP server did not start")
        assert unauthorized[0] == 401
        assert call(2, "initialize", INIT, token, "http://wrong.invalid")[0] == 403
        status, response = call(3, "initialize", INIT, token)
        assert status == 200 and response["result"]["protocolVersion"] == "2025-11-25"
        status, response = call(4, "tools/list", {}, token)
        assert status == 200 and len(response["result"]["tools"]) == len(CASES)
        for number, (name, arguments) in enumerate(CASES, 5):
            status, response = call(number, "tools/call", {"name": name, "arguments": arguments}, token)
            assert status == 200 and "result" in response, f"HTTP tool dispatch failed: {name}"
        status, started = call(20, "tools/call", {"name": "login_start", "arguments": {
            "provider": "gmail", "oauth_config": "/nonexistent/assistantctl-smoke-oauth.json"}}, token)
        assert status == 200
        session = started["result"]["structuredContent"]["sessionID"]
        for _ in range(20):
            status, response = call(21, "tools/call", {"name": "login_status", "arguments": {
                "session_id": session}}, token)
            if response["result"]["structuredContent"]["state"] == "failed":
                break
            time.sleep(0.05)
        else:
            raise AssertionError("HTTP login failure was not reported")
        status, rejected = call(22, "tools/call", {"name": "login_complete", "arguments": {
            "session_id": session, "value": "unused"}}, token)
        assert status == 200 and rejected["result"]["isError"]
        new_token = subprocess.check_output([CLI, "mcp", "token", "--rotate"], text=True).strip()
        assert call(30, "tools/list", {}, token)[0] == 401
        assert call(31, "tools/list", {}, new_token)[0] == 200
    finally:
        process.terminate()
        process.wait(timeout=5)
        assert not process.stdout.read(), "HTTP server wrote to stdout"


stdio()
http()
print("MCP stdio and HTTP smoke checks passed")

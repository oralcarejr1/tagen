#!/usr/bin/env python3
"""Deterministic stand-in for `claude -p --output-format stream-json` (test fixture only).
Scenario via FAKE_SCENARIO: success | approval | auth | crash | hang | max_turns."""
import json, os, signal, subprocess, sys, time

args = sys.argv[1:]
def opt(name):
    return args[args.index(name) + 1] if name in args else None

if os.environ.get("FAKE_ARGS_FILE"):
    with open(os.environ["FAKE_ARGS_FILE"], "w") as f: json.dump(args, f)

scenario = os.environ.get("FAKE_SCENARIO", "success")
prompt = sys.stdin.read()
session = opt("--resume") or "sess-123"
signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

def out(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()

out({"type": "system", "subtype": "init", "session_id": session, "tools": ["Read", "Bash"], "model": opt("--model") or "fake"})

if scenario == "auth":
    out({"type": "result", "subtype": "success", "is_error": True, "result": "Invalid API key · Please run /login", "session_id": session})
    sys.exit(1)
if scenario == "crash":
    sys.stderr.write("panic: fake crash in tool loop\n"); sys.stderr.flush()
    sys.exit(3)
if scenario == "hang":
    while True: time.sleep(0.1)
if scenario == "max_turns":
    out({"type": "result", "subtype": "error_max_turns", "is_error": False, "num_turns": 2, "session_id": session, "errors": []})
    sys.exit(0)

for chunk in ["Work", "ing…"]:
    out({"type": "stream_event", "session_id": session, "parent_tool_use_id": None,
         "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": chunk}}})
out({"type": "assistant", "session_id": session, "parent_tool_use_id": None,
     "message": {"content": [{"type": "text", "text": "Working…"}, {"type": "tool_use", "id": "toolu_read", "name": "Read", "input": {"file_path": "README.md"}}]}})
out({"type": "user", "session_id": session, "parent_tool_use_id": None,
     "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_read", "content": "file contents"}]}})

final = "echo: " + prompt.strip()
if opt("--resume"): final = "resumed " + opt("--resume") + " / " + final

if scenario == "approval":
    cfg = json.load(open(opt("--mcp-config")))
    tool = opt("--permission-prompt-tool")
    server_name = tool.split("__")[1]
    srv = cfg["mcpServers"][server_name]
    env = dict(os.environ); env.update(srv.get("env", {}))
    p = subprocess.Popen([srv["command"]] + srv.get("args", []), stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True)
    def rpc(i, method, params):
        p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n"); p.stdin.flush()
        return json.loads(p.stdout.readline())
    rpc(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "fake-claude", "version": "0"}})
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); p.stdin.flush()
    tools = rpc(2, "tools/list", {})
    assert tools["result"]["tools"][0]["name"] == tool.split("__")[2]
    out({"type": "assistant", "session_id": session, "parent_tool_use_id": None,
         "message": {"content": [{"type": "tool_use", "id": "toolu_bash", "name": "Bash", "input": {"command": "rm -rf build"}}]}})
    r = rpc(3, "tools/call", {"name": tool.split("__")[2], "arguments": {"tool_name": "Bash", "input": {"command": "rm -rf build"}, "tool_use_id": "toolu_bash"}})
    decision = json.loads(r["result"]["content"][0]["text"])
    p.stdin.close(); p.wait(timeout=5)
    if decision["behavior"] == "allow":
        assert decision["updatedInput"] == {"command": "rm -rf build"}
        out({"type": "user", "session_id": session, "parent_tool_use_id": None, "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_bash", "content": "removed"}]}})
        final = "allowed"
    else:
        out({"type": "user", "session_id": session, "parent_tool_use_id": None, "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_bash", "is_error": True, "content": decision.get("message", "")}]}})
        final = "denied: " + decision.get("message", "")

out({"type": "assistant", "session_id": session, "parent_tool_use_id": None, "message": {"content": [{"type": "text", "text": final}]}})
out({"type": "result", "subtype": "success", "is_error": False, "result": final, "session_id": session, "num_turns": 3,
     "total_cost_usd": 0.0123, "duration_ms": 456, "permission_denials": []})

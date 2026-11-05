#!/usr/bin/env python3
"""Deterministic stand-in for `claude -p --input-format stream-json --output-format stream-json`
used as a plain model call by ClaudeCLIModelClient (test fixture only).
Scenario via FAKE_SCENARIO: success | result_only | auth | limit | crash | hang.
FAKE_RECORD_FILE receives {"args": [...], "stdin": [...], "env": {...}}."""
import json, os, signal, sys, time

args = sys.argv[1:]
def opt(name):
    return args[args.index(name) + 1] if name in args else None

lines = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
if os.environ.get("FAKE_RECORD_FILE"):
    with open(os.environ["FAKE_RECORD_FILE"], "w") as f:
        json.dump({"args": args, "stdin": lines, "cwd": os.getcwd(),
                   "env": {k: os.environ[k] for k in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN") if k in os.environ}}, f)

scenario = os.environ.get("FAKE_SCENARIO", "success")
signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

def out(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()

model = {"sonnet": "claude-sonnet-5-5", "opus": "claude-opus-5-5"}.get(opt("--model"), opt("--model") or "fake")
out({"type": "system", "subtype": "init", "session_id": "s1", "tools": [], "mcp_servers": [], "model": model})

if scenario == "auth":
    out({"type": "assistant", "session_id": "s1", "parent_tool_use_id": None, "error": "authentication_failed",
         "message": {"content": [{"type": "text", "text": "Not logged in · Please run /login"}]}})
    out({"type": "result", "subtype": "success", "is_error": True, "result": "Not logged in · Please run /login", "session_id": "s1"})
    sys.exit(1)
if scenario == "limit":
    out({"type": "result", "subtype": "success", "is_error": True, "result": "Claude usage limit reached. Your limit will reset at 5pm.", "session_id": "s1"})
    sys.exit(1)
if scenario == "crash":
    sys.stderr.write("fatal: fake crash before result\n"); sys.stderr.flush()
    sys.exit(2)
if scenario == "hang":
    while True: time.sleep(0.1)

content = lines[0]["message"]["content"] if lines else []
images = sum(1 for b in content if b.get("type") == "image")
texts = [b["text"] for b in content if b.get("type") == "text"]
answer = f"images={images} last={texts[-1] if texts else ''}"

if scenario == "result_only":
    out({"type": "result", "subtype": "success", "is_error": False, "result": answer, "session_id": "s1",
         "usage": {"input_tokens": 3, "output_tokens": 5}})
    sys.exit(0)

for chunk in [answer[:7], answer[7:]]:
    out({"type": "stream_event", "session_id": "s1", "parent_tool_use_id": None,
         "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": chunk}}})
out({"type": "assistant", "session_id": "s1", "parent_tool_use_id": None, "message": {"content": [{"type": "text", "text": answer}]}})
out({"type": "result", "subtype": "success", "is_error": False, "result": answer, "session_id": "s1",
     "usage": {"input_tokens": 11, "output_tokens": 7, "cache_read_input_tokens": 2, "cache_creation_input_tokens": 954}})

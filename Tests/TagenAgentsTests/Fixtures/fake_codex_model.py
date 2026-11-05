#!/usr/bin/env python3
"""Deterministic stand-in for `codex exec --json --ephemeral ... -` used as a plain model call by
CodexCLIModelClient (test fixture only).
Scenario via FAKE_SCENARIO: success | no_answer | auth | limit | crash | hang.
FAKE_RECORD_FILE receives {"args", "stdin", "cwd", "env", "images": [[path, size, exists]]}."""
import json, os, signal, sys, time

args = sys.argv[1:]
stdin = sys.stdin.read()
images = [args[i + 1] for i, a in enumerate(args) if a == "--image"]
if os.environ.get("FAKE_RECORD_FILE"):
    with open(os.environ["FAKE_RECORD_FILE"], "w") as f:
        json.dump({"args": args, "stdin": stdin, "cwd": os.getcwd(),
                   "images": [[p, os.path.getsize(p) if os.path.exists(p) else -1] for p in images],
                   "env": {k: os.environ[k] for k in ("OPENAI_API_KEY", "CODEX_API_KEY") if k in os.environ}}, f)

scenario = os.environ.get("FAKE_SCENARIO", "success")
signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
def out(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()

assert args[0] == "exec" and "--json" in args and args[-1] == "-"
out({"type": "thread.started", "thread_id": "thr_model"})
out({"type": "turn.started"})
if scenario == "auth":
    out({"type": "error", "message": "unexpected status 401 Unauthorized"})
    out({"type": "turn.failed", "error": {"message": "unexpected status 401 Unauthorized: please run codex login"}}); sys.exit(1)
if scenario == "limit":
    out({"type": "turn.failed", "error": {"message": "You've hit your usage limit. Try again later."}}); sys.exit(1)
if scenario == "crash":
    sys.stderr.write("thread 'main' panicked: fake\n"); sys.stderr.flush(); sys.exit(101)
if scenario == "hang":
    while True: time.sleep(0.1)

out({"type": "item.completed", "item": {"id": "item_0", "type": "error", "message": "Code Mode is unavailable because code-mode host is disabled."}})
if scenario != "no_answer":
    out({"type": "item.completed", "item": {"id": "item_1", "type": "agent_message", "text": "I'll look at the image."}})
    last = stdin.strip().splitlines()[-1] if stdin.strip() else ""
    out({"type": "item.completed", "item": {"id": "item_2", "type": "agent_message", "text": f"images={len(images)} last={last}"}})
out({"type": "turn.completed", "usage": {"input_tokens": 120, "cached_input_tokens": 80, "output_tokens": 9}})

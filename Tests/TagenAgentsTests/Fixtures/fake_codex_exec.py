#!/usr/bin/env python3
"""Deterministic stand-in for `codex exec --json` (test fixture only)."""
import json, os, sys
args = sys.argv[1:]
if os.environ.get("FAKE_ARGS_FILE"):
    with open(os.environ["FAKE_ARGS_FILE"], "w") as f: json.dump(args, f)
scenario = os.environ.get("FAKE_SCENARIO", "success")
def out(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
assert args[0] == "exec" and "--json" in args
tid = args[args.index("resume") + 1] if "resume" in args else "thr_exec"
out({"type": "thread.started", "thread_id": tid})
out({"type": "turn.started"})
if scenario == "fail":
    out({"type": "turn.failed", "error": {"message": "stream error: 401 Unauthorized"}}); sys.exit(1)
out({"type": "item.started", "item": {"id": "item_0", "type": "command_execution", "command": "bash -lc ls", "status": "in_progress"}})
out({"type": "item.completed", "item": {"id": "item_0", "type": "command_execution", "command": "bash -lc ls", "aggregated_output": "a\n", "exit_code": 0, "status": "completed"}})
out({"type": "item.completed", "item": {"id": "item_1", "type": "file_change", "changes": [{"path": "src/x.py", "kind": "update"}], "status": "completed"}})
out({"type": "item.completed", "item": {"id": "item_2", "type": "agent_message", "text": "Done: " + args[-1]}})
out({"type": "turn.completed", "usage": {"input_tokens": 10, "output_tokens": 5}})

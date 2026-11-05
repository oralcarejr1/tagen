#!/usr/bin/env python3
"""Deterministic stand-in for `codex app-server` (JSONL JSON-RPC, no "jsonrpc" header).
Scenario via FAKE_SCENARIO: success | approval | fileapproval | legacy | auth | crash | hang | turnfail."""
import json, os, sys

scenario = os.environ.get("FAKE_SCENARIO", "success")
log = os.environ.get("FAKE_LOG")
def note(s):
    if log:
        with open(log, "a") as f: f.write(s + "\n")
def out(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()

thread_id, turn_id, resumed, pending, cwd = None, "turn_1", False, None, os.getcwd()

def finish_turn(text):
    out({"method": "item/completed", "params": {"item": {"type": "agentMessage", "id": "msg1", "text": text}}})
    out({"method": "turn/completed", "params": {"turn": {"id": turn_id, "status": "completed"}}})

for line in sys.stdin:
    line = line.strip()
    if not line: continue
    m = json.loads(line)
    assert "jsonrpc" not in m, "client must omit the jsonrpc header"
    method, mid = m.get("method"), m.get("id")
    note(f"recv {method or 'response'}")
    if method is None:  # response to our server request
        if pending == mid:
            if "error" in m:
                finish_turn("error=" + str(m["error"]["code"])); continue
            decision = m["result"]["decision"]
            valid = {"accept", "acceptForSession", "decline", "cancel", "approved", "approved_for_session", "abort"}
            if isinstance(decision, dict):
                assert set(decision) == {"denied"} and "rejection" in decision["denied"], decision
                decision = "denied"
            else:
                assert decision in valid, decision
            note("decision " + decision)
            finish_turn("decision=" + decision)
        continue
    params = m.get("params") or {}
    if method == "initialize":
        assert params["clientInfo"]["name"] == "tagen"
        assert "capabilities" in params, "InitializeParams.capabilities is required (nullable)"
        out({"id": mid, "result": {"userAgent": "fake-codex/0"}})
    elif method == "initialized":
        pass
    elif method == "account/read":
        if scenario == "auth": out({"id": mid, "result": {"account": None, "requiresOpenaiAuth": True}})
        else: out({"id": mid, "result": {"account": {"type": "apiKey"}, "requiresOpenaiAuth": True}})
    elif method == "thread/start":
        note("thread/start " + json.dumps(params, sort_keys=True))
        cwd = params.get("cwd", cwd)
        thread_id = "thr_new"
        out({"id": mid, "result": {"thread": {"id": thread_id}}})
        out({"method": "thread/started", "params": {"thread": {"id": thread_id}}})
    elif method == "thread/resume":
        assert params.get("excludeTurns") is True, "use excludeTurns (full-history hydration is deprecated)"
        thread_id, resumed = params["threadId"], True
        out({"id": mid, "result": {"thread": {"id": thread_id}}})
    elif method == "turn/start":
        assert params["threadId"] == thread_id
        inp = params["input"][0]
        assert inp["type"] == "text" and isinstance(inp.get("text_elements"), list), "UserInput text requires text_elements"
        prompt = inp["text"]
        out({"id": mid, "result": {"turn": {"id": turn_id, "status": "inProgress"}}})
        out({"method": "turn/started", "params": {"turn": {"id": turn_id}}})
        if scenario == "crash" and not resumed:
            sys.stderr.write("thread 'main' panicked\n"); sys.stderr.flush(); sys.exit(5)
        if scenario == "hang":
            continue
        if scenario == "turnfail":
            out({"method": "turn/completed", "params": {"turn": {"id": turn_id, "status": "failed", "error": {"message": "unexpected status 401 Unauthorized"}}}})
            continue
        out({"method": "item/started", "params": {"item": {"type": "commandExecution", "id": "cmd1", "command": "ls", "status": "inProgress"}}})
        out({"method": "item/commandExecution/outputDelta", "params": {"itemId": "cmd1", "delta": "README.md\n"}})
        out({"method": "item/completed", "params": {"item": {"type": "commandExecution", "id": "cmd1", "command": "ls", "exitCode": 0, "status": "completed", "aggregatedOutput": "README.md\n"}}})
        if scenario == "userinput":
            pending = "srv-1"
            out({"id": pending, "method": "item/tool/requestUserInput", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "q1", "questions": []}})
            continue
        if scenario in ("approval", "fileapproval", "legacy"):
            pending = "srv-1"
            if scenario == "approval":
                out({"id": pending, "method": "item/commandExecution/requestApproval", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "cmd2", "command": "rm -rf build", "cwd": cwd, "reason": "clean build"}})
            elif scenario == "fileapproval":
                # Per schema: paths are announced on the fileChange item; the approval request references itemId only.
                out({"method": "item/started", "params": {"threadId": thread_id, "turnId": turn_id, "startedAtMs": 0, "item": {"type": "fileChange", "id": "fc1", "status": "inProgress", "changes": [{"path": cwd + "/a.swift", "kind": {"type": "update", "move_path": None}, "diff": "@@"}]}}})
                out({"id": pending, "method": "item/fileChange/requestApproval", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "fc1", "startedAtMs": 0, "reason": None, "grantRoot": None}})
            else:
                out({"id": pending, "method": "execCommandApproval", "params": {"conversationId": thread_id, "callId": "c1", "command": ["git", "push"], "cwd": cwd}})
            continue
        for d in ["Hel", "lo"]:
            out({"method": "item/agentMessage/delta", "params": {"itemId": "msg1", "delta": d}})
        finish_turn("recovered" if resumed else "Hello")
    elif method == "turn/interrupt":
        note("interrupt")
        out({"id": mid, "result": {}})
        out({"method": "turn/completed", "params": {"turn": {"id": turn_id, "status": "interrupted"}}})
    else:
        out({"id": mid, "error": {"code": -32601, "message": "unknown method " + method}})

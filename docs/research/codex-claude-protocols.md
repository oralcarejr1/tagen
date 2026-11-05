# Codex and Claude Code integration — protocol notes

## Claude Code (verified against code.claude.com docs, 2026-11)
- Headless: `claude -p --output-format stream-json --verbose` (prompt on stdin), optional `--include-partial-messages`
  (emits `stream_event` with `event.delta.type == "text_delta"`).
- Session: `--resume <session_id>`; `session_id` appears on stream messages.
- Permissions: `--permission-mode default|acceptEdits|plan|auto|dontAsk|bypassPermissions` — **Tagen never uses bypass**;
  read-only → `plan`, ask → `default`, auto-edits → `acceptEdits`.
- Approvals: `--permission-prompt-tool mcp__<server>__<tool>` with `--mcp-config`. Tagen ships `tagen-approval-mcp`
  (stdio MCP server, tool `approve`) that relays to the app over a 0600 Unix socket with a per-run token. Reply shape
  `{"behavior":"allow","updatedInput":{…}}` / `{"behavior":"deny","message":"…"}` matches the documented `canUseTool`
  result. **The exact MCP prompt-tool contract was not confirmed in the fetched docs** — verify on a Mac (see
  `docs/known-limitations.md`). If it differs, Claude Code still reports blocked tools in `permission_denials`, which
  Tagen displays.
- Result message: `type:"result"`, `subtype` `success` / `error_max_turns` / `error_during_execution` /
  `error_max_budget_usd` …, `is_error`, `result` (success only), `errors[]` (error arm), `session_id`,
  `total_cost_usd`, `num_turns`, `duration_ms`, `permission_denials`.
- Auth on the Mac: `claude auth status` (JSON `authMethod`, exit 0/1); `claude setup-token` → `CLAUDE_CODE_OAUTH_TOKEN`;
  `ANTHROPIC_API_KEY` always wins in `-p` mode if set.

## Codex
- The app-server README fetched (2026-11) documents features but not the wire spec; the implemented flow follows
  the publicly described protocol: JSONL over stdio, JSON-RPC 2.0 messages **without** the `"jsonrpc"` header;
  `initialize` → `initialized`; `account/read`; `thread/start {cwd, approvalPolicy, sandbox, model}` /
  `thread/resume {threadId}`; `turn/start {threadId, input:[{type:"text",text}]}`; notifications `turn/started`,
  `item/started`, `item/completed`, `item/agentMessage/delta`, `item/commandExecution/outputDelta`, `turn/completed`
  (`completed|interrupted|failed`); server→client requests `item/commandExecution/requestApproval`,
  `item/fileChange/requestApproval` answered `{"decision":"accept"|"decline"}` (legacy `execCommandApproval` /
  `applyPatchApproval` → `approved|denied`); cancel via `turn/interrupt {threadId, turnId}`.
- **Verify on the Mac:** `codex app-server generate-json-schema --out schema/` and compare field names. Adapter parsing is
  defensive (unknown notifications ignored, alternative field names accepted).
- Fallback mode `codex exec --json --cd DIR --sandbox read-only|workspace-write [resume ID] PROMPT` (events
  `thread.started`, `item.*`, `turn.completed`, `turn.failed`, `error`). No approval round-trips; the sandbox is the boundary.
- Auth: `codex login` / `codex login status`; API key via `CODEX_API_KEY` for exec.

## Testing approach
Real CLIs are never launched in tests (avoids recursively starting Claude Code inside the development session).
`Tests/TagenAgentsTests/Fixtures/fake_*.py` emulate each protocol deterministically, including approvals, auth
failures, crashes, hangs and resume; the Claude fake drives the real `tagen-approval-mcp` binary.

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

## Codex — verified against codex-cli 0.166.0 (2026-11-05)
Method: `npm install @openai/codex@0.166.0`, `codex app-server generate-ts` / `generate-json-schema`
(subset saved in `docs/research/codex-app-server-0.166.0/`), plus live probes of the real `codex app-server` binary
(no login; model calls blocked by the network) — both with a raw JSON script and through `tagen-cli` (the Swift adapter).

| Item | Schema / observed | Adapter |
|---|---|---|
| Envelope | JSON-RPC without `"jsonrpc"` (`JSONRPCRequest` requires `id`,`method`) | ✔ |
| `initialize` | `{clientInfo:{name,title,version}, capabilities: … | null}` → `{userAgent,codexHome,platformFamily,platformOs}` | ✔ (now sends `capabilities: null`) |
| `initialized` | client notification | ✔ |
| `account/read` | `{account: Account|null, requiresOpenaiAuth}`; signed out → `account:null, requiresOpenaiAuth:true` (observed) | ✔ fail fast unless an API key is in the environment |
| `thread/start` | `cwd, approvalPolicy ("untrusted"|"on-request"|"never"|granular), sandbox ("read-only"|"workspace-write"|…), model` → `{thread:{id,…}}` | ✔ accepted by real server |
| `thread/resume` | `{threadId, excludeTurns?}`; full-history hydration deprecated (observed `deprecationNotice`) | ✔ now sends `excludeTurns: true` |
| `turn/start` | `{threadId, input:[{type:"text", text, text_elements:[]}]}` → `{turn:{id,status:"inProgress"}}` | ✔ (now sends `text_elements`) |
| `turn/interrupt` | `{threadId, turnId}` → `{}` then `turn/completed` with `status:"interrupted"` (observed) | ✔ |
| Notifications | `turn/started`, `turn/completed {threadId, turn{status,error{message,codexErrorInfo}}}`, `item/started|completed {item, threadId, turnId}`, `item/agentMessage/delta {itemId,delta}`, `item/commandExecution/outputDelta`, `error {error, willRetry}` | ✔ |
| Items | `agentMessage{text}`, `reasoning{summary[],content[]}`, `commandExecution{command,status,aggregatedOutput,exitCode}`, `fileChange{changes[{path,kind,diff}],status}`, `mcpToolCall{server,tool}` | ✔ |
| Command approval | `item/commandExecution/requestApproval {kind:"command"|"writeStdin", itemId, command?, cwd?, reason?}` → `{decision:"accept"|"acceptForSession"|"decline"|"cancel"}` | ✔ (+ acceptForSession for "allow for this task") |
| File approval | `item/fileChange/requestApproval {itemId, reason?, grantRoot?}` — **no paths**; paths come from the earlier `fileChange` item | **fixed** (previously assumed `changes` in the request) |
| Legacy | `execCommandApproval {command[]…}`, `applyPatchApproval {fileChanges{path:…}}` → `ReviewDecision`: `"approved"`, `"approved_for_session"`, `{"denied":{"rejection":…}}`, `"abort"` | **fixed** deny shape |
| Other server requests | `item/tool/requestUserInput`, `mcpServer/elicitation/request`, `item/permissions/requestApproval`, `item/tool/call`, … | now answered with JSON-RPC error −32601 (previously a malformed result) |
| `codex exec --json` | real output: `thread.started`, `turn.started`, `error{message}` (retry noise), `item.completed` (incl. `type:"error"`); `exec [opts] resume <id> <prompt>` parses | ✔ |
| `codex login status` | signed out → "Not logged in", exit 1 | ✔ |

Re-check after upgrading Codex: `scripts/check-codex-protocol.sh <version>`.

## Testing approach
Real CLIs are never launched in tests (avoids recursively starting Claude Code inside the development session).
`Tests/TagenAgentsTests/Fixtures/fake_*.py` emulate each protocol deterministically, including approvals, auth
failures, crashes, hangs and resume; the Claude fake drives the real `tagen-approval-mcp` binary.

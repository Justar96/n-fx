# Driving nfx from another agent

This is the contract for invoking `nfx` noninteractively from a program or from
another coding agent, and for monitoring a run while it is still in flight.

Everything here is additive to upstream `fx` behavior: existing `--json`
consumers keep working, and exit codes are unchanged.

## Discovering the surface

```bash
nfx help --json            # every command, flag, example, and exit code
nfx ask --help --json      # one command, plus the stream event vocabulary
```

Both print a single JSON object with a schema version in `v`. Prefer this over
parsing the human help text; the text layout is not a contract.

## One-shot request

```bash
nfx ask --json --no-save "summarize the git history"
```

Prints one object on stdout:

```json
{
  "v": 1,
  "output": "…assistant markdown…",
  "exit_code": 0,
  "model": "gpt-5.6-sol",
  "session_id": "sess_…",
  "steps": 2,
  "tool_calls": [{ "name": "write_file", "status": "success" }]
}
```

Failures add `error` (the raw internal error name) and `error_detail`:

```json
{ "error": "PromptInputReadFailed",
  "error_detail": { "code": "stdin_read_failed", "retryable": true } }
```

Match on `error_detail.code`, not on `error`. Current codes: `usage`,
`prompt_too_large`, `stdin_read_failed`, `auth`, `permission_required`,
`interrupted`, `provider`, `session`, `internal`.

Human-facing progress and diagnostics go to **stderr**; stdout carries only the
machine payload, so the two never interleave.

## Monitoring a run in flight

```bash
nfx ask --stream-json --no-save "fix the failing test"
```

Prints newline-delimited JSON: one object per line, each with `v` and a `t` type
tag. The last line is always `t: "run_end"` and carries the same fields as
`ask --json`, so `… | tail -1` gives the final result.

| `t` | payload |
| --- | --- |
| `run_start` | `model`, `session_id`, `cwd`, `permission_mode` |
| `step` | `n` — step counter, incremented per tool call |
| `text` | `delta` — assistant markdown as it streams |
| `tool_start` | `call_id`, `name`, `args` (the tool's own argument object) |
| `tool_progress` | `call_id`, `message` |
| `tool_end` | `call_id`, `status`, `summary` |
| `notice` | `topic`, `level`, `text` |
| `recovery` | `state` (`active`/`recovered`/`paused`), `kind`, `attempt`, `attempt_limit`, `message` |
| `run_end` | the `ask --json` result object |

`tool_start.args` is how a caller learns which path a write targets:

```json
{"v":1,"t":"tool_start","call_id":"call_rL6…","name":"write_file",
 "args":{"path":"out/note.txt","content":"hello-from-nfx"}}
```

A run cancelled by SIGINT exits 130 and may end without a `run_end` line, so
treat process exit as the terminal signal rather than waiting for the event.

Argument payloads over 4 KiB are replaced by `"args_omitted": true` rather than
duplicating file contents into the stream. Event strings are stripped of
terminal escape sequences, so they are safe to log or re-render.

## Where files land

Tool paths are resolved against the **process working directory** of the `nfx`
invocation, which is also reported as `cwd` in `run_start`. To target a
different tree, run nfx with that cwd:

```bash
cd /path/to/project && nfx ask --stream-json --yolo "…"
```

Paths outside the workspace root are gated by the permission layer, not by a
hard refusal: `--yolo` disables that gate, so an absolute path is written exactly
as the model gave it. Keep out-of-root writes under `--auto` or a rule set if
that matters.

To grant additional roots for one run, pass the global `--add-dir <path>` flag
*before* the subcommand (repeatable); to persist them, use
`nfx workspace add <path>`:

```bash
nfx --add-dir /srv/shared ask --json "…"
```

## Permissions

A noninteractive run has no one to prompt, so choose a mode up front:

- no override: the configured mode applies (`auto` unless changed); a sensitive
  call that no rule and no reviewer resolves fails the run with
  `error_detail.code = "permission_required"`
- `--auto`: unresolved requests are reviewed automatically
- `--yolo`: permission checks and command sandboxing are disabled

Inspect the active rules with `nfx permissions --json`.

## Exit codes

| code | meaning |
| --- | --- |
| 0 | success |
| 1 | failure — read `error_detail.code` for the reason |
| 130 | interrupted |

## Sessions

```bash
nfx ask --json "…"                       # saves a session, returns session_id
nfx ask --json --resume-id <id> "…"      # continue that session
nfx sessions --json                      # list sessions for this workspace
nfx session <id> --json                  # inspect one session
```

Use `--no-save` for throwaway runs; it cannot be combined with `--resume`.

If a run ends with `recovery.state = "paused"`, the model response can be
resumed later with `nfx ask --resume-id <id> --continue-recovery`.

## When to use ACP instead

`nfx acp` speaks JSON-RPC 2.0 over stdio (`session/new`, `session/prompt`,
`session/cancel`, `session/request_permission`). Use it when the caller needs a
long-lived session, or needs to answer permission requests interactively.
`--stream-json` is the right choice for a single scripted run.

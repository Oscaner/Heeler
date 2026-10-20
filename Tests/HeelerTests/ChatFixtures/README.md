# Chat fixtures

Captured inputs for the native Chat tests. The test bundle carries this
directory as a folder reference (`project.yml`), and
`Tests/HeelerTests/Support/ChatFixture.swift` loads files by their path below
this directory.

## Provenance

All captures come from live probes against an isolated herdr backend on
2026-10-06: herdr 0.9.3 (protocol 22), Claude Code 2.1.291 and Codex 0.160.1.
None came from a personal session.

| Path | Source |
|---|---|
| `claude/probe1-transcript.jsonl` | First probe: Claude Code session with Bash, AskUserQuestion, plan mode and Write permissions |
| `claude/probe2-transcript.jsonl` | Second probe (session `e951205e-24af-4a5e-baa7-3ccbebd2de2c`): declines with and without feedback, notes on approvals, multi-question AskUserQuestion, plan mode, Edit/WebFetch declines, a background subagent, parallel Bash |
| `claude/probe2-subagent.jsonl`, `.meta.json` | The background subagent the second probe launched (`agent-a9985bf0a8b4ebbe3`) |
| `codex/probe1-rollout.jsonl` | First probe: Codex rollout with exec approvals and `request_user_input` |
| `codex/probe2-rollout.jsonl` | Second probe: paginated rollout with approvals, declines, sync and async questions, interrupted turns and parallel commands |
| `omp/approvals-asks-plan.jsonl` | Oh My Pi 18.11.1 session from the 2026-10-15 probes below: approved and denied Bash approvals (one denied with a steering message), answered and cancelled `ask` calls, the empty `branch_summary` an atomic rewrite appends, and a plan proposal ending in `__omp.silent_abort__` |
| `pi/auth-error-skill.jsonl` | Pi 0.85.1 session from the same probes: a provider authentication error and a `/skill:probe-hello world args` invocation recorded as its `<skill>` block |
| `pi/provider-retry.jsonl` | Pi 0.85.1 session from a later 2026-10-15 probe against herdr 0.9.5: a `Connection error.` Pi retried on its own, the retry recorded as the error's reply |
| `pi/summaries.jsonl` | Pi 0.85.1's `branch_summary` and `compaction` records from the 2026-10-17 E2E run (isolated root), summaries verbatim: Markdown headings, task checkboxes and a `<read-files>` block. The messages around them are written for the test |
| `grok/fork-head.jsonl` | Grok Build 1.0.62 on herdr 0.9.5 (2026-10-19): the start of a scratch session made with `/fork` without a worktree, lines 1, 3–6 and 10 of the capture. The first five are the parent's records as the fork copied them, with the fork in `sessionId` and the parent's id still prefixing `eventId`; the last is the fork's own. The dropped lines are the developer's hook records, a copied `background_tasks` record and two more herdr `session_start` records |
| `grok/core-turns.jsonl` | Grok Build 1.0.62 on herdr 0.9.5 (2026-10-19): a scratch session's first four turns, lines 1, 3–5, 7–9, 11–13, 15–17, 19 and 21–24 of the capture: herdr's `session_start` record, a one-line prompt, a three-line prompt, a prompt with the space Chat adds after it, and a turn with a `run_terminal_command` call (its start, input and result), reasoning and a reply in Chinese. The dropped lines are the developer's hook records |
| `grok/cancel-takeover.jsonl` | The same Grok Build and herdr (2026-10-19), lines 1, 3–7, 9–12 and 14–17 of another scratch session's capture: a prompt stopped with Ctrl+C before any output, the prompt that took over its index, and a turn that spawned a subagent and was cancelled with Ctrl+C, the subagent's end written after the turn's. Line 3 is the developer's `user_prompt_submit` hook between the two prompts, its run renamed `project/probe:user_prompt_submit[0].hooks[0]`; the other hook records are dropped |
| `grok/rewind.jsonl` | The same (2026-10-19), lines 1, 3, 5–6, 8–11, 13 and 15–16 of a scratch session's capture: two turns, a `rewind_marker` to prompt 1, and the prompt that reused index 1, the restored draft joined to it. The dropped lines are the developer's hook records and two reasoning records |
| `grok/compaction.jsonl` | Lines 1–6 are lines 139–144 of an earlier capture of `core-turns.jsonl`'s session (2026-10-19): a turn, then a manual `/compact` (`compaction_checkpoint` and `auto_compact_completed`). Lines 7–12 are written for the test in the same session, from event number 606 on: an automatic compaction inside the next turn, recorded as Grok Build's source writes one |
| `grok/dispatch-order.jsonl` | The same (2026-10-19), lines 1–4 of a session dispatched from Grok's dashboard: its prompt is written before herdr's `session_start` record |
| `grok/agent-turns-and-errors.jsonl` | Written for the test, not captured: a skill, a prompt of text, image and text chunks with an `image_dropped` notice, an interjection and a thought written after its turn's end, a retry that gave up and an expired sign-in (each ending its turn with an error), a shell-mode command, a hidden prompt Grok wrote for itself after a background command, fork and resume context wrappers, an unknown record kind, and a cancelled and a failed automatic compaction. The records take the captures' shapes, or Grok Build's source where no capture shows one |

## Scrubbing

The probe tooling already re-serialized each JSON line, replaced attachment
bodies with `{"type": …, "redacted": true}` and thinking text with
`<redacted>`. Real transcripts are compact JSON, so tests parse lines and
never compare bytes with a live file.

Copying them here also rewrote, with replacements of the same length so
byte offsets and screen columns stay exactly as captured:

- the account name to `developer` (so `/Users/developer` and its project-key
  form `-Users-developer`);
- the probe root `heeler-iso-chat` to `heeler-tmp-chat`.

The 2026-10-15 sessions were re-serialized as compact JSON without
`credentialId`, `providerPayload`, `responseId`, `textSignature`,
`contextSnapshot` and the `credential_pin` hash, with the account name
replaced as above; `pi/provider-retry.jsonl` also drops the encrypted
`thinkingSignature`. Each keeps every line of its session, so tests address
records by line number.

Grok Build captures keep their chosen lines byte for byte, apart from
these replacements:

- Every id (session, prompt, tool call, compaction checkpoint, subagent)
  becomes a synthetic UUIDv7-shaped id (`01900000-0000-7000-8000-0000000000NN`),
  the same one wherever the real id appeared: in a call id's `call-<id>-0`,
  in the `eventId` prefix a fork keeps from its parent, and, without its
  dashes, in a subagent attempt's `at1.<id>`.
- The account name becomes `developer`, also inside the byte arrays Grok
  writes for a command's output. The name has the same length, so
  `total_bytes` still holds.
- The scratch directory the probes ran in becomes `/Users/developer/scratch/`,
  plain and percent-encoded.

The developer's own hook records (`global/settings:` runs) are dropped, except
the one `cancel-takeover.jsonl` keeps under a renamed run; herdr's
`session_start` records stay. The fixtures written for the tests use ids
from the same range only. Searching `grok/` for a UUID outside that range, a
`global/settings` run or the account name, in text or in a byte array, finds
nothing.

After adding a capture, check that searching this directory for `/Users/`
(other than `/Users/developer`), `ghp_`, `Bearer` and e-mail addresses finds
nothing.

## Screens

`screens/claude/*.ansi` and `screens/codex/*.ansi` are visible-screen reads
(`agent.read` with `source: visible`, `format: ansi`, `strip_ansi: false`)
taken during the same isolated probes, kept as herdr returned them apart from
the scrubbing below: CRLF rows, SGR styling only. Each keeps the stem of its
capture.

- `claude-03-bash-touch-permission.ansi` comes from the first probe; every
  other screen comes from the second.
- Most screens are 120×40. `claude-27` through `claude-31` and `codex-12`
  through `codex-14` were read at 40×30.
- `codex-15-x6-mcp-tool-list` comes from Codex 0.162.1 on herdr 0.9.5
  (2026-10-17), read at 41 columns (app terminal font size 12): the MCP
  tool approval "Allow the probe MCP server to run tool ...", a two-column
  list with the footer `enter to submit | esc to cancel`.
- `codex-16-x7-phone-question-pointed` and `codex-17-x7-phone-question-notes`
  come from Codex 0.162.1 on herdr 0.9.5 (2026-10-17), read at the phone's
  62×40 grid: a `request_user_input` question with the pointer on `None of
  the above`, whose description wraps `(tab)` onto a second reverse row, then
  the same question after Tab and a paste opened its notes (0.162.1 drops a
  paste while the options have focus).
- `codex-18-x7-phone-async-countdown` comes from the same Codex at 62×41:
  `request_user_input_async` questions folded under "Queued follow-up
  inputs" while a command runs, the count row carrying Codex's countdown
  (`? 2 questions · 20s`).
- `codex-19-x3-implement-plan` is derived, not captured: Codex 0.162.1's
  `Implement this plan?` selector after a Plan-mode turn on herdr 0.9.5
  (2026-10-17), rebuilt from that run's plain-text pane read, rows as read,
  with the styles of `codex-06` and `codex-15`: a bold reverse pointed row,
  dim descriptions and footer, and a bold-dim `›` on the history's prompt.
  Replace it with a capture when one is taken.
- `claude-27`, `-28`, `-30` and `-31` keep the live rendering residue after
  option 4 (`No` followed by a stale grey `r you`).
- `claude-32` through `claude-37` come from Claude Code 2.1.301 on herdr
  0.9.5 (2026-10-17), read at the phone's 62×41 grid: a Bash dialog with
  the `Tip:` line, focus on `No`, Tab on `No`, and a pasted note too long
  for its row, cut off with `…` and no cursor cell; then another Bash
  dialog and a note on `Yes` wrapped onto a second row, with the cursor
  cell only on that row.
- `claude-38` is a 2.1.301 plan dialog at the same grid whose call
  recorded the previous plan: Claude wrote the plan file and called
  ExitPlanMode in one message, and `input.plan` kept the file as it was
  before the Write.
- `claude-39` is a 2.1.301 question at the same grid in a named session:
  under the footer Claude draws a rule carrying the session's name.
  `claude-40` is the review page after a multi-select answer: no footer,
  only that rule.
  `claude-41` is the second page of a two-question form: it keeps the
  first page's height, so blank rows sit between its footer and that rule.
  `claude-42` is a question whose options have previews: the preview box
  beside the options and an `n to add notes` hint in a wrapped footer.
- `claude-43-c12-read-file` is derived, not captured: Claude Code 2.1.301's
  `Read file` dialog for a staged upload outside the project, rebuilt at the
  phone's 62-column grid from `claude-32`'s rows and colors and the rows the
  2026-10-17 E2E run's generic card showed (title, dashed rules, the
  `Read(<path>)` call wrapped at the edge, `Do you want to proceed?`, `1. Yes`,
  `2. No`, `Esc to cancel · Tab to amend`). The macOS temporary directory in
  the path is a same-length placeholder. Replace it with a capture when one
  is taken.

Scrubbing used the same same-length replacements as above, so every column
is as captured. The shell prompt on the first row of `claude-00-trust.ansi`
also had its host name replaced by `probe-host-placeholder-01`.

### Pi and Oh My Pi screens

`screens/pi/pi-*.ansi` and `screens/omp/omp-*.ansi` are visible-screen reads
taken the same way on 2026-10-15 against isolated herdr 0.9.5 backends: pi
0.85.1 and Oh My Pi 18.11.1. Each backend had its own socket, but the pane's
`HOME` pointed at the developer's account so both Agents used a real
subscription and real settings; no credential file was read or copied. Each
file keeps the capture's number and name behind the `pi-` or `omp-` prefix.

- Pi's model calls failed authentication, so `pi-03` to `pi-20` show that error
  above the editor; `pi-06` also shows the Update Available box and a working
  directory outside `HOME`.
- `pi-31` to `pi-39` come from a second pi capture on 2026-10-16 after the
  developer logged in again (numbered here, not by capture), so they show real model turns: the Working
  rule, queued steers, a retry countdown and compaction. They are 120
  columns wide except the `-40` ones.
- `pi-40-phone-extended-steer` comes from Pi 0.85.1 on 2026-10-17 at the
  phone's 62 columns: a steer Stop returned to the editor, with text the user
  added after it (`say FIG and also say PEAR`). Its `40` is the capture
  number, not a width.
- `pi-41-compact-nothing` comes from Pi 0.85.1 on herdr 0.9.5 (2026-10-18),
  started with `--no-session` in an empty directory: `/compact` typed into
  the fresh session printed `Error: Compaction failed: Nothing to compact
  (session too small)` above the editor, and the Agent stayed idle.
- `pi-42-compact-nothing-62` and `omp-35-compact-nothing-62` come from Pi
  0.85.1 and Oh My Pi 18.11.2 on herdr 0.9.5 (2026-10-18) at the phone's 62
  columns, after one turn each: the same refusal wraps `small)` onto a
  second row, and Oh My Pi draws its session title, dim and italic, between
  it and the status band.
- Oh My Pi used the nerd-font status band.
- Captures are 119, 120, 62 or 40 columns wide; Pi's are 119 unless the
  name or the note above says otherwise, Oh My Pi's 120.
- The shell rows of `pi-03`, `pi-06`, `omp-21` and `omp-33` keep the probe's
  `SOCK=`/`HOME=` echo and the shell prompt.

Scrubbing replaced the account name as above and the shell prompt's
`user@host` with `developer@probe-host-placeholder-01`, both with
replacements of the same length. These screens are not part of
`ScreenFixture.all`, which the dialog and input-box suites walk.

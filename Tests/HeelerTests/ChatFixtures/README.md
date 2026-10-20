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

### OpenCode screens

`screens/opencode/opencode-*.ansi` are visible-screen reads of OpenCode
2.0.32 on herdr 0.9.5, with scratch prompts. Stems keep their capture
numbers, so the numbers have gaps.

- `opencode-01` to `opencode-21`, `opencode-23`, `opencode-24` and
  `opencode-26` come from the sessions of the stores below, through 180×47
  clients on 2026-10-19; their rows are 182 cells wide (181 in
  `opencode-01`).
- `opencode-22`, `opencode-25` and the `-62` stems come from an isolated
  herdr server on 2026-10-20, in a scratch project under `/tmp`. A client of
  the named width attached and detached before each read, so the pane kept
  its size; `opencode-22` and `opencode-25` are 180×47 and the `-62` stems
  62×41. `opencode-25` and `opencode-42` show the `Reject permission` stage:
  a scratch `.opencode/opencode.json` rule asked before a subagent read a
  scratch file, and Esc in the terminal rejected it.
- `opencode-27`, `-28` and `-29` are derived, not captured: OpenCode
  2.0.32's permission for a shell command, which no capture shows, rebuilt
  at 180×47 from stem 10's rows and colors and the permission component in
  OpenCode's bundle. A shell command's permission has no action row under
  `△ Permission required`, only its `$ git status` line in the text color;
  with Always allow focused (`opencode-28`) that line gives way to the
  rule's, `This will always allow the following patterns for this
  project.` and `- git status *`, a blank row apart. `opencode-29` is the
  next command's permission, `rm -rf build`. Above them are stem 10's
  earlier rows, a scratch prompt asking for both commands, and the two
  calls running, the one whose permission shows in the warning color. A
  script outside the repository derives them. Replace them with captures
  when they are taken.

Scrubbing applied the stores' path, account and placeholder rules to every
byte. Assistant text in Chinese became English no wider than it, with blanks
added at the end of its row, so every row keeps its captured width. The
`/tmp` stems keep that scratch project's path, whole or shortened. The checks
under the stores' scrubbing cover `screens/opencode/` as well. Together the
files are about 570 KB. These screens are not part of `ScreenFixture.all`
either.

## OpenCode stores

`opencode/` holds OpenCode session stores for the store query tests
(ADR 0025). They come from OpenCode 2.0.32 sessions on herdr 0.9.5, captured
on 2026-10-19 and 2026-10-20 in scratch projects with scratch prompts. None
came from a personal session.

- `schema.sql` is the DDL of the four tables the query reads (`session_v2`,
  `session_message`, `event_sequence` and `session_inbox`), with OpenCode
  2.0.32's column order, types and indexes, the unique `(session_id, seq)`
  index included. Foreign keys are left out.
- `store-<scenario>.json` is one store: `session`, `event_seq`, `rows` and
  `inbox` as the tables hold them, JSON columns as compact JSON text, and
  `otherSessions` for further sessions in the same database.
  `Support/OpenCodeSQLiteHarness.swift` builds an SQLite database from one.
- `rows-<scenario>.jsonl` is what the query prints for that store's tail with
  a 512 KiB budget: the session line, the inbox line, then the rows oldest
  first.

| Scenario | Source |
|---|---|
| `pong` | A one-word reply |
| `approve`, `reject` | A `read` permission approved, then the same read declined |
| `esc-stop` | A shell command stopped with Esc |
| `patch` | Two `patch` calls: a file added, then edited |
| `compact` | `/compact` and its summary |
| `steer`, `steer-queued` | A message sent while a shell command ran. `steer` is the finished exchange. `steer-queued` is derived, not captured: the store when the message was sent, rebuilt from the session's poll log, with the shell call still running and the message waiting in the inbox |
| `subagent` | A `subagent` call; its child session is under `otherSessions` |
| `question-blocked`, `question-answered` | A `question` call waiting for its answer, then answered. The waiting store takes its rows from a dump taken while the call waited and their ids and creation times from the answered dump; its event counter (111) is set between the two dumps' |
| `undo-before`, `undo-staged`, `undo-committed` | `/undo` in a second session: before it, with the revert staged, and after the next prompt committed it |
| `two-sessions` | Written for the tests: a second session in the same store, with its own rows and inbox, which no query may read |
| `v1-names` | Written for the tests: OpenCode 1.x tool names (`bash`, `task`, `apply_patch`, `todowrite`, `edit`) and their `diff`, `filediff` and `files` metadata |
| `odd-types` | Written for the tests: a string tool error and input, numeric times, an attached file, content parts with an unknown type or none, and an inbox item whose text is a number and whose files are a string |
| `row-types` | Written for the tests: rows of the other types (`shell`, `synthetic`, `system`, `skill`, `location-switched` and `model-switched`), an unknown type, a running shell command, compaction and assistant row, and an assistant row of the wrong shape |

The tests build three stores in place rather than from files: one with
OpenCode 1.x tables only, a staged revert carrying 3 MiB of patch text, and
an inbox of 20 long items.

Together the files are about 116 KB: 71 KB of stores, 42 KB of rows and the
schema.

### Scrubbing

A script outside the repository derived the stores from the captures, in
this order:

1. The scratch project paths became `work/heeler-tmp-chat/opencode-a/project`
   and `work/heeler-tmp-chat/opencode-b/project`, the account name
   `developer`, and the capture's job directory, scratch directory names and
   host name same-length placeholders.
2. `ses_`, `msg_`, `prt_` and `sh_` ids became synthetic ids of the same
   shape (12 hex digits, then 14 base62 characters), consistently across a
   scenario's stores; the session under test is
   `ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9` in each. `call_` ids became `call_` and
   24 base62 characters, and project ids hashes of fixed strings.
3. Assistant text in Chinese became English, the compaction summary
   included. User text is the scratch prompts only.
4. `providerState`, `providerResultState`, `itemId`,
   `reasoningEncryptedContent`, `responseId`, `snapshot`, `files[].data` and
   `metadata.diagnostics` were dropped.
5. Times moved so each scenario's earliest is `1800000000000`, keeping the
   gaps between them. Model names, token counts and costs are as captured.

Before committing a change here, check that searching `opencode/` finds none
of the account, host or scratch directory names, no `/Users/` other than
`/Users/developer`, no `ghp_`, `Bearer`, `sk-` keys or e-mail addresses, no
CJK text, and none of the real ids the script replaced (it lists them in a
file outside the repository).

### Regenerating the rows

`OpenCodeStoreQueryTests/rowFixturesMatchTheProbeOutput()` fails when the
query's output drifts from `rows-*.jsonl`. After an intended change, run that
test with `HEELER_WRITE_OPENCODE_ROWS` naming a directory outside the
repository (`TEST_RUNNER_HEELER_WRITE_OPENCODE_ROWS` through `xcodebuild`):
it writes the files there instead of comparing. Review them, copy them in,
and run the test again. It compares parsed JSON, since SQLite versions may
escape text differently.

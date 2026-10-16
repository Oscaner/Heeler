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
- Oh My Pi used the nerd-font status band.
- Captures are 119, 120 or 40 columns wide; Pi's are 119 unless the name
  says otherwise, Oh My Pi's 120.
- The shell rows of `pi-03`, `pi-06`, `omp-21` and `omp-33` keep the probe's
  `SOCK=`/`HOME=` echo and the shell prompt.

Scrubbing replaced the account name as above and the shell prompt's
`user@host` with `developer@probe-host-placeholder-01`, both with
replacements of the same length. These screens are not part of
`ScreenFixture.all`, which the dialog and input-box suites walk.

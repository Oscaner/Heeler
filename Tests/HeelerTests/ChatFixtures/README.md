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

- Pi's model calls failed authentication, so the pi screens show that error
  above the editor; `pi-06` also shows the Update Available box and a working
  directory outside `HOME`.
- Oh My Pi used the nerd-font status band.
- Captures are 119, 120 or 40 columns wide; Pi's are 119 unless the name
  says otherwise, Oh My Pi's 120.
- The shell rows of `pi-03`, `pi-06`, `omp-21` and `omp-33` keep the probe's
  `SOCK=`/`HOME=` echo and the shell prompt.

Scrubbing replaced the account name as above and the shell prompt's
`user@host` with `developer@probe-host-placeholder-01`, both with
replacements of the same length. These screens are not part of
`ScreenFixture.all`, which the dialog and input-box suites walk.

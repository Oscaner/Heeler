# Pi and Oh My Pi transcript observations

Versioned source observations:

- Pi coding-agent 1.2.0, source commit
  `7d75a0e3eb273dff753d49c066ea29fbe7b3b6f6`:
  [session manager](https://github.com/earendil-works/pi/blob/7d75a0e3eb273dff753d49c066ea29fbe7b3b6f6/packages/coding-agent/src/core/session-manager.ts),
  [stock editor](https://github.com/earendil-works/pi/blob/7d75a0e3eb273dff753d49c066ea29fbe7b3b6f6/packages/tui/src/components/editor.ts).
- Oh My Pi package 18.10.4, `src/session/session-entries.ts`,
  `session-manager.ts`, `session-paths.ts`, and pi-tui's
  `components/composer/box.ts` and `pi.ts`:
  [upstream source repository](https://github.com/can1357/oh-my-pi).
- The herdr Pi extension `herdr-agent-state.ts` reports
  `source: herdr:pi`, `agent: pi`, preferring `agent_session_path` over
  `agent_session_id`. The existing herdr 0.9.3 observations in
  [compatibility notes](../agents/herdr-compatibility.md) record `kind: path`
  for Pi and OMP; [official integrations](https://herdr.dev/docs/integrations/)
  describe the two separate integrations.

## Identity and location

The native session has a UUID. The JSONL file normally lives under
`~/.pi/agent/sessions/<encoded-cwd>/<timestamp>_<UUID>.jsonl` or OMP's own
`~/.omp/agent/sessions` tree. OMP also uses home-relative project keys. Exact
paths reported by herdr cover custom agent roots and custom session directories
without guessing environment variables. Only official matching source/agent
pairs bind. Paths must be absolute JSONL files with no dot traversal or control
characters. All reads use the existing SFTP seam; no reported path becomes
shell code.

Pi starts with `{type: session, version: 3, id, cwd}`. OMP 18.10.4 can put a
fixed-width `{type: title, ...}` slot before that header. Locate validates the
header (including its UUID for UUID lookup). Versions 2 and 3 are supported;
legacy v1 and unknown future versions show an unavailable explanation.

## Tree and content

Entries have `id`, `parentId`, `timestamp`, and `type`. Replay the last
selected leaf back through parents; invisible extension and metadata entries
are still ancestry links. OMP's late `model_usage` may carry `activeLeafId`,
which restores the active leaf rather than selecting the usage record's
branch. Incremental append and earlier-history prepend converge by file offset.

`message.message.role` is `user`, `assistant`, or `toolResult`. User content
may be a string or blocks. Assistant blocks include `text`, `thinking`, and
`toolCall` (`id`, `name`, `arguments`). Results pair by `toolCallId`, carry
`isError`, and expose capped text previews; an expanded result re-reads its
exact line. Images are counted, not decoded from base64. Tool calls without
results retain activity-derived running/blocked/interrupted status. Assistant
`stopReason` ends turns; `aborted` and `error` show notices.

`compaction` inserts a separator and keeps earlier visible history.
`branch_summary` and OMP `reset_boundary` show notices. Displayable custom
extension messages become notices; hidden extension state remains invisible.
Unknown record types remain tree links and are counted in diagnostics.

Observed on 2026-10-15 with Pi 0.85.1 and Oh My Pi 18.11.1 (the
`pi/auth-error-skill.jsonl` and `omp/approvals-asks-plan.jsonl` Chat
fixtures):

- Pi records `/skill:name args` as a user message holding the expanded
  `<skill name="…" location="…">` block, then a blank line and the
  arguments, before the model call. Chat parses it as Pi does, shows
  `/name args`, and matches the echo as `/skill:name args`. OMP records the
  same invocation as a `custom_message` with `customType: skill-prompt`,
  `attribution: user` and the submitted text in `details.prompt`; Chat treats
  it as the turn's prompt and never shows the expanded skill.
- Whether a call without a result is still running or Blocked follows the
  stop reason of the branch's last assistant message, whatever opened the
  turn.
- OMP `ask` arguments are `questions[{id, question, options[{label,
  description, preview}], header, multi, recommended}]`; absent fields are
  JSON null. The result's `details.selectedOptions` holds one question's
  answer, `details.results[{id, selectedOptions}]` several. A denied approval
  results in `Tool call denied by user: <tool>` and a dismissed question in
  `Ask tool was cancelled by the user`, both `isError`; Chat reads them as
  declined.
- Pi's Esc during a tool records the result `Command aborted` and then an
  empty assistant message with `stopReason: error` and `errorMessage: This
  operation was aborted`. A provider error has the same empty shape, so only
  that message tells an interruption from an error.
- OMP's plan proposal records the `write xd://propose` result `Plan ready
  for review.`, then an empty assistant message with `stopReason: aborted`
  and `errorMessage: __omp.silent_abort__`. Chat ends the turn normally with a
  plan-ready notice instead of an interruption.
- OMP's atomic file rewrite appends a `branch_summary` with an empty
  `summary` and `details.kind: discarded-entry-branch`, which Chat hides.

## Input and limits

Pi's standard editor has full-width horizontal rules and a reverse-video
software cursor. OMP's classic box uses a rounded top and a last input row
merged into the bottom border, with a `▏` insertion cursor. OMP 18.10.4 now
defaults to `band`: a filled status row above an unboxed `╰─ ` prompt
(`pi-tui/src/components/composer/band.ts`). herdr 0.9.1's visible ANSI
screen can omit the hardware cursor for this composer.
The detector requires the normal-mode `π > ` status band, its fill and gauge,
and reads every following editor row; missing/custom chrome stays unsendable.
Chat sends only
after positively reading an empty stock editor. Drafts, completion popups,
custom editors and unrecognized composer styles require the terminal. Native
permission-dialog actions are not implemented for Pi/OMP; no generic digit
option is sent to them. Stop and explicit tools keys retain the existing RPCs.

A separate server compatibility constraint applies to herdr 0.9.1: its
`src/detect/mod.rs` does not recognize the full
`@oh-my-pi/pi-coding-agent/dist/cli.js` path used by OMP's `/restart`.
`src/app/api/agents.rs` then rejects `agent.prompt` with `agent_not_ready`
before writing any input, even though the integration reports the session.
The v0.9.3 source recognizes that package path. With 0.9.1, launching the
existing session with the official `HERDR_AGENT=omp` environment hint can
retain identification without changing other panes or bypassing the RPC guard.

UUID fallback search is bounded and limited to default session roots; custom
roots need herdr's path reference. External blob-backed content, compressed
files and nested subagent transcripts are not followed by this adapter.
Focused tests and Simulator demo use synthetic JSONL through production
locators/followers/reducers. They do not prove a live Pi/OMP Host's prompt
delivery or its extension dialogs.

Preview with `--demo-screenshots --demo-pi-chat`; this replaces two existing
demo Agents with Pi and OMP while keeping the default demo unchanged. Samples
are synthetic and have no Host connection.

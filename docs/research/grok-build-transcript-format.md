# Grok Build transcript and screen observations

Versioned observations:

- Grok Build 1.0.62 (macOS arm64), live on scratch panes against herdr 0.9.5
  on 2026-10-19: `agent.get`, pane reads (plain and ANSI), the new
  `updates.jsonl` lines polled every 50–100 ms, and the user guide that ships
  with the build (`~/.grok/docs/user-guide/`).
- Grok Build 1.0.45 source,
  [`xai-org/grok-build` at `2bdd1d6a`](https://github.com/xai-org/grok-build/tree/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen).
  Source paths below are under `crates/codegen/`, in `xai-grok-pager/src`
  unless a crate is named. The source predates the installed build, so a
  claim that rests on it alone says so.
- A structure-only census of one Host's `~/.grok/sessions` (406 sessions in
  185 folders, 216,425 records, written by builds from 2026-08 to 2026-10):
  keys, types, short enum values, counts and sizes, never text.
- herdr 0.9.5 source: the Grok hook asset (integration version 3),
  `src/agent_resume.rs`, `src/terminal/state.rs` and the `grok.toml`
  detection manifest (2026.10.05.1). The herdr facts are also in the
  [compatibility notes](../agents/herdr-compatibility.md).

## Identity and location

herdr's Grok integration installs a SessionStart hook that reports
`{source: "herdr:grok", agent: "grok", kind: "id", value}`, never a path.
The value is the session id: a lowercase UUIDv7 (all 406 census sessions)
that names the session folder and equals every record's `params.sessionId`.
Grok mints these ids, but `grok -s` accepts one chosen by the caller (user
guide `17-sessions.md`). At start, the session folder appears first,
`updates.jsonl` 100–300 ms later with herdr's `session_start` hook record,
and herdr reported the id 60–110 ms after that record, before any prompt.

herdr replaces a Grok Agent's session only when SessionStart's `source` is
`new`, or when the pane has none yet; it normalises Grok's `load` away
(herdr 0.9.5 `normalize_session_start_source`). Live, unless marked:

- `/new` and `/clear` start a new folder in the same group, adopted within
  about 0.1 s of its first record. The earlier session stays open in the
  process, its file untouched, and the screen prints `Session <id>, use
  /dashboard to switch between sessions`.
- `/resume` to a session already open in the process writes nothing
  anywhere. herdr keeps the old id, and the next prompt lands in the resumed
  file. `/resume` to a closed session appends `background_tasks{tasks: []}`
  and a `session_start` hook record (source `load`) to that file, which
  herdr ignores.
- `/fork` first asks, on a Blocked card, whether to use a worktree. Either
  answer creates a session holding a copy of the parent's records, and
  herdr keeps the parent. The screen prints `Session <id> (forked from
  <parent>), use /dashboard to switch between sessions`, with `(both agents
  share cwd)` on the next row when no worktree was made.
- A message sent while the dashboard shows dispatches a new agent, which
  herdr adopts (`new`) while the screen still shows the dashboard. Esc back
  to the earlier session leaves herdr on the new agent.
- `grok --resume <id>` and `grok --continue` in a pane with no reported
  session are adopted, because the pane has no id.
- `/quit` clears `agent_session` and the Agent's status.
- `/home` (alias `/welcome`) leaves the session for the Welcome screen, by
  the user guide. What a send from there does to herdr's report was not
  captured.

The two `Session` lines sit outside any box at the scrollback's
five-column indent; a pane narrower than the line wraps it (not captured at
40 columns). When Grok resumes a
session it finds under another directory, it also prints `Session <id>
found locally (originally in <dir>)` on standard error at start (source:
`app/session_startup.rs`).

Sessions live in `<GROK_HOME>/sessions/<group>/<id>/`, where `GROK_HOME`
defaults to `~/.grok` (`xai-dirs` `grok_home`). The variable lives in the
Grok process's environment, which herdr does not report, so a custom root
can't be found from the Agent's report. The group is the session's working
directory with every UTF-8 byte outside `A-Z a-z 0-9 - _ . ~` written as
uppercase `%XX` (`xai-grok-config/src/paths.rs` `encode_cwd_dirname`):
`/home/dev/My Project` becomes `%2Fhome%2Fdev%2FMy%20Project`. All 406
census sessions match. Grok takes the directory from `getcwd`, so a session
started in a symlinked directory files under the physical path, which is
also what herdr's `cwd` and `foreground_cwd` report.

A name longer than 255 bytes becomes `<slug>-<16 hex>` instead. The slug is
the path's last component lowercased, with every run of characters other
than ASCII letters and digits turned into one `-`, trimmed of `-` at both
ends and then cut to 40 characters, so a cut can end on `-` (`workspace`
when empty); the hex is the start of the BLAKE3 hash of the path's bytes.
The group then holds a `.cwd` file with the raw path bytes and no newline,
created exclusively. This is source only: no census group was that long.

herdr's directory is not always the session's. `/fork` into a worktree,
and `/new` inside that worktree session, file the session under the group
of the worktree's path (which lies under `~/.grok/worktrees/`), while herdr's
`cwd` and `foreground_cwd` keep naming the pane's directory; herdr adopted
the `/new` session's id all the same. Finding such a session takes a
search of other groups for `<id>/updates.jsonl`. A session folder can exist
without `updates.jsonl` for 100–300 ms, and 2 of the 406 census sessions
never got one. The file's first record names the session in `"sessionId"`
within about 110 bytes. A fork's copied records carry the fork's
`sessionId` but keep the parent's `eventId` prefix.

Each session folder also holds `summary.json`, `chat_history.jsonl` (the
model's context, not a display source), `events.jsonl`,
`rewind_points.jsonl` and more; a subagent gets a sibling session folder in
the same group. The group itself holds `prompt_history.jsonl`. For every
submitted prompt, any Grok process working in that directory appends
`{prompt, is_bash, session_id, timestamp}` just before it writes the user
record, with the prompt trimmed (unlike `updates.jsonl`). A prompt queued
while Grok works gets its line when it is submitted, not when it is
queued; commands such as `/new` and `/compact` add none. Grok keeps at most
10,000 entries and may rewrite the file through a temporary file and a
rename when it installs a session (source: `xai-grok-shell`
`session/prompt_history.rs`). `~/.grok/active_sessions.json` lists every
open session on the machine (`{session_id, pid, pid_start, cwd,
opened_at}`), but not which one a process shows.

## Records and turns

Each `updates.jsonl` line is `{timestamp, method, params{sessionId,
update{sessionUpdate, …}, _meta}}`. `timestamp` is whole seconds;
`_meta.agentTimestampMs` is milliseconds and, for a merged block, the time
it was flushed (`turnStartMs` and `streamStartMs` give the stream's times).
`method` is `session/update` for ACP kinds and `_x.ai/session/update` for
Grok's own. `_meta.eventId` is `<sessionId>-<n>` from a counter shared by
the whole process, and it is not a key: a fork's copied records keep the
parent's prefix, and the census found 92 reused after one rewind by an older
build. Agent records carry `_meta.promptId`; user records don't. New builds
add kinds and keys.

Grok holds the newest ACP record in memory, merges consecutive message or
thought chunks into it, and writes it when the next ACP record arrives or
the turn ends (`xai-grok-shell` `session/persistence.rs`). Its own records
are written at once and can overtake it: a spawn's `subagent_spawned` and
`subagent_finished` landed before the spawn's input update. So message and
thought chunks are whole blocks on disk, a turn's last text appears with its
`turn_completed`, and while a command runs the file shows only its
`tool_call` (for 40 s with `sleep 40`). Every capture flushed the held record
before `turn_completed`. Appends take a lock and write whole lines with
`O_APPEND`; the file is rewritten whole only on a session import or a remote
pull (source). Live, it stayed append-only through restarts, `/compact`,
`/rewind`, `/new` and `/resume`. A user record reached disk 343–496 ms after
`agent.prompt` started, herdr's 300 ms Enter delay included.

`user_message_chunk` holds `content{type, text, _meta?}` and
`update._meta{modelId, promptIndex?, hideFromScrollback?}`:

- One prompt content block is one chunk. A prompt of several blocks is
  consecutive chunks with consecutive event numbers and one `timestamp`.
- The text is recorded byte for byte, Heeler's trailing space included.
  Multi-line pastes and an 11,262-byte paste were recorded whole.
- `promptIndex` counts submitted prompts from 0. A chunk without one is an
  interjection in the running turn (steer mode; census and source only) or a
  shell-mode record.
- `hideFromScrollback` marks a turn Grok started itself, after a task,
  subagent or notification; its text starts with a tag such as
  `<system-reminder>`.
- A skill records `content._meta.displayAsSkill` and `displayText`
  (`/name args`) beside the expanded text.
- `!cmd` typed in Grok records `content._meta.bash_command`, then a command
  call whose id is `bash-mode-<uuid>`.
- Image blocks are possible (source) but none were seen; `image_dropped`
  and `image_compressed` are Grok's notices about them.

A chunk with a `promptIndex` opens a turn, and `turn_completed{prompt_id,
stop_reason, agent_result?, error_kind?, usage, elapsed_ms?}` closes it. The
census has `stop_reason` `end_turn` 941 times, `cancelled` 47 and `error`
once. A cancel's `params._meta` carries:

- `cancelTrigger`: `ctrl_c`, `send_now` or `shutdown`, plus `esc` in
  builds until early September 2026; the source adds `mouse` and
  `dashboard_stop`.
- `cancellationCategory`: `MidTurnAbort`, or `PermissionRejected` with
  `cancellationContext{tool_name, reason}` and no trigger after a reject.
  The source gives `PermissionCancelled` for Ctrl+C on a permission card and
  `HookDenied` for a hook; the 1.0.62 binary also holds `HookStopped`, so
  that spelling is unverified.

A cancelled turn keeps its usage. Neither 1.0.62 cancel captured with
records (Ctrl+C during a command, and a reject) wrote a final message, and a
call still open at the cancel never gets a final update. Thought, message
and tool records can follow a `turn_completed`, and some completions name no
prompt (census). Hook records (`hook_execution`) exist only for configured
hooks: herdr's SessionStart hook, and hooks from the user's settings, such
as the Claude Code hooks Grok imports from `~/.claude/settings.json`. They
never mark turns.

Ctrl+C before the first output is a cancel-rewind. Grok drops the prompt
from its conversation, puts the text back in its input box, and writes no
`turn_completed` and no marker, but the user chunk stays on disk. The next
prompt reuses its `promptIndex`, and because the text sits in the box, a
paste joins it: Grok recorded `Reply with the word kiwi.Reply with the word
lime.` as one chunk. All 7 census prompts that reuse the previous
`promptIndex` follow a prompt with no output and no `turn_completed`.

`/rewind` (alias `/undo`), or Esc twice on an empty idle box, opens the
picker `Rewind to which turn?`; its confirmation card (`y`, `a`, `n`) is
Blocked. A rewind appends `rewind_marker{target_prompt_index, created_at}`
and rewrites nothing in `updates.jsonl` (it rewrites `chat_history.jsonl`
and `rewind_points.jsonl`), shows `Reverted conversation`, and restores the
rewound prompt as a draft that the next paste joins. Every record from the
first chunk whose `promptIndex` is at or above the target, up to the
marker, is gone from the conversation. Grok's replay counts user runs
instead (`xai-grok-shell` `session/storage/mod.rs` `filter_rewind_by`); the
two agree on every capture. Event numbers kept rising after the 1.0.62
rewinds. The census's one rewind, by an August build, wrote no marker, only
a drop in `promptIndex`.

`/compact` writes no user chunk and no `turn_completed`. About 8 s after the
send come `compaction_checkpoint{checkpoint_id, prompt_index_at_compaction,
checkpoint_file, schema_version: 1, created_at}` and
`auto_compact_completed{tokens_before, tokens_after, summary_preview: null}`,
without the `elapsed_ms` key the source writes as null. Automatic compaction
writes `auto_compact_started{reason, tokens_used, context_window,
percentage}`, the checkpoint and `auto_compact_completed` in mid-turn, and a
cancelled one writes `auto_compact_cancelled` (source). Nothing above a
compaction is rewritten, and `summary_preview` was always null.

Each `toolCallId` writes three records:

1. `tool_call`, whose `title` is the tool name, with a partial `rawInput`
   and `_meta["x.ai/tool"]{name, kind, label, namespace, read_only,
   version}`;
2. the input update, which Grok holds back: `kind`, a human `title`,
   `locations`, `rawInput{variant, …}`, and a `diff` preview for edits;
3. the result: `status` `completed` or `failed`, `content`, `rawOutput`, and
   in 1.0.62 `_meta.toolNotRun` (`rejected` or `cancelled`) for a call that
   never ran.

While a card waits, only the first is on disk. It already holds what the
card names: `rawInput{command, description}` for `run_terminal_command`,
`{file_path, old_string, new_string}` for `search_replace`, and
`questions[{question, options[{label, description}]}]` for
`ask_user_question` (`multiSelect` comes only in the update). An approval
writes nothing. A reject writes the failed result `User rejected the
execution for tool …` and ends the whole turn (`PermissionRejected`).

- Edit results carry `content[{type: diff, path, oldText, newText,
  _meta.details[{old_line, new_line, old_string, new_string,
  context_before, context_after, line_prefix}]}]` and `rawOutput{type:
  SearchReplace, EditsApplied{…}}`; the input update's preview has
  `_meta{old_line, new_line}`, and a created file has no `oldText`.
- Command results keep `output_for_prompt` beside the byte arrays `output`,
  `stdout` and `stderr`.
- Failures are `{error: tool_execution_failed, message}`, or a tagged
  variant such as `FileNotFound`, `MultipleMatchesFound`, `InvalidInput`,
  `IsADirectory` or `FileTooLarge`.
- `todo_write` is followed by a `plan{entries}` snapshot of the whole list.
- A question's result text reads `User has answered your questions:
  "<question>"="<label>"`. A skipped or timed-out question (30 minutes by
  default) completes with an "unanswered" message, and the turn goes on
  (source).

`spawn_subagent` (`rawInput{description, prompt, background}`) is followed
by `subagent_spawned{subagent_id, attempt_id, parent_session_id,
parent_prompt_id, child_session_id, subagent_type, description,
effective_context_source, model}` and `subagent_finished{subagent_id,
status, tool_calls, turns, duration_ms, tokens_used, output, will_wake,
error?}`, both of which can land before the spawn's held input update. The
child is a sibling session folder (`session_kind: subagent`) with no
`session_start` and no herdr report. When the parent turn is cancelled, its
`turn_completed` comes before the child's `subagent_finished{status:
cancelled, error: "Subagent was cancelled"}`, and the spawn call never gets
a final update. A backgrounded command writes `task_backgrounded{task_id,
tool_call_id, command, cwd, description, output_file}` and later
`task_completed{task_snapshot{…, exit_code, signal, kind}, will_wake}`;
`will_wake: true` comes before a turn Grok starts itself.

Errors rest on the source and the census. `retry_state` is
`retrying{attempt, max_retries, reason, error_type?}` between records (73 in
the census, none ending a turn), or `exhausted{attempts, reason,
is_rate_limited}` and `failed{error_type, message}`. An error turn ends with
`turn_completed{stop_reason: error, agent_result, error_kind?}`, where
`agent_result` is the error text and `error_kind` the sampler's kind
(`auth`, `http`, `api`, `rate_limited`, `idle_timeout` and others).
`session_recap{auto, summary}` after a `turn_completed` is a summary, not a
turn. `response_started`, `turn_usage`, `model_changed`, `served_model`,
`available_commands_update` and `current_mode_update` never reached disk in
1.0.62.

## Screen, input and keys

Grok's input box is the bottom-most rounded box: a `╭─` top border, rows
starting `│ ❯ `, and a `╰─` bottom border that carries the model label
(`Grok 4.7 Fast (high)`). A typed `!` on an empty box enters Bash mode
(`│ ! `, with the placeholder `Run shell command`), and a typed `#` enters
Remember mode (`│ # `) only with `[features] remember_mode`. The bottom
border adds `multiline` while `/multiline` is on, and the top border can
carry a label such as `Stashed`, `editing queued #N` or a `/rename` title
(source). The agent view draws no placeholder; the dashboard's box reads
`❯ Dispatch a new agent`. A paste of 4 or more lines, or over 10,000 bytes,
shows as a chip that still holds the whole text. `/minimal` draws no box at
all (user guide; not captured).

Grok draws ghost text, shell completions and prompt suggestions after a
turn, dim and italic (`xai-grok-pager-render/src/theme/mod.rs`
`ghost_text_style`); typed text is never italic. On an empty box the ghost
is the whole suggestion; after typed text it is the rest of it, so a footer
offering `accept suggestion` never by itself means the box is empty. Grok
can also put text back into the box: a stash it restores after the next
send, or a prompt restored by a cancel-rewind or a rewind. Ghost text was
not captured live.

The footer is the last row under the box. With the prompt focused on the
main view it shows `Shift+Tab:mode` first or second:

- idle and empty: `Shift+Tab:mode │ Ctrl+.:shortcuts`;
- a draft: `Enter:send │ Shift+Enter/Opt+Enter:newline │ Shift+Tab:mode │
  Ctrl+.:shortcuts`;
- working: `Shift+Tab:mode │ Ctrl+c:cancel │ Ctrl+b:send to bg │
  Ctrl+.:shortcuts`, with `Ctrl+b` only while a tool runs;
- working with a draft: `Enter:queue │ … │ Ctrl+c:cancel │ Ctrl+Enter:send
  now │ …`;
- items queued and an empty box: `Enter:send now │ … │ Ctrl+;:queue │ …`,
  where Enter sends the first queued item at once, cancelling the turn.

`Tab/→:accept suggestion` is pinned and shows only with prompt focus
(`views/agent.rs`). A pending double press replaces every hint with `press
again to <label>` (`app/app_view.rs`; not captured). Hints stop at the
pane's right edge. The Welcome screen's footer holds only the channel tag
(`[stable]`).

While a turn runs, a status row above the box starts with a braille spinner
(U+2800–U+28FF), then a label, the elapsed times, tokens and `[stop]`:
`⠧ Sleep 40 seconds then echo two… 15s  18s ⇣25.8k [↓][stop]`. A card's
status row starts with `◆` instead. Between that row and the box sit dock
sections: `▾ Queued N` with `#n <text>` rows, `▾ Subagents N` with
`⋅ Subagent …` rows, and others such as Tasks. Labels include `Waiting for
response…`, `Thinking`, `Responding…` and `Compacting…` (during
`/compact`), and by the source `Cancelling…`. During some waits a plain
Enter with text cancels the waiting turn and runs the message next (user
guide `03-keyboard-shortcuts.md`; `views/turn_status.rs`
`is_sendable_wait`): `Waiting for subagent…`, `Waiting for 2 subagents…`,
`Waiting on task output…`, `Waiting on tasks…` and `Sleeping…`. A blocking
wait on a background task that has a description shows `<description>…`,
like a running command. Toasts such as `Press Ctrl+c to cancel the turn`
and `Input cleared · ctrl+z to undo` also sit above the box.

Scrollback user rows are unboxed, five columns in: `❯ <text>`, with a time
at the right edge (`11:10 PM`, or `HH:MM:SS | Mon D` while hovered) and
sometimes a scrollbar glyph (`█`) after it. A long prompt wraps and ends
with `…`.

Other views take the box's place or sit on it, and herdr reports all of them
idle or done:

- the Welcome modal at start (`Resume session ctrl+r`, `Quit ctrl+q`, a
  `Tip:` row). Its box sends normally: the first message becomes the bound
  session's first prompt.
- the resume picker (`┌─ Resume session`, footer `↑↓ nav | e expand | /
  search | f filter | d delete`) and the rewind picker;
- the slash, `@` and `/model` popups, drawn above the box with a count at
  the end of their top rule;
- the `/btw` side panel (`╭─ /btw <question> … [Esc] ╮`);
- the dashboard: `+ New Agent`, `▾ Idle N` session rows, the dispatch box,
  and the footer `Enter:create │ Tab:input │ Ctrl+.:shortcuts`.

The header (`<branch> <cwd> <N>K / 256K │ [Dashboard]`) never shows the
session id.

By the 1.0.45 source, the dashboard also opens one agent's own view (its
session overlay, not captured), whose box sends to that agent:
`Ctrl+\:dashboard` comes first in the footer, and `‹ i/n ›` sits in the
header while there are other agents to cycle to (`agent_view/render.rs`). A
card there replaces the footer's hints with its own.

Cards replace the input box with a panel of rows starting `┃`. Options read
`┃ <key> (○|●) <label>`, `●` marking the preselected row; the focused row
has a lighter background and a bold label.

- The permission card names a command (`┃ › <description>`,
  `┃ │ <command>` and a scope line) or an edit (`Allow Edit to <path>?`).
  A single command lists `Yes, and don't ask again for anything
  (always-approve mode)`, `Always allow: <cmd>`, `(●) Yes, proceed`,
  `No, reject (type to add feedback)` and `Never allow: <prefix>`; a
  compound command only always-approve, `Yes, proceed` and reject; an edit
  always-approve, `Yes, allow all edits during this session`, `(●) Yes`
  and reject. Row 1 is always the always-approve mode. A command card's
  footer reads `1/5:select │ Tab:next option │ ←/→:scope │ e:edit pattern │
  Ctrl+o:always-approve │ Ctrl+c:cancel │ Esc:scrollback`.
- The question card shows one question; options `1 (○) <label>
  <description>`, where a label may end `(Recommended)`; and `z (○) Type
  your answer here`. Nothing is preselected. Its footer reads `Tab:next
  answer │ Esc:scrollback │ Shift+x:dismiss`, under the status row
  `◆ Waiting on answers for <question>`.
- The rewind confirmation offers `y (●) Yes`, `a (○) Yes, and don't ask
  again` and `n (○) No`.
- The `/fork` worktree question offers `1 Yes`, `2 No`, `3 Always worktree`
  and `4 Never worktree`; 3 and 4 write the config.
- Ctrl+C while subagents run opens a stop panel, `Subagents are still
  running. Stop them?`, with `1 (●) Stop running`, `2 Continue to run`,
  `3 Always stop` and `4 Always continue`, and the footer `1/4:select │
  Tab:next choice │ Enter:confirm │ Esc:keep running`.

The plan-approval card, the MCP elicitation card and the prompt-blocked
card were not captured. Permission cards depend on configuration: where
Claude Code's `~/.claude/settings.json` sets `permissions.defaultMode:
"auto"`, Grok imports it and runs in Auto-review. No card appeared and herdr
never reported Blocked, even with `[ui] permission_mode = "ask"`,
`--permission-mode default` or `GROK_AUTO_PERMISSION_MODE=0`; cards appeared
only with `HOME` pointing elsewhere.

Keys, live unless marked:

- Ctrl+C cancels a running turn with an empty box within 0.4 s. Esc never
  cancels; it shows the toast `Press Ctrl+c to cancel the turn`. 1.0.6x has
  no Esc cancel, although the census shows `esc` cancels until September
  2026.
- Ctrl+C on a draft only clears it, whether a turn runs or not.
- Ctrl+C before the first output is the cancel-rewind above.
- With subagents running, Ctrl+C opens the stop panel. There only Esc keeps
  the turn running; `Continue to run` still ends the parent turn, and only
  the subagents survive (source: `app/agent_view/key_owner.rs`).
- Source only: Ctrl+C on an idle empty box arms quit, and a second Ctrl+C
  or Ctrl+D within 1,000 ms quits; while a cancel is pending, Ctrl+C maps to
  quit; on the Welcome screen's resume picker one press quits; on a
  permission card it cancels the request and ends the turn
  (`PermissionCancelled`); on a question it skips.
- Esc twice within 800 ms on an empty idle box opens the rewind picker. On
  a card, Esc parks focus in the scrollback and answers nothing.
- A row's key (a digit, or `a`–`f` on a question) selects and submits at
  once; on a card with several questions it moves to the next one. The
  numbers change with the card's shape, so a key is chosen by its label.
  A letter typed on the reject row opens a feedback field instead, and
  Ctrl+Y hides a question without answering it, leaving the tool waiting.

`agent.prompt` pastes, then presses Enter 300 ms later. What Grok does with
it:

- A draft in the box, typed, restored by a cancel-rewind or a rewind, or
  left by a refused `/goal`, is joined with the paste and sent as one
  prompt.
- While Grok works, the message is queued (`▾ Queued 1`) and becomes the
  next turn. Its records were written when that turn started, 27 s after
  the send in one capture and 37 ms after the previous `turn_completed`;
  herdr stayed working across the handoff. A message sent within 0.3–0.5 s
  of a submit arrives while herdr still reports idle or done.
- On the dashboard it dispatches a new agent.
- `exit`, `quit`, `:q`, `:q!`, `:wq` and `:wq!` quit at once (source; the
  1.0.62 binary compiles these short literals to integer compares, so its
  strings can't confirm them).
- A `/btw` token anywhere turns the whole message into a side question that
  never reaches `updates.jsonl`. A `/goal` token after the start is refused
  with the toast `Slash commands only work at the start of the message: put
  /goal … first.` and stays in the box, while `agent.prompt` still
  succeeds. A token is `/` at the start or after ASCII whitespace, up to the
  next whitespace (`slash/mod.rs`), so `/btw,` is not one.
- `/model ` puts the highlighted model in the box and opens a context-size
  list, so the next Enter would switch models. An unknown `/foo bar ` goes
  to the model as text.
- `/new`, `/clear`, `/compact`, `/resume`, `/fork`, `/dashboard` and `/quit`
  ran with Heeler's trailing space.
- A pasted leading `!` stays text, without Bash mode, but the model ran the
  command as a tool anyway. Only a typed `#` enters Remember mode
  (source).
- In `/multiline` mode Enter adds a line, so nothing is sent (source).
- A skill runs as `/name args`. A skill named like a built-in command runs
  the built-in, and is reachable only as `/local:<name>` or `/user:<name>`
  (user guide `04-slash-commands.md`). Whether the slash popup takes the
  Enter after `/name args ` was not captured.

## Open questions

Not captured yet:

- F1: a skill sent through `agent.prompt` with arguments and a trailing
  space, and its `/local:` form.
- F2: Ctrl+C on an idle, empty box: the `press again to quit` footer at 40,
  62 and 120 columns, including while a new turn starts.
- F3: a second Ctrl+C while a cancel is pending, and the `Cancelling…` row.
- F4: Ctrl+C on a permission card, and how far herdr's Blocked lags the
  card.
- F5: a reject with typed feedback, which continues the turn.
- F6: question variants: a skip with Ctrl+C or Shift+X, a free-text answer,
  several questions, and multi-select.
- F7: an image prompt's chunk.
- F8: every `retry_state` variant and an error turn.
- F9: `/multiline`: the bottom-border label and its place at 40 and 62
  columns.
- F10: the dashboard's Ctrl+N, and a session closed in its details view and
  reopened with `/resume`.
- F11: steer mode's interjection chunk (needs a config change).
- F12: why `GROK_AUTO_PERMISSION_MODE=0` alone did not bring cards back.
- F13: plan mode's approval card.
- F14: automatic compaction in 1.0.62.
- F15: a hook cancel's `cancellationCategory`.
- F16: a directory whose encoded name exceeds 255 bytes.
- F17: what `Always allow: <cmd>` and `Yes, allow all edits during this
  session` keep, and whether they outlive a restart.
- F18: `prompt_history.jsonl` for a session in a worktree group, and its
  rewrite at 10,000 entries.
- F19: Esc on the subagent stop panel.
- F20: `/compact` with nothing to compact, and with a focus.
- F21: captures at 40×30, 62×40 and 120×40 of the idle, draft, working,
  queued and subagent-wait screens, both cards, a Session line after `/new`,
  the dashboard and the armed-quit footer.
- F22: a pasted `#` and a pasted `!` at the start.
- F23: focus states: the queue pane, the scrollback after Esc on a card,
  Tasks and Todo focus, the `editing queued` border, a subagent's child
  view, and the Welcome screen with a reported session.
- F24: prompt suggestions: an idle ghost at three widths, typed text plus a
  ghost, and a stash restored after a send.
- F25: the waits: a described background task, `Waiting for 2 subagents…`
  and `Sleeping…`.
- F26: minimal mode.
- F27: `/fork`, then `/resume` back to the parent: does the fork's Session
  line stay on screen? By the 1.0.45 source it doesn't: Grok prints a
  Session line only into the scrollback of the session it names
  (`dispatch/session/lifecycle.rs`, `load.rs`), the parent gets `Forked`,
  and each agent keeps its own scrollback.
- F28: the Welcome screen after `/home` with a reported session: does a
  send start a new session that herdr adopts?

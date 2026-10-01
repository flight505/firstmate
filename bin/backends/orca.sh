#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. Escape and Ctrl-U
# are delivered as their raw --text control bytes; see fm_backend_orca_send_key.
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

# Shared, backend-neutral harness-process identity (bin/fm-agent-process-lib.sh):
# reused here to judge Orca's own reported `agentIdentity` string against the
# same verified-harness vocabulary every other backend uses, so "claude",
# "codex", etc. cannot drift into a second identity list.
# shellcheck source=bin/fm-agent-process-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-agent-process-lib.sh"

# Shared normalized-transition shape and status->action policy table, reused by
# the native agent-state wait at the end of this file so Orca's `waiting` state
# follows the same supervision policy as every other push-capable backend.
# shellcheck source=bin/fm-transition-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-transition-lib.sh"

fm_backend_orca_tool_check() {
  command -v orca >/dev/null 2>&1 || { echo "error: backend=orca selected but the 'orca' CLI is not installed" >&2; return 1; }
}

fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local out
  out=$(orca status --json 2>/dev/null) || {
    echo "error: backend=orca selected but 'orca status --json' failed; start Orca and wait for the runtime to be ready" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca status JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: Orca runtime is not ready" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const r = data.result || {};
const runtime = r.runtime || {};
const reachable = runtime.reachable ?? r.runtimeReachable;
const state = runtime.state || r.runtimeState || "";
if (reachable === true && state === "ready") process.exit(0);
console.error(`error: backend=orca requires a ready Orca runtime (reachable=${String(reachable)}, state=${state || "unknown"})`);
process.exit(1);
'
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path terminal-handle worktree-terminal-handle repo-id
  # Terminal handles are accepted only from verified terminal result shapes:
  # result.terminal or a root terminal object with .handle. Undocumented
  # result.id and result.worktree.terminal shapes are ignored until a real Orca
  # smoke run proves them.
  local field=$1
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const wt = r.worktree || r.item || r;
const explicitTerm = r.terminal || null;
const repo = r.repo || r.repository || r;
function scalar(v) {
  return (typeof v === "string" || typeof v === "number") ? String(v) : "";
}
function handle(obj) {
  if (!obj) return "";
  if (typeof obj === "string" || typeof obj === "number") return String(obj);
  return scalar(obj.handle) || "";
}
let v = "";
if (field === "worktree-id") v = wt.id || wt.worktreeId || r.worktreeId || "";
if (field === "worktree-path") v = wt.path || (wt.git && wt.git.path) || r.path || "";
if (field === "terminal-handle") v = handle(explicitTerm || r) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm) || "";
if (field === "repo-id") v = repo.id || repo.repoId || r.repoId || "";
if (!v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_run_json() {
  local out
  out=$("$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 out repo_id
  fm_backend_orca_tool_check || return 1
  out=$(orca repo show --repo "path:$project" --json 2>/dev/null || true)
  if repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id 2>/dev/null); then
    printf '%s' "$repo_id"
    return 0
  fi
  out=$(orca repo add --path "$project" --json) || return 1
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
    echo "error: orca repo add did not return a repo id for $project" >&2
    return 1
  }
  printf '%s' "$repo_id"
}

fm_backend_orca_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 repo_id out wt_id wt_path terminal
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  # Nest the task worktree under the project's main checkout so Orca lists the
  # crew as child rows of that project, the way a Herdr space groups its task
  # tabs. Worktree ids are <repo-id>::<path>, so the main checkout's id needs
  # no extra lookup. A host that rejects the parent selector gets one retry as
  # an independent worktree rather than a refused spawn.
  out=$(orca worktree create --repo "id:$repo_id" --name "$name" --parent-worktree "worktree:${repo_id}::${project}" --setup skip --json 2>/dev/null) \
    && printf '%s' "$out" | fm_backend_orca_json_get worktree-id >/dev/null 2>&1 \
    || out=$(orca worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --json) \
    || return 1
  wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: orca worktree create did not return a worktree id for $name" >&2
    return 1
  }
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null || true)
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree create did not return a path for $name" >&2
    [ -z "$terminal" ] || fm_backend_orca_kill "$terminal" >/dev/null 2>&1 || true
    if fm_backend_orca_remove_worktree "$wt_id" >/dev/null; then
      return 1
    fi
    if [ -n "$terminal" ]; then
      printf '%s\t\t%s' "$wt_id" "$terminal"
    else
      printf '%s\t' "$wt_id"
    fi
    return 2
  }
  printf '%s\t%s' "$wt_id" "$wt_path"
  [ -z "$terminal" ] || printf '\t%s' "$terminal"
}

fm_backend_orca_terminal_create() {  # <worktree-id> <title>
  local worktree_id=$1 title=$2 out terminal
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal create --worktree "id:$worktree_id" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  printf '%s' "$terminal"
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_remove_worktree() {  # <worktree-id>
  local worktree_id=${1:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca worktree rm --worktree "id:$worktree_id" --force --json
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} out path
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(orca worktree show --worktree "id:$worktree_id" --json) || return 1
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id" >&2
    return 1
  }
  printf '%s' "$path"
}

# fm_backend_orca_terminal_show_fields: read `orca terminal show`'s own
# `connected` and `agentIdentity` fields for <terminal-id>, one per output
# line as `connected=<true|false|unknown>` and `identity=<value-or-empty>`.
# Exit 0 only for a successful, parseable read; exit 2 for a command failure
# or an `ok: false` response (the terminal handle did not resolve, or some
# other request-level error); exit 1 for unparseable JSON. The caller
# (fm_backend_orca_agent_state) does not need to tell those failure shapes
# apart itself - both mean "this read did not prove anything either way".
fm_backend_orca_terminal_show_fields() {  # <terminal-id>
  local terminal=$1 out
  out=$(orca terminal show --terminal "$terminal" --json 2>/dev/null) || return 2
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  process.exit(1);
}
if (data.ok === false) process.exit(2);
const r = data.result || {};
const term = r.terminal || r;
const connected = term.connected;
const identity = term.agentIdentity;
const connStr = (typeof connected === "boolean") ? String(connected) : "unknown";
process.stdout.write("connected=" + connStr + "\n");
process.stdout.write("identity=" + (typeof identity === "string" ? identity : "") + "\n");
'
}

# fm_backend_orca_agent_state: recovery-grade harness-agent state for one
# recorded Orca terminal handle. See bin/fm-backend.sh's fm_backend_agent_state
# for the shared state vocabulary. Built directly on `orca terminal show`'s own
# `connected` and `agentIdentity` fields (docs/orca-backend.md "Recovery")
# rather than text-scraping the composer, the same way the herdr adapter
# cross-checks its own native pane/process fields instead of guessing from
# rendered output.
#
# `connected=true` is `alive`, downgraded to `ambiguous` when Orca reports an
# `agentIdentity` that the shared fm_agent_process_classify_name vocabulary
# does not recognize as an agent. An absent identity does not downgrade the
# verdict, because Orca omits it for some running agents as well as for a bare
# shell (docs/verification/runtime-backends.md "Orca agent state").
# `connected=false` is `dead`: the terminal handle still resolves but its
# terminal is closed, so nothing can be running in it.
#
# `connected` is the TERMINAL's liveness, not the agent's: an agent that exited
# back to its shell still reads `connected=true`, and so `alive`. This
# classifier therefore never reports a false `dead` or `missing` - the only
# verdicts that license recovery - but it cannot prove that an agent stopped
# inside an open terminal, which is why bin/fm-control-lib.sh's
# fm_control_backend_state_verified keeps exit/relaunch refused on Orca.
#
# A read that is refused outright (command failure or `ok: false`) cannot by
# itself tell "the terminal is gone" apart from "Orca could not be asked right
# now", so it falls back to the same two-source pattern
# fm_backend_herdr_agent_state uses for its own failed pane read: a separately
# confirmed ready Orca runtime means the refusal is authoritative absence
# (`missing`), while an unreachable runtime means nothing was proven either way
# (`unreadable`). A successful read that omits or garbles `connected`, and
# unparseable JSON, prove nothing about the terminal and are always
# `unreadable`, never `missing`.
fm_backend_orca_agent_state() {  # <terminal-id>
  local terminal=$1 fields status connected identity
  fm_backend_orca_tool_check || { printf 'unreadable'; return 0; }
  fields=$(fm_backend_orca_terminal_show_fields "$terminal")
  status=$?
  if [ "$status" -eq 0 ]; then
    connected=$(printf '%s\n' "$fields" | sed -n 's/^connected=//p')
    identity=$(printf '%s\n' "$fields" | sed -n 's/^identity=//p')
    case "$connected" in
      true)
        if [ -n "$identity" ] && [ "$(fm_agent_process_classify_name "$identity")" != agent ]; then
          printf 'ambiguous'
        else
          printf 'alive'
        fi
        return 0
        ;;
      false)
        printf 'dead'
        return 0
        ;;
    esac
    printf 'unreadable'
    return 0
  fi
  if [ "$status" -eq 2 ] && fm_backend_orca_runtime_check >/dev/null 2>&1; then
    printf 'missing'
  else
    printf 'unreadable'
  fi
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_orca_agent_alive() {  # <terminal-id>
  case "$(fm_backend_orca_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$terminal" --limit "$lines" --json) || return 1
  fm_backend_orca_json_text "$out"
}

fm_backend_orca_json_text() {  # <json>
  printf '%s' "$1" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else if (Array.isArray(r.tail)) {
  process.stdout.write(r.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

# fm_backend_orca_composer_capture: the orca composer screen - one bounded
# tail read of the live terminal. Deliberately NOT the old 200-line
# backward-paged read: the composer is bottom-anchored, and paging back into
# scrollback is what let a stale startup banner (codex's bordered
# "permissions" box) compete with - and once outrank - the live composer.
fm_backend_orca_composer_capture() {  # <terminal-id> [expected-label]
  fm_backend_orca_capture "$1" "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh). Orca's `terminal read` returns
# plain text; whether it can emit ANSI is unverified (orca is not installed
# on the verification machine), so styled stays 0 - the conservative
# degradation - until a live capture proves otherwise.
fm_backend_orca_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape (bordered boxes AND the borderless bare-glyph
# row this adapter never learned, which left every claude/codex/pi/muse steer
# unconfirmed) lives in bin/fm-composer-lib.sh.
fm_backend_orca_composer_state() {  # <terminal-id> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_orca_composer_capture "$1") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_orca_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# fm_backend_orca_send_key: one named special key.
# C-c uses Orca's dedicated --interrupt (SIGINT-style) primitive. Enter is an
# empty --enter send. Escape and C-u are delivered as their raw control bytes
# through --text, which passes bytes straight to the PTY.
# This matters because --interrupt is NOT a substitute for Escape: every
# harness except grok cancels a turn with Escape, not Ctrl-C (bin/fm-control-lib.sh),
# so aliasing them would mis-fire (e.g. exit Claude instead of interrupting it).
fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    Escape|escape|Esc|esc)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$(printf '\033')" --json
      ;;
    C-u|ctrl+u|Ctrl-u|Ctrl-U)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$(printf '\025')" --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_orca_send_text_submit: type <text> once, then drive the shared
# verify-and-retry-Enter loop (bin/fm-composer-lib.sh:
# fm_composer_submit_retry_core) against the shared composer verdict, so a
# slash-command popup placeholder fill gets the required second Enter without
# duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_orca_send_key fm_backend_orca_composer_state \
    "$terminal" "$retries" "$sleep_s"
}

# fm_backend_orca_kill: close one recorded task terminal. A missing CLI is a
# close that was never even attempted, not an endpoint proven gone - with no
# CLI there is no read that could show the terminal absent - so it reports the
# failure its tool check already named instead of a success. The close call
# itself stays best-effort: whether an accepted-then-failed close left the
# terminal alive is not yet decidable without a presence re-read proven
# against the real Orca binary (docs/verification/runtime-backends.md
# "Endpoint close").
fm_backend_orca_kill() {  # <terminal-id>
  fm_backend_orca_tool_check || return 1
  orca terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}

# --- native agent state: worktree ps rows and the tui-idle wait --------------
#
# Orca reports the agent in each terminal through two native surfaces. Both were
# verified live; docs/verification/runtime-backends.md "Orca" records the exact
# response shapes, and only those shapes are accepted here.
#
#   orca worktree ps --json
#       One row per agent, fed by Orca's own status hooks and keyed by
#       `paneKey` ("<tabId>:<leafId>", the two ids `orca terminal show` reports
#       for a terminal handle). `state` is working, waiting, or done, and
#       `mainAgent.state` is the same vocabulary for the main turn alone: a
#       turn that ended with a background shell still running reads
#       state=working beside mainAgent.state=done.
#   orca terminal wait --terminal <handle> --for tui-idle --timeout-ms <ms> --json
#       Answers `result.wait.satisfied=true` once the TUI is idle - at its
#       prompt or at a permission dialog - and `error.code=timeout` otherwise.
#       A timeout is NOT proof of work: a terminal with no agent in it times
#       out the same way.
#
# Three rules follow from what the live run showed, and every reader below
# keeps them:
#   - Only a `working` row whose main turn is also `working` is busy, and only
#     a `done` row whose main turn is also `done` is idle. No row, a
#     disagreeing pair, and an unrecognized state are all unknown.
#   - `waiting` is never idle on its own word. Orca keeps reporting it after
#     the human approves, for as long as the approved tool runs, so a waiting
#     row is escalated only when the tui-idle wait independently agrees.
#   - Orca drops a row within seconds of its agent exiting or being killed, so
#     a row is never a registration left behind over a bare shell.

# Dedupe marker for an escalated waiting episode, one per terminal under the
# state dir. It holds the row's `stateStartedAt`, so a later, different
# waiting episode re-escalates even when no `working` read fell in between.
FM_BACKEND_ORCA_ESCALATED_PREFIX=".orca-escalated-"
# How long one tui-idle read may take to agree that a `waiting` row really is
# parked on the human. A live dialog answers at once; an approved tool that is
# still running does not answer at all.
FM_BACKEND_ORCA_IDLE_CONFIRM_MS=${FM_BACKEND_ORCA_IDLE_CONFIRM_MS:-1500}

# fm_backend_orca_pane_key: the `paneKey` Orca's agent rows carry for
# <terminal-id>, built from the `tabId` and `leafId` of a `terminal show`
# answer that names the same handle. Fails on any other shape.
fm_backend_orca_pane_key() {  # <terminal-id> -> <tabId>:<leafId>
  local terminal=$1 out
  fm_backend_orca_tool_check 2>/dev/null || return 1
  out=$(orca terminal show --terminal "$terminal" --json 2>/dev/null) || return 1
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  process.exit(1);
}
const term = data && data.ok === true && data.result && data.result.terminal;
const id = (v) => typeof v === "string" && v !== "";
if (!term || term.handle !== process.argv[1] || !id(term.tabId) || !id(term.leafId)) process.exit(1);
process.stdout.write(term.tabId + ":" + term.leafId);
' "$terminal"
}

fm_backend_orca_ps_json() {
  fm_backend_orca_tool_check 2>/dev/null || return 1
  orca worktree ps --json 2>/dev/null
}

# fm_backend_orca_ps_row: the one agent row for <pane-key> in a `worktree ps`
# answer on stdin, as "<state> <main-state> <state-started-at>" with `-` for an
# absent second or third field. Returns 1 when no single row matches and 2 when
# the answer itself is not the verified shape.
fm_backend_orca_ps_row() {  # <pane-key> (stdin: worktree ps JSON)
  node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  process.exit(2);
}
const worktrees = data && data.ok === true && data.result && data.result.worktrees;
if (!Array.isArray(worktrees)) process.exit(2);
const rows = [];
for (const wt of worktrees) {
  if (!wt || !Array.isArray(wt.agents)) continue;
  for (const agent of wt.agents) {
    if (agent && agent.paneKey === process.argv[1]) rows.push(agent);
  }
}
if (rows.length !== 1) process.exit(1);
const token = (v) => (typeof v === "string" && /^[a-z][a-z-]*$/.test(v) ? v : "");
const row = rows[0];
const state = token(row.state);
if (!state) process.exit(1);
const main = token(row.mainAgent && row.mainAgent.state) || "-";
const since = Number.isSafeInteger(row.stateStartedAt) && row.stateStartedAt > 0 ? String(row.stateStartedAt) : "-";
process.stdout.write(state + " " + main + " " + since);
' "$1"
}

# fm_backend_orca_agent_status_raw: one `terminal show` plus one `worktree ps`
# read for <terminal-id>, echoing its row as fm_backend_orca_ps_row prints it.
fm_backend_orca_agent_status_raw() {  # <terminal-id>
  local key ps
  key=$(fm_backend_orca_pane_key "$1") || return 1
  ps=$(fm_backend_orca_ps_json) || return 1
  printf '%s' "$ps" | fm_backend_orca_ps_row "$key"
}

# fm_backend_orca_classify_agent_status: busy and idle each need Orca's row
# state and its main-turn state to agree; see the rules in the block header.
fm_backend_orca_classify_agent_status() {  # <state> <main-state>
  case "$1:$2" in
    working:working) printf 'busy' ;;
    done:done) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_orca_busy_state: semantic busy state from Orca's own agent row.
# Any failed or unrecognized read is unknown, never idle.
fm_backend_orca_busy_state() {  # <terminal-id> -> busy|idle|unknown
  local raw main
  raw=$(fm_backend_orca_agent_status_raw "$1") || { printf 'unknown'; return 0; }
  main=${raw#* }
  fm_backend_orca_classify_agent_status "${raw%% *}" "${main%% *}"
}

# fm_backend_orca_idle_wait: block until the first of <terminal-id...> reports
# its TUI idle, up to <timeout-ms>. Prints that terminal id and returns 0;
# returns 1 when none went idle and at least one wait ended in Orca's own
# timeout answer, and 2 when no wait gave a recognized answer at all. The waits
# run side by side as children of one short-lived reader, which stops the rest
# as soon as one is satisfied and never outlives its budget by more than a few
# seconds.
fm_backend_orca_idle_wait() {  # <timeout-ms> <terminal-id...>
  local ms=$1
  shift
  case "$ms" in ''|*[!0-9]*|0) return 2 ;; esac
  [ "$#" -gt 0 ] || return 2
  fm_backend_orca_tool_check 2>/dev/null || return 2
  node -e '
const fs = require("fs");
const { spawn } = require("child_process");
const ms = process.argv[1];
const handles = process.argv.slice(2);
const kids = [];
let pending = handles.length;
let clean = 0;
let finished = false;
function finish(code, out) {
  if (finished) return;
  finished = true;
  for (const kid of kids) {
    try {
      kid.kill("SIGTERM");
    } catch (err) {}
  }
  if (out) fs.writeSync(1, out);
  process.exit(code);
}
for (const handle of handles) {
  let buf = "";
  let settled = false;
  const settle = (spawned) => {
    if (settled) return;
    settled = true;
    let data = null;
    if (spawned) {
      try {
        data = JSON.parse(buf);
      } catch (err) {}
    }
    const wait = data && data.ok === true && data.result && data.result.wait;
    if (wait && wait.handle === handle && wait.condition === "tui-idle" && wait.satisfied === true) {
      finish(0, handle);
      return;
    }
    if (data && data.ok === false && data.error && data.error.code === "timeout") clean += 1;
    pending -= 1;
    if (pending === 0) finish(clean > 0 ? 1 : 2);
  };
  const kid = spawn(
    "orca",
    ["terminal", "wait", "--terminal", handle, "--for", "tui-idle", "--timeout-ms", ms, "--json"],
    { stdio: ["ignore", "pipe", "ignore"] },
  );
  kids.push(kid);
  kid.stdout.on("data", (chunk) => {
    buf += chunk;
  });
  kid.on("error", () => settle(false));
  kid.on("close", () => settle(true));
}
setTimeout(() => finish(2), Number(ms) + 5000);
process.on("SIGTERM", () => finish(2));
process.on("SIGINT", () => finish(2));
' "$ms" "$@"
}

# fm_backend_orca_events_capable: the capability gate for the native wait.
# Orca prints its own machine-readable command schema, so the gate asks that
# schema for the three commands and flags this file relies on rather than
# comparing version numbers. FM_BACKEND_ORCA_EVENTS_FORCE overrides the verdict
# for tests (1 = capable, 0 = incapable) without touching the real binary.
fm_backend_orca_events_capable() {  # [<session>]
  local out
  case "${FM_BACKEND_ORCA_EVENTS_FORCE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  fm_backend_orca_tool_check 2>/dev/null || return 1
  out=$(orca agent-context --json 2>/dev/null) || return 1
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  process.exit(1);
}
const commands = data && Array.isArray(data.commands) ? data.commands : [];
const need = {
  "terminal wait": ["terminal", "for", "timeout-ms", "json"],
  "terminal show": ["terminal", "json"],
  "worktree ps": ["json"],
};
for (const name of Object.keys(need)) {
  const cmd = commands.find((c) => c && c.command === name);
  if (!cmd || !Array.isArray(cmd.flags)) process.exit(1);
  for (const flag of need[name]) {
    if (!cmd.flags.includes(flag)) process.exit(1);
  }
}
const wait = commands.find((c) => c && c.command === "terminal wait");
if (typeof wait.usage !== "string" || !wait.usage.includes("tui-idle")) process.exit(1);
'
}

# fm_backend_orca_normalize_status: Orca's row state in the shared agent-state
# vocabulary of bin/fm-transition-lib.sh. `waiting` is Orca's word for an agent
# parked on the human, which that vocabulary calls `blocked`.
fm_backend_orca_normalize_status() {  # <state>
  case "$1" in
    working) printf 'working' ;;
    waiting) printf 'blocked' ;;
    done) printf 'done' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_orca_escalation_marker() {  # <state_dir> <terminal-id>
  local key
  key=$(printf '%s' "$2" | tr ':/.' '___')
  printf '%s/%s%s' "$1" "$FM_BACKEND_ORCA_ESCALATED_PREFIX" "$key"
}

# fm_backend_orca_reconcile_row: route one terminal's row through the shared
# policy table. Returns 0 and prints the normalized record for a waiting
# episode that has not been escalated yet and that the tui-idle wait agrees is
# parked; returns 3 when the terminal is in a turn whose end is worth waiting
# for; returns 1 for everything else. <idle-proven> is 1 when the caller has
# just seen this terminal's tui-idle wait satisfied, which is that agreement.
# The episode stamp is staged beside the marker and only becomes the marker
# when the caller commits, so a wake that was never queued stays eligible.
fm_backend_orca_reconcile_row() {  # <state_dir> <terminal-id> <row> <idle-proven>
  local state=$1 terminal=$2 row=$3 idle_proven=$4 status main since marker rc
  status=$(fm_backend_orca_normalize_status "${row%% *}")
  main=${row#* }
  main=${main%% *}
  since=${row##* }
  marker=$(fm_backend_orca_escalation_marker "$state" "$terminal")
  case "$(fm_transition_policy "$status")" in
    actionable)
      if [ -e "$marker" ] && [ "$(cat "$marker" 2>/dev/null || true)" = "$since" ]; then
        return 1
      fi
      if [ "$idle_proven" != 1 ]; then
        rc=0
        fm_backend_orca_idle_wait "$FM_BACKEND_ORCA_IDLE_CONFIRM_MS" "$terminal" >/dev/null || rc=$?
        case "$rc" in
          0) ;;
          1) return 3 ;;
          *) return 1 ;;
        esac
      fi
      printf '%s' "$since" > "$marker.pending" || return 1
      fm_transition_record "$terminal" "" "" "$status" ""
      return 0
      ;;
    absorb)
      rm -f "$marker" "$marker.pending" 2>/dev/null || true
      # A main turn that is already over leaves the TUI idle while a background
      # shell keeps the row working, so there is no turn end left to wait for.
      [ "$main" != "done" ] || return 1
      return 3
      ;;
  esac
  return 1
}

fm_backend_orca_commit_transition() {  # <state_dir> <session> <record>
  local marker terminal
  terminal=$(fm_transition_pane_id "$3")
  [ -n "$terminal" ] || return 1
  marker=$(fm_backend_orca_escalation_marker "$1" "$terminal")
  if [ -e "$marker.pending" ]; then
    mv -f "$marker.pending" "$marker"
  else
    : > "$marker"
  fi
}

fm_backend_orca_clear_transition() {  # <state_dir> <terminal-id>
  local marker
  [ -n "${2:-}" ] || return 0
  marker=$(fm_backend_orca_escalation_marker "$1" "$2")
  rm -f "$marker" "$marker.pending" 2>/dev/null || true
}

# fm_backend_orca_wait_transition: the watcher's bounded wait for an Orca home.
# Instead of sleeping blind it reads every listed terminal's row once, then
# blocks on Orca's tui-idle wait for the ones still in a turn, and returns the
# moment one of them parks on the human. It prints the normalized record and
# returns 0 for a fresh waiting episode; returns 1 once the whole budget has
# passed with nothing to escalate, so the caller has already slept; and returns
# 2 when Orca could not be read, so the caller sleeps the budget itself. A turn
# that simply ends is left to the watcher's ordinary status and turn-end
# handling on its next cycle, exactly as the shared policy defers it.
fm_backend_orca_wait_transition() {  # <session> <timeout_secs> <state_dir> <terminal-id...>
  local timeout=$2 state=$3
  shift 3
  [ "$#" -gt 0 ] || return 2
  case "$timeout" in ''|*[!0-9]*) return 2 ;; esac
  if [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" != 1 ]; then
    fm_backend_orca_events_capable || return 2
  fi
  local ps terminal other key row hit rc started now remaining
  local busy=() rest=()
  started=$(date +%s)
  ps=$(fm_backend_orca_ps_json) || return 2
  for terminal in "$@"; do
    key=$(fm_backend_orca_pane_key "$terminal") || continue
    rc=0
    row=$(printf '%s' "$ps" | fm_backend_orca_ps_row "$key") || rc=$?
    [ "$rc" -ne 2 ] || return 2
    [ "$rc" -eq 0 ] || continue
    rc=0
    hit=$(fm_backend_orca_reconcile_row "$state" "$terminal" "$row" 0) || rc=$?
    case "$rc" in
      0)
        printf '%s' "$hit"
        return 0
        ;;
      3) busy+=("$terminal") ;;
    esac
  done
  while [ "${#busy[@]}" -gt 0 ]; do
    now=$(date +%s)
    remaining=$(( timeout - (now - started) ))
    [ "$remaining" -gt 0 ] || return 1
    rc=0
    terminal=$(fm_backend_orca_idle_wait "$(( remaining * 1000 ))" "${busy[@]}") || rc=$?
    case "$rc" in
      0) ;;
      1) return 1 ;;
      *) return 2 ;;
    esac
    # This terminal's turn reached an idle TUI. It leaves the wait set whatever
    # its row says, so an idle terminal can never make this loop spin.
    rest=()
    for other in "${busy[@]}"; do
      [ "$other" = "$terminal" ] || rest+=("$other")
    done
    busy=(${rest[@]+"${rest[@]}"})
    row=$(fm_backend_orca_agent_status_raw "$terminal") || continue
    rc=0
    hit=$(fm_backend_orca_reconcile_row "$state" "$terminal" "$row" 1) || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s' "$hit"
      return 0
    fi
  done
  now=$(date +%s)
  remaining=$(( timeout - (now - started) ))
  [ "$remaining" -le 0 ] || sleep "$remaining"
  return 1
}

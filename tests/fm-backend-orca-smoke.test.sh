#!/usr/bin/env bash
# tests/fm-backend-orca-smoke.test.sh - real Orca smoke test for the native
# agent-state reads in bin/backends/orca.sh. tests/fm-backend-orca.test.sh
# fakes the CLI, so it can only confirm the shapes written into its own fake;
# this one asks the REAL app whether it still answers in those shapes, and
# fails naming the Orca version when it does not.
#
# Orca is one shared GUI app, the same posture as cmux, so this test is
# read-only: it creates nothing, sends nothing, and closes nothing. It runs
# `orca status`, `orca agent-context`, `orca worktree ps`, one `terminal show`
# of the terminal it is itself running in when there is one, and one
# `terminal wait` on a handle that cannot exist. It submits no prompt.
#
# Skips cleanly when orca or node is absent or the runtime is not ready, so CI
# and dev machines without a running Orca are unaffected. Run it after every
# Orca upgrade and before trusting a refreshed docs/verification/runtime-backends.md
# "Orca" entry; the transitions between agent states need a live agent and stay
# a recorded manual observation there.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s (orca %s)\n' "$1" "${ORCA_VERSION:-unknown}" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v orca >/dev/null 2>&1 || { echo "skip: orca not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by the orca adapter)"; exit 0; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source orca || { echo "skip: could not source the orca adapter"; exit 0; }
fm_backend_orca_runtime_check >/dev/null 2>&1 || { echo "skip: orca runtime not reachable and ready"; exit 0; }

ORCA_VERSION=$(orca --version 2>/dev/null | head -1)
NO_SUCH_TERMINAL=term_00000000-0000-0000-0000-000000000000

# --- capability gate ---------------------------------------------------------

fm_backend_orca_events_capable \
  || fail "agent-context no longer lists terminal wait (tui-idle, --timeout-ms), terminal show, and worktree ps with the flags the adapter uses"
pass "orca $ORCA_VERSION: the command schema lists the native wait and agent-row commands the adapter uses"

# --- worktree ps: the agent-row shape ----------------------------------------

PS_JSON=$(fm_backend_orca_ps_json) || fail "worktree ps --json failed"
ROWS=$(printf '%s' "$PS_JSON" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const worktrees = data && data.ok === true && data.result && data.result.worktrees;
if (!Array.isArray(worktrees)) {
  console.log("bad: result.worktrees is not an array under ok:true");
  process.exit(0);
}
const known = new Set(["working", "waiting", "done"]);
let rows = 0;
for (const wt of worktrees) {
  if (wt.agents === undefined) continue;
  if (!Array.isArray(wt.agents)) {
    console.log("bad: a worktree row carries a non-array agents field");
    process.exit(0);
  }
  for (const agent of wt.agents) {
    rows += 1;
    if (typeof agent.paneKey !== "string" || !/^[^:]+:[^:]+$/.test(agent.paneKey)) {
      console.log("bad: an agent row has no <tabId>:<leafId> paneKey");
      process.exit(0);
    }
    if (!known.has(agent.state)) {
      console.log("bad: an agent row state is outside working|waiting|done: " + String(agent.state));
      process.exit(0);
    }
    if (!agent.mainAgent || !known.has(agent.mainAgent.state)) {
      console.log("bad: an agent row has no mainAgent.state in working|waiting|done");
      process.exit(0);
    }
    if (!Number.isSafeInteger(agent.stateStartedAt)) {
      console.log("bad: an agent row has no integer stateStartedAt");
      process.exit(0);
    }
  }
}
console.log("rows: " + rows);
') || fail "worktree ps --json did not return parseable JSON"
case "$ROWS" in
  "rows: 0") pass "orca $ORCA_VERSION: worktree ps answers in the verified envelope (no agent is live, so the row shape was not checked)" ;;
  "rows: "*) pass "orca $ORCA_VERSION: worktree ps answers in the verified envelope and all ${ROWS#rows: } live agent rows carry the verified fields" ;;
  *) fail "worktree ps shape drifted - ${ROWS#bad: }" ;;
esac

# --- terminal show: the pane key of this very terminal -----------------------

if [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
  KEY=$(fm_backend_orca_pane_key "$ORCA_TERMINAL_HANDLE") \
    || fail "terminal show no longer returns result.terminal.{handle,tabId,leafId} for this terminal"
  if [ -n "${ORCA_PANE_KEY:-}" ] && [ "$KEY" != "$ORCA_PANE_KEY" ]; then
    fail "the pane key built from terminal show ($KEY) is not the one Orca gave this terminal ($ORCA_PANE_KEY)"
  fi
  STATE=$(fm_backend_busy_state orca "$ORCA_TERMINAL_HANDLE")
  case "$STATE" in
    busy|idle|unknown) ;;
    *) fail "busy state of this terminal is outside busy|idle|unknown: '$STATE'" ;;
  esac
  pass "orca $ORCA_VERSION: terminal show yields this terminal's pane key, and its native busy state reads '$STATE'"
else
  pass "orca $ORCA_VERSION: not running inside an Orca terminal, so terminal show was not checked"
fi

# --- a terminal that does not exist is never busy and never idle --------------

STATE=$(fm_backend_busy_state orca "$NO_SUCH_TERMINAL")
[ "$STATE" = unknown ] || fail "a terminal that does not exist must read unknown, got '$STATE'"
RC=0
OUT=$(fm_backend_orca_idle_wait 200 "$NO_SUCH_TERMINAL") || RC=$?
[ "$RC" -eq 2 ] && [ -z "$OUT" ] \
  || fail "a tui-idle wait on a terminal that does not exist must be an unusable read (rc 2), got rc=$RC out='$OUT'"
pass "orca $ORCA_VERSION: a terminal that does not exist reads unknown, and its tui-idle wait is an unusable read rather than idle"

echo "# fm-backend-orca-smoke.test.sh: all assertions passed"

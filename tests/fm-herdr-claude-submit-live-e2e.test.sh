#!/usr/bin/env bash
set -u

if [ "${FM_HERDR_CLAUDE_SUBMIT_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_CLAUDE_SUBMIT_LIVE_E2E=1 to run the real Claude/Herdr submit regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
CLAUDE_VERSION=unavailable
HERDR_VERSION=unavailable

fail() {
  printf 'not ok - %s [claude=%s herdr=%s]\n' \
    "$1" "$CLAUDE_VERSION" "$HERDR_VERSION" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

for tool in claude herdr jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found"
done
[ -x "$LAB_HELPER" ] || fail "Herdr lab helper not executable at $LAB_HELPER"
CLAUDE_VERSION=$(claude --version 2>&1) || fail "Claude did not report its version"
CLAUDE_VERSION=${CLAUDE_VERSION%%$'\n'*}
HERDR_VERSION=$(herdr --version 2>&1) || fail "Herdr did not report its version"
HERDR_VERSION=${HERDR_VERSION%%$'\n'*}
HERDR_VERSION=${HERDR_VERSION#herdr }

SESSION=$("$LAB_HELPER" name fm-claude-submit) || fail "could not allocate guarded Herdr lab name"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-claude-submit.XXXXXX") \
  || fail "could not create Claude/Herdr test directory"
FAKEBIN="$TMP_ROOT/fakebin"
CALL_LOG="$TMP_ROOT/calls.log"
PENDING_CAPTURE="$TMP_ROOT/pending.ansi"
ORIGINAL_PATH=$PATH
PROVISIONED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$PROVISIONED" -eq 1 ] && ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

"$LAB_HELPER" provision "$SESSION" || fail "could not provision guarded Herdr lab session"
PROVISIONED=1
WORKSPACE=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$ROOT" --label claude-submit --no-focus) \
  || fail "could not create Claude submit workspace"
PANE=$(printf '%s' "$WORKSPACE" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
AGENT_STARTED=0
for _ in $(seq 1 40); do
  if START_OUT=$("$LAB_HELPER" run "$SESSION" agent start fixture-claude \
    --kind claude --pane "$PANE" --timeout 300000 2>&1); then
    AGENT_STARTED=1
    break
  fi
  printf '%s\n' "$START_OUT" | grep -F '"code":"agent_pane_busy"' >/dev/null \
    || fail "could not start real Claude in the guarded Herdr lab: $START_OUT"
  sleep 0.25
done
[ "$AGENT_STARTED" -eq 1 ] || fail "guarded Herdr pane did not become available for Claude"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

IDENTITY=
for _ in $(seq 1 120); do
  IDENTITY=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null || true)
  AGENT=$(printf '%s' "$IDENTITY" | jq -r '.result.agent.agent // empty' 2>/dev/null)
  [ "$AGENT" = claude ] && break
  sleep 0.25
done
[ "${AGENT:-}" = claude ] || fail "real Herdr agent identity did not become claude"

COMPOSER_READY=0
COMPOSER_EMPTY_READS=0
for _ in $(seq 1 120); do
  COMPOSER_STATE=$(fm_backend_composer_state herdr "$SESSION:$PANE")
  if [ "$COMPOSER_STATE" = empty ]; then
    COMPOSER_EMPTY_READS=$((COMPOSER_EMPTY_READS + 1))
    if [ "$COMPOSER_EMPTY_READS" -ge 3 ]; then
      COMPOSER_READY=1
      break
    fi
  else
    COMPOSER_EMPTY_READS=0
  fi
  sleep 0.25
done
[ "$COMPOSER_READY" -eq 1 ] || fail "real Claude composer did not become stably empty"

"$LAB_HELPER" run "$SESSION" agent prompt "$PANE" \
  'Use the Bash tool to run sleep 60, then reply with exactly done. Begin now.' >/dev/null \
  || fail "could not submit the real Claude seed prompt"
AGENT_WORKING=0
for seed_attempt in 0 1 2; do
  for _ in $(seq 1 20); do
    IDENTITY=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null || true)
    AGENT=$(printf '%s' "$IDENTITY" | jq -r '.result.agent.agent // empty' 2>/dev/null)
    AGENT_STATUS=$(printf '%s' "$IDENTITY" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
    if [ "$AGENT" = claude ] && [ "$AGENT_STATUS" = working ]; then
      AGENT_WORKING=1
      break 2
    fi
    sleep 0.25
  done
  [ "$seed_attempt" -lt 2 ] || break
  SEED_COMPOSER=$(fm_backend_composer_state herdr "$SESSION:$PANE")
  [ "$SEED_COMPOSER" = pending ] \
    || fail "real Claude seed was not pending before Enter retry: $SEED_COMPOSER"
  "$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null \
    || fail "could not retry Enter for the real Claude seed"
done
[ "$AGENT_WORKING" -eq 1 ] || fail "real Claude did not enter working state"
AGENT=$(printf '%s' "$IDENTITY" | jq -er '.result.agent.agent') \
  || fail "native agent output omitted agent identity"
AGENT_STATUS=$(printf '%s' "$IDENTITY" | jq -er '.result.agent.agent_status') \
  || fail "native agent output omitted agent status"
[ "$AGENT" = claude ] || fail "native agent identity was $AGENT instead of claude"
[ "$AGENT_STATUS" = working ] || fail "native Claude status was $AGENT_STATUS instead of working"

MESSAGE="fm-herdr-claude-live-submit-$$"
printf '─────────────────────────────────────────────────────\n❯\302\240%s\n─────────────────────────────────────────────────────\n' \
  "$MESSAGE" > "$PENDING_CAPTURE"
mkdir -p "$FAKEBIN"
: > "$CALL_LOG"
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -eu
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
call_log='$CALL_LOG'
pending_capture='$PENDING_CAPTURE'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || exit 97
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || exit 98
fi
if [ "\${args[0]:-}" = pane ] && [ "\${args[1]:-}" = send-text ]; then
  printf 'send-text\t%s\t%s\n' "\${args[2]:-}" "\${args[3]:-}" >> "\$call_log"
fi
if [ "\${args[0]:-}" = pane ] && [ "\${args[1]:-}" = send-keys ] && [ "\${args[3]:-}" = enter ]; then
  printf 'enter\t%s\n' "\${args[2]:-}" >> "\$call_log"
fi
if [ "\${args[0]:-}" = pane ] && [ "\${args[1]:-}" = read ]; then
  cat "\$pending_capture"
  exit 0
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

VERDICT=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" \
  fm_backend_send_text_submit herdr "$SESSION:$PANE" "$MESSAGE" 2 0.01 0.01)
[ "$VERDICT" = empty ] || fail "public Herdr submit returned $VERDICT instead of empty"
LITERAL_SENDS=$(awk -F '\t' -v pane="$PANE" -v message="$MESSAGE" \
  '$1 == "send-text" && $2 == pane && $3 == message { count++ } END { print count + 0 }' "$CALL_LOG")
[ "$LITERAL_SENDS" -eq 1 ] || fail "public submit typed the unique literal $LITERAL_SENDS times"
ENTER_RETRIES=$(awk -F '\t' -v pane="$PANE" \
  '$1 == "enter" && $2 == pane { count++ } END { print count + 0 }' "$CALL_LOG")
[ "$ENTER_RETRIES" -eq 2 ] || fail "public submit used $ENTER_RETRIES Enter attempts instead of 2"

QUEUED_TRANSCRIPT=0
for _ in $(seq 1 100); do
  REAL_CAPTURE=$(PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" \
    pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  if printf '%s\n' "$REAL_CAPTURE" | grep -F "$MESSAGE" >/dev/null \
    && printf '%s\n' "$REAL_CAPTURE" | grep -F 'Press up to edit queued messages' >/dev/null; then
    QUEUED_TRANSCRIPT=1
    break
  fi
  sleep 0.1
done
[ "$QUEUED_TRANSCRIPT" -eq 1 ] \
  || fail "real Claude pane did not show the unique literal in its queued transcript"

printf 'evidence: claude=%s herdr=%s agent=%s agent_status=%s public_submit=%s literal_sends=%s enter_retries=%s queued_transcript=%s\n' \
  "$CLAUDE_VERSION" "$HERDR_VERSION" "$AGENT" "$AGENT_STATUS" "$VERDICT" "$LITERAL_SENDS" "$ENTER_RETRIES" observed
pass "real Claude/Herdr public submit confirms one queued literal"

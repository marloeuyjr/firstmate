#!/usr/bin/env bash
set -u

if [ "${FM_HERDR_CLAUDE_SUBMIT_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_CLAUDE_SUBMIT_LIVE_E2E=1 to run the real Claude/Herdr submit regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

for tool in claude herdr jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found"
done
[ -x "$LAB_HELPER" ] || fail "Herdr lab helper not executable at $LAB_HELPER"

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
"$LAB_HELPER" run "$SESSION" agent start fixture-claude --kind claude --pane "$PANE" --timeout 300000 >/dev/null \
  || fail "could not start real Claude in the guarded Herdr lab"

IDENTITY=
for _ in $(seq 1 120); do
  IDENTITY=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null || true)
  AGENT=$(printf '%s' "$IDENTITY" | jq -r '.result.agent.agent // empty' 2>/dev/null)
  [ "$AGENT" = claude ] && break
  sleep 0.25
done
[ "${AGENT:-}" = claude ] || fail "real Herdr agent identity did not become claude"

"$LAB_HELPER" run "$SESSION" agent prompt "$PANE" \
  'Use the Bash tool to run sleep 60, then reply with exactly done. Begin now.' \
  --wait --until working --timeout 30000 >/dev/null \
  || fail "real Claude did not enter working state"
IDENTITY=$("$LAB_HELPER" run "$SESSION" agent get "$PANE") \
  || fail "could not read real Claude native identity"
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

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
VERDICT=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" \
  fm_backend_send_text_submit herdr "$SESSION:$PANE" "$MESSAGE" 2 0.01 0.01)
[ "$VERDICT" = empty ] || fail "public Herdr submit returned $VERDICT instead of empty"
LITERAL_SENDS=$(awk -F '\t' -v pane="$PANE" -v message="$MESSAGE" \
  '$1 == "send-text" && $2 == pane && $3 == message { count++ } END { print count + 0 }' "$CALL_LOG")
[ "$LITERAL_SENDS" -eq 1 ] || fail "public submit typed the unique literal $LITERAL_SENDS times"
ENTER_RETRIES=$(awk -F '\t' -v pane="$PANE" \
  '$1 == "enter" && $2 == pane { count++ } END { print count + 0 }' "$CALL_LOG")
[ "$ENTER_RETRIES" -eq 2 ] || fail "public submit used $ENTER_RETRIES Enter attempts instead of 2"

CLAUDE_VERSION=$(claude --version | head -n 1)
HERDR_VERSION=$(PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" status --json \
  | jq -er '.client.version') || fail "Herdr did not report its version"
printf 'evidence: claude=%s herdr=%s agent=%s agent_status=%s public_submit=%s literal_sends=%s enter_retries=%s\n' \
  "$CLAUDE_VERSION" "$HERDR_VERSION" "$AGENT" "$AGENT_STATUS" "$VERDICT" "$LITERAL_SENDS" "$ENTER_RETRIES"
pass "real Claude/Herdr public submit confirms one queued literal"

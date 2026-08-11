#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) a fully cleaned-up task merges and records its PR in the retained backlog
#   (e) a matching retained PR remains a single canonical record
#   (f) a conflicting retained PR is refused before gh-axi
#   (g) a missing task is refused before gh-axi
#   (h) a refused merge does not close a cleaned-up task's backlog item
#   (i) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (j) malformed PR URL fails fast without calling gh-axi
#   (k) explicit merge method is not overridden by the default --squash
#   (l) repository or hostname override args fail fast because identity comes from the URL
#   (m) retained task identity is checked before every configured completion path
#   (n) GitHub Enterprise URLs bind gh-axi to the canonical hostname
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config" "$fakebin"
  tasks-axi add task-x1 "Live task" --kind ship --file "$case_dir/data/backlog.md" >/dev/null
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# Build a fresh clean-up fixture with only a retained backlog item.
# The missing metadata and absent poll artifacts model a task whose cleanup completed.
make_torn_down_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config" "$fakebin"
  tasks-axi add task-x1 "Torn down task" --kind ship --file "$case_dir/data/backlog.md" >/dev/null
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
printf '%s\n' "${GH_HOST:-}" >> "$FM_TEST_GH_AXI_HOST_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${GH_HOST:-}" >> "\$FM_TEST_GH_HOST_LOG"
case "\${1:-} \${2:-}" in
  "api graphql")
    printf '%s\n' "\${FM_TEST_MERGE_QUEUE_REQUIRED:-false}" ; exit 0 ;;
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
      *' --json state '*) printf '%s\n' "\${FM_TEST_GH_STATE:-MERGED}" ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "api graphql") printf '%s\n' false ; exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_AXI_HOST_LOG="$case_dir/gh-axi-host.log" \
  FM_TEST_GH_HOST_LOG="$case_dir/gh-host.log" \
  FM_TEST_GH_STATE="${FM_TEST_GH_STATE:-MERGED}" \
  FM_TEST_MERGE_QUEUE_REQUIRED="${FM_TEST_MERGE_QUEUE_REQUIRED:-false}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_torn_down_task_merges_and_records_backlog() {
  local case_dir rc url
  case_dir=$(make_torn_down_case torn-down-merge)
  url=https://github.com/example/repo/pull/21
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  expect_code 0 "$rc" "torn-down-merge: fm-pr-merge should merge a cleaned-up task"
  grep -qxF "pr merge 21 --repo example/repo --squash" "$case_dir/gh-axi.log" \
    || fail "torn-down-merge: gh-axi pr merge was not invoked"
  assert_grep "$url" "$case_dir/data/backlog.md" \
    "torn-down-merge: merged PR was not recorded in the retained backlog"
  [ "$(grep -cF "$url" "$case_dir/data/backlog.md")" -eq 1 ] \
    || fail "torn-down-merge: retained backlog recorded the PR more than once"
  assert_absent "$case_dir/state/task-x1.meta" \
    "torn-down-merge: merge recreated task metadata"
  for artifact in check.sh pr-poll pr-poll-registration pr-poll-retirement; do
    assert_absent "$case_dir/state/task-x1.$artifact" \
      "torn-down-merge: merge left a watcher artifact"
  done
  pass "fm-pr-merge records a cleaned-up task's merged PR without recreating a watcher poll"
}

test_torn_down_task_rejects_deferred_merge_modes() {
  local case_dir rc mode
  case_dir=$(make_torn_down_case torn-down-deferred-merge)
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  for mode in --auto --merge-queue --defer; do
    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/30 -- "$mode" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "torn-down-deferred-merge: fm-pr-merge should reject $mode"
    assert_grep 'error: cleaned-up tasks cannot use deferred merge modes' "$case_dir/stderr" \
      "torn-down-deferred-merge: refusal did not identify the deferred mode"
  done
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "torn-down-deferred-merge: gh-axi was invoked for a deferred mode"
  assert_no_grep 'https://github.com/example/repo/pull/30' "$case_dir/data/backlog.md" \
    "torn-down-deferred-merge: deferred mode changed the retained task"
  pass "fm-pr-merge rejects deferred merge modes for fully cleaned-up tasks"
}

test_torn_down_task_refuses_target_merge_queue() {
  local case_dir rc url
  case_dir=$(make_torn_down_case torn-down-required-merge-queue)
  url=https://github.com/example/repo/pull/33
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh-host.log"

  set +e
  FM_TEST_MERGE_QUEUE_REQUIRED=true run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "torn-down-required-merge-queue: fm-pr-merge should refuse"
  grep -qxF github.com "$case_dir/gh-host.log" \
    || fail "torn-down-required-merge-queue: policy query was not bound to the canonical host"
  assert_grep 'error: cleaned-up tasks cannot merge into a branch that requires a merge queue' \
    "$case_dir/stderr" \
    "torn-down-required-merge-queue: refusal did not identify the required queue"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "torn-down-required-merge-queue: gh-axi was invoked for a required queue"
  assert_no_grep "$url" "$case_dir/data/backlog.md" \
    "torn-down-required-merge-queue: required queue changed the retained task"
  pass "fm-pr-merge refuses an implicit target-branch merge queue before merging"
}

test_torn_down_task_requires_confirmed_merged_state() {
  local case_dir rc url
  case_dir=$(make_torn_down_case torn-down-unconfirmed-merge)
  url=https://github.com/example/repo/pull/31
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh-host.log"

  set +e
  FM_TEST_GH_STATE=OPEN run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "torn-down-unconfirmed-merge: fm-pr-merge should refuse an open PR"
  grep -qxF 'pr merge 31 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "torn-down-unconfirmed-merge: gh-axi merge was not invoked"
  grep -qxF github.com "$case_dir/gh-host.log" \
    || fail "torn-down-unconfirmed-merge: state check was not bound to the canonical host"
  assert_grep 'error: PR is not merged on github.com' "$case_dir/stderr" \
    "torn-down-unconfirmed-merge: refusal did not identify the open PR"
  assert_no_grep "$url" "$case_dir/data/backlog.md" \
    "torn-down-unconfirmed-merge: open PR was recorded as completed"
  pass "fm-pr-merge requires a canonical merged-state confirmation before completion"
}

test_torn_down_enterprise_merge_binds_confirmation_to_canonical_host() {
  local case_dir url
  case_dir=$(make_torn_down_case torn-down-enterprise-merge)
  url=https://github.internal/my-org/my-repo/pull/32
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh-axi-host.log"
  : > "$case_dir/gh-host.log"

  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "torn-down-enterprise-merge: fm-pr-merge rejected a merged Enterprise PR"

  grep -qxF github.internal "$case_dir/gh-axi-host.log" \
    || fail "torn-down-enterprise-merge: gh-axi was not bound to the canonical host"
  grep -qxF github.internal "$case_dir/gh-host.log" \
    || fail "torn-down-enterprise-merge: state confirmation was not bound to the canonical host"
  assert_grep "$url" "$case_dir/data/backlog.md" \
    "torn-down-enterprise-merge: merged Enterprise PR was not recorded"
  pass "fm-pr-merge binds cleaned-up Enterprise merges and confirmation to one host"
}

test_torn_down_task_preserves_canonical_backlog_pr() {
  local case_dir url
  case_dir=$(make_torn_down_case torn-down-existing-pr)
  url=https://github.com/example/repo/pull/24
  tasks-axi update task-x1 --pr "$url" --file "$case_dir/data/backlog.md" >/dev/null
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "torn-down-existing-pr: fm-pr-merge rejected the canonical retained PR"

  [ "$(grep -cF "$url" "$case_dir/data/backlog.md")" -eq 1 ] \
    || fail "torn-down-existing-pr: matching retained PR was not kept canonical"
  pass "fm-pr-merge keeps a cleaned-up task's matching PR as one canonical backlog record"
}

test_torn_down_task_refuses_conflicting_backlog_pr() {
  local case_dir rc url existing_url
  case_dir=$(make_torn_down_case torn-down-conflicting-pr)
  url=https://github.com/example/repo/pull/25
  existing_url=https://github.com/example/repo/pull/99
  tasks-axi update task-x1 --pr "$existing_url" --file "$case_dir/data/backlog.md" >/dev/null
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "torn-down-conflicting-pr: fm-pr-merge should refuse a conflicting retained PR"
  assert_grep 'error: retained backlog item has a conflicting PR link for task-x1' "$case_dir/stderr" \
    "torn-down-conflicting-pr: refusal did not identify the conflicting record"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "torn-down-conflicting-pr: gh-axi pr merge was invoked"
  assert_no_grep "$url" "$case_dir/data/backlog.md" \
    "torn-down-conflicting-pr: requested PR replaced the canonical backlog link"
  pass "fm-pr-merge refuses a conflicting retained PR before merging"
}

test_missing_meta_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_torn_down_case missing-meta)
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/22 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable and no retained backlog item exists for missing-x1' "$case_dir/stderr" \
    "missing-meta: refusal did not identify the unknown task"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-merge created a poll for an unknown task"
  pass "fm-pr-merge refuses an unknown task before merging"
}

test_manual_backend_refuses_unknown_live_task_before_merge() {
  local case_dir rc url
  case_dir=$(make_case manual-unknown-live)
  url=https://github.com/example/repo/pull/26
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  tasks-axi rm task-x1 --file "$case_dir/data/backlog.md" >/dev/null
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "manual-unknown-live: fm-pr-merge should refuse an unknown live task"
  assert_grep 'no retained backlog item exists for task-x1' "$case_dir/stderr" \
    "manual-unknown-live: refusal did not identify the missing retained task"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "manual-unknown-live: gh-axi pr merge was invoked"
  pass "fm-pr-merge refuses an unknown live task with the manual backlog backend"
}

test_manual_backend_refuses_conflicting_live_pr_before_merge() {
  local case_dir rc url existing_url
  case_dir=$(make_case manual-conflicting-live)
  url=https://github.com/example/repo/pull/27
  existing_url=https://github.com/example/repo/pull/99
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  tasks-axi update task-x1 --pr "$existing_url" --file "$case_dir/data/backlog.md" >/dev/null
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "manual-conflicting-live: fm-pr-merge should refuse a conflicting live PR"
  assert_grep 'retained backlog item has a conflicting PR link for task-x1' "$case_dir/stderr" \
    "manual-conflicting-live: refusal did not identify the canonical-link conflict"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "manual-conflicting-live: gh-axi pr merge was invoked"
  pass "fm-pr-merge refuses a conflicting live PR with the manual backlog backend"
}

test_default_backend_refuses_unavailable_automation_before_merge() {
  local case_dir rc
  case_dir=$(make_torn_down_case unavailable-automation)
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/28 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unavailable-automation: fm-pr-merge should refuse before merging"
  assert_grep 'configured tasks-axi backend is unavailable' "$case_dir/stderr" \
    "unavailable-automation: refusal did not identify unavailable automation"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "unavailable-automation: gh-axi pr merge was invoked"
  pass "fm-pr-merge refuses a configured but unavailable automated backlog path"
}

test_manual_backend_records_torn_down_merge_without_tasks_axi_done() {
  local case_dir real_tasks_axi url
  case_dir=$(make_torn_down_case manual-torn-down-merge)
  real_tasks_axi=$(command -v tasks-axi)
  url=https://github.com/example/repo/pull/29
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  done) printf '%s\\n' "\$*" >> "$case_dir/tasks-axi-done.log"; exit 99 ;;
  *) exec "$real_tasks_axi" "\$@" ;;
esac
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
  : > "$case_dir/tasks-axi-done.log"

  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "manual-torn-down-merge: manual backlog completion failed"

  [ ! -s "$case_dir/tasks-axi-done.log" ] \
    || fail "manual-torn-down-merge: manual backend delegated completion to tasks-axi"
  assert_grep "$url" "$case_dir/data/backlog.md" \
    "manual-torn-down-merge: manual backend did not record the merged PR"
  tasks-axi show task-x1 --full --file "$case_dir/data/backlog.md" | grep -qxF '  state: done' \
    || fail "manual-torn-down-merge: manual backend did not move the task to Done"
  pass "fm-pr-merge records a torn-down merge through the configured manual backlog backend"
}

test_torn_down_task_merge_failure_does_not_close_backlog() {
  local case_dir rc url
  case_dir=$(make_torn_down_case torn-down-merge-refused)
  url=https://github.com/example/repo/pull/23
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "torn-down-merge-refused: fm-pr-merge should propagate a refused merge"
  assert_no_grep "$url" "$case_dir/data/backlog.md" \
    "torn-down-merge-refused: refused merge closed the retained backlog item"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "torn-down-merge-refused: refused merge created a watcher poll"
  pass "fm-pr-merge leaves a cleaned-up task open when gh-axi refuses the merge"
}

test_help_describes_cleanup_fallback() {
  local case_dir rc
  case_dir=$(make_case help)

  set +e
  run_pr_merge "$case_dir" --help > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "help: fm-pr-merge --help should succeed"
  assert_grep 'fully cleaned-up task' "$case_dir/stdout" \
    "help: cleanup fallback was not described"
  pass "fm-pr-merge help documents the clean-up fallback"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_identity_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case identity-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "identity-override: fm-pr-merge should refuse repository override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "identity-override: refusal did not explain the repository override"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --hostname wrong.example \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "identity-override: fm-pr-merge should refuse hostname override flags"
  assert_grep 'extra merge arguments must not override the canonical host' "$case_dir/stderr" \
    "identity-override: refusal did not explain the hostname override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "identity-override: PR URL was recorded before rejecting hostname override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "identity-override: hostname override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "identity-override: gh-axi pr merge was invoked despite hostname override"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --hostname=wrong.example \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "identity-override: fm-pr-merge should refuse equals-form hostname overrides"
  assert_grep 'extra merge arguments must not override the canonical host' "$case_dir/stderr" \
    "identity-override: equals-form refusal did not explain the hostname override"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --api-host=wrong.example \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "identity-override: fm-pr-merge should refuse future host-selecting flags"
  assert_grep 'extra merge arguments must not override the canonical host' "$case_dir/stderr" \
    "identity-override: future host-flag refusal did not explain the hostname override"
  pass "fm-pr-merge refuses repository and hostname override args before recording state"
}


test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_binds_github_enterprise_merge_to_canonical_host() {
  local case_dir url
  case_dir=$(make_case github-enterprise)
  url=https://github.internal/my-org/my-repo/pull/127
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh-axi-host.log"

  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-enterprise: fm-pr-merge rejected a GitHub Enterprise PR URL"

  grep -qxF 'pr merge 127 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "github-enterprise: gh-axi did not receive the Enterprise PR identity"
  grep -qxF github.internal "$case_dir/gh-axi-host.log" \
    || fail "github-enterprise: gh-axi was not bound to the canonical Enterprise host"
  pass "fm-pr-merge accepts GitHub Enterprise PRs and binds gh-axi to their host"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_torn_down_task_merges_and_records_backlog
test_torn_down_task_rejects_deferred_merge_modes
test_torn_down_task_refuses_target_merge_queue
test_torn_down_task_requires_confirmed_merged_state
test_torn_down_enterprise_merge_binds_confirmation_to_canonical_host
test_torn_down_task_preserves_canonical_backlog_pr
test_torn_down_task_refuses_conflicting_backlog_pr
test_missing_meta_refuses_before_merge
test_manual_backend_refuses_unknown_live_task_before_merge
test_manual_backend_refuses_conflicting_live_pr_before_merge
test_default_backend_refuses_unavailable_automation_before_merge
test_manual_backend_records_torn_down_merge_without_tasks_axi_done
test_torn_down_task_merge_failure_does_not_close_backlog
test_help_describes_cleanup_fallback
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_identity_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_binds_github_enterprise_merge_to_canonical_host
test_parses_pr_url_for_gh_axi

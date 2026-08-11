#!/usr/bin/env bash
# Behavior tests for fm-fleet-sync.sh drift handling.
#
# fm-fleet-sync fast-forwards a clone that is cleanly on its default branch. This
# suite pins the two behavioral additions on top of that:
#   - the one safe drift self-heals: a clean, detached HEAD that holds no unique
#     commits (it is an ancestor of origin/<default>) and whose <default> is free
#     to check out is re-attached and then fast-forwarded ("recovered:").
#   - every other off-default state is left untouched and reported as a loud,
#     quantified "STUCK: ... N commits behind ... - needs attention" warning
#     instead of a quiet skip.
# The pre-existing fast-forward / already-current / local-only / no-origin paths
# must be unchanged, and bootstrap must relay the new outcomes as FLEET_SYNC lines.
#
# It also pins the orphaned .git/packed-refs.lock recovery in the fetch step
# (fetch_with_packed_refs_lock_guard, backed by bin/fm-lock-lib.sh's shared
# staleness proof): a provably-stale lock is retried then removed and the clone
# syncs (with a "recovered:" summary on stdout so a session-start refresh, which
# discards stderr, still surfaces it); a live lock (fake lsof holder) is never
# removed and the sync fails loudly; a live process merely holding the clone
# worktree dir as its cwd also blocks removal (the clone-dir liveness check); a
# transient lock that self-clears is retried without a force-remove; and any
# non-packed-refs.lock fetch failure keeps today's behavior with no retry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-fleet-sync-tests)
HOME_N=0

# --- fixtures ---------------------------------------------------------------

# new_home: fresh isolated FM_HOME with an empty projects/ dir. Each test gets its
# own so the whole-fleet form never sees another test's clones.
new_home() {
  HOME_N=$((HOME_N + 1))
  local h="$TMP_ROOT/home-$HOME_N"
  mkdir -p "$h/projects"
  printf '%s\n' "$h"
}

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# build_pair <home> <name>: create projects/<name>, a clone of a fresh bare origin
# with one commit on main, plus a side "work-<name>" repo wired to that origin for
# advancing it later. Portable branch naming (no init -b) for older git.
build_pair() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0

  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  git clone --quiet "file://$remote_abs" "$clone"
  printf '%s\n' "$clone"
}

# advance_origin <home> <name> <msg>: push one more commit to <name>'s origin via
# its work repo, so the clone (until it fetches) is one commit behind origin/main.
advance_origin() {
  local home=$1 name=$2 msg=$3 work
  work="$home/work-$name"
  commit_file "$work" file.txt "$msg" "$msg"
  git -C "$work" push -q origin main
}

head_sha() { git -C "$1" rev-parse HEAD; }

add_submodule_at_path() {
  local work=$1 url=$2 path=$3 section=$4 add_path target
  add_path=$path
  case "$path" in
    *$'\n'*) add_path="core/$section" ;;
  esac
  git -C "$work" -c protocol.file.allow=always submodule add -q "$url" "$add_path"
  if [ "$add_path" != "$path" ]; then
    target=$(git -C "$work/$add_path" rev-parse HEAD)
    git -C "$work" config --file .gitmodules --rename-section \
      "submodule.$add_path" "submodule.$section"
    git -C "$work" config --file .gitmodules "submodule.$section.path" "$path"
    mv "$work/$add_path" "$work/$path"
    git -C "$work" update-index --force-remove -- "$add_path"
    git -C "$work" update-index --add --cacheinfo 160000 "$target" "$path"
  fi
}

initialize_submodule_at_path() {
  local outer=$1 url=$2 path=$3
  rm -rf "$outer/$path"
  git clone --quiet "$url" "$outer/$path"
  git -C "$outer" submodule absorbgitdirs -- "$path"
  git -C "$outer" submodule init -- "$path"
}

newline_only_path() {
  local path=$1
  [ -n "$path" ] && [ -z "${path//$'\n'/}" ]
}

# build_submodule_pair <home> <name> [with-second]: create an outer clone that
# records the second commit from an origin-backed core/openelis submodule.
# The paired outer work repo remains at home/work-<name>, so advance_origin can
# advance its origin after the clone has been created.
# The optional second submodule exercises mixed-pointer safety cases.
# The returned clone initializes the submodule through Git's executable interface.
build_submodule_pair() {
  local home=$1 name=$2 with_second=${3:-no} submodule_path=${4:-core/openelis} second_submodule_path=${5:-core/second} inner_work inner_remote work remote clone remote_abs inner_remote_abs
  inner_work="$home/submodule-work-$name"
  inner_remote="$home/remotes/$name-openelis.git"
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$inner_work"
  git -C "$inner_work" symbolic-ref HEAD refs/heads/main
  commit_file "$inner_work" README.md S0 S0
  commit_file "$inner_work" README.md S1 S1
  git clone --quiet --bare "$inner_work" "$inner_remote"
  git -C "$inner_remote" symbolic-ref HEAD refs/heads/main
  inner_remote_abs=$(cd "$inner_remote" && pwd)
  git -C "$inner_work" remote add origin "file://$inner_remote_abs"
  git -C "$inner_work" push -q -u origin main

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0
  add_submodule_at_path "$work" "file://$inner_remote_abs" "$submodule_path" openelis
  if [ "$with_second" = with-second ]; then
    add_submodule_at_path "$work" "file://$inner_remote_abs" "$second_submodule_path" second
  fi
  git -C "$work" add .gitmodules
  git -C "$work" commit -qm "add submodule"
  git clone --quiet --bare "$work" "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  if newline_only_path "$submodule_path" \
    || { [ "$with_second" = with-second ] && newline_only_path "$second_submodule_path"; }; then
    git clone --quiet "file://$remote_abs" "$clone"
    initialize_submodule_at_path "$clone" "file://$inner_remote_abs" "$submodule_path"
    if [ "$with_second" = with-second ]; then
      initialize_submodule_at_path "$clone" "file://$inner_remote_abs" "$second_submodule_path"
    fi
  else
    git -c protocol.file.allow=always clone --quiet --recurse-submodules \
      "file://$remote_abs" "$clone"
  fi
  printf '%s\n' "$clone"
}

# Move the initialized submodule from its recorded S1 pin to origin/main^ (S0).
# This produces only an unstaged, origin-anchored gitlink drift in the outer clone.
drift_submodule_to_origin_ancestor() {
  local clone=$1 inner
  inner="$clone/core/openelis"
  git -C "$inner" checkout --detach --quiet origin/main^
}

# Detach the named submodule at origin/main^ and prune the recorded HEAD pin from
# its local object store, so the recorded target is no longer check-outable while
# the drifted ancestor stays anchored on origin. Returns 0 only when the recorded
# pin is provably absent afterwards; used to exercise the preflight that blocks a
# partial recovery when a later submodule's target is missing.
prune_inner_recorded_pin() {
  local clone=$1 path=$2 pin ancestor
  pin=$(git -C "$clone" ls-tree HEAD -- "$path" | awk '$1 == "160000" { print $3; exit }')
  [ -n "$pin" ] || return 1
  ancestor=$(git -C "$clone/$path" rev-parse --verify --quiet "origin/main^") || return 1
  [ -n "$ancestor" ] || return 1
  git -C "$clone/$path" checkout --detach --quiet "$ancestor"
  git -C "$clone/$path" update-ref refs/remotes/origin/main "$ancestor"
  git -C "$clone/$path" update-ref -d refs/heads/main 2>/dev/null || true
  git -C "$clone/$path" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null || true
  git -C "$clone/$path" reflog expire --expire=now --all 2>/dev/null || true
  git -C "$clone/$path" gc --prune=now --quiet
  git -C "$clone/$path" cat-file -e "${pin}^{commit}" 2>/dev/null && return 1
  return 0
}

# run_sync <home> [args...]: run fleet-sync against an isolated home, stdout only.
run_sync() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$@" 2>/dev/null
}

# --- packed-refs.lock fixtures ----------------------------------------------

# build_packed_prunable <home> <name>: like build_pair, but the clone has PACKED
# refs plus a local `feature` branch tracking a since-deleted origin/feature, so a
# fetch --prune must rewrite packed-refs - which an orphaned .git/packed-refs.lock
# blocks with Git's "Unable to create '...packed-refs.lock': File exists". origin/main
# is advanced by one commit so a successful sync fast-forwards. Echoes the clone path.
build_packed_prunable() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0
  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main
  git -C "$work" push -q origin main:refs/heads/feature

  git clone --quiet "file://$remote_abs" "$clone"
  git -C "$clone" branch -q feature origin/feature
  commit_file "$work" file.txt v1 C1
  git -C "$work" push -q origin main
  git -C "$work" push -q origin --delete feature
  git -C "$clone" pack-refs --all
  printf '%s\n' "$clone"
}

plant_packed_refs_lock() { : > "$1/.git/packed-refs.lock"; }

# lsof shims mirror tests/fm-teardown.test.sh: no-holder (provably free), a live
# holder, and an lsof error. Written into a per-home fakebin/ prepended to PATH.
lsof_no_holder() {
  cat > "$1/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$1/lsof"
}
lsof_live_holder() {
  cat > "$1/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$1/lsof"
}

# lsof shim: a holder ONLY for $FLEET_TEST_LIVE_DIR (a live `git -C <clone>` keeping
# its cwd there), and no holder of the lock file itself - the exact window the
# clone-dir liveness check must cover.
lsof_holds_only_live_dir() {
  cat > "$1/lsof" <<'SH'
#!/usr/bin/env bash
target=
for a in "$@"; do case "$a" in --|-*) ;; *) target=$a ;; esac; done
[ -n "${FLEET_TEST_LIVE_DIR:-}" ] && [ "$target" = "$FLEET_TEST_LIVE_DIR" ] && exit 0
exit 1
SH
  chmod +x "$1/lsof"
}

# git shim: fail the FIRST `fetch` with the packed-refs.lock signature and drop
# the lock (simulating the dying ref-rewrite finishing), then delegate every
# later call - including the retried fetch - to the real git so the sync completes.
git_transient_packed_refs_lock() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=; is_fetch=0
for a in "$@"; do [ "$a" = fetch ] && is_fetch=1; done
prev=
for a in "$@"; do [ "$prev" = -C ] && dir=$a; prev=$a; done
if [ "$is_fetch" = 1 ]; then
  n=$(cat "${GIT_FETCH_COUNTER:?}" 2>/dev/null || echo 0); n=$(( n + 1 ))
  printf '%s\n' "$n" > "$GIT_FETCH_COUNTER"
  if [ "$n" -eq 1 ]; then
    lock="$dir/.git/packed-refs.lock"
    echo "error: could not delete reference refs/remotes/origin/feature: Unable to create '$lock': File exists." >&2
    rm -f "$lock"
    exit 1
  fi
fi
exec "$real" "$@"
SH
  chmod +x "$1/git"
}

git_fail_fast_forward() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
for a in "$@"; do
  [ "$a" != merge ] || { echo "fatal: simulated fast-forward failure" >&2; exit 1; }
done
exec "$real" "$@"
SH
  chmod +x "$1/git"
}

# run_sync_guarded <home> <fakebin> <outfile> <errfile> [args...]: run fleet-sync
# with the fakebin on PATH and stdout/stderr captured separately. Per-test knobs
# (FM_FLEET_SYNC_PACKED_REFS_LOCK_*, GIT_FETCH_COUNTER) are read from the caller's
# exported environment.
run_sync_guarded() {
  local home=$1 fakebin=$2 outf=$3 errf=$4 realgit
  shift 4
  realgit=$(command -v git)
  PATH="$fakebin:$PATH" REAL_GIT_FOR_TEST="$realgit" \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-fleet-sync.sh" "$@" >"$outf" 2>"$errf"
}

# --- tests ------------------------------------------------------------------

test_detached_clean_ancestor_recovers() {
  local home clone out before after
  home=$(new_home)
  clone=$(build_pair "$home" alpha)
  advance_origin "$home" alpha C1
  before=$(head_sha "$clone")
  # Detach at the clone's main (C0), an ancestor of the now-advanced origin/main.
  git -C "$clone" checkout --detach --quiet

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "alpha: recovered: re-attached main" "detached-clean-ancestor reports recovered"
  assert_contains "$out" "alpha: synced" "detached-clean-ancestor reports sync"
  assert_not_contains "$out" "STUCK" "recovered case is not flagged STUCK"
  [ "$(git -C "$clone" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "expected re-attach to main, HEAD still detached"
  after=$(head_sha "$clone")
  [ "$after" != "$before" ] || fail "expected fast-forward after re-attach, HEAD unchanged"
  [ "$after" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "expected HEAD at origin/main after recovery"
  pass "detached clean ancestor is re-attached and fast-forwarded (recovered)"
}

test_detached_unique_commit_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" beta)
  git -C "$clone" checkout --detach --quiet
  commit_file "$clone" extra.txt unique "local unique work"
  before=$(head_sha "$clone")
  advance_origin "$home" beta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "beta: STUCK:" "detached-with-unique-commit reports STUCK"
  assert_contains "$out" "unique commits" "STUCK names the unique-commit state"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  assert_not_contains "$out" "recovered" "unique-commit case is never recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "expected unique-commit detached HEAD left untouched"
  pass "detached HEAD with unique commits is reported STUCK and left untouched"
}

test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched() {
  local home clone out before local_main
  home=$(new_home)
  clone=$(build_pair "$home" beta-local-default)
  commit_file "$clone" local.txt local "local divergent main commit"
  local_main=$(git -C "$clone" rev-parse main)
  git -C "$clone" checkout --detach --quiet HEAD^
  before=$(head_sha "$clone")
  advance_origin "$home" beta-local-default C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "beta-local-default: STUCK:" "diverged local default reports STUCK"
  assert_contains "$out" "local main diverged from origin/main" "STUCK names the unsafe local default"
  assert_not_contains "$out" "recovered" "diverged local default is never recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "detached HEAD was moved"
  ! git -C "$clone" symbolic-ref -q HEAD >/dev/null || fail "clone re-attached to local default"
  [ "$(git -C "$clone" rev-parse main)" = "$local_main" ] || fail "local default branch was moved"
  pass "detached clean ancestor with diverged local default is reported STUCK and left untouched"
}

test_dirty_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" gamma)
  advance_origin "$home" gamma C1
  before=$(head_sha "$clone")
  printf 'uncommitted edit\n' >> "$clone/file.txt"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "gamma: STUCK:" "dirty clone reports STUCK"
  assert_contains "$out" "uncommitted changes" "STUCK names the dirty state"
  assert_contains "$out" "1 commits behind origin/main" "STUCK quantifies how far behind"
  [ "$(head_sha "$clone")" = "$before" ] || fail "dirty clone HEAD was moved"
  grep -q "uncommitted edit" "$clone/file.txt" || fail "dirty working-tree change was discarded"
  pass "dirty working tree is reported STUCK and left untouched"
}

test_non_default_branch_is_stuck_untouched() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" delta)
  git -C "$clone" checkout -q -b feature
  advance_origin "$home" delta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "delta: STUCK: on branch feature" "non-default branch reports STUCK with branch name"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  assert_not_contains "$out" "recovered" "named branch is never auto-changed"
  [ "$(git -C "$clone" symbolic-ref --short HEAD)" = "feature" ] || fail "named branch checkout was changed"
  pass "non-default named branch is reported STUCK and left untouched"
}

test_diverged_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" epsilon)
  # Local main gains its own commit; origin advances down a different line.
  commit_file "$clone" local.txt local "local divergent commit"
  before=$(head_sha "$clone")
  advance_origin "$home" epsilon C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "epsilon: STUCK:" "diverged clone reports STUCK"
  assert_contains "$out" "diverged main" "STUCK names the diverged state"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  [ "$(head_sha "$clone")" = "$before" ] || fail "diverged clone was moved"
  pass "diverged default branch is reported STUCK and left untouched"
}

test_on_default_clean_behind_fast_forwards() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" zeta)
  advance_origin "$home" zeta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "zeta: synced" "on-default clean behind fast-forwards as before"
  assert_not_contains "$out" "recovered" "ordinary fast-forward is not labelled recovered"
  assert_not_contains "$out" "STUCK" "ordinary fast-forward is not flagged STUCK"
  [ "$(head_sha "$clone")" = "$(git -C "$clone" rev-parse origin/main)" ] || fail "clone was not fast-forwarded"
  pass "on-default clean behind clone still fast-forwards"
}

test_anchored_submodule_pointer_drift_recovers_and_syncs() {
  local home clone inner out expected
  home=$(new_home)
  clone=$(build_submodule_pair "$home" submodule-recover)
  inner="$clone/core/openelis"
  drift_submodule_to_origin_ancestor "$clone"
  advance_origin "$home" submodule-recover C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "submodule-recover: recovered: restored submodule pointer core/openelis" \
    "anchored submodule pointer drift is visibly recovered"
  assert_contains "$out" "submodule-recover: synced" "anchored submodule pointer drift still syncs"
  assert_not_contains "$out" "STUCK" "anchored submodule pointer drift is not stuck"
  [ -z "$(git -C "$clone" status --porcelain --ignore-submodules=none)" ] \
    || fail "recovered submodule clone remained dirty"
  expected=$(git -C "$clone" ls-tree HEAD core/openelis | awk '{print $3}')
  [ "$(head_sha "$inner")" = "$expected" ] || fail "submodule did not return to its recorded pin"
  [ "$(head_sha "$clone")" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "recovered clone did not sync to origin/main"
  pass "anchored unstaged submodule pointer drift is restored and synced"
}

test_newline_submodule_pointer_drift_recovers_and_syncs() {
  local home clone path inner out expected
  home=$(new_home)
  path=$'core/new\nline'
  clone=$(build_submodule_pair "$home" submodule-newline no "$path")
  inner="$clone/$path"
  git -C "$inner" checkout --detach --quiet origin/main^
  advance_origin "$home" submodule-newline C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "submodule-newline: recovered: restored submodule pointer" \
    "newline submodule pointer drift is visibly recovered"
  assert_not_contains "$out" "STUCK" "newline submodule pointer drift is not stuck"
  [ -z "$(git -C "$clone" status --porcelain --ignore-submodules=none)" ] \
    || fail "newline submodule clone remained dirty"
  expected=$(git -C "$clone" ls-tree HEAD -- "$path" | awk '{print $3}')
  [ "$(head_sha "$inner")" = "$expected" ] || fail "newline submodule did not return to its recorded pin"
  [ "$(head_sha "$clone")" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "newline submodule clone did not sync to origin/main"
  pass "newline-named submodule pointer drift is restored and synced"
}

test_newline_only_submodule_pointer_drift_recovers() {
  local home clone path inner out expected
  home=$(new_home)
  path=$'\n'
  clone=$(build_submodule_pair "$home" submodule-newline-only no "$path")
  inner="$clone/$path"
  [ -z "$(git -C "$clone" status --porcelain --ignore-submodules=none)" ] \
    || fail "newline-only submodule: fixture did not start clean"
  git -C "$inner" checkout --detach --quiet origin/main^ \
    || fail "newline-only submodule: fixture did not create pointer drift"
  advance_origin "$home" submodule-newline-only C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "submodule-newline-only: recovered: restored submodule pointer" \
    "newline-only submodule pointer drift is visibly recovered"
  assert_not_contains "$out" "STUCK" "newline-only submodule pointer drift is not stuck"
  expected=$(git -C "$clone" ls-files --stage -- "$path" | awk '$1 == "160000" { print $2; exit }')
  [ "$(head_sha "$inner")" = "$expected" ] \
    || fail "newline-only submodule did not return to its recorded pin"
  pass "newline-only submodule pointer drift is restored and synced"
}

test_newline_only_unsafe_outer_dirt_blocks_recovery() {
  local home clone safe_path unsafe_path safe unsafe out safe_before
  home=$(new_home)
  safe_path=$'\n'
  unsafe_path=$'\n\n'
  clone=$(build_submodule_pair "$home" submodule-newline-unsafe with-second "$safe_path" "$unsafe_path")
  safe="$clone/$safe_path"
  unsafe="$clone/$unsafe_path"
  [ -z "$(git -C "$clone" status --porcelain --ignore-submodules=none)" ] \
    || fail "newline-only unsafe outer dirt: fixture did not start clean"
  git -C "$safe" checkout --detach --quiet origin/main^ \
    || fail "newline-only unsafe outer dirt: safe submodule did not drift"
  git -C "$unsafe" checkout --detach --quiet origin/main^ \
    || fail "newline-only unsafe outer dirt: unsafe submodule did not drift"
  git -C "$clone" add -- "$unsafe_path" \
    || fail "newline-only unsafe outer dirt: unsafe pointer did not stage"
  safe_before=$(head_sha "$safe")
  advance_origin "$home" submodule-newline-unsafe C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "submodule-newline-unsafe: STUCK:" \
    "newline-only unsafe outer dirt remains stuck"
  assert_not_contains "$out" "recovered" "newline-only unsafe outer dirt was recovered over"
  [ "$(head_sha "$safe")" = "$safe_before" ] \
    || fail "newline-only unsafe outer dirt allowed the eligible pointer reset"
  if git -C "$clone" diff --cached --quiet -- "$unsafe_path"; then
    fail "newline-only unsafe outer dirt lost the staged pointer"
  fi
  pass "newline-only outer paths keep mixed submodule dirt stuck and untouched"
}

test_staged_submodule_pointer_is_stuck_untouched() {
  local home clone inner out staged_before staged_after
  home=$(new_home)
  clone=$(build_submodule_pair "$home" submodule-staged)
  inner="$clone/core/openelis"
  drift_submodule_to_origin_ancestor "$clone"
  git -C "$clone" add core/openelis
  staged_before=$(git -C "$clone" diff --cached -- core/openelis)
  advance_origin "$home" submodule-staged C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "submodule-staged: STUCK:" "staged submodule pointer remains stuck"
  assert_contains "$out" "uncommitted changes" "staged pointer names the dirty state"
  staged_after=$(git -C "$clone" diff --cached -- core/openelis)
  [ "$staged_before" = "$staged_after" ] || fail "staged submodule pointer was altered"
  [ "$(head_sha "$inner")" = "$(git -C "$inner" rev-parse origin/main^)" ] \
    || fail "staged submodule inner HEAD was altered"
  pass "staged submodule pointer is reported STUCK and left untouched"
}

test_dirty_submodule_inner_tree_is_stuck_untouched() {
  local home clone inner out before
  home=$(new_home)
  clone=$(build_submodule_pair "$home" submodule-dirty)
  inner="$clone/core/openelis"
  drift_submodule_to_origin_ancestor "$clone"
  before=$(head_sha "$inner")
  printf 'uncommitted edit\n' >> "$inner/README.md"
  advance_origin "$home" submodule-dirty C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "submodule-dirty: STUCK:" "dirty submodule inner tree remains stuck"
  assert_contains "$out" "uncommitted changes" "dirty inner tree names the dirty state"
  [ "$(head_sha "$inner")" = "$before" ] || fail "dirty inner tree was reset"
  grep -q 'uncommitted edit' "$inner/README.md" || fail "dirty inner edit was discarded"
  pass "dirty submodule inner tree is reported STUCK and left untouched"
}

test_untracked_submodule_inner_tree_is_stuck_untouched() {
  local home clone inner out before
  home=$(new_home)
  clone=$(build_submodule_pair "$home" submodule-untracked)
  inner="$clone/core/openelis"
  drift_submodule_to_origin_ancestor "$clone"
  before=$(head_sha "$inner")
  printf 'untracked\n' > "$inner/untracked.txt"
  advance_origin "$home" submodule-untracked C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "submodule-untracked: STUCK:" "untracked submodule inner tree remains stuck"
  assert_contains "$out" "uncommitted changes" "untracked inner tree names the dirty state"
  [ "$(head_sha "$inner")" = "$before" ] || fail "untracked inner tree was reset"
  assert_present "$inner/untracked.txt" "untracked inner file was discarded"
  pass "untracked submodule inner tree is reported STUCK and left untouched"
}

test_unanchored_submodule_head_is_stuck_untouched() {
  local home clone inner out before
  home=$(new_home)
  clone=$(build_submodule_pair "$home" submodule-unanchored)
  inner="$clone/core/openelis"
  commit_file "$inner" local.txt local "local-only inner commit"
  before=$(head_sha "$inner")
  advance_origin "$home" submodule-unanchored C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "submodule-unanchored: STUCK:" "unanchored submodule HEAD remains stuck"
  assert_contains "$out" "uncommitted changes" "unanchored HEAD names the dirty state"
  [ "$(head_sha "$inner")" = "$before" ] || fail "unanchored inner HEAD was reset"
  pass "unanchored submodule HEAD is reported STUCK and left untouched"
}

test_other_outer_dirt_with_submodule_pointer_is_stuck_untouched() {
  local home clone inner out before
  home=$(new_home)
  clone=$(build_submodule_pair "$home" submodule-outer-dirty)
  inner="$clone/core/openelis"
  drift_submodule_to_origin_ancestor "$clone"
  before=$(head_sha "$inner")
  printf 'uncommitted outer edit\n' >> "$clone/file.txt"
  advance_origin "$home" submodule-outer-dirty C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "submodule-outer-dirty: STUCK:" "other outer dirt remains stuck"
  assert_contains "$out" "uncommitted changes" "other outer dirt names the dirty state"
  [ "$(head_sha "$inner")" = "$before" ] || fail "outer dirt allowed submodule reset"
  grep -q 'uncommitted outer edit' "$clone/file.txt" || fail "outer edit was discarded"
  pass "other outer dirt is reported STUCK and leaves the submodule pointer untouched"
}

test_mixed_submodule_drift_is_stuck_without_partial_recovery() {
  local home clone safe staged out safe_before staged_before
  home=$(new_home)
  clone=$(build_submodule_pair "$home" submodule-mixed with-second)
  safe="$clone/core/openelis"
  staged="$clone/core/second"
  drift_submodule_to_origin_ancestor "$clone"
  git -C "$staged" checkout --detach --quiet origin/main^
  git -C "$clone" add core/second
  safe_before=$(head_sha "$safe")
  staged_before=$(head_sha "$staged")
  advance_origin "$home" submodule-mixed C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "submodule-mixed: STUCK:" "mixed submodule dirt remains stuck"
  [ "$(head_sha "$safe")" = "$safe_before" ] || fail "safe pointer was reset beside staged drift"
  [ "$(head_sha "$staged")" = "$staged_before" ] || fail "staged pointer was reset"
  pass "mixed submodule drift is reported STUCK without partial recovery"
}

test_hidden_untracked_outer_file_with_submodule_drift_is_stuck_untouched() {
  local home clone inner out before
  home=$(new_home)
  clone=$(build_submodule_pair "$home" submodule-hidden-untracked)
  inner="$clone/core/openelis"
  drift_submodule_to_origin_ancestor "$clone"
  # status.showUntrackedFiles=no hides untracked files from a bare `git status`,
  # so a status query without --untracked-files=all would see only the gitlink
  # drift and wrongly self-heal over the hidden outer file.
  git -C "$clone" config status.showUntrackedFiles no
  printf 'untracked outer\n' > "$clone/outer-untracked.txt"
  advance_origin "$home" submodule-hidden-untracked C1
  before=$(head_sha "$inner")

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "submodule-hidden-untracked: STUCK:" \
    "a hidden untracked outer file beside gitlink drift stays STUCK"
  assert_not_contains "$out" "recovered" "hidden untracked file was recovered over"
  [ "$(head_sha "$inner")" = "$before" ] \
    || fail "hidden untracked outer file let the submodule pointer be reset"
  assert_present "$clone/outer-untracked.txt" "hidden untracked outer file was discarded"
  pass "an outer untracked file hidden by status.showUntrackedFiles=no keeps drift STUCK and untouched"
}

test_recovered_submodule_drift_with_diverged_main_reports_both() {
  local home clone inner out pin_before
  home=$(new_home)
  clone=$(build_submodule_pair "$home" submodule-diverged)
  inner="$clone/core/openelis"
  drift_submodule_to_origin_ancestor "$clone"
  # Give local main a commit origin does not have, then move origin/main down a
  # different line, so eligible drift is restored but the clone still diverges.
  commit_file "$clone" local.txt local "local divergent commit"
  advance_origin "$home" submodule-diverged C1
  pin_before=$(git -C "$clone" ls-tree HEAD core/openelis | awk '{print $3}')

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "submodule-diverged: recovered: restored submodule pointer core/openelis" \
    "diverged main still reports the submodule recovery visibly"
  assert_contains "$out" "submodule-diverged: STUCK:" "diverged main still reports STUCK"
  assert_contains "$out" "diverged main" "STUCK names the diverged state"
  [ "$(head_sha "$inner")" = "$pin_before" ] \
    || fail "diverged-main submodule pointer was not restored to its recorded pin"
  [ "$(head_sha "$clone")" != "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "diverged main clone was fast-forwarded despite the divergence"
  pass "recovered submodule drift on a diverged main reports both recovery and STUCK"
}

test_recovered_submodule_drift_is_visible_when_fast_forward_fails() {
  local home clone inner fakebin out_file err_file out pin
  home=$(new_home)
  clone=$(build_submodule_pair "$home" submodule-ff-failure)
  inner="$clone/core/openelis"
  drift_submodule_to_origin_ancestor "$clone"
  advance_origin "$home" submodule-ff-failure C1
  pin=$(git -C "$clone" ls-tree HEAD core/openelis | awk '{print $3}')
  fakebin="$home/fb-merge-failure"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  git_fail_fast_forward "$fakebin"
  out_file="$home/out-merge-failure"
  err_file="$home/err-merge-failure"

  run_sync_guarded "$home" "$fakebin" "$out_file" "$err_file" submodule-ff-failure
  out=$(cat "$out_file")

  case "$out" in
    *"submodule-ff-failure: recovered: restored submodule pointer core/openelis"$'\n'"submodule-ff-failure: skipped: fast-forward failed"*) ;;
    *) fail "submodule-ff-failure: recovery was not reported before the failed fast-forward" ;;
  esac
  [ "$(head_sha "$inner")" = "$pin" ] \
    || fail "submodule-ff-failure: recovered pointer did not return to its recorded pin"
  [ "$(head_sha "$clone")" != "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "submodule-ff-failure: clone fast-forwarded despite the injected failure"
  pass "submodule recovery stays visible before a later fast-forward failure"
}

test_pruned_second_submodule_target_refuses_without_partial_recovery() {
  local home clone safe missing out safe_before missing_before
  home=$(new_home)
  clone=$(build_submodule_pair "$home" submodule-pruned with-second)
  safe="$clone/core/openelis"
  missing="$clone/core/second"
  drift_submodule_to_origin_ancestor "$clone"
  prune_inner_recorded_pin "$clone" core/second \
    || fail "submodule-pruned: fixture did not prune the second submodule's recorded target"
  safe_before=$(head_sha "$safe")
  missing_before=$(head_sha "$missing")
  advance_origin "$home" submodule-pruned C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "submodule-pruned: STUCK:" \
    "a later submodule with a pruned target stays STUCK"
  assert_not_contains "$out" "recovered" \
    "a pruned-target recovery must not report a partial recovery"
  [ "$(head_sha "$safe")" = "$safe_before" ] \
    || fail "pruned-target: the present-target submodule was reset (partial recovery)"
  [ "$(head_sha "$missing")" = "$missing_before" ] \
    || fail "pruned-target: the pruned-target submodule was reset"
  pass "a pruned later submodule target refuses recovery without a partial restore"
}

test_already_current_unchanged() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" eta)
  before=$(head_sha "$clone")

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "eta: already current" "already-current clone reports unchanged"
  assert_not_contains "$out" "STUCK" "already-current is not flagged STUCK"
  assert_not_contains "$out" "recovered" "already-current is not labelled recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "already-current clone was moved"
  pass "already-current clone is reported unchanged"
}

test_no_origin_skipped() {
  local home clone out
  home=$(new_home)
  clone="$home/projects/theta"
  git init -q "$clone"
  git -C "$clone" symbolic-ref HEAD refs/heads/main
  commit_file "$clone" file.txt v0 C0

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "theta: skipped: no origin remote" "no-origin clone is skipped as before"
  assert_not_contains "$out" "STUCK" "no-origin skip is not escalated to STUCK"
  pass "no-origin clone is skipped (benign), not flagged STUCK"
}

test_local_only_skipped() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" iota)
  advance_origin "$home" iota C1
  mkdir -p "$home/data"
  printf -- '- iota [local-only] - test project (added 2026-06-27)\n' > "$home/data/projects.md"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "iota: skipped: local-only project" "local-only clone is skipped as before"
  assert_not_contains "$out" "STUCK" "local-only skip is not escalated to STUCK"
  pass "local-only clone is skipped (benign), not flagged STUCK"
}

test_single_project_by_bare_name_resolves() {
  local home out
  home=$(new_home)
  build_pair "$home" kappa >/dev/null
  advance_origin "$home" kappa C1

  out=$(run_sync "$home" "kappa")

  assert_contains "$out" "kappa: synced" "bare project name resolves against the home's projects dir"
  pass "single-project form accepts a bare project name"
}

test_single_project_by_bare_name_ignores_cwd_shadow() {
  local home cwd out
  home=$(new_home)
  build_pair "$home" mu >/dev/null
  advance_origin "$home" mu C1
  cwd="$home/shadow"
  mkdir -p "$cwd/mu"

  out=$(cd "$cwd" && run_sync "$home" "mu")

  assert_contains "$out" "mu: synced" "bare project name prefers the home's projects dir"
  assert_not_contains "$out" "skipped: not a git repo" "bare project name ignores a cwd shadow directory"
  pass "single-project bare name resolution is not cwd-sensitive"
}

test_single_project_by_projects_relative_name_resolves() {
  local home out
  home=$(new_home)
  build_pair "$home" lambda >/dev/null
  advance_origin "$home" lambda C1

  out=$(run_sync "$home" "projects/lambda")

  assert_contains "$out" "lambda: synced" "projects/<name> form resolves against the home's projects dir"
  pass "single-project form accepts a projects/<name> relative name"
}

test_single_project_by_projects_relative_name_ignores_cwd_shadow() {
  local home cwd out
  home=$(new_home)
  build_pair "$home" nu >/dev/null
  advance_origin "$home" nu C1
  cwd="$home/shadow"
  mkdir -p "$cwd/projects/nu"

  out=$(cd "$cwd" && run_sync "$home" "projects/nu")

  assert_contains "$out" "nu: synced" "projects/<name> form prefers the home's projects dir"
  assert_not_contains "$out" "skipped: not a git repo" "projects/<name> form ignores a cwd shadow directory"
  pass "single-project projects/<name> resolution is not cwd-sensitive"
}

test_single_project_unresolvable_name_still_skips() {
  local home out
  home=$(new_home)

  out=$(run_sync "$home" "does-not-exist")

  assert_contains "$out" "skipped: not a directory" "an unresolvable name still hits the existing not-a-directory skip"
  pass "single-project form leaves a genuinely bad name unresolved"
}

test_whole_fleet_form() {
  local home behind current out
  home=$(new_home)
  behind=$(build_pair "$home" fleet-behind)
  advance_origin "$home" fleet-behind C1
  current=$(build_pair "$home" fleet-current)

  # Whole-fleet form: no project-dir argument.
  out=$(run_sync "$home")

  assert_contains "$out" "fleet-behind: synced" "whole-fleet form syncs a behind clone"
  assert_contains "$out" "fleet-current: already current" "whole-fleet form reports a current clone"
  : "$behind $current"
  pass "whole-fleet form processes every clone under projects/"
}

test_bootstrap_relays_recovered_and_stuck() {
  local home stuck rec out
  home=$(new_home)
  # A clone we will leave STUCK (dirty), and one that self-heals (detached-clean-ancestor).
  stuck=$(build_pair "$home" stuck-clone)
  advance_origin "$home" stuck-clone C1
  printf 'dirty\n' >> "$stuck/file.txt"
  rec=$(build_pair "$home" rec-clone)
  advance_origin "$home" rec-clone C1
  git -C "$rec" checkout --detach --quiet

  # Full bootstrap: no state/ dir -> secondmate sync no-ops; no .env -> X mode off.
  # We only assert the fleet-sync relay lines; other detect lines are irrelevant.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "FLEET_SYNC: stuck-clone: STUCK:" "bootstrap relays the STUCK outcome"
  assert_contains "$out" "FLEET_SYNC: rec-clone: recovered:" "bootstrap relays the recovered outcome"
  pass "bootstrap relays recovered: and STUCK: fleet-sync outcomes"
}

# --- packed-refs.lock guard tests -------------------------------------------

test_orphaned_stale_packed_refs_lock_recovers() {
  local home fakebin clone out err
  home=$(new_home)
  fakebin="$home/fb-lockstale"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" lockstale)
  plant_packed_refs_lock "$clone"
  lsof_no_holder "$fakebin"           # provably no live holder
  out="$home/out-lockstale"; err="$home/err-lockstale"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" lockstale
  set -e

  assert_grep "removed provably-stale packed-refs lock" "$err" \
    "stale lock: guard did not force-remove the provably-stale lock"
  assert_grep "fetch succeeded after stale packed-refs lock cleanup" "$err" \
    "stale lock: fetch did not succeed after cleanup"
  assert_contains "$(cat "$out")" "lockstale: synced" "stale lock: clone did not sync after recovery"
  assert_grep "recovered: removed a stale packed-refs lock" "$out" \
    "stale lock: recovery summary not emitted on stdout (bootstrap relays stdout, discards stderr)"
  assert_absent "$clone/.git/packed-refs.lock" "stale lock: lock should be gone after removal"
  [ "$(git -C "$clone" rev-parse HEAD)" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "stale lock: clone HEAD not at origin/main after recovery"
  pass "orphaned provably-stale packed-refs.lock is cleared and the clone syncs"
}

test_live_packed_refs_lock_is_never_removed() {
  local home fakebin clone out err before
  home=$(new_home)
  fakebin="$home/fb-locklive"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" locklive)
  plant_packed_refs_lock "$clone"
  lsof_live_holder "$fakebin"         # a live process holds the lock/.git open
  before=$(head_sha "$clone")
  out="$home/out-locklive"; err="$home/err-locklive"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locklive
  set -e

  assert_grep "is not provably stale" "$err" "live lock: guard did not explain the refusal"
  assert_no_grep "removed provably-stale packed-refs lock" "$err" \
    "live lock: guard force-removed a live lock"
  assert_contains "$(cat "$out")" "locklive: skipped: fetch failed" "live lock: fleet-sync did not skip"
  assert_present "$clone/.git/packed-refs.lock" "live lock: lock must never be removed"
  [ "$(head_sha "$clone")" = "$before" ] || fail "live lock: clone was advanced despite the refusal"
  pass "a live packed-refs.lock is never removed and the sync fails loudly"
}

test_live_git_cwd_in_clone_dir_blocks_removal() {
  local home fakebin clone out err before
  home=$(new_home)
  fakebin="$home/fb-lockcwd"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" lockcwd)
  plant_packed_refs_lock "$clone"
  # Nobody holds the lock file, but a live process holds the clone worktree as its
  # cwd - the narrow race where git closed packed-refs.lock but has not yet exited.
  lsof_holds_only_live_dir "$fakebin"
  before=$(head_sha "$clone")
  out="$home/out-lockcwd"; err="$home/err-lockcwd"

  set +e
  FLEET_TEST_LIVE_DIR="$clone" \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" lockcwd
  set -e

  assert_grep "is not provably stale" "$err" "clone-cwd holder: guard did not refuse"
  assert_no_grep "removed provably-stale packed-refs lock" "$err" \
    "clone-cwd holder: guard removed a lock while a live process held the clone dir"
  assert_present "$clone/.git/packed-refs.lock" "clone-cwd holder: lock must not be removed"
  [ "$(head_sha "$clone")" = "$before" ] || fail "clone-cwd holder: clone was advanced despite the refusal"
  pass "a live process holding the clone worktree dir blocks lock removal (clone-dir liveness)"
}

test_transient_packed_refs_lock_self_clears() {
  local home fakebin clone out err counter
  home=$(new_home)
  fakebin="$home/fb-locktrans"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" locktrans)
  plant_packed_refs_lock "$clone"
  git_transient_packed_refs_lock "$fakebin"   # fail once + drop lock, then real git
  counter="$home/git-fetch-count"; : > "$counter"
  out="$home/out-locktrans"; err="$home/err-locktrans"

  set +e
  GIT_FETCH_COUNTER="$counter" \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locktrans
  set -e

  assert_grep "cleared on its own" "$err" "transient lock: guard did not report the self-clear"
  assert_no_grep "removed provably-stale packed-refs lock" "$err" \
    "transient lock: guard force-removed a lock that only needed patience"
  assert_contains "$(cat "$out")" "locktrans: synced" "transient lock: clone did not sync after self-clear"
  assert_grep "recovered: packed-refs lock cleared on its own" "$out" \
    "transient lock: recovery summary not emitted on stdout"
  assert_absent "$clone/.git/packed-refs.lock" "transient lock: lock should be gone after self-clear"
  pass "a transient packed-refs.lock that self-clears is retried without a force-remove"
}

test_non_signature_fetch_failure_is_not_retried() {
  local home fakebin clone out err
  home=$(new_home)
  fakebin="$home/fb-locknonsig"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_pair "$home" locknonsig)
  advance_origin "$home" locknonsig C1
  git -C "$clone" remote set-url origin "file://$home/remotes/does-not-exist.git"
  out="$home/out-locknonsig"; err="$home/err-locknonsig"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locknonsig
  set -e

  assert_contains "$(cat "$out")" "locknonsig: skipped: fetch failed" "non-signature: fleet-sync did not report the fetch failure"
  assert_no_grep "waiting" "$err" "non-signature: a non-lock failure was wrongly retried"
  assert_no_grep "packed-refs lock" "$err" "non-signature: a non-lock failure entered the lock guard"
  pass "a non-packed-refs.lock fetch failure keeps today's behavior (no retry)"
}

test_detached_clean_ancestor_recovers
test_detached_unique_commit_is_stuck_untouched
test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched
test_dirty_is_stuck_untouched
test_non_default_branch_is_stuck_untouched
test_diverged_is_stuck_untouched
test_on_default_clean_behind_fast_forwards
test_anchored_submodule_pointer_drift_recovers_and_syncs
test_newline_submodule_pointer_drift_recovers_and_syncs
test_newline_only_submodule_pointer_drift_recovers
test_newline_only_unsafe_outer_dirt_blocks_recovery
test_staged_submodule_pointer_is_stuck_untouched
test_dirty_submodule_inner_tree_is_stuck_untouched
test_untracked_submodule_inner_tree_is_stuck_untouched
test_unanchored_submodule_head_is_stuck_untouched
test_other_outer_dirt_with_submodule_pointer_is_stuck_untouched
test_mixed_submodule_drift_is_stuck_without_partial_recovery
test_hidden_untracked_outer_file_with_submodule_drift_is_stuck_untouched
test_recovered_submodule_drift_with_diverged_main_reports_both
test_recovered_submodule_drift_is_visible_when_fast_forward_fails
test_pruned_second_submodule_target_refuses_without_partial_recovery
test_already_current_unchanged
test_no_origin_skipped
test_local_only_skipped
test_single_project_by_bare_name_resolves
test_single_project_by_bare_name_ignores_cwd_shadow
test_single_project_by_projects_relative_name_resolves
test_single_project_by_projects_relative_name_ignores_cwd_shadow
test_single_project_unresolvable_name_still_skips
test_whole_fleet_form
test_bootstrap_relays_recovered_and_stuck
test_orphaned_stale_packed_refs_lock_recovers
test_live_packed_refs_lock_is_never_removed
test_live_git_cwd_in_clone_dir_blocks_removal
test_transient_packed_refs_lock_self_clears
test_non_signature_fetch_failure_is_not_retried

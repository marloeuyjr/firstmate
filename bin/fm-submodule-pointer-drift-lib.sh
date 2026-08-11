#!/usr/bin/env bash
# Safely restore unstaged submodule gitlink drift only when the inner tree is
# clean and its current HEAD is anchored by an origin ref or a qualifying local
# branch ref that survives the outer worktree's removal.
#
# fm_restore_anchored_submodule_pointer_drift [--dry-run] <worktree> emits each
# eligible submodule path on stdout and restores it unless --dry-run is given.
# It leaves staged gitlink changes, dirty or untracked inner trees, unanchored
# inner HEADs, and every non-gitlink outer change untouched.
# Before any checkout it preflights every eligible submodule's recorded target
# object as a locally present commit, so a missing target refuses without
# altering the worktree (no partial recovery).
# `git submodule update` checkout progress is written to stderr, so the helper's
# path-list stdout remains structured while teardown still observes checkout output.
# A failed preflight or checkout prints a refusal to stderr and returns non-zero.

fm_submodule_drift_canonical_existing_dir() {
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  IFS= read -r -d '' FM_SUBMODULE_DRIFT_CANONICAL_DIR < <(
    CDPATH='' cd -P -- "$target" && printf '%s\0' "$PWD"
  )
}

fm_restore_anchored_submodule_pointer_drift() {
  local dry_run=no worktree worktree_abs
  local config_entry path submodule submodule_head submodule_git_dir
  local inner_status diff_rc local_anchor_survives target

  if [ "${1:-}" = --dry-run ]; then
    dry_run=yes
    shift
  fi
  [ "$#" -eq 1 ] || return 2
  worktree=$1
  FM_SUBMODULE_POINTER_DRIFT_PATHS=()

  [ -f "$worktree/.gitmodules" ] || return 0
  fm_submodule_drift_canonical_existing_dir "$worktree" || return 0
  worktree_abs=$FM_SUBMODULE_DRIFT_CANONICAL_DIR
  git -C "$worktree" config --file .gitmodules --get-regexp '^submodule\..*\.path$' \
    >/dev/null 2>&1 || return 0

  # Collect every eligible submodule and preflight its recorded target object
  # locally before any checkout, so a missing target refuses without altering
  # the worktree (no partial recovery).
  while IFS= read -r -d '' config_entry; do
    path=${config_entry#*$'\n'}
    [ -n "$path" ] || continue
    fm_submodule_drift_canonical_existing_dir "$worktree/$path" || continue
    submodule=$FM_SUBMODULE_DRIFT_CANONICAL_DIR
    case "$submodule" in
      "$worktree_abs"/*) ;;
      *) continue ;;
    esac
    git -C "$submodule" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$worktree" ls-files --stage -- "$path" | grep -q '^160000 ' || continue
    if ! git -C "$worktree" diff --cached --quiet -- "$path"; then
      continue
    fi
    if git -C "$worktree" diff --quiet --ignore-submodules=dirty -- "$path"; then
      continue
    else
      diff_rc=$?
    fi
    [ "$diff_rc" -eq 1 ] || continue
    if ! inner_status=$(git -C "$submodule" status --porcelain --untracked-files=all); then
      continue
    fi
    [ -z "$inner_status" ] || continue
    submodule_head=$(git -C "$submodule" rev-parse --verify HEAD 2>/dev/null) || continue
    submodule_git_dir=$(git -C "$submodule" rev-parse --absolute-git-dir 2>/dev/null) || continue
    fm_submodule_drift_canonical_existing_dir "$submodule_git_dir" || continue
    submodule_git_dir=$FM_SUBMODULE_DRIFT_CANONICAL_DIR
    local_anchor_survives=1
    case "$submodule_git_dir" in
      "$worktree_abs"|"$worktree_abs"/*) local_anchor_survives=0 ;;
    esac
    if git -C "$submodule" for-each-ref --contains="$submodule_head" --format='%(refname)' \
        refs/remotes/origin | grep -q .; then
      :
    elif [ "$local_anchor_survives" -eq 1 ] \
      && git -C "$submodule" for-each-ref --contains="$submodule_head" --format='%(refname)' \
        refs/heads | grep -q .; then
      :
    else
      continue
    fi
    target=$(git -C "$worktree" ls-tree HEAD -- "$path" \
      | awk '$1 == "160000" { print $3; exit }')
    [ -n "$target" ] || continue
    if ! git -C "$submodule" cat-file -e "${target}^{commit}" >/dev/null 2>&1; then
      echo "REFUSED: recorded submodule pointer target $target for $path is not available locally in $worktree." >&2
      FM_SUBMODULE_POINTER_DRIFT_PATHS=()
      return 1
    fi
    FM_SUBMODULE_POINTER_DRIFT_PATHS+=("$path")
  done < <(git -C "$worktree" config --null --file .gitmodules --get-regexp '^submodule\..*\.path$')

  [ "${#FM_SUBMODULE_POINTER_DRIFT_PATHS[@]}" -gt 0 ] || return 0

  # Restore each eligible submodule (or only list it under --dry-run). Route the
  # checkout progress to stderr so a structured-stdout caller stays clean while a
  # stderr-surfacing caller still observes it.
  for path in "${FM_SUBMODULE_POINTER_DRIFT_PATHS[@]}"; do
    if [ "$dry_run" = no ]; then
      if ! git -C "$worktree" submodule update --no-fetch --checkout -- "$path" >&2 </dev/null; then
        echo "REFUSED: cannot restore landed submodule pointer $path in $worktree." >&2
        return 1
      fi
    fi
    printf '%s\0' "$path"
  done
}

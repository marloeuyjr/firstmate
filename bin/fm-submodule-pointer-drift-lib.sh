#!/usr/bin/env bash
# Safely restore unstaged submodule gitlink drift only when the inner tree is
# clean and its current HEAD is anchored by an origin ref or a qualifying local
# branch ref that survives the outer worktree's removal.
#
# fm_restore_anchored_submodule_pointer_drift <worktree> emits each restored
# submodule path on stdout.
# It leaves staged gitlink changes, dirty or untracked inner trees, unanchored
# inner HEADs, and every non-gitlink outer change untouched.
# A failed checkout prints a refusal and returns non-zero.

fm_submodule_drift_canonical_existing_dir() {
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  (
    CDPATH='' cd -- "$target" && pwd -P
  )
}

fm_restore_anchored_submodule_pointer_drift() {
  local worktree=$1 config_entry path worktree_abs submodule submodule_head
  local submodule_git_dir inner_status diff_rc local_anchor_survives

  [ -f "$worktree/.gitmodules" ] || return 0
  worktree_abs=$(fm_submodule_drift_canonical_existing_dir "$worktree") || return 0
  git -C "$worktree" config --file .gitmodules --get-regexp '^submodule\..*\.path$' \
    >/dev/null 2>&1 || return 0

  while IFS= read -r -d '' config_entry; do
    path=${config_entry#*$'\n'}
    [ -n "$path" ] || continue
    submodule=$(fm_submodule_drift_canonical_existing_dir "$worktree/$path") || continue
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
    submodule_git_dir=$(fm_submodule_drift_canonical_existing_dir "$submodule_git_dir") || continue
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
    if ! git -C "$worktree" submodule update --no-fetch --checkout -- "$path" >/dev/null </dev/null; then
      echo "REFUSED: cannot restore landed submodule pointer $path in $worktree." >&2
      return 1
    fi
    printf '%s\n' "$path"
  done < <(git -C "$worktree" config --null --file .gitmodules --get-regexp '^submodule\..*\.path$')
}

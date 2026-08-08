#!/usr/bin/env bash
# Merge a task's GitHub PR through the guarded gh-axi path.
# A live task records one canonical pr= and any available pr_head= through
# bin/fm-pr-check.sh before merging, so teardown can verify landed work after
# squash merges and the watcher can follow the PR until it merges.
# After complete task cleanup has removed metadata and every PR-poll artifact,
# the retained backlog item is the durable task record instead.
# That path proves the task exists with tasks-axi show and accepts only an
# absent or matching canonical PR link before merging.
# It then runs tasks-axi done --pr only after gh-axi reports a successful merge.
# It never recreates task metadata or a watcher poll.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator.
# Extra args must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG="$DATA/backlog.md"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]

For a live task, records the canonical PR and arms its merge poll before merging.
For a fully cleaned-up task, verifies its retained backlog item and canonical PR link before recording the merged PR there after a successful merge.
The cleanup fallback never creates metadata or a watcher poll.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

backlog_pr_is_absent_or_canonical() {
  local record links link pr_count=0
  local -a link_items
  if ! record=$(tasks-axi show "$ID" --full --file "$BACKLOG"); then
    echo "error: task metadata is unavailable and no retained backlog item exists for $ID" >&2
    return 1
  fi
  links=$(printf '%s\n' "$record" | sed -n 's/^  links: //p' | head -1)
  case "$links" in
    none) return 0 ;;
    \"*\")
      links=${links#\"}
      links=${links%\"}
      ;;
    *)
      echo "error: retained backlog item has unreadable PR links for $ID" >&2
      return 1
      ;;
  esac
  IFS=, read -r -a link_items <<< "$links"
  for link in "${link_items[@]}"; do
    case "$link" in
      pr:*)
        pr_count=$((pr_count + 1))
        if [ "$pr_count" -ne 1 ] || [ "${link#pr:}" != "$URL" ]; then
          echo "error: retained backlog item has a conflicting PR link for $ID" >&2
          return 1
        fi
        ;;
    esac
  done
}

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
BACKLOG_RECORD=0
if [ -e "$META" ] || [ -L "$META" ]; then
  if [ ! -f "$META" ] || [ -L "$META" ] \
    || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
    echo "error: task metadata is unavailable" >&2
    exit 1
  fi
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    exit 1
  }
else
  for artifact in "$STATE/$ID.check.sh" "$STATE/$ID.pr-poll" \
    "$STATE/$ID.pr-poll-registration" "$STATE/$ID.pr-poll-retirement"; do
    if [ -e "$artifact" ] || [ -L "$artifact" ]; then
      echo "error: task cleanup is incomplete; watcher artifacts remain for $ID" >&2
      exit 1
    fi
  done
  if [ ! -f "$BACKLOG" ] || [ -L "$BACKLOG" ]; then
    echo "error: task metadata is unavailable and backlog is unavailable for $ID" >&2
    exit 1
  fi
  backlog_pr_is_absent_or_canonical || exit 1
  BACKLOG_RECORD=1
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"

if [ "$BACKLOG_RECORD" -eq 1 ]; then
  tasks-axi "done" "$ID" --pr "$URL" --file "$BACKLOG" || {
    echo "error: merged PR could not be recorded in the task backlog" >&2
    exit 1
  }
fi

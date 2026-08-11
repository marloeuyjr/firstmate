#!/usr/bin/env bash
# Merge a task's GitHub PR through the guarded gh-axi path.
# A live task records one canonical pr= and any available pr_head= through
# bin/fm-pr-check.sh before merging, so teardown can verify landed work after
# squash merges and the watcher can follow the PR until it merges.
# After complete task cleanup has removed metadata and every PR-poll artifact,
# the retained backlog item is the durable task record instead.
# That path proves the task exists with tasks-axi show and accepts only an
# absent or matching canonical PR link before merging.
# It then records completion through the configured backlog backend only after
# gh-axi reports a successful merge.
# It never recreates task metadata or a watcher poll.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# host, owner/repository, and PR number bind gh-axi to that exact instance.
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
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BACKLOG="$DATA/backlog.md"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

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
PR_HOST=$FM_PR_HOST
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

reject_identity_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --*host*|-H|-H?*)
        echo "error: extra merge arguments must not override the canonical host" >&2
        return 1
        ;;
    esac
  done
}

reject_identity_overrides "$@" || exit 1

reject_deferred_merge_modes() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --auto|--auto=*|--*queue*|--*defer*)
        echo "error: cleaned-up tasks cannot use deferred merge modes" >&2
        return 1
        ;;
    esac
  done
}

reject_target_merge_queue() {
  local merge_queue
  if ! merge_queue=$(GH_HOST="$PR_HOST" gh api graphql \
    -f query='query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { mergeQueue { id } } } }' \
    -f owner="$PR_OWNER" -f name="$PR_REPO" -F number="$PR_NUMBER" \
    --jq '.data.repository.pullRequest.mergeQueue != null' 2>/dev/null); then
    echo "error: could not determine whether the target branch requires a merge queue" >&2
    return 1
  fi
  if [ "$merge_queue" != false ]; then
    echo "error: cleaned-up tasks cannot merge into a branch that requires a merge queue" >&2
    return 1
  fi
}

confirm_pr_merged() {
  local state
  if ! state=$(GH_HOST="$PR_HOST" gh pr view "$URL" --json state -q .state 2>/dev/null); then
    echo "error: could not confirm the PR merged on $PR_HOST" >&2
    return 1
  fi
  if [ "$state" != MERGED ]; then
    echo "error: PR is not merged on $PR_HOST" >&2
    return 1
  fi
}

RETAINED_PR_LINK=0
backlog_legacy_pr_is_absent_or_canonical() {
  local line fragment candidate pr_count=0 seen=0
  local url_pattern='https://[a-z0-9.-]{1,253}/[A-Za-z0-9._/-]+/pull/[1-9][0-9]*'
  RETAINED_PR_LINK=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$seen" -eq 1 ]; then
      case "$line" in
        '## '*|'- ['*) break ;;
      esac
    elif [[ "$line" == "- [ ] $ID - "* ]]; then
      seen=1
    fi
    [ "$seen" -eq 1 ] || continue
    fragment=$line
    while [[ "$fragment" =~ $url_pattern ]]; do
      candidate=${BASH_REMATCH[0]}
      fragment=${fragment#*"$candidate"}
      if fm_pr_url_parse "$candidate" && [ "$FM_PR_PROVIDER" = github ]; then
        pr_count=$((pr_count + 1))
        if [ "$pr_count" -ne 1 ] || [ "$FM_PR_URL" != "$URL" ]; then
          echo "error: retained backlog item has a conflicting PR link for $ID" >&2
          return 1
        fi
        RETAINED_PR_LINK=1
      fi
    done
  done < "$BACKLOG"
  if [ "$seen" -ne 1 ]; then
    echo "error: task metadata is unavailable and no retained backlog item exists for $ID" >&2
    return 1
  fi
  return 0
}

backlog_pr_is_absent_or_canonical() {
  local record links link pr_count=0
  local -a link_items
  RETAINED_PR_LINK=0
  if ! record=$(tasks-axi show "$ID" --full --file "$BACKLOG"); then
    backlog_legacy_pr_is_absent_or_canonical
    return $?
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
        RETAINED_PR_LINK=1
        ;;
    esac
  done
  return 0
}

backlog_manual_completion_preflight() {
  local line section='' matches=0 done_after=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '## Done')
        [ "$matches" -eq 1 ] && done_after=1
        section=Done
        ;;
      '## '*) section=${line#'## '} ;;
      "- [ ] $ID - "*)
        [ "$section" != Done ] || return 1
        matches=$((matches + 1))
        ;;
    esac
  done < "$BACKLOG"
  [ "$matches" -eq 1 ] && [ "$done_after" -eq 1 ]
}

backlog_manual_done_header() {
  local header=$1 body before_metadata suffix today
  body=${header#"- [ ] $ID - "}
  if [ "$RETAINED_PR_LINK" -eq 0 ]; then
    case "$body" in
      *" (kind:"*)
        before_metadata=${body%%" (kind:"*}
        suffix=${body#"$before_metadata"}
        body="$before_metadata $URL$suffix"
        ;;
      *) body="$body $URL" ;;
    esac
  fi
  header="- [x] $ID - $body"
  if [[ "$header" =~ ^(.*)\ \(since\ [0-9]{4}-[0-9]{2}-[0-9]{2}\)$ ]]; then
    today=$(date +%F)
    header="${BASH_REMATCH[1]} (merged $today)"
  fi
  printf '%s\n' "$header"
}

backlog_mark_done_manually() {
  local output target line section='' capture=0 found=0 done_after=0 mode write_failed=0
  backlog_manual_completion_preflight || return 1
  mode=$(fm_pr_file_mode "$BACKLOG") || return 1
  output=$(mktemp "$DATA/.fm-pr-merge-backlog.XXXXXX") || return 1
  target=$(mktemp "$DATA/.fm-pr-merge-target.XXXXXX") || {
    rm -f -- "$output"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '## Done')
        capture=0
        printf '%s\n' "$line" >> "$output" || { write_failed=1; break; }
        cat "$target" >> "$output" || { write_failed=1; break; }
        done_after=1
        ;;
      '## '*)
        capture=0
        printf '%s\n' "$line" >> "$output" || { write_failed=1; break; }
        ;;
      "- [ ] $ID - "*)
        if [ "$section" != Done ] && [ "$found" -eq 0 ]; then
          found=1
          capture=1
          backlog_manual_done_header "$line" >> "$target" || { write_failed=1; break; }
        else
          capture=0
          printf '%s\n' "$line" >> "$output" || { write_failed=1; break; }
        fi
        ;;
      '- ['*)
        capture=0
        printf '%s\n' "$line" >> "$output" || { write_failed=1; break; }
        ;;
      *)
        if [ "$capture" -eq 1 ]; then
          printf '%s\n' "$line" >> "$target" || { write_failed=1; break; }
        else
          printf '%s\n' "$line" >> "$output" || { write_failed=1; break; }
        fi
        ;;
    esac
    case "$line" in '## '*) section=${line#'## '} ;; esac
  done < "$BACKLOG"
  if [ "$write_failed" -ne 0 ] || [ "$found" -ne 1 ] || [ "$done_after" -ne 1 ] \
    || ! chmod "$mode" "$output" || ! mv -f -- "$output" "$BACKLOG"; then
    rm -f -- "$output" "$target"
    return 1
  fi
  rm -f -- "$target"
}

if ! fm_tasks_axi_compatible; then
  if fm_backlog_backend_manual "$CONFIG"; then
    echo "error: compatible tasks-axi is required to verify the retained backlog item" >&2
  else
    echo "error: configured tasks-axi backend is unavailable" >&2
  fi
  exit 1
fi
if [ ! -f "$BACKLOG" ] || [ -L "$BACKLOG" ]; then
  echo "error: task metadata is unavailable and backlog is unavailable for $ID" >&2
  exit 1
fi
backlog_pr_is_absent_or_canonical || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
BACKLOG_RECORD=0
BACKLOG_MANUAL=0
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
  BACKLOG_RECORD=1
  if fm_backlog_backend_manual "$CONFIG"; then
    backlog_manual_completion_preflight || {
      echo "error: retained backlog item cannot be completed manually for $ID" >&2
      exit 1
    }
    BACKLOG_MANUAL=1
  fi
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

if [ "$BACKLOG_RECORD" -eq 1 ]; then
  reject_deferred_merge_modes "$@" || exit 1
  reject_target_merge_queue || exit 1
fi

GH_HOST="$PR_HOST" gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"

if [ "$BACKLOG_RECORD" -eq 1 ]; then
  confirm_pr_merged || exit 1
  if [ "$BACKLOG_MANUAL" -eq 1 ]; then
    backlog_mark_done_manually || {
      echo "error: merged PR could not be recorded in the task backlog" >&2
      exit 1
    }
  else
    tasks-axi "done" "$ID" --pr "$URL" --file "$BACKLOG" || {
      echo "error: merged PR could not be recorded in the task backlog" >&2
      exit 1
    }
  fi
fi

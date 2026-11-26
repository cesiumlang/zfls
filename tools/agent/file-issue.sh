#!/usr/bin/env bash
# file-issue.sh TITLE BODY_FILE LABELS AFTER [BLOCKER...]
# Files a zfls issue as the app with LABELS (comma-separated) and `agent`, in
# the milestone MILESTONE (environment; default: the next version, the open
# `v...` milestone created first), puts it in the Roadmap after the row of
# issue AFTER (or first: `top`) with "Next action: agent", and records its
# blockers. Prints the number.
set -euo pipefail
title=$1 body=$2 labels=$3 after=$4
shift 4
export GH_TOKEN="${GH_TOKEN:-$(bash /c/scratch/github-apps/app-token.sh cesiumlang)}"
R=cesiumlang/zfls

milestone=${MILESTONE:-$(gh api "repos/$R/milestones?state=open&per_page=100" --jq '[.[] | select(.title | startswith("v"))] | sort_by(.number) | .[0].title // empty' < /dev/null)}
[ -n "$milestone" ] || { echo "no open milestone" >&2; exit 1; }
args=(--repo "$R" --title "$title" --label agent --milestone "$milestone" --body-file "$body")
IFS=, read -ra list <<< "$labels"
for l in "${list[@]}"; do [ -n "$l" ] && args+=(--label "$l"); done
url=$(gh issue create "${args[@]}" < /dev/null | tail -1)
number=${url##*/}
for blocker in "$@"; do
  id=$(gh api "repos/$R/issues/$blocker" --jq .id < /dev/null)
  gh api -X POST "repos/$R/issues/$number/dependencies/blocked_by" -F "issue_id=$id" < /dev/null > /dev/null
done

bash "$(dirname "$0")/place.sh" "$number" "$after" > /dev/null
echo "$number"

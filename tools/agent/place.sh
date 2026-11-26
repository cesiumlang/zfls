#!/usr/bin/env bash
# place.sh NUMBER AFTER
# Adds zfls issue NUMBER to the Roadmap if it is not on it (Status Todo,
# "Next action: agent"), and puts its row after the row of issue AFTER, or
# first when AFTER is `top`. Run rank.sh after a batch.
set -euo pipefail
number=$1 after=$2
export GH_TOKEN="${GH_TOKEN:-$(bash /c/scratch/github-apps/app-token.sh cesiumlang)}"
items() { gh project item-list 2 --owner cesiumlang --limit 200 --format json --jq "$1" < /dev/null; }
field() { gh project field-list 2 --owner cesiumlang --format json --jq "$1" < /dev/null; }
project=$(gh project view 2 --owner cesiumlang --format json --jq .id < /dev/null)

item=$(items ".items[] | select(.content.number == $number) | .id")
if [ -z "$item" ]; then
  item=$(gh project item-add 2 --owner cesiumlang --url "https://github.com/cesiumlang/zfls/issues/$number" --format json --jq .id < /dev/null)
  status=$(field '.fields[] | select(.name == "Status") | .id')
  todo=$(field '.fields[] | select(.name == "Status") | .options[] | select(.name == "Todo") | .id')
  gh project item-edit --id "$item" --project-id "$project" --field-id "$status" --single-select-option-id "$todo" < /dev/null > /dev/null
  next=$(field '.fields[] | select(.name == "Next action") | .id')
  agent=$(field '.fields[] | select(.name == "Next action") | .options[] | select(.name == "agent") | .id')
  gh project item-edit --id "$item" --project-id "$project" --field-id "$next" --single-select-option-id "$agent" < /dev/null > /dev/null
fi
if [ "$after" = top ]; then
  gh api graphql -f query='mutation($p: ID!, $i: ID!) { updateProjectV2ItemPosition(input: {projectId: $p, itemId: $i}) { clientMutationId } }' -f p="$project" -f i="$item" < /dev/null > /dev/null
else
  after_item=$(items ".items[] | select(.content.number == $after) | .id")
  [ -n "$after_item" ] || { echo "#$after is not on the Roadmap" >&2; exit 1; }
  gh api graphql -f query='mutation($p: ID!, $i: ID!, $a: ID!) { updateProjectV2ItemPosition(input: {projectId: $p, itemId: $i, afterId: $a}) { clientMutationId } }' -f p="$project" -f i="$item" -f a="$after_item" < /dev/null > /dev/null
fi
echo "#$number placed"

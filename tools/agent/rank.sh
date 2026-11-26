#!/usr/bin/env bash
# rank.sh: sets the Rank field of the zfls Roadmap to each row's position,
# changing only the rows whose Rank differs, 15 to a GraphQL request (larger
# batches have been refused with 502).
set -euo pipefail
export GH_TOKEN="${GH_TOKEN:-$(bash /c/scratch/github-apps/app-token.sh cesiumlang)}"
project=$(gh project view 2 --owner cesiumlang --format json --jq .id < /dev/null)
rank=$(gh project field-list 2 --owner cesiumlang --format json --jq '.fields[] | select(.name == "Rank") | .id' < /dev/null)
changes=$(gh project item-list 2 --owner cesiumlang --limit 200 --format json --jq '.items | to_entries[] | select((.value.rank // 0) != (.key + 1)) | "\(.value.id) \(.key + 1)"' < /dev/null)
[ -z "$changes" ] && { echo "ranks already in order"; exit 0; }
body="" i=0
while read -r id n; do
  i=$((i + 1))
  body="$body m$i: updateProjectV2ItemFieldValue(input: {projectId: \"$project\", itemId: \"$id\", fieldId: \"$rank\", value: {number: $n}}) { clientMutationId }"
  if [ $((i % 15)) -eq 0 ]; then gh api graphql -f query="mutation {$body }" < /dev/null > /dev/null; body=""; fi
done <<< "$changes"
[ -n "$body" ] && gh api graphql -f query="mutation {$body }" < /dev/null > /dev/null
echo "ranks set on $i rows"

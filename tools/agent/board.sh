#!/usr/bin/env bash
# board.sh: the rows of the zfls Roadmap that are not done, in order: the
# first is the next to work
set -euo pipefail
export GH_TOKEN="${GH_TOKEN:-$(bash /c/scratch/github-apps/app-token.sh cesiumlang)}"
gh project item-list 2 --owner cesiumlang --limit 200 --format json --jq '.items | to_entries[] | select(.value.status != "Done" and .value.content.type == "Issue") | "\(.key + 1)\t#\(.value.content.number)\t\(.value.status)\t\(.value."next action" // "")\t\(.value.milestone.title // "")\t\(.value.content.title)"' < /dev/null

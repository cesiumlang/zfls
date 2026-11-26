#!/usr/bin/env bash
# next-action.sh: brings the zfls Roadmap's "Next action" and the label
# `agent` in line with the assignees: a row assigned to emanspeaks is his
# (no `agent` label), every other row not done is the agent's.
set -euo pipefail
export GH_TOKEN="${GH_TOKEN:-$(bash /c/scratch/github-apps/app-token.sh cesiumlang)}"
R=cesiumlang/zfls
project=$(gh project view 2 --owner cesiumlang --format json --jq .id < /dev/null)
field() { gh project field-list 2 --owner cesiumlang --format json --jq "$1" < /dev/null; }
fid=$(field '.fields[] | select(.name == "Next action") | .id')
owner_opt=$(field '.fields[] | select(.name == "Next action") | .options[] | select(.name == "emanspeaks") | .id')
agent_opt=$(field '.fields[] | select(.name == "Next action") | .options[] | select(.name == "agent") | .id')
gh label create agent --repo "$R" --color 5319E7 --description "The next step is the agent's" --force < /dev/null > /dev/null
owners=0 agents=0
while IFS=$'\t' read -r item number who; do
  [ -z "$item" ] && continue
  if [ "$who" = emanspeaks ]; then
    opt=$owner_opt owners=$((owners + 1))
    gh issue edit "$number" --repo "$R" --remove-label agent < /dev/null > /dev/null 2>&1 || true
  else
    opt=$agent_opt agents=$((agents + 1))
    gh issue edit "$number" --repo "$R" --add-label agent < /dev/null > /dev/null
  fi
  gh project item-edit --id "$item" --project-id "$project" --field-id "$fid" --single-select-option-id "$opt" < /dev/null > /dev/null
done <<< "$(gh project item-list 2 --owner cesiumlang --limit 500 --format json --jq '.items[] | select(.status != "Done" and .content.type == "Issue") | [.id, (.content.number | tostring), (if (.assignees // []) | index("emanspeaks") then "emanspeaks" else "agent" end)] | @tsv' < /dev/null)"
echo "next action emanspeaks on $owners, agent on $agents"

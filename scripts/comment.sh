#!/usr/bin/env bash
# comment.sh - post the summary on the pull request, or update the one this
# action posted before, so a pull request carries one comment and not one per
# push. Only with comment: true. It never runs polinrider.

set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

repo=${GITHUB_REPOSITORY:?}
number=${PR_NUMBER:?}
body="$STATE/comment.md"

previous=$(gh api --paginate "repos/${repo}/issues/${number}/comments" \
  --jq '.[] | select(.user.type == "Bot" and (.body | startswith("<!-- polinrider-action -->"))) | .id' | head -n 1)

if [[ -n "$previous" ]]; then
  jq -n --rawfile body "$body" '{body: $body}' \
    | gh api -X PATCH "repos/${repo}/issues/comments/${previous}" --input - >/dev/null
else
  jq -n --rawfile body "$body" '{body: $body}' \
    | gh api -X POST "repos/${repo}/issues/${number}/comments" --input - >/dev/null
fi

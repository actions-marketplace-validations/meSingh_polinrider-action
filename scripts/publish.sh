#!/usr/bin/env bash
# publish.sh - open the pull request that removes the payload.
#
# It never commits to the branch it scanned, never force-pushes and never
# merges. It creates a new branch at the scanned commit, makes one commit on
# it through GitHub's GraphQL createCommitOnBranch, and opens a pull request
# into the scanned branch. A commit made that way is signed by GitHub, and no
# git credentials are needed on the runner, so the checkout can keep
# persist-credentials: false.
#
# It never runs polinrider. The scan step did, without the token.

set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

die() { state_put fix/error "$1"; echo "::error title=PolinRider Scanner::$(ann_data "$1")"; exit 1; }

repo=${GITHUB_REPOSITORY:?}
owner=${repo%%/*}
base=$(state_get fix/base)
tip=$(state_get fix/tip)
branch="polinrider/remove-payload-${tip:0:12}"
workspace=$(cd "${GITHUB_WORKSPACE:?}" && pwd -P)
work="$STATE/publish"
mkdir -p "$work"

command -v gh >/dev/null 2>&1 || die "fix mode needs the gh command, which GitHub's own runners have."
command -v jq >/dev/null 2>&1 || die "fix mode needs the jq command, which GitHub's own runners have."

# One pull request per scanned commit. If one was opened before, say where it
# is; if it was closed without merging, a person decided, so leave it closed.
existing=$(gh api "repos/${repo}/pulls?state=all&head=${owner}:${branch}" \
  --jq '[.[] | {state, url: .html_url, merged: (.merged_at != null)}] | first // empty')
if [[ -n "$existing" ]]; then
  url=$(jq -r .url <<<"$existing")
  if [[ "$(jq -r .state <<<"$existing")" == open ]]; then
    state_put fix/pr-url "$url"
    state_put fix/pr-state already-open
    output pr-url "$url"
  else
    state_put fix/pr-url "$url"
    state_put fix/pr-state closed
  fi
  exit 0
fi
if gh api "repos/${repo}/git/ref/heads/${branch}" >/dev/null 2>&1; then
  die "The branch ${branch} already exists with no pull request. Delete it and run this again."
fi

n_cut=$(grep -c '' "$STATE/fix/cut" || true)
n_removed=$(grep -c '' "$STATE/fix/removed" || true)
total=$((n_cut + n_removed))
title="Remove the PolinRider payload ($(plural "$total" file files))"

: > "$work/additions.jsonl"
while IFS= read -r f; do
  jq -n --arg path "$f" --rawfile contents <(base64 < "$workspace/$f" | tr -d '\n') \
    '{path: $path, contents: $contents}' >> "$work/additions.jsonl"
done < "$STATE/fix/cut"
: > "$work/deletions.jsonl"
while IFS= read -r f; do
  jq -n --arg path "$f" '{path: $path}' >> "$work/deletions.jsonl"
done < "$STATE/fix/removed"

jq -n \
  --arg query 'mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }' \
  --arg repo "$repo" --arg branch "$branch" --arg head "$tip" --arg headline "$title" \
  --slurpfile additions "$work/additions.jsonl" --slurpfile deletions "$work/deletions.jsonl" \
  '{query: $query, variables: {input: {
      branch: {repositoryNameWithOwner: $repo, branchName: $branch},
      expectedHeadOid: $head,
      message: {headline: $headline},
      fileChanges: {additions: $additions, deletions: $deletions}
    }}}' > "$work/mutation.json"

# The pull request's text, exactly as the mock has it. Empty sections are left out.
{
  printf 'PolinRider Scanner found the payload on %s and removed it.\n' "$(md "$base")"
  if [[ -s "$STATE/fix/cut" ]]; then
    printf '\nCut out, the rest of the file kept:\n'
    while IFS= read -r f; do printf -- '- %s\n' "$(md "$f")"; done < "$STATE/fix/cut"
  fi
  if [[ -s "$STATE/fix/removed" ]]; then
    printf '\nRemoved, the whole file was the payload:\n'
    while IFS= read -r f; do printf -- '- %s\n' "$(md "$f")"; done < "$STATE/fix/removed"
  fi
  prefix=$(state_get prefix)
  if grep -q '^confirmed' "$STATE/fix/after.tsv"; then
    printf '\nStill carries the payload, not changed because cutting it out was not safe:\n'
    while IFS=$'\t' read -r lvl what file; do
      [[ "$lvl" == confirmed ]] || continue
      printf -- '- %s: %s\n' "$(md "${prefix}${file}")" "$(md "$(finding_text "$what")")"
    done < "$STATE/fix/after.tsv"
  fi
  if grep -q '^review' "$STATE/fix/after.tsv"; then
    printf '\nNot changed, for a person to look at:\n'
    while IFS=$'\t' read -r lvl what file; do
      [[ "$lvl" == review ]] || continue
      if [[ -n "$file" ]]; then printf -- '- %s: %s\n' "$(md "${prefix}${file}")" "$(md "$(finding_text "$what")")"
      else printf -- '- %s\n' "$(md "$(finding_text "$what")")"; fi
    done < "$STATE/fix/after.tsv"
  fi
  printf '\nBefore merging: check every computer that worked on this repository\n'
  printf '(%s), because the payload\n' "$GUIDE_MACHINE"
  printf 'came from one of them and will come back from it.\n'
} > "$work/body.md"

gh api -X POST "repos/${repo}/git/refs" -f "ref=refs/heads/${branch}" -f "sha=${tip}" >/dev/null \
  || die "Could not create the branch ${branch}. Fix mode needs contents: write."

drop_branch() { gh api -X DELETE "repos/${repo}/git/refs/heads/${branch}" >/dev/null 2>&1 || true; }

if ! oid=$(gh api graphql --input "$work/mutation.json" --jq .data.createCommitOnBranch.commit.oid) \
   || ! [[ "$oid" =~ ^[0-9a-f]{40}$ ]]; then
  drop_branch
  die "Could not commit the cleaned files to ${branch}. A change to a file under .github/workflows needs a token with the workflows permission."
fi

jq -n --arg title "$title" --arg head "$branch" --arg base "$base" --rawfile body "$work/body.md" \
  '{title: $title, head: $head, base: $base, body: $body}' > "$work/pull.json"
if ! url=$(gh api -X POST "repos/${repo}/pulls" --input "$work/pull.json" --jq .html_url); then
  drop_branch
  die "Could not open the pull request. It needs pull-requests: write, and the repository's Actions settings must allow GitHub Actions to create pull requests."
fi

state_put fix/pr-url "$url"
state_put fix/pr-state opened
output pr-url "$url"
echo "Opened $url"

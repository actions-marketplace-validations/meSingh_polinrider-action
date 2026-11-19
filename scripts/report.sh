#!/usr/bin/env bash
# report.sh - the job summary, the annotations, the outputs and SARIF.
#
# Runs after every other step, whether or not they succeeded, so a scan that
# could not run says so instead of leaving an empty summary. No token.

set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

version=$(state_get version)
reviewed=$(state_get reviewed)
verdict=$(state_get verdict)
error=$(state_get error)
mode=$(state_get mode)
prefix=$(state_get prefix)
findings="$STATE/scan/findings.tsv"
summary="$STATE/summary.md"

[[ -z "$error" && -n "$verdict" ]] || verdict=error
confirmed=$(state_get scan/confirmed); confirmed=${confirmed:-0}
review=$(state_get scan/review); review=${review:-0}
files=$(state_get scan/files); files=${files:-0}

output verdict "$verdict"
output confirmed "$confirmed"
output review "$review"
output files "$files"

# The repository path of a finding, or nothing when it is outside the
# workspace or the finding names no file.
repo_path() { [[ -n "$1" && "$prefix" != "-" ]] && printf '%s%s' "$prefix" "$1"; return 0; }

provenance() {
  printf 'PolinRider %s, indicators last reviewed %s.\n' "$version" "$(long_date "$reviewed")"
}

table() {
  printf '| Result | Finding | File |\n|---|---|---|\n'
  while IFS=$'\t' read -r lvl what file; do
    case "$lvl" in confirmed) tag=CONFIRMED ;; *) tag="TO REVIEW" ;; esac
    shown=$(repo_path "$file"); [[ -n "$shown" ]] || shown=$file
    printf '| %s | %s | %s |\n' "$tag" "$(md "$(finding_text "$what")")" "$(md "$shown")"
  done < "$findings"
}

# ---------------------------------------------------------------- summary

pr_url=$(state_get fix/pr-url)
pr_state=$(state_get fix/pr-state)
fix_why=$(state_get fix/why)

{
  case "$verdict" in
    clean)
      printf '## PolinRider Scanner: clean\n\n'
      printf 'Nothing found in %s.\\\n' "$(plural "$files" file files)"
      provenance
      ;;

    review)
      printf '## PolinRider Scanner: to review\n\n'
      printf 'Nothing confirmed. %s to review, in %s.\\\n' "$(num "$review")" "$(plural "$files" file files)"
      provenance
      printf '\n'; table
      printf '\nWhat to do next\n'
      printf '1. Read each file named above and ask whether you put that line there.\n'
      printf '2. If one is not yours, treat this repository as infected and check every\n'
      printf '   computer that has worked on it:\n'
      printf '   %s\n' "$GUIDE_MACHINE"
      ;;

    infected)
      printf '## PolinRider Scanner: infected\n\n'
      if [[ "$review" -gt 0 ]]; then
        printf '%s confirmed and %s to review, in %s.\\\n' "$(num "$confirmed")" "$(num "$review")" "$(plural "$files" file files)"
      else
        printf '%s confirmed, in %s.\\\n' "$(num "$confirmed")" "$(plural "$files" file files)"
      fi
      provenance
      printf '\n'; table
      printf '\nWhat to do next\n'
      printf '1. Check every computer that has worked on this repository:\n'
      printf '   %s\n' "$GUIDE_MACHINE"
      if [[ "$pr_state" == opened || "$pr_state" == already-open ]]; then
        printf '2. Remove the payload: review and merge the pull request that removes it:\n'
        printf '   %s\n' "$pr_url"
      else
        printf '2. Remove the payload: run this action with mode: fix, or run\n'
        printf '   polinrider clean --apply on a clean computer.\n'
      fi
      printf "3. Change the secrets this repository's CI can read.\n"
      if [[ "$mode" == fix ]]; then
        if [[ -n "$fix_why" ]]; then
          printf '\nNo pull request was opened: %s.\n' "$fix_why"
        elif [[ "$pr_state" == closed ]]; then
          printf '\nA pull request for this commit was closed without merging, so no other was opened:\n%s\n' "$pr_url"
        elif [[ "${PUBLISH_OUTCOME:-}" == failure ]]; then
          printf '\nNo pull request was opened: %s\n' "$(state_get fix/error)"
        fi
      fi
      ;;

    *)
      printf '## PolinRider Scanner: could not run\n\n'
      printf 'Nothing was scanned to the end, so this is not a clean result.\\\n'
      printf '%s\n' "${error:-The scan step did not finish.}"
      ;;
  esac
} > "$summary"

cat "$summary" >> "${GITHUB_STEP_SUMMARY:?}"

# ---------------------------------------------------------------- annotations

if [[ -f "$findings" ]]; then
  while IFS=$'\t' read -r lvl what file; do
    case "$lvl" in
      confirmed) cmd=error tag=CONFIRMED ;;
      *) cmd=warning tag="TO REVIEW" ;;
    esac
    where=$(repo_path "$file")
    if [[ -n "$where" ]]; then
      echo "::${cmd} file=$(ann_prop "$where")::$(ann_data "$tag  $(finding_text "$what")")"
    else
      echo "::${cmd}::$(ann_data "$tag  $(finding_text "$what")")"
    fi
  done < "$findings"
fi

# ---------------------------------------------------------------- SARIF

if [[ -n "${INPUT_SARIF_FILE:-}" ]]; then
  case "$INPUT_SARIF_FILE" in /*) sarif=$INPUT_SARIF_FILE ;; *) sarif="${GITHUB_WORKSPACE:?}/$INPUT_SARIF_FILE" ;; esac
  mkdir -p "$(dirname "$sarif")"
  : > "$STATE/sarif-results.jsonl"
  if [[ -f "$findings" ]]; then
    while IFS=$'\t' read -r lvl what file; do
      where=$(repo_path "$file")
      # Code scanning needs a location; a finding without a file is in the
      # summary and the annotations.
      [[ -n "$where" ]] || continue
      case "$lvl" in confirmed) rule=polinrider/confirmed level=error tag=CONFIRMED ;;
                     *) rule=polinrider/review level=warning tag="TO REVIEW" ;; esac
      jq -n --arg rule "$rule" --arg level "$level" --arg text "$tag  $(finding_text "$what")" --arg uri "$where" \
        '{ruleId: $rule, level: $level, message: {text: $text},
          locations: [{physicalLocation: {artifactLocation: {uri: ($uri | gsub("%"; "%25") | gsub(" "; "%20")), uriBaseId: "%SRCROOT%"}}}]}' \
        >> "$STATE/sarif-results.jsonl"
    done < "$findings"
  fi
  jq -n --arg version "${version:-unknown}" --slurpfile results "$STATE/sarif-results.jsonl" '{
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    version: "2.1.0",
    runs: [{
      tool: {driver: {
        name: "PolinRider Scanner",
        version: $version,
        informationUri: "https://polinriderscanner.com/",
        rules: [
          {id: "polinrider/confirmed", name: "PolinRiderConfirmed",
           shortDescription: {text: "A confirmed PolinRider indicator"},
           help: {text: "Check every computer that has worked on this repository: https://polinriderscanner.com/docs/guides/machine/"},
           defaultConfiguration: {level: "error"},
           properties: {"security-severity": "9.0", tags: ["security", "malware"]}},
          {id: "polinrider/review", name: "PolinRiderToReview",
           shortDescription: {text: "Something the PolinRider campaign also uses, for a person to look at"},
           help: {text: "Read the line and ask whether you put it there. If not, treat the repository as infected."},
           defaultConfiguration: {level: "warning"},
           properties: {"security-severity": "5.0", tags: ["security"]}}
        ]
      }},
      results: $results
    }]
  }' > "$sarif"
fi

# ---------------------------------------------------------------- comment

if [[ "${INPUT_COMMENT:-false}" == true && -n "${PR_NUMBER:-}" ]]; then
  if [[ -n "${PR_HEAD_REPO:-}" && "$PR_HEAD_REPO" != "${GITHUB_REPOSITORY:-}" ]]; then
    echo "::notice title=PolinRider Scanner::No comment: a pull request from a fork gets a read-only token."
  else
    { printf '<!-- polinrider-action -->\n'; cat "$summary"; } > "$STATE/comment.md"
    output comment-ready true
  fi
fi

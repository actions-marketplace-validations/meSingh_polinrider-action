# shellcheck shell=bash disable=SC2034
# (SC2034: the words below are read by the scripts that source this file.)
# lib.sh - shared by every step of the action. Sourced, never run.
#
# Written for bash 3.2, which is /bin/bash on macOS: no associative arrays,
# no mapfile, no ${var,,}.
#
# Every sentence the action prints is in the "Words" section below, so what a
# person reads can be checked in one place against the approved mock.

STATE="${RUNNER_TEMP:?RUNNER_TEMP is not set}/polinrider-action"
GUIDE_MACHINE="https://polinriderscanner.com/docs/guides/machine/"

# ---------------------------------------------------------------- state

state_get() { [[ -f "$STATE/$1" ]] && cat "$STATE/$1"; return 0; }
state_put() { mkdir -p "$(dirname "$STATE/$1")"; printf '%s' "$2" > "$STATE/$1"; }

# Record why nothing could be scanned. report.sh says it; result.sh fails.
could_not_run() {
  state_put error "$1"
  echo "::error title=PolinRider Scanner::$(ann_data "$1")"
  exit 1
}

output() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:?}"; }

# ---------------------------------------------------------------- escaping

# A workflow command's message. A file name can hold a newline or a percent
# sign, and either would end or rewrite the command.
ann_data() {
  local s=$1
  s=${s//'%'/%25}; s=${s//$'\r'/%0D}; s=${s//$'\n'/%0A}
  printf '%s' "$s"
}

# A workflow command's property, such as file=. Also escapes : and ,.
ann_prop() {
  local s
  s=$(ann_data "$1"); s=${s//':'/%3A}; s=${s//','/%2C}
  printf '%s' "$s"
}

# Text from the scanned repository going into Markdown: a file name must not
# become a link, an image, HTML or a table cell boundary.
md() {
  local s=${1//$'\r'/ }
  s=${s//$'\n'/ }
  printf '%s\n' "$s" | sed -e 's/[][\\`*_{}<>#|!]/\\&/g'
}

# 1284 -> 1,284
num() {
  local n=$1 out=""
  while [[ ${#n} -gt 3 ]]; do
    out=",${n: -3}$out"
    n=${n:0:${#n}-3}
  done
  printf '%s%s' "$n" "$out"
}

# 2026-11-09 -> 9 November 2026
long_date() {
  local months=(January February March April May June July August September October November December)
  local y=${1%%-*} rest=${1#*-}
  local m=${rest%%-*} d=${rest#*-}
  printf '%d %s %s' "$((10#$d))" "${months[$((10#$m - 1))]}" "$y"
}

plural() { if [[ $1 -eq 1 ]]; then printf '%s %s' "$1" "$2"; else printf '%s %s' "$(num "$1")" "$3"; fi; }

# ---------------------------------------------------------------- the binary

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

strip_ansi() { sed -e $'s/\x1b\\[[0-9;]*m//g'; }

# Run polinrider with its output in the log but unable to issue workflow
# commands: a file name in the output that starts with :: stays text.
run_polinrider() {
  local token rc=0
  token="polinrider-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  echo "::stop-commands::$token"
  "$(state_get bin)" "$@" </dev/null || rc=$?
  echo "::$token::"
  return $rc
}

# The findings a report lists as it goes, one per line:
#   confirmed|review <TAB> what <TAB> path (empty when the finding names none)
# Read from the steps at the top of the report, which every finding passes
# through (ADR-0059 in meSingh/polinrider-scanner), and nothing after them.
findings_of() {
  awk '
    /^== / { exit }
    /^    (CONFIRMED|TO REVIEW)  / {
      if (pend != "") print pend "\t"
      lvl = ($0 ~ /^    CONFIRMED/) ? "confirmed" : "review"
      pend = lvl "\t" substr($0, 16)
      next
    }
    pend != "" && /^               [^ ]/ { print pend "\t" substr($0, 16); pend = ""; next }
    pend != "" { print pend "\t"; pend = "" }
    END { if (pend != "") print pend "\t" }
  ' "$1"
}

# A report's count after "label :", or nothing if the report has no result.
count_of() {
  awk -v want="$2" '
    /^== RESULT ==/ { inres = 1; next }
    inres && index($0, want) { sub(/.*: */, ""); print $1 + 0; exit }
  ' "$1"
}

files_of() {
  awk '/\[info\] +[0-9]+ files listed/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { print $i; exit } }' "$1"
}

has_result() { grep -q '^== RESULT ==' "$1"; }

# The finding as the table shows it: the binary's own words, without the
# "verify by hand" the Result column already says.
finding_text() { printf '%s' "${1%, verify by hand}"; }

# ---------------------------------------------------------------- words

say_mode()         { printf 'mode must be check or fix, not "%s". Nothing was scanned.' "$1"; }
say_fail_on()      { printf 'fail-on must be confirmed, review or never, not "%s". Nothing was scanned.' "$1"; }
say_no_dir()       { printf 'path "%s" is not a directory in this checkout. Nothing was scanned.' "$1"; }
say_platform()     { printf 'This runner is %s on %s. The action runs on Linux and macOS, on x86_64 and arm64.' "$1" "$2"; }
say_no_pin()       { printf 'action.yml has no SHA-256 for %s, so nothing was downloaded.' "$1"; }
say_download()     { printf 'Could not download %s.' "$1"; }
say_mismatch()     { printf '%s does not match the SHA-256 this action pins, so it was not run. Expected %s, got %s.' "$1" "$2" "$3"; }
say_bad_archive()  { printf '%s does not hold polinrider and its indicators. It was not run.' "$1"; }
say_no_start()     { printf 'polinrider %s did not start on this runner: %s. On Linux it needs glibc 2.39 or later, as on ubuntu-24.04.' "$1" "$2"; }
say_wrong_ver()    { printf 'The archive for %s reports version "%s". It was not run.' "$1" "$2"; }
say_verified()     { printf 'polinrider %s for %s, SHA-256 %s, matches the pin.' "$1" "$2" "$3"; }
say_no_result()    { printf 'polinrider stopped with exit code %s and no result. Nothing in this run counts as clean.' "$1"; }

say_fix_fork='this pull request comes from a fork, and the action never writes to one'
say_fix_not_branch='this run is not on a branch'
say_fix_not_tip='the checkout is not the tip of the branch. On pull_request, check out the head branch with `ref: ${{ github.head_ref }}`'
say_fix_not_repo='the scanned path is not inside the checked-out repository'
say_fix_own='this is a branch the action opened'
say_fix_dirty='files in the checkout had already changed before the scan, so the action could not tell its changes apart'
say_fix_clean_failed='polinrider clean did not finish'
say_fix_untracked='what it removed is not tracked by git'

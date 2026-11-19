#!/usr/bin/env bash
# result.sh - pass or fail the step, by verdict and fail-on.
#
# A scan that could not run always fails, whatever fail-on says: nothing
# scanned must never read as clean. So does fix mode when it was asked to
# open a pull request and could not.

set -euo pipefail

case "${VERDICT:-error}/${INPUT_FAIL_ON:-confirmed}" in
  error/*)                          exit 1 ;;
  infected/confirmed|infected/review) exit 1 ;;
  review/review)                    exit 1 ;;
esac
[[ "${PUBLISH_OUTCOME:-}" != failure ]] || exit 1
exit 0

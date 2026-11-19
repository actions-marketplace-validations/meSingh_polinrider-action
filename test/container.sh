#!/usr/bin/env bash
# test/container.sh - run test/run.sh in a disposable container.
#
#   test/container.sh DIST
#
# DIST holds the release the action pins, at DIST/vX.Y.Z/, downloaded with
#   gh release download vX.Y.Z --repo meSingh/polinrider-scanner \
#     --pattern 'polinrider-vX.Y.Z-linux-*.tar.gz' --dir DIST/vX.Y.Z
# (gh release download is not counted as a download; a browser or curl is).
#
# The container is Ubuntu 24.04, the glibc the Linux binaries need, with no
# network, no capabilities, a non-root user and this repository read-only.
# The binary and fix mode run only in there.

set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
dist=$(cd "${1:?usage: test/container.sh DIST}" && pwd)
image=polinrider-action-test

docker build -q -t "$image" - >/dev/null <<'DOCKERFILE'
FROM ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash git jq curl ca-certificates shellcheck \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE

docker run --rm -i --network none --user "$(id -u):$(id -g)" --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 512 --tmpfs /tmp:rw,exec,size=1g -e HOME=/tmp -e SHOW \
  --mount "type=bind,source=$here,target=/action,readonly" \
  --mount "type=bind,source=$dist,target=/dist,readonly" \
  "$image" bash -c 'cd /action/scripts && shellcheck -x --severity=warning *.sh ../test/*.sh && cd / && bash /action/test/run.sh'

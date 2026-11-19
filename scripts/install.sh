#!/usr/bin/env bash
# install.sh - download the pinned polinrider release and refuse anything else.
#
# The version and the SHA-256 of each archive come from action.yml, through
# the step's environment. The archive is hashed before it is unpacked, and a
# mismatch stops here: nothing from it runs. Then the binary must start and
# report the pinned version, so a binary this runner cannot execute is "could
# not run", never a result.

set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

rm -rf "$STATE"
mkdir -p "$STATE"

version=${POLINRIDER_VERSION:?}
reviewed=${POLINRIDER_INDICATORS_REVIEWED:?}
releases=${POLINRIDER_RELEASES:?}
state_put version "$version"
state_put reviewed "$reviewed"

case "${RUNNER_OS:-}/${RUNNER_ARCH:-}" in
  Linux/X64)   platform=linux-x86_64;  want=${POLINRIDER_SHA256_LINUX_X86_64:-} ;;
  Linux/ARM64) platform=linux-arm64;   want=${POLINRIDER_SHA256_LINUX_ARM64:-} ;;
  macOS/ARM64) platform=macos-arm64;   want=${POLINRIDER_SHA256_MACOS_ARM64:-} ;;
  macOS/X64)   platform=macos-x86_64;  want=${POLINRIDER_SHA256_MACOS_X86_64:-} ;;
  *) could_not_run "$(say_platform "${RUNNER_OS:-an unknown system}" "${RUNNER_ARCH:-an unknown processor}")" ;;
esac

name="polinrider-v${version}-${platform}"
[[ "$want" =~ ^[0-9a-f]{64}$ ]] || could_not_run "$(say_no_pin "$name.tar.gz")"

dl="$STATE/download"
mkdir -p "$dl"
# The hash below is what makes this download safe, not the transport. HTTPS
# is still required for the release and for any redirect it gives.
if ! curl -fsSL --retry 3 --proto '=https,file' --proto-redir '=https' \
      -o "$dl/$name.tar.gz" "$releases/v${version}/$name.tar.gz"; then
  could_not_run "$(say_download "$name.tar.gz")"
fi

got=$(sha256_of "$dl/$name.tar.gz")
if [[ "$got" != "$want" ]]; then
  rm -f "$dl/$name.tar.gz"
  could_not_run "$(say_mismatch "$name.tar.gz" "$want" "$got")"
fi

mkdir -p "$STATE/dist"
tar -xzf "$dl/$name.tar.gz" -C "$STATE/dist"
rm -rf "$dl"
bin="$STATE/dist/$name/polinrider"
ioc="$STATE/dist/$name/ioc"
[[ -x "$bin" && -f "$ioc/strong.txt" ]] || could_not_run "$(say_bad_archive "$name.tar.gz")"

if ! out=$("$bin" --version </dev/null 2>&1); then
  could_not_run "$(say_no_start "$version" "$(printf '%s\n' "$out" | strip_ansi | grep -v '^ *$' | head -n 1)")"
fi
reported=$(printf '%s\n' "$out" | strip_ansi | awk '$1 == "version" { print $2; exit }')
[[ "$reported" == "$version" ]] || could_not_run "$(say_wrong_ver "$name.tar.gz" "$reported")"

state_put bin "$bin"
state_put ioc "$ioc"
say_verified "$version" "$platform" "$got"
echo

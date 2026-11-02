#!/usr/bin/env bash
#
# Runs both signing script test suites. Requires bash, keytool and base64.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
status=0

printf '== signing preflight ==\n'
if ! bash "$HERE/test-signing-preflight.sh"; then
  status=1
fi

printf '\n== Termux setup helper ==\n'
if ! bash "$HERE/test-termux-signing-setup.sh"; then
  status=1
fi

exit "$status"

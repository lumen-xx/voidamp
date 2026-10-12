#!/bin/bash
# Builds the driver unsigned into a scratch folder and runs DriverCheck against it, without installing anything.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
bash scripts/build-driver.sh "$WORK" --unsigned >/dev/null
clang -O0 -Wall -Wextra -Werror -framework CoreAudio -framework CoreFoundation -o "$WORK/DriverCheck" Driver/DriverCheck.c
"$WORK/DriverCheck" "$WORK/VoidampMic.driver"

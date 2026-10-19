#!/bin/zsh
# Build both release apps, then update this Mac and one connected Android device.
set -euo pipefail
ROOT="${0:A:h}"
exec python3 "$ROOT/tools/build-release.py" "$@"

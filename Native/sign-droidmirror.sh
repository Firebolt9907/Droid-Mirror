#!/bin/sh
set -eu
# Preserve this identity (or another certificate from the same development team)
# across updates. Ad-hoc signatures bind Keychain ACLs to changing binary hashes.
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
signing_identity=${DROIDMIRROR_SIGNING_IDENTITY:-045FAB101B6F8C94BA65ED2909CE8DAFAF01468A}
codesign --force --deep --sign "$signing_identity" "$task_root/outputs/DroidMirror.app"
codesign --verify --deep --strict "$task_root/outputs/DroidMirror.app"

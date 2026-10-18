#!/bin/sh
set -eu
# Preserve this identity (or another certificate from the same development team)
# across updates. Ad-hoc signatures bind Keychain ACLs to changing binary hashes.
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
signing_identity=${DROIDMIRROR_SIGNING_IDENTITY:-045FAB101B6F8C94BA65ED2909CE8DAFAF01468A}
app_path=${1:-"$task_root/outputs/DroidMirror.app"}
staging=$(mktemp -d "$(dirname "$app_path")/.droidmirror-sign.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM
signed_app="$staging/DroidMirror.app"
# Signing modifies executable files. Give every signed file a fresh inode first.
/usr/bin/ditto "$app_path" "$signed_app"
share_extension="$signed_app/Contents/PlugIns/DroidMirrorShare.appex"
if [ -d "$share_extension" ]; then
    codesign --force --sign "$signing_identity" --entitlements "$task_root/Resources/ShareExtension.entitlements" "$share_extension"
fi
codesign --force --deep --preserve-metadata=entitlements --sign "$signing_identity" "$signed_app"
codesign --verify --deep --strict "$signed_app"
python3 "$task_root/tools/app-bundle.py" publish "$signed_app" "$app_path"

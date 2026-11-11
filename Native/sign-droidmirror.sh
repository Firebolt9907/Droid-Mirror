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
camera_extension="$signed_app/Contents/Library/SystemExtensions/app.droidmirror.camera.systemextension"
# The camera extension needs a paid Apple Developer team (System Extension
# entitlement plus provisioning profiles). Without a team ID, ship without it.
if [ -d "$camera_extension" ] && [ -z "${DROIDMIRROR_TEAM_ID:-}" ]; then
    echo "Omitting Continuity Camera extension: set DROIDMIRROR_TEAM_ID (paid Apple Developer team) to include it." >&2
    rm -rf "$signed_app/Contents/Library/SystemExtensions"
    rmdir "$signed_app/Contents/Library" 2>/dev/null || true
fi
if [ -d "$camera_extension" ]; then
    # Sign existing nested libraries/helpers first; later host signing must not
    # recursively apply host entitlements to the sandboxed camera extension.
    codesign --force --deep --preserve-metadata=entitlements --sign "$signing_identity" "$signed_app"
    # Resolve the build-setting placeholder: this build does not run Xcode's plist expansion.
    camera_team=$DROIDMIRROR_TEAM_ID
    case "$camera_team" in *[!A-Z0-9]*) echo "DROIDMIRROR_TEAM_ID must be an Apple team identifier" >&2; exit 2 ;; esac
    for component in CameraExtension CameraHost CameraReceiver; do
        cp "$task_root/Resources/$component.entitlements" "$staging/$component.entitlements"
        /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $camera_team.app.droidmirror.camera" "$staging/$component.entitlements"
    done
    /usr/libexec/PlistBuddy -c "Set :CMIOExtension:CMIOExtensionMachServiceName $camera_team.app.droidmirror.camera" "$camera_extension/Contents/Info.plist"
    if [ -n "${DROIDMIRROR_CAMERA_PROFILE:-}" ]; then
        cp "$DROIDMIRROR_CAMERA_PROFILE" "$camera_extension/Contents/embedded.provisionprofile"
    fi
    codesign --force --options runtime --sign "$signing_identity" --entitlements "$staging/CameraExtension.entitlements" "$camera_extension"
    receiver="$signed_app/Contents/Helpers/DroidMirror Notifications.app"
    if [ -n "${DROIDMIRROR_RECEIVER_PROFILE:-}" ]; then
        cp "$DROIDMIRROR_RECEIVER_PROFILE" "$receiver/Contents/embedded.provisionprofile"
    fi
    codesign --force --sign "$signing_identity" --entitlements "$staging/CameraReceiver.entitlements" "$receiver"
    if [ -n "${DROIDMIRROR_HOST_PROFILE:-}" ]; then
        cp "$DROIDMIRROR_HOST_PROFILE" "$signed_app/Contents/embedded.provisionprofile"
    fi
    codesign --force --sign "$signing_identity" --entitlements "$staging/CameraHost.entitlements" "$signed_app"
else
    codesign --force --deep --preserve-metadata=entitlements --sign "$signing_identity" "$signed_app"
fi
codesign --verify --deep --strict "$signed_app"
python3 "$task_root/tools/app-bundle.py" publish "$signed_app" "$app_path"

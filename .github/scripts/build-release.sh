#!/bin/bash
# Usage: build-release.sh <version> <build-number> <empty-output-dir>
# Notary credentials: NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID, or NOTARY_PROFILE.
# SKIP_NOTARIZATION=1 only builds and signs, for a local dry run.
set -euo pipefail

usage="usage: build-release.sh <version> <build-number> <empty-output-dir>"
version=${1:?$usage}
build=${2:?$usage}
out=${3:?$usage}
team=${TEAM_ID:-F6A5PBNZF2}
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)

if [[ -e $out && -n $(ls -A "$out") ]]; then
  echo "error: $out is not empty" >&2
  exit 1
fi
mkdir -p "$out"

if [[ ${SKIP_NOTARIZATION:-} == 1 ]]; then
  notary=()
elif [[ -n ${NOTARY_KEY_PATH:-} ]]; then
  notary=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
elif [[ -n ${NOTARY_PROFILE:-} ]]; then
  notary=(--keychain-profile "$NOTARY_PROFILE")
else
  echo "error: no notary credentials (see the usage lines at the top of this script)" >&2
  exit 1
fi

identity=$(security find-identity -v -p codesigning |
  awk -v team="($team)\"" '/"Developer ID Application: / && index($0, team) { print $2; exit }')
if [[ -z $identity ]]; then
  echo "error: no valid Developer ID Application identity for team $team" >&2
  exit 1
fi

notarize() {
  local upload=$1 staple=$2 result id status
  if [[ ${SKIP_NOTARIZATION:-} == 1 ]]; then
    echo "Skipping notarization of $upload"
    return
  fi
  result=$(xcrun notarytool submit "$upload" "${notary[@]}" --wait --timeout 1h --output-format json) || true
  id=$(plutil -extract id raw -o - - <<<"$result") || { echo "error: notarytool: $result" >&2; exit 1; }
  status=$(plutil -extract status raw -o - - <<<"$result")
  xcrun notarytool log "$id" "${notary[@]}"
  if [[ $status != Accepted ]]; then
    echo "error: notarization of $upload ended as $status" >&2
    exit 1
  fi
  xcrun stapler staple "$staple"
  xcrun stapler validate "$staple"
}

xcodebuild archive \
  -project "$root/Smuggler.xcodeproj" \
  -scheme Smuggler \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$out/Smuggler.xcarchive" \
  -derivedDataPath "$out/DerivedData" \
  -quiet \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build" \
  DEVELOPMENT_TEAM="$team" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application"

cat >"$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>teamID</key>
  <string>$team</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
  -archivePath "$out/Smuggler.xcarchive" \
  -exportPath "$out/export" \
  -exportOptionsPlist "$out/ExportOptions.plist" \
  -quiet

app=$out/export/Smuggler.app
appex=$app/Contents/PlugIns/SmugglerFinderExtension.appex
codesign --verify --strict --deep "$app"
codesign -d --entitlements - --xml "$app" >"$out/app-entitlements.plist" 2>/dev/null
codesign -d --entitlements - --xml "$appex" >"$out/appex-entitlements.plist" 2>/dev/null
python3 -I - "$out" "$app" "$appex" "$version" "$build" "$team.group.com.benjaminhuebner.Smuggler" <<'PY'
import plistlib
import sys

out, app_path, appex_path, version, build, group = sys.argv[1:]


def load(path):
    with open(path, "rb") as file:
        return plistlib.load(file)


app, appex = load(f"{out}/app-entitlements.plist"), load(f"{out}/appex-entitlements.plist")
infos = [load(f"{path}/Contents/Info.plist") for path in (app_path, appex_path)]
read_only = appex.get("com.apple.security.temporary-exception.files.absolute-path.read-only")
checks = {
    "version": all(info["CFBundleShortVersionString"] == version for info in infos),
    "build number": all(info["CFBundleVersion"] == build for info in infos),
    "app unsandboxed": app.get("com.apple.security.app-sandbox") is False,
    "extension sandboxed": appex.get("com.apple.security.app-sandbox") is True,
    "app group": all(e.get("com.apple.security.application-groups") == [group] for e in (app, appex)),
    "extension read access": read_only == ["/"],
    "no get-task-allow": not any(e.get("com.apple.security.get-task-allow") for e in (app, appex)),
}
failed = [name for name, passed in checks.items() if not passed]
if failed:
    sys.exit("error: the exported app fails: " + ", ".join(failed))
PY

ditto -c -k --keepParent "$app" "$out/Smuggler.zip"
notarize "$out/Smuggler.zip" "$app"

mkdir "$out/dmg"
ditto "$app" "$out/dmg/Smuggler.app"
ln -s /Applications "$out/dmg/Applications"
# Disk image creation sometimes fails with "Resource busy" on CI runners; a retry gets through.
for attempt in 1 2 3; do
  rm -f "$out/Smuggler.dmg"
  diskutil image create from --format ULFO --volumeName Smuggler "$out/dmg" "$out/Smuggler.dmg" && break
  if [[ $attempt == 3 ]]; then exit 1; fi
  sleep 10
done
codesign --sign "$identity" --timestamp "$out/Smuggler.dmg"
notarize "$out/Smuggler.dmg" "$out/Smuggler.dmg"

if [[ ${SKIP_NOTARIZATION:-} != 1 ]]; then
  spctl --assess --type execute --verbose=2 "$app"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$out/Smuggler.dmg"
fi
echo "$out/Smuggler.dmg"

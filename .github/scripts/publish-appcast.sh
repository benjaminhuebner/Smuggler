#!/bin/bash
# Usage: publish-appcast.sh [output.xml]
# Rebuilds the appcast from all published releases, signs it, attaches it to the newest one and only
# then marks that release latest, so the app's feed URL never lacks it. An output path only writes the file.
set -euo pipefail

output=${1:-}
repo=${GITHUB_REPOSITORY:-benjaminhuebner/Smuggler}
sign_update=${SPARKLE_BIN:?set SPARKLE_BIN to the folder holding sign_update}/sign_update
: "${SPARKLE_PRIVATE_KEY:?set SPARKLE_PRIVATE_KEY}"
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'diskutil eject "$work/volume" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

feed=$work/appcast.xml
python3 -I "$here/appcast.py" new "$feed"
gh api "repos/$repo/releases?per_page=100" --paginate --slurp >"$work/releases.json"
jq -r 'add | map(select(.draft == false and .prerelease == false and any(.assets[]; .name == "Smuggler.dmg")))
  | sort_by(.tag_name | ltrimstr("v") | split(".") | map(tonumber? // 0)) | .[] | [.tag_name, .published_at] | @tsv' \
  "$work/releases.json" >"$work/releases.tsv"

while IFS=$'\t' read -r tag published <&3; do
  mkdir "$work/$tag"
  dmg=$work/$tag/Smuggler.dmg
  gh release download "$tag" --repo "$repo" --pattern Smuggler.dmg --dir "$work/$tag"
  length=$(stat -f %z "$dmg")
  signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - -p "$dmg")
  jq -r --arg tag "$tag" 'add | .[] | select(.tag_name == $tag) | .body // ""' "$work/releases.json" >"$work/$tag/notes.md"
  diskutil image attach --readOnly --nobrowse --mountPoint "$work/volume" "$dmg" >/dev/null
  python3 -I "$here/appcast.py" add "$feed" \
    --app "$work/volume/Smuggler.app" \
    --expect-version "${tag#v}" \
    --url "https://github.com/$repo/releases/download/$tag/Smuggler.dmg" \
    --length "$length" \
    --signature "$signature" \
    --published "$published" \
    --notes "$work/$tag/notes.md"
  diskutil eject "$work/volume" >/dev/null
done 3<"$work/releases.tsv"

printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$feed"
if [[ -n $output ]]; then
  cp "$feed" "$output"
  exit 0
fi
newest=$(tail -n 1 "$work/releases.tsv" | cut -f 1)
gh release upload "$newest" "$feed" --repo "$repo" --clobber
gh release edit "$newest" --repo "$repo" --latest >/dev/null
echo "Attached the appcast with $(grep -c '<item>' "$feed") items to $newest, now the latest release."

#!/bin/bash
# Stores the release workflow's secrets in GitHub, each one checked first. Between the two
# certificate steps, create a Developer ID Application certificate (G2 Sub-CA) from request.csr.
set -euo pipefail

usage="usage: release-secrets.sh certificate-request <dir>
       release-secrets.sh certificate-install <dir> <developerID_application.cer>
       release-secrets.sh notary-key <AuthKey_….p8> <key-id> <issuer-id>
       release-secrets.sh sparkle-key"
repo=benjaminhuebner/Smuggler
team=F6A5PBNZF2
openssl=/usr/bin/openssl
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)

case ${1:-} in
  certificate-request)
    dir=${2:?$usage}
    mkdir -m 700 "$dir"
    "$openssl" req -new -newkey rsa:2048 -nodes -keyout "$dir/key.pem" -out "$dir/request.csr" \
      -subj "/CN=Smuggler release CI/emailAddress=hello@benjaminhuebner.com"
    echo "Create a Developer ID Application certificate (G2 Sub-CA) from $dir/request.csr."
    ;;

  certificate-install)
    dir=${2:?$usage}
    certificate=${3:?$usage}
    P12_PASSWORD=$("$openssl" rand -base64 24)
    export P12_PASSWORD
    "$openssl" x509 -inform DER -in "$certificate" -out "$dir/certificate.pem"
    # macOS imports only the older PKCS#12 ciphers reliably, so they are named explicitly.
    "$openssl" pkcs12 -export -inkey "$dir/key.pem" -in "$dir/certificate.pem" -out "$dir/identity.p12" \
      -passout env:P12_PASSWORD -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
    keychain=$dir/check.keychain-db
    security create-keychain -p check "$keychain"
    trap 'security delete-keychain "$keychain" 2>/dev/null || true' EXIT
    security import "$dir/identity.p12" -k "$keychain" -P "$P12_PASSWORD" >/dev/null
    if ! security find-identity -p codesigning "$keychain" | grep -q "Developer ID Application: .*($team)"; then
      echo "error: $certificate is no Developer ID Application certificate of team $team for this key" >&2
      exit 1
    fi
    base64 -i "$dir/identity.p12" | gh secret set DEVELOPER_ID_P12 --repo "$repo"
    printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo "$repo"
    rm "$dir/key.pem" "$dir/identity.p12" "$dir/certificate.pem" "$dir/request.csr"
    echo "Stored the identity; its private key now exists only in the GitHub secret."
    ;;

  notary-key)
    key=${2:?$usage}
    key_id=${3:?$usage}
    issuer=${4:?$usage}
    xcrun notarytool history --key "$key" --key-id "$key_id" --issuer "$issuer" >/dev/null
    gh secret set NOTARY_KEY --repo "$repo" <"$key"
    printf '%s' "$key_id" | gh secret set NOTARY_KEY_ID --repo "$repo"
    printf '%s' "$issuer" | gh secret set NOTARY_ISSUER_ID --repo "$repo"
    echo "Stored the notary key."
    ;;

  sparkle-key)
    generate_keys=$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin/generate_keys' -print -quit)
    if [[ -z $generate_keys ]]; then
      echo "error: Sparkle's generate_keys not found; build Smuggler in Xcode once" >&2
      exit 1
    fi
    expected=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$root/Smuggler/Info.plist")
    if [[ $("$generate_keys" -p) != "$expected" ]]; then
      echo "error: the keychain's Sparkle key does not match SUPublicEDKey $expected" >&2
      exit 1
    fi
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    "$generate_keys" -x "$work/private-key"
    gh secret set SPARKLE_PRIVATE_KEY --repo "$repo" <"$work/private-key"
    echo "Stored the Sparkle key."
    ;;

  *)
    echo "$usage" >&2
    exit 1
    ;;
esac

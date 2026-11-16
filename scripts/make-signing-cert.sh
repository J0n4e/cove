#!/bin/bash
# One-time setup: creates Cove's self-signed code-signing certificate (valid 10 years).
#
#   scripts/make-signing-cert.sh            # writes cove-signing.p12 and prints what to do next
#   scripts/make-signing-cert.sh --github   # also stores it in the GitHub environment "release" with `gh`
#   --show-password                         # print the .p12 password (default: copied to the clipboard)
#
# Why: ad-hoc signatures change with every build, so macOS treats each update as a different app (Keychain
# prompts after every update). With one stable certificate, every release is recognized as the same app.
# It is not an Apple Developer ID: Gatekeeper still shows the "unidentified developer" warning on first launch.
set -euo pipefail
OSSL=/usr/bin/openssl          # macOS LibreSSL: writes .p12 files that `security import` reads on every macOS
OUT=cove-signing.p12
GITHUB=0; SHOW=0
for a in "$@"; do
  case "$a" in
    --github) GITHUB=1 ;;
    --show-password) SHOW=1 ;;
    *) echo "Unknown option: $a" >&2; exit 2 ;;
  esac
done
PASS=$(uuidgen)
[ -e "$OUT" ] && { echo "$OUT already exists; not overwriting it." >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Cove Code Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

"$OSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
LEGACY=""; "$OSSL" version | grep -q '^OpenSSL 3' && LEGACY="-legacy"
"$OSSL" pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "Cove Code Signing" \
  -out "$OUT" -passout "pass:$PASS"
chmod 600 "$OUT"

# The password never goes to the terminal unless asked for (scrollback, screen recordings, shared logs)
tell_password() {
  if [ "$SHOW" = 1 ]; then
    echo "Password of $OUT (save it with the file): $PASS"
  elif command -v pbcopy >/dev/null 2>&1 && printf '%s' "$PASS" | pbcopy; then
    echo "Password copied to the clipboard — save it in your password manager"
  else
    echo "Couldn't copy the password to the clipboard; run again with --show-password." >&2
  fi
}

if [ "$GITHUB" = 1 ]; then
  base64 -i "$OUT" | gh secret set CODESIGN_P12 --env release -R J0n4e/cove
  printf '%s' "$PASS" | gh secret set CODESIGN_P12_PASSWORD --env release -R J0n4e/cove
  echo "Secrets CODESIGN_P12 and CODESIGN_P12_PASSWORD are set in the 'release' environment of J0n4e/cove."
  if [ "$SHOW" = 1 ]; then echo "Password of $OUT (save it with the file): $PASS"; fi
else
  echo "Created $OUT. Add two secrets to the 'release' environment (repo Settings > Environments > release):"
  echo "  base64 -i $OUT | gh secret set CODESIGN_P12 --env release -R J0n4e/cove"
  echo "  gh secret set CODESIGN_P12_PASSWORD --env release -R J0n4e/cove    # paste the password when asked"
  tell_password
fi
echo "Keep $OUT and its password in your password manager (losing them means a one-time Keychain prompt for users), then delete $OUT."

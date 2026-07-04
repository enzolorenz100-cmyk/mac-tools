#!/bin/bash
# Richtet das stabile Code-Signing-Zertifikat für LocalFlow ein, damit die
# Accessibility-Berechtigung Rebuilds überlebt (ad-hoc-Signaturen tun das NICHT).
#
# Trick: eigener Signier-Schlüsselbund mit BEKANNTEM Passwort → codesign kann den
# privaten Schlüssel prompt-frei nutzen (der Anmelde-Schlüsselbund verlangt sonst
# bei jedem Zugriff das Mac-Passwort = nicht automatisierbar).
#
# Nutzung: scripts/setup-signing-cert.sh   (einmalig; idempotent)
set -euo pipefail
cd "$(dirname "$0")/.."

P12="localflow-signing.p12"          # enthält Cert + privaten Schlüssel (Passwort: localflow)
KC="$HOME/Library/Keychains/localflow-signing.keychain-db"
KCPASS="localflow-local-signing"     # belanglos — Schlüsselbund enthält nur ein lokales Dev-Cert

if [ ! -f "$P12" ]; then
    echo "FEHLER: $P12 fehlt. Zertifikat neu erzeugen mit:"
    echo "  openssl genrsa -out k.key 2048"
    echo "  openssl req -x509 -new -key k.key -out k.crt -days 3650 -sha256 -subj '/CN=LocalFlow' \\"
    echo "    -addext 'extendedKeyUsage=critical,codeSigning' -addext 'keyUsage=critical,digitalSignature'"
    echo "  openssl pkcs12 -export -inkey k.key -in k.crt -out $P12 -name LocalFlow \\"
    echo "    -passout pass:localflow -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES"
    exit 1
fi

echo "▸ Signier-Schlüsselbund (neu) anlegen"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"               # kein Auto-Lock
security unlock-keychain -p "$KCPASS" "$KC"

echo "▸ Zertifikat importieren"
security import "$P12" -k "$KC" -P localflow -T /usr/bin/codesign -A

echo "▸ Partition-List setzen (codesign darf prompt-frei signieren)"
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KC" >/dev/null 2>&1

echo "▸ Zur Suchliste hinzufügen"
EXISTING=$(security list-keychains -d user | sed 's/[" ]//g' | tr '\n' ' ')
case "$EXISTING" in
    *localflow-signing*) : ;;   # schon drin
    *) security list-keychains -d user -s "$KC" $EXISTING ;;
esac

echo "▸ Fertig. Verfügbare Identität:"
security find-identity -p codesigning | grep -i localflow || { echo "FEHLER: Identität nicht gefunden"; exit 1; }
echo "Jetzt: scripts/build.sh --install   (signiert automatisch mit diesem Zertifikat)"

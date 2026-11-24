#!/usr/bin/env bash
set -euo pipefail

# Inspects available stable macOS code-signing identities for Glance, or
# optionally generates a local self-signed Code Signing certificate
# ("Glance Local Signing") when no Apple Development / Developer ID certificate
# is present on this Mac.
#
# Why this matters:
# Ad-hoc signing (`-`) generates a unique `cdhash` on every rebuild, causing
# macOS TCC (Accessibility / Camera) and Legacy Keychain ACLs to silently deny
# Glance after updates. A stable certificate pins Glance's designated
# requirement to its certificate instead of a per-build `cdhash`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/codesign_common.sh
source "${SCRIPT_DIR}/codesign_common.sh"

CERT_NAME="${CERT_NAME:-Glance Local Signing}"
CREATE_SELF_SIGNED=0
OUT_DIR="${HOME}/Library/Application Support/Glance/LocalSigning"

usage() {
    cat <<'EOF'
Usage: tools/setup_local_signing.sh [options]

Options:
  --create-self-signed   Generate a 10-year local self-signed Code Signing
                         certificate (.p12) and import it into login.keychain-db
  --cert-name <name>     Certificate Common Name (default: "Glance Local Signing")
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --create-self-signed) CREATE_SELF_SIGNED=1; shift ;;
        --cert-name) CERT_NAME="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

echo "==> Checking valid code-signing identities on this Mac..."
glance_list_valid_identities

glance_resolve_signing_identity "auto"
if [[ "${GLANCE_RESOLVED_IDENTITY}" != "-" && "${CREATE_SELF_SIGNED}" -eq 0 ]]; then
    glance_classify_certificate "${GLANCE_RESOLVED_IDENTITY}"
    echo ""
    echo "==> Stable signing identity already available:"
    echo "    Name: ${GLANCE_RESOLVED_NAME}"
    echo "    SHA1: ${GLANCE_RESOLVED_IDENTITY}"
    echo "    Kind: ${GLANCE_CERT_KIND}"
    echo ""
    echo "You can now build & install Glance with:"
    echo "    ./tools/install_local.sh"
    exit 0
fi

if [[ "${CREATE_SELF_SIGNED}" -eq 0 ]]; then
    echo ""
    echo "No valid Developer ID, Apple Development, or '${CERT_NAME}' identity was found."
    echo "Options:"
    echo "  1. Sign in to Xcode -> Settings -> Accounts to download a free Apple Development certificate."
    echo "  2. Or create a local self-signed certificate:"
    echo "       ./tools/setup_local_signing.sh --create-self-signed"
    exit 1
fi

echo "==> Generating 10-year self-signed Code Signing certificate '${CERT_NAME}'..."
mkdir -p "${OUT_DIR}"
chmod 700 "${OUT_DIR}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

OPENSSL_CFG="${TMP_DIR}/codesign.cnf"
cat > "${OPENSSL_CFG}" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_codesign
prompt = no

[dn]
CN = ${CERT_NAME}
O = Glance Local

[v3_codesign]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

KEY_PATH="${TMP_DIR}/cert.key"
CRT_PATH="${TMP_DIR}/cert.crt"
P12_PATH="${OUT_DIR}/${CERT_NAME// /_}.p12"
P12_PASS="$(/usr/bin/openssl rand -hex 16)"

/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes \
    -keyout "${KEY_PATH}" \
    -out "${CRT_PATH}" \
    -days 3650 \
    -sha256 \
    -config "${OPENSSL_CFG}" 2>/dev/null

/usr/bin/openssl pkcs12 -export \
    -inkey "${KEY_PATH}" \
    -in "${CRT_PATH}" \
    -out "${P12_PATH}" \
    -name "${CERT_NAME}" \
    -passout "pass:${P12_PASS}"
chmod 600 "${P12_PATH}"

LOGIN_KC="${HOME}/Library/Keychains/login.keychain-db"
echo "==> Importing '${CERT_NAME}' into ${LOGIN_KC}..."
/usr/bin/security import "${P12_PATH}" \
    -k "${LOGIN_KC}" \
    -P "${P12_PASS}" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

rm -f "${P12_PATH}"

echo ""
echo "==> Next (one-time) step required by macOS:"
echo "    Open Keychain Access -> login -> Certificates -> '${CERT_NAME}'"
echo "    Double-click -> Trust -> Code Signing -> 'Always Trust'."
echo "    Then verify with:"
echo "      security find-identity -v -p codesigning"
echo "    and build/install with:"
echo "      ./tools/install_local.sh"

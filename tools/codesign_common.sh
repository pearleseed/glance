#!/usr/bin/env bash
# Shared code-signing helpers for tools/build_release.sh and tools/install_local.sh.
#
# Resolves a stable signing identity (avoiding ad-hoc cdhash churn that breaks
# macOS TCC Accessibility/Camera grants and Legacy Keychain ACLs on every rebuild)
# and applies AMFI-safe entitlements when no provisioning profile is embedded.

glance_list_valid_identities() {
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null || true
}

# Resolves an identity selector ("auto", "-", SHA-1 hash, or substring) into:
#   GLANCE_RESOLVED_IDENTITY  (40-char SHA-1 hash or "-")
#   GLANCE_RESOLVED_NAME      (human-readable label)
glance_resolve_signing_identity() {
    local requested="${1:-auto}"
    if [[ "${requested}" == "-" ]]; then
        GLANCE_RESOLVED_IDENTITY="-"
        GLANCE_RESOLVED_NAME="ad-hoc (-)"
        return 0
    fi

    local resolved
    resolved="$(python3 - "${requested}" <<'PY'
import re
import subprocess
import sys

requested = sys.argv[1].strip()
raw = subprocess.check_output(
    ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
    text=True,
    stderr=subprocess.DEVNULL,
)

entries = []
for line in raw.splitlines():
    m = re.match(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"', line)
    if m:
        entries.append((m.group(1).upper(), m.group(2)))

def pick_auto():
    for prefix in (
        "Developer ID Application:",
        "Apple Development:",
        "Glance Local Signing",
    ):
        for sha1, name in entries:
            if name.startswith(prefix):
                return sha1, name
    return None

if requested == "auto":
    choice = pick_auto()
    if choice:
        print(f"{choice[0]}\t{choice[1]}")
    else:
        print("-\tad-hoc (-)")
    sys.exit(0)

# Exact 40-char SHA-1 match first
if re.fullmatch(r"[0-9A-Fa-f]{40}", requested):
    target = requested.upper()
    for sha1, name in entries:
        if sha1 == target:
            print(f"{sha1}\t{name}")
            sys.exit(0)
    print(f"ERROR: Valid codesigning identity with SHA-1 {target} not found.", file=sys.stderr)
    sys.exit(1)

# Exact common-name match, then substring match against valid identities
exact = [(s, n) for s, n in entries if n == requested]
if len(exact) == 1:
    print(f"{exact[0][0]}\t{exact[0][1]}")
    sys.exit(0)

partial = [(s, n) for s, n in entries if requested.lower() in n.lower()]
if len(partial) == 1:
    print(f"{partial[0][0]}\t{partial[0][1]}")
    sys.exit(0)

if len(exact) > 1 or len(partial) > 1:
    print(f"ERROR: Ambiguous codesigning identity '{requested}'. Pass its 40-char SHA-1 hash.", file=sys.stderr)
    sys.exit(1)

print(f"ERROR: Valid codesigning identity '{requested}' not found.", file=sys.stderr)
sys.exit(1)
PY
)" || return 1

    GLANCE_RESOLVED_IDENTITY="${resolved%%$'\t'*}"
    GLANCE_RESOLVED_NAME="${resolved#*$'\t'}"
}

# Inspects the exact certificate matching a 40-char SHA-1 hash and sets:
#   GLANCE_CERT_KIND  ("apple_developer_id" | "apple_development" | "self_signed" | "other")
#   GLANCE_CERT_SHA1  (lowercase 40-char hex)
glance_classify_certificate() {
    local sha1_upper="$1"
    local info
    info="$(python3 - "${sha1_upper}" <<'PY'
import re
import subprocess
import sys

target = sys.argv[1].strip().upper()
pem_dump = subprocess.check_output(
    ["/usr/bin/security", "find-certificate", "-a", "-p"],
    text=True,
    stderr=subprocess.DEVNULL,
)
certs = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem_dump, re.S)

for cert in certs:
    out = subprocess.check_output(
        ["/usr/bin/openssl", "x509", "-noout", "-subject", "-issuer", "-fingerprint", "-sha1"],
        input=cert,
        text=True,
        stderr=subprocess.DEVNULL,
    )
    fp_match = re.search(r"Fingerprint=([0-9A-Fa-f:]+)", out)
    if not fp_match:
        continue
    fp = fp_match.group(1).replace(":", "").upper()
    if fp != target:
        continue
    subj_match = re.search(r"^subject=(.*)$", out, re.M)
    iss_match = re.search(r"^issuer=(.*)$", out, re.M)
    subj = subj_match.group(1).strip() if subj_match else ""
    iss = iss_match.group(1).strip() if iss_match else ""

    if "Developer ID Application:" in subj and "Apple" in iss:
        kind = "apple_developer_id"
    elif "Apple Development:" in subj and "Apple" in iss:
        kind = "apple_development"
    elif subj and subj == iss:
        kind = "self_signed"
    else:
        kind = "other"
    print(f"{kind}\t{fp.lower()}")
    sys.exit(0)

print(f"other\t{target.lower()}")
PY
)"
    GLANCE_CERT_KIND="${info%%$'\t'*}"
    GLANCE_CERT_SHA1="${info#*$'\t'}"
}

# Signs a built Glance.app inside-out with safe entitlements and a stable
# designated requirement when a real certificate is used.
#
# Usage: glance_sign_app_bundle <app_path> <requested_identity> <repo_root> <bundle_id>
glance_sign_app_bundle() {
    local app_path="$1"
    local requested_identity="$2"
    local repo_root="$3"
    local bundle_id="${4:-com.pearleseed.glance}"

    glance_resolve_signing_identity "${requested_identity}"

    local nested_args=(--force --sign "${GLANCE_RESOLVED_IDENTITY}")
    local app_args=(--force --sign "${GLANCE_RESOLVED_IDENTITY}")

    if [[ "${GLANCE_RESOLVED_IDENTITY}" != "-" ]]; then
        glance_classify_certificate "${GLANCE_RESOLVED_IDENTITY}"

        local entitlements_path="${repo_root}/tools/runtime.entitlements"
        if [[ -f "${app_path}/Contents/embedded.provisionprofile" ]]; then
            entitlements_path="${repo_root}/glance/glance.entitlements"
        fi

        echo "==> Code-signing with ${GLANCE_RESOLVED_NAME} (${GLANCE_CERT_KIND})"
        echo "    Entitlements: ${entitlements_path}"

        case "${GLANCE_CERT_KIND}" in
            apple_developer_id)
                nested_args+=(--options runtime --timestamp)
                app_args+=(--options runtime --timestamp --entitlements "${entitlements_path}")
                ;;
            apple_development)
                nested_args+=(--options runtime --timestamp=none)
                app_args+=(--options runtime --timestamp=none --entitlements "${entitlements_path}")
                ;;
            self_signed)
                local req="=designated => identifier \"${bundle_id}\" and certificate leaf = H\"${GLANCE_CERT_SHA1}\""
                nested_args+=(--options runtime --timestamp=none)
                app_args+=(--options runtime --timestamp=none --entitlements "${entitlements_path}" --requirements "${req}")
                ;;
            *)
                nested_args+=(--options runtime --timestamp=none)
                app_args+=(--options runtime --timestamp=none --entitlements "${entitlements_path}")
                ;;
        esac
    else
        echo "==> Code-signing ad-hoc (-); warning: TCC & Keychain ACLs will churn across rebuilds."
    fi

    # Sign nested binaries inside-out before signing the outer app bundle.
    local sparkle_fw="${app_path}/Contents/Frameworks/Sparkle.framework"
    if [[ -d "${sparkle_fw}" ]]; then
        for nested in \
            "${sparkle_fw}/Versions/B/XPCServices/Downloader.xpc" \
            "${sparkle_fw}/Versions/B/XPCServices/Installer.xpc" \
            "${sparkle_fw}/Versions/B/Autoupdate" \
            "${sparkle_fw}/Versions/B/Updater.app" \
            "${sparkle_fw}"; do
            if [[ -e "${nested}" ]]; then
                /usr/bin/codesign "${nested_args[@]}" "${nested}"
            fi
        done
    fi

    local pam_so="${app_path}/Contents/Helpers/pam_glance.so"
    if [[ -f "${pam_so}" ]]; then
        /usr/bin/codesign "${nested_args[@]}" "${pam_so}"
    fi

    /usr/bin/codesign "${app_args[@]}" "${app_path}"
    /usr/bin/codesign --verify --deep --strict "${app_path}"
}

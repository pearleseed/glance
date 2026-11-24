#!/usr/bin/env bash
set -euo pipefail

# Builds Release Glance for the host architecture, signs it with a stable local
# signing identity (so Accessibility/Camera TCC and Keychain ACLs survive future
# rebuilds), verifies the signature and designated requirement, and installs it
# cleanly into /Applications/Glance.app.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${REPO_ROOT}/glance.xcodeproj"
SOURCE_PACKAGES_DIR="${REPO_ROOT}/build/SourcePackages"
ARCH="$(uname -m)"
DERIVED_DATA="${REPO_ROOT}/build/DerivedData-local-${ARCH}"
STAGE_DIR="${REPO_ROOT}/build/local-${ARCH}"
INSTALL_PATH="/Applications/Glance.app"
BUNDLE_ID="com.pearleseed.glance"
SIGN_IDENTITY="${GLANCE_SIGN_IDENTITY:-auto}"
ALLOW_ADHOC=0
LAUNCH_AFTER_INSTALL=1
CLEAN_BUILD=0

# shellcheck source=tools/codesign_common.sh
source "${SCRIPT_DIR}/codesign_common.sh"

usage() {
    cat <<'EOF'
Usage: tools/install_local.sh [options]

Options:
  --sign-identity <id|auto|->  Code-signing identity (default: auto)
  --allow-adhoc                Allow falling back to ad-hoc signing if no cert exists
  --install-path <path>        Destination app bundle (default: /Applications/Glance.app)
  --no-launch                  Do not launch Glance after installing
  --clean                      Remove local DerivedData before building
  -h, --help                   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign-identity) SIGN_IDENTITY="$2"; shift 2 ;;
        --allow-adhoc) ALLOW_ADHOC=1; shift ;;
        --install-path) INSTALL_PATH="$2"; shift 2 ;;
        --no-launch) LAUNCH_AFTER_INSTALL=0; shift ;;
        --clean) CLEAN_BUILD=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

glance_resolve_signing_identity "${SIGN_IDENTITY}"
if [[ "${GLANCE_RESOLVED_IDENTITY}" == "-" && "${ALLOW_ADHOC}" -ne 1 ]]; then
    echo "ERROR: No stable code-signing identity found." >&2
    echo "Run ./tools/setup_local_signing.sh to inspect or create one, or pass --allow-adhoc." >&2
    exit 1
fi

echo "==> Selected signing identity: ${GLANCE_RESOLVED_NAME} (${GLANCE_RESOLVED_IDENTITY})"

if [[ "${CLEAN_BUILD}" -eq 1 ]]; then
    echo "==> Cleaning ${DERIVED_DATA}..."
    rm -rf "${DERIVED_DATA}"
fi

echo "==> Building Glance Release (${ARCH})..."
xcodebuild \
    -project "${PROJECT}" \
    -scheme glance \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA}" \
    -clonedSourcePackagesDirPath "${SOURCE_PACKAGES_DIR}" \
    -destination "platform=macOS,arch=${ARCH}" \
    ARCHS="${ARCH}" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

BUILT_APP="${DERIVED_DATA}/Build/Products/Release/glance.app"
if [[ ! -d "${BUILT_APP}" ]]; then
    echo "ERROR: Expected built app at ${BUILT_APP}" >&2
    exit 1
fi

STAGED_APP="${STAGE_DIR}/Glance.app"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
ditto "${BUILT_APP}" "${STAGED_APP}"

glance_sign_app_bundle "${STAGED_APP}" "${GLANCE_RESOLVED_IDENTITY}" "${REPO_ROOT}" "${BUNDLE_ID}"

DESIGNATED_REQ="$(/usr/bin/codesign -dr - "${STAGED_APP}" 2>&1 || true)"
echo "==> Designated requirement:"
echo "    ${DESIGNATED_REQ}"
if [[ "${GLANCE_RESOLVED_IDENTITY}" != "-" && "${DESIGNATED_REQ}" == *"cdhash"* ]]; then
    echo "ERROR: Signed app unexpectedly fell back to a cdhash designated requirement!" >&2
    exit 1
fi

# Stop any running Glance process cleanly before replacing the bundle.
if pgrep -x glance >/dev/null 2>&1; then
    echo "==> Quitting running Glance instance..."
    /usr/bin/osascript -e 'tell application id "com.pearleseed.glance" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! pgrep -x glance >/dev/null 2>&1; then
            break
        fi
        sleep 0.2
    done
    if pgrep -x glance >/dev/null 2>&1; then
        pkill -TERM -x glance || true
        sleep 0.5
    fi
fi

echo "==> Installing to ${INSTALL_PATH}..."
BACKUP_PATH="${INSTALL_PATH}.prev.$$"
NEW_PATH="${INSTALL_PATH}.new.$$"
rm -rf "${NEW_PATH}" "${BACKUP_PATH}"
ditto "${STAGED_APP}" "${NEW_PATH}"
/usr/bin/xattr -cr "${NEW_PATH}" 2>/dev/null || true

if [[ -e "${INSTALL_PATH}" ]]; then
    mv "${INSTALL_PATH}" "${BACKUP_PATH}"
fi
if mv "${NEW_PATH}" "${INSTALL_PATH}"; then
    if [[ -e "${BACKUP_PATH}" ]]; then
        if ! rm -rf "${BACKUP_PATH}" 2>/dev/null; then
            echo "NOTE: Previous bundle at ${BACKUP_PATH} is root-owned; remove it with:" >&2
            echo "      sudo rm -rf \"${BACKUP_PATH}\"" >&2
        fi
    fi
else
    if [[ -e "${BACKUP_PATH}" ]]; then
        mv "${BACKUP_PATH}" "${INSTALL_PATH}"
    fi
    exit 1
fi

/usr/bin/codesign --verify --deep --strict "${INSTALL_PATH}"
echo "==> Installed and verified: ${INSTALL_PATH}"

if [[ "${LAUNCH_AFTER_INSTALL}" -eq 1 ]]; then
    echo "==> Launching ${INSTALL_PATH}..."
    open -a "${INSTALL_PATH}"
fi

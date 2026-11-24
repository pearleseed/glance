#!/usr/bin/env bash
set -euo pipefail

# Build, ad-hoc sign, package, and EdDSA-sign dual-architecture Glance release
# artifacts (`arm64` + `x86_64` DMGs, `SHA256SUMS.txt`, and Sparkle `appcast.xml`)
# ready to upload to https://github.com/pearleseed/glance/releases.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${REPO_ROOT}/glance.xcodeproj"
PBXPROJ="${PROJECT}/project.pbxproj"
INFO_PLIST="${REPO_ROOT}/glance/Info.plist"
OUTPUT_DIR="${REPO_ROOT}/build/release"
SOURCE_PACKAGES_DIR="${REPO_ROOT}/build/SourcePackages"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-com.pearleseed.glance}"
GITHUB_REPO="${GITHUB_REPO:-pearleseed/glance}"
KEY_MIGRATION_BUILD="${KEY_MIGRATION_BUILD:-7}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ED_KEY_FILE="${ED_KEY_FILE:-}"
RELEASE_NOTES="${RELEASE_NOTES:-}"
CLEAN_BUILD=0

# shellcheck source=tools/codesign_common.sh
source "${SCRIPT_DIR}/codesign_common.sh"

usage() {
    cat <<'EOF'
Usage: tools/build_release.sh [options]

Options:
  --clean                      Remove previous DerivedData and build/release artifacts before building
  --output-dir <dir>           Output directory (default: build/release)
  --sign-identity <id|auto|->  codesign identity (default: '-' for ad-hoc; 'auto' picks a stable local cert)
  --sparkle-account <account>  Keychain account for Sparkle EdDSA key (default: com.pearleseed.glance)
  --ed-key-file <path>         Optional Sparkle EdDSA private key file (or '-' for stdin)
  --repo <owner/name>          GitHub repository (default: pearleseed/glance)
  --key-migration-build <num>  Informational update threshold build (default: 7, 0 to disable)
  --release-notes <html|@file> Optional inline HTML release notes
  -h, --help                   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean) CLEAN_BUILD=1; shift ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --sign-identity) SIGN_IDENTITY="$2"; shift 2 ;;
        --sparkle-account) SPARKLE_ACCOUNT="$2"; shift 2 ;;
        --ed-key-file) ED_KEY_FILE="$2"; shift 2 ;;
        --repo) GITHUB_REPO="$2"; shift 2 ;;
        --key-migration-build) KEY_MIGRATION_BUILD="$2"; shift 2 ;;
        --release-notes) RELEASE_NOTES="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

read_pbxproj_value() {
    local key="$1"
    python3 - "$PBXPROJ" "$key" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
key = sys.argv[2]
matches = sorted(set(re.findall(rf"\b{re.escape(key)}\s*=\s*([^;]+);", text)))
if len(matches) != 1:
    sys.exit(f"Expected exactly 1 unique value for {key} in project.pbxproj, found: {matches}")
print(matches[0].strip().strip('"'))
PY
}

VERSION="$(read_pbxproj_value MARKETING_VERSION)"
BUILD="$(read_pbxproj_value CURRENT_PROJECT_VERSION)"
BUNDLE_ID="$(read_pbxproj_value PRODUCT_BUNDLE_IDENTIFIER)"
EXPECTED_FEED_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/appcast.xml"
EXPECTED_PUB_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${INFO_PLIST}")"
CONFIGURED_FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "${INFO_PLIST}")"

if [[ "${CONFIGURED_FEED_URL}" != "${EXPECTED_FEED_URL}" ]]; then
    echo "ERROR: glance/Info.plist SUFeedURL (${CONFIGURED_FEED_URL}) != ${EXPECTED_FEED_URL}" >&2
    exit 1
fi
if [[ -z "${EXPECTED_PUB_KEY}" ]]; then
    echo "ERROR: glance/Info.plist SUPublicEDKey is empty" >&2
    exit 1
fi

echo "==> Building Glance v${VERSION} (build ${BUILD}, ${BUNDLE_ID})"
echo "    Feed URL: ${CONFIGURED_FEED_URL}"
echo "    EdDSA Key: ${EXPECTED_PUB_KEY}"
echo "    Output: ${OUTPUT_DIR}"

if [[ "${CLEAN_BUILD}" -eq 1 ]]; then
    echo "==> Cleaning previous build outputs and DerivedData..."
    rm -rf "${OUTPUT_DIR}" \
        "${REPO_ROOT}/build/DerivedData-arm64" \
        "${REPO_ROOT}/build/DerivedData-x86_64" \
        "${REPO_ROOT}/build/DerivedData-local-"* \
        "${REPO_ROOT}/build/local-"*
fi

mkdir -p "${OUTPUT_DIR}"

sign_app_bundle() {
    local app_path="$1"
    glance_sign_app_bundle "${app_path}" "${SIGN_IDENTITY}" "${REPO_ROOT}" "${BUNDLE_ID}"
}

build_and_package_arch() {
    local arch="$1"
    local arch_dir="${OUTPUT_DIR}/${arch}"
    local arch_derived="${REPO_ROOT}/build/DerivedData-${arch}"
    local app_dst="${arch_dir}/Glance.app"
    local dmg_path="${OUTPUT_DIR}/Glance-${VERSION}-${arch}.dmg"
    local stage_dir

    echo "==> Building ${arch} Release..."
    xcodebuild \
        -project "${PROJECT}" \
        -scheme glance \
        -configuration Release \
        -derivedDataPath "${arch_derived}" \
        -clonedSourcePackagesDirPath "${SOURCE_PACKAGES_DIR}" \
        -destination "generic/platform=macOS" \
        ARCHS="${arch}" \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        build >/dev/null

    local built_app="${arch_derived}/Build/Products/Release/glance.app"
    if [[ ! -d "${built_app}" ]]; then
        echo "ERROR: Expected built app at ${built_app}" >&2
        exit 1
    fi

    rm -rf "${arch_dir}"
    mkdir -p "${arch_dir}"
    ditto "${built_app}" "${app_dst}"

    sign_app_bundle "${app_dst}"

    # Verify architecture, bundled universal PAM module, and Info.plist metadata.
    local exec_archs
    exec_archs="$(lipo -archs "${app_dst}/Contents/MacOS/glance")"
    if [[ "${exec_archs}" != "${arch}" ]]; then
        echo "ERROR: Expected arch ${arch} for glance executable, got: ${exec_archs}" >&2
        exit 1
    fi

    local pam_archs
    pam_archs="$(lipo -archs "${app_dst}/Contents/Helpers/pam_glance.so")"
    if [[ "${pam_archs}" != *"arm64"* || "${pam_archs}" != *"x86_64"* ]]; then
        echo "ERROR: Expected universal pam_glance.so, got: ${pam_archs}" >&2
        exit 1
    fi

    local app_plist="${app_dst}/Contents/Info.plist"
    local actual_pub_key actual_feed actual_ver actual_build
    actual_pub_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${app_plist}")"
    actual_feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "${app_plist}")"
    actual_ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app_plist}")"
    actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${app_plist}")"

    if [[ "${actual_pub_key}" != "${EXPECTED_PUB_KEY}" || \
          "${actual_feed}" != "${EXPECTED_FEED_URL}" || \
          "${actual_ver}" != "${VERSION}" || \
          "${actual_build}" != "${BUILD}" ]]; then
        echo "ERROR: Built Info.plist metadata mismatch in ${app_plist}" >&2
        exit 1
    fi

    echo "==> Packaging ${dmg_path}..."
    stage_dir="$(mktemp -d)"
    trap 'rm -rf "${stage_dir}"' RETURN
    ditto "${app_dst}" "${stage_dir}/Glance.app"
    ln -s /Applications "${stage_dir}/Applications"
    rm -f "${dmg_path}"
    hdiutil create \
        -volname "Glance ${VERSION}" \
        -srcfolder "${stage_dir}" \
        -ov \
        -format UDZO \
        "${dmg_path}" >/dev/null
    rm -rf "${stage_dir}"
    trap - RETURN
}

build_and_package_arch "arm64"
build_and_package_arch "x86_64"

ARM64_DMG="${OUTPUT_DIR}/Glance-${VERSION}-arm64.dmg"
X86_64_DMG="${OUTPUT_DIR}/Glance-${VERSION}-x86_64.dmg"

echo "==> Generating SHA256SUMS.txt..."
(
    cd "${OUTPUT_DIR}"
    shasum -a 256 "$(basename "${ARM64_DMG}")" "$(basename "${X86_64_DMG}")" > SHA256SUMS.txt
)

echo "==> Signing DMGs and generating appcast.xml..."
APPCAST_ARGS=(
    --version "${VERSION}"
    --build "${BUILD}"
    --arm64-dmg "${ARM64_DMG}"
    --x86-64-dmg "${X86_64_DMG}"
    --output "${OUTPUT_DIR}/appcast.xml"
    --repo "${GITHUB_REPO}"
    --account "${SPARKLE_ACCOUNT}"
    --key-migration-build "${KEY_MIGRATION_BUILD}"
    --info-plist "${INFO_PLIST}"
)
if [[ -n "${ED_KEY_FILE}" ]]; then
    APPCAST_ARGS+=(--ed-key-file "${ED_KEY_FILE}")
fi
if [[ -n "${RELEASE_NOTES}" ]]; then
    APPCAST_ARGS+=(--release-notes "${RELEASE_NOTES}")
fi

SPARKLE_BIN="${SOURCE_PACKAGES_DIR}/artifacts/sparkle/Sparkle/bin" \
    python3 "${SCRIPT_DIR}/generate_appcast.py" "${APPCAST_ARGS[@]}"

echo ""
echo "==> Release artifacts ready in ${OUTPUT_DIR}:"
ls -lh "${ARM64_DMG}" "${X86_64_DMG}" "${OUTPUT_DIR}/SHA256SUMS.txt" "${OUTPUT_DIR}/appcast.xml"

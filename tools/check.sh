#!/usr/bin/env bash
set -euo pipefail

# Unified verification runner for Glance.
# Compiles and runs standalone Swift self-test suites using the same isolation
# and visibility flags as the Xcode app target, plus Xcode Debug build,
# GlanceTests (xcodebuild test), SwiftLint, swift-format, Python tests,
# PAM C syntax, shell syntax, and optional website checks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

SWIFT_VERSION="6"
RUN_BUILD=1
RUN_LINT=1
SKIP_INTEGRATION=0
WITH_WEBSITE=0
LIST_ONLY=0
SELECTED_SUITES=()

# Single centralized registry of all 13 Swift self-test suites.
# Format: "name|kind|entry_mode|source1 source2 ..."
#   kind:       "offline" | "integration"
#   entry_mode: "library" (-parse-as-library for @main) | "script"
SUITE_REGISTRY=(
    "enrollment_storage|offline|library|\
glance/Recognition/FaceEmbedder.swift \
glance/Recognition/FaceEnrollmentStore.swift \
glance/Security/KeychainManager.swift \
glance/Security/SecureFaceStore.swift \
glance/Security/SecureCredentialManager.swift \
tools/enrollment_storage_selftest.swift"

    "onboarding_flow|offline|library|\
glance/Core/GlobalHotKey.swift \
glance/Core/NotificationObserverBox.swift \
glance/AppLock/AppLockBlacklist.swift \
glance/AppLock/LockedApp.swift \
glance/AppLock/RelockPolicy.swift \
glance/Settings/SettingsModels.swift \
glance/Settings/GlanceSettings.swift \
glance/Camera/SharedCoreImageContext.swift \
glance/Camera/CameraFrame.swift \
glance/Camera/CameraCaptureSession.swift \
glance/Camera/CameraDeviceCatalog.swift \
glance/Camera/CameraManager.swift \
glance/Camera/CameraPreviewView.swift \
glance/Liveness/LandmarkGeometry.swift \
glance/Liveness/DeviceBezelDetector.swift \
glance/Liveness/GlareFaceRegion.swift \
glance/Liveness/GlareCue.swift \
glance/Liveness/GlareCueExtractor.swift \
glance/Liveness/LivenessFeatures.swift \
glance/Liveness/GeometryLiveness.swift \
glance/Liveness/LivenessScoring.swift \
glance/Liveness/LivenessCues.swift \
glance/Recognition/FaceEmbedder.swift \
glance/Recognition/FaceDetector.swift \
glance/Recognition/FaceAligner.swift \
glance/Recognition/ArcFaceEmbedder.swift \
glance/Recognition/FaceRecognitionPipeline.swift \
glance/Recognition/FaceEnrollmentStore.swift \
glance/Security/KeychainManager.swift \
glance/Security/SecureFaceStore.swift \
glance/Security/SecureCredentialManager.swift \
glance/Unlock/LockMonitor.swift \
glance/Unlock/KeystrokeInjector.swift \
glance/NotchOverlay/NotchPanelStyle.swift \
glance/NotchOverlay/DisplayContext.swift \
glance/NotchOverlay/NotchGeometry.swift \
glance/NotchOverlay/NotchGeometry+Screen.swift \
glance/NotchOverlay/NotchShape.swift \
glance/NotchOverlay/NotchSkyLight.swift \
glance/NotchOverlay/NotchWindow.swift \
glance/NotchOverlay/NotchWindowController.swift \
glance/NotchOverlay/AnimationTint.swift \
glance/NotchOverlay/ScanAnimationView.swift \
glance/NotchOverlay/MinimalUnlockView.swift \
glance/NotchOverlay/NotchOverlayView.swift \
glance/NotchOverlay/NotchOverlayController.swift \
glance/Onboarding/OnboardingStep.swift \
glance/Onboarding/GlanceTheme.swift \
glance/Onboarding/OnboardingMetrics.swift \
glance/Onboarding/EnrollmentPoseEvaluator.swift \
glance/Onboarding/EnrollmentRingAnimationState.swift \
glance/Onboarding/EnrollmentRingView.swift \
glance/Onboarding/EnrollmentDirectionSweep.swift \
glance/Onboarding/EnrollmentSweepWindowController.swift \
glance/Onboarding/LoopingVideoView.swift \
glance/Onboarding/AnimatedCheckmark.swift \
glance/Onboarding/OnboardingControls.swift \
glance/Onboarding/OnboardingStepViews.swift \
glance/Onboarding/OnboardingEnrollmentStepViews.swift \
glance/Onboarding/OnboardingNotchView.swift \
glance/Onboarding/OnboardingController.swift \
glance/Onboarding/OnboardingController+Flow.swift \
glance/Onboarding/OnboardingController+Enrollment.swift \
tools/onboarding_flow_selftest.swift"

    "applock|offline|library|\
glance/AppLock/RelockPolicy.swift \
glance/AppLock/AppLockBlacklist.swift \
glance/AppLock/AppLockEngine.swift \
tools/applock_selftest.swift"

    "glare_mask|offline|library|\
glance/Camera/SharedCoreImageContext.swift \
glance/Camera/CameraFrame.swift \
glance/Liveness/GlareCue.swift \
glance/Liveness/GlareFaceRegion.swift \
glance/Liveness/GlareCueExtractor.swift \
tools/glare_mask_selftest.swift"

    "liveness|offline|library|\
glance/Liveness/LandmarkGeometry.swift \
glance/Liveness/GeometryLiveness.swift \
glance/Liveness/GlareCue.swift \
glance/Liveness/LivenessCues.swift \
glance/Liveness/LivenessScoring.swift \
glance/Liveness/LivenessAnalyzer.swift \
tools/liveness_selftest.swift"

    "night_boost|offline|library|\
glance/Core/NotificationObserverBox.swift \
glance/NightBoost/SceneLuminance.swift \
glance/Camera/SharedCoreImageContext.swift \
glance/NightBoost/LowLightEnhancer.swift \
glance/NightBoost/DisplayBrightnessControl.swift \
glance/NightBoost/SceneIlluminator.swift \
tools/night_boost_selftest.swift"

    "notch_ui|offline|library|\
glance/NotchOverlay/NotchPanelStyle.swift \
glance/NotchOverlay/NotchGeometry.swift \
glance/NotchOverlay/AnimationTint.swift \
tools/notch_ui_selftest.swift"

    "performance|offline|library|\
glance/Core/ObservationWaiter.swift \
glance/AppLock/RelockPolicy.swift \
glance/AppLock/AppLockBlacklist.swift \
glance/AppLock/LockedApp.swift \
glance/AppLock/InstalledApps.swift \
glance/Liveness/LandmarkGeometry.swift \
glance/Liveness/GeometryLiveness.swift \
glance/Liveness/GlareCue.swift \
glance/Liveness/GlareFaceRegion.swift \
glance/Liveness/GlareCueExtractor.swift \
glance/Liveness/LivenessCues.swift \
glance/Liveness/LivenessScoring.swift \
glance/Liveness/LivenessAnalyzer.swift \
glance/Camera/SharedCoreImageContext.swift \
glance/Camera/CameraFrame.swift \
glance/Recognition/FaceAligner.swift \
glance/Recognition/FaceDetector.swift \
glance/Recognition/FaceEmbedder.swift \
glance/Recognition/ArcFaceEmbedder.swift \
glance/Recognition/FaceRecognitionPipeline.swift \
glance/Recognition/FaceEnrollmentStore.swift \
glance/Security/KeychainManager.swift \
glance/Security/SecureCredentialManager.swift \
glance/Security/SecureFaceStore.swift \
glance/NotchOverlay/NotchPanelStyle.swift \
glance/NotchOverlay/NotchGeometry.swift \
glance/NotchOverlay/NotchShape.swift \
tools/performance_selftest.swift"

    "security|offline|library|\
glance/Core/NotificationObserverBox.swift \
glance/Liveness/LandmarkGeometry.swift \
glance/Liveness/DeviceBezelDetector.swift \
glance/Camera/SharedCoreImageContext.swift \
glance/Camera/CameraFrame.swift \
glance/Recognition/FaceDetector.swift \
glance/Recognition/FaceAligner.swift \
glance/Recognition/FaceEmbedder.swift \
glance/Recognition/ArcFaceEmbedder.swift \
glance/Recognition/FaceRecognitionPipeline.swift \
glance/Recognition/FaceEnrollmentStore.swift \
glance/Security/SecureFaceStore.swift \
glance/Security/SecureCredentialManager.swift \
glance/Security/KeychainManager.swift \
glance/Unlock/LockMonitor.swift \
glance/Unlock/KeystrokeInjector.swift \
tools/security_selftest.swift"

    "settings_window|offline|library|\
tools/settings_window_selftest.swift \
glance/Settings/SettingsMetrics.swift \
glance/Settings/Components/SettingsWindowHelpers.swift"

    "unlock_reliability|offline|library|\
glance/Core/NotificationObserverBox.swift \
glance/Settings/SettingsModels.swift \
glance/Recognition/FaceEmbedder.swift \
glance/Recognition/FaceEnrollmentStore.swift \
glance/Security/KeychainManager.swift \
glance/Security/SecureFaceStore.swift \
glance/Security/SecureCredentialManager.swift \
glance/Unlock/LockMonitor.swift \
glance/Unlock/KeystrokeInjector.swift \
glance/NotchOverlay/NotchPanelStyle.swift \
glance/NotchOverlay/NotchGeometry.swift \
tools/unlock_reliability_selftest.swift"

    "sudo_protocol|integration|library|\
glance/SudoAuth/SudoAuthProtocol.swift \
glance/SudoAuth/SudoAuthServer.swift \
tools/sudo_protocol_selftest.swift"

    "sudo_installer|integration|library|\
glance/SudoAuth/SudoPAMCommandBuilder.swift \
glance/SudoAuth/SudoPAMStatus.swift \
tools/sudo_installer_selftest.swift"
)

usage() {
    cat <<'EOF'
Usage: tools/check.sh [options]

Options:
  --list                        List all registered suites and their kind (offline/integration)
  --suite <name>[,<name>...]    Run only the specified Swift suite(s)
  --no-build                    Skip the Xcode Debug build and GlanceTests (xcodebuild test)
  --no-lint                     Skip SwiftLint, swift-format, PAM C syntax, and bash syntax checks
  --skip-integration            Compile-check integration suites (sudo_protocol, sudo_installer) without executing
  --swift-version <5|6>         Swift language version for swiftc and xcodebuild (default: 6)
  --with-website                Also run bun test, bun run lint, and bunx tsc --noEmit in website/
  -h, --help                    Show this help
EOF
}

find_suite_entry() {
    local target="$1"
    local entry s_name
    for entry in "${SUITE_REGISTRY[@]}"; do
        s_name="${entry%%|*}"
        if [[ "${s_name}" == "${target}" ]]; then
            printf '%s\n' "${entry}"
            return 0
        fi
    done
    return 1
}

add_selected_suites() {
    local raw="$1"
    local item existing dup
    local items=()
    if [[ -z "${raw}" ]]; then
        echo "ERROR: --suite cannot be empty." >&2
        exit 2
    fi

    # Split strictly on commas while rejecting empty segments (e.g. "a," or ",a").
    local IFS=','
    read -r -a items <<< "${raw}"
    if [[ "${raw}" == *, ]] || [[ "${raw}" == ,* ]]; then
        echo "ERROR: Invalid empty suite name in --suite '${raw}'." >&2
        exit 2
    fi

    for item in "${items[@]}"; do
        if [[ -z "${item}" ]]; then
            echo "ERROR: Invalid empty suite name in --suite '${raw}'." >&2
            exit 2
        fi
        if ! find_suite_entry "${item}" >/dev/null; then
            echo "ERROR: Unknown suite '${item}'. Run './tools/check.sh --list' to see valid suites." >&2
            exit 2
        fi
        dup=0
        if [[ ${#SELECTED_SUITES[@]} -gt 0 ]]; then
            for existing in "${SELECTED_SUITES[@]}"; do
                if [[ "${existing}" == "${item}" ]]; then
                    dup=1
                    break
                fi
            done
        fi
        if [[ "${dup}" -eq 0 ]]; then
            SELECTED_SUITES+=("${item}")
        fi
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)
            LIST_ONLY=1
            shift
            ;;
        --suite)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --suite requires an argument." >&2
                exit 2
            fi
            add_selected_suites "$2"
            shift 2
            ;;
        --suite=*)
            add_selected_suites "${1#--suite=}"
            shift
            ;;
        --no-build)
            RUN_BUILD=0
            shift
            ;;
        --no-lint)
            RUN_LINT=0
            shift
            ;;
        --skip-integration)
            SKIP_INTEGRATION=1
            shift
            ;;
        --swift-version)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --swift-version requires an argument (5 or 6)." >&2
                exit 2
            fi
            SWIFT_VERSION="$2"
            shift 2
            ;;
        --swift-version=*)
            SWIFT_VERSION="${1#--swift-version=}"
            shift
            ;;
        --with-website)
            WITH_WEBSITE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "${SWIFT_VERSION}" in
    5|6) ;;
    *)
        echo "ERROR: Unsupported --swift-version '${SWIFT_VERSION}'. Expected 5 or 6." >&2
        exit 2
        ;;
esac

if [[ "${LIST_ONLY}" -eq 1 ]]; then
    for entry in "${SUITE_REGISTRY[@]}"; do
        IFS='|' read -r s_name s_kind _ <<< "${entry}"
        printf "%-20s %s\n" "${s_name}" "${s_kind}"
    done
    exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/glance-check.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT
mkdir -p "${TMP_DIR}/bin"

HOST_ARCH="$(uname -m)"

# Mirror the Xcode target's concurrency & import visibility settings.
# Under Swift 5 mode, Xcode's SWIFT_APPROACHABLE_CONCURRENCY = YES also passes
# DisableOutwardActorInference, InferSendableFromCaptures, and
# GlobalActorIsolatedTypesUsability (which are always-on in Swift 6 mode).
SWIFTC_FLAGS=(
    -swift-version "${SWIFT_VERSION}"
    -target "${HOST_ARCH}-apple-macos14.0"
    -default-isolation MainActor
    -enable-upcoming-feature MemberImportVisibility
    -enable-upcoming-feature InferIsolatedConformances
    -enable-upcoming-feature NonisolatedNonsendingByDefault
    -O
)
if [[ "${SWIFT_VERSION}" == "5" ]]; then
    SWIFTC_FLAGS+=(
        -enable-bare-slash-regex
        -enable-upcoming-feature DisableOutwardActorInference
        -enable-upcoming-feature InferSendableFromCaptures
        -enable-upcoming-feature GlobalActorIsolatedTypesUsability
    )
fi

SUMMARY_ROWS=()
HAS_FAILURE=0

record_result() {
    local step="$1"
    local build_status="$2"
    local run_status="$3"
    SUMMARY_ROWS+=("${step}|${build_status}|${run_status}")
    if [[ "${build_status}" == "FAIL" || "${run_status}" == "FAIL" ]]; then
        HAS_FAILURE=1
    fi
}

run_check_step() {
    local step_name="$1"
    shift
    if "$@"; then
        record_result "${step_name}" "-" "PASS"
    else
        record_result "${step_name}" "-" "FAIL"
    fi
}

run_in_website() {
    (cd "${REPO_ROOT}/website" && "$@")
}

# 1. Xcode Debug build & GlanceTests (xcodebuild test)
if [[ "${RUN_BUILD}" -eq 1 ]]; then
    echo "==> [build] Building Glance Debug (Swift ${SWIFT_VERSION}, ${HOST_ARCH})..."
    XCODE_LOG="${TMP_DIR}/xcodebuild.log"
    if xcodebuild \
        -project "${REPO_ROOT}/glance.xcodeproj" \
        -scheme glance \
        -configuration Debug \
        -derivedDataPath "${TMP_DIR}/DerivedData" \
        -destination "platform=macOS,arch=${HOST_ARCH}" \
        ARCHS="${HOST_ARCH}" \
        ONLY_ACTIVE_ARCH=YES \
        SWIFT_VERSION="${SWIFT_VERSION}.0" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        build >"${XCODE_LOG}" 2>&1; then
        echo "    PASS: xcodebuild Debug succeeded."
        record_result "xcode_debug_build" "PASS" "-"
    else
        echo "    FAIL: xcodebuild Debug failed. Build log:" >&2
        cat "${XCODE_LOG}" >&2
        record_result "xcode_debug_build" "FAIL" "-"
    fi

    echo "==> [test] Running GlanceTests (Swift ${SWIFT_VERSION}, ${HOST_ARCH})..."
    XCODE_TEST_LOG="${TMP_DIR}/xcodebuild-test.log"
    if xcodebuild \
        -project "${REPO_ROOT}/glance.xcodeproj" \
        -scheme glance \
        -configuration Debug \
        -derivedDataPath "${TMP_DIR}/DerivedData" \
        -destination "platform=macOS,arch=${HOST_ARCH}" \
        ARCHS="${HOST_ARCH}" \
        ONLY_ACTIVE_ARCH=YES \
        SWIFT_VERSION="${SWIFT_VERSION}.0" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        test >"${XCODE_TEST_LOG}" 2>&1; then
        echo "    PASS: GlanceTests succeeded."
        record_result "xcode_test" "PASS" "PASS"
    else
        echo "    FAIL: GlanceTests failed. Test log:" >&2
        cat "${XCODE_TEST_LOG}" >&2
        if grep -q "Testing started" "${XCODE_TEST_LOG}" 2>/dev/null; then
            record_result "xcode_test" "PASS" "FAIL"
        else
            record_result "xcode_test" "FAIL" "-"
        fi
    fi
else
    record_result "xcode_debug_build" "SKIP" "-"
    record_result "xcode_test" "SKIP" "SKIP"
fi

# 2. Swift self-test suites
SUITES_TO_RUN=()
if [[ ${#SELECTED_SUITES[@]} -gt 0 ]]; then
    SUITES_TO_RUN=("${SELECTED_SUITES[@]}")
else
    for entry in "${SUITE_REGISTRY[@]}"; do
        SUITES_TO_RUN+=("${entry%%|*}")
    done
fi

for suite_name in "${SUITES_TO_RUN[@]}"; do
    entry="$(find_suite_entry "${suite_name}")"
    IFS='|' read -r s_name s_kind s_mode s_sources_str <<< "${entry}"
    IFS=' ' read -r -a suite_sources <<< "${s_sources_str}"

    compile_flags=("${SWIFTC_FLAGS[@]}")
    if [[ "${s_mode}" == "library" ]]; then
        compile_flags+=(-parse-as-library)
    fi

    bin_path="${TMP_DIR}/bin/${s_name}"
    echo "==> [suite] ${s_name} (${s_kind}, Swift ${SWIFT_VERSION})..."
    if swiftc "${compile_flags[@]}" -o "${bin_path}" "${suite_sources[@]}"; then
        if [[ "${s_kind}" == "integration" && "${SKIP_INTEGRATION}" -eq 1 ]]; then
            echo "    SKIP (compile-only): ${s_name}"
            record_result "${s_name}" "PASS" "SKIP (compile-only)"
        elif "${bin_path}"; then
            record_result "${s_name}" "PASS" "PASS"
        else
            echo "    FAIL: ${s_name} runtime check failed." >&2
            record_result "${s_name}" "PASS" "FAIL"
        fi
    else
        echo "    FAIL: ${s_name} failed to compile." >&2
        record_result "${s_name}" "FAIL" "-"
    fi
done

# 3. Python unit tests (run in full mode when no --suite filter is specified)
if [[ ${#SELECTED_SUITES[@]} -eq 0 ]]; then
    echo "==> [python] Running Python unit tests..."
    PYTHON_CMD=(python3 -m unittest discover -s tools -p 'test_*.py')
    BUILT_SPARKLE_BIN="${TMP_DIR}/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
    if [[ -z "${SPARKLE_BIN:-}" && -x "${BUILT_SPARKLE_BIN}/sign_update" ]]; then
        PYTHON_CMD=(env "SPARKLE_BIN=${BUILT_SPARKLE_BIN}" "${PYTHON_CMD[@]}")
    fi
    run_check_step "python_tests" "${PYTHON_CMD[@]}"
fi

# 4. Lint & static syntax checks
if [[ "${RUN_LINT}" -eq 1 ]]; then
    echo "==> [lint] Running SwiftLint..."
    run_check_step "swiftlint" swiftlint lint --strict --quiet

    echo "==> [lint] Running swift-format..."
    run_check_step "swift_format" xcrun swift-format lint --strict -r glance tools GlanceTests

    echo "==> [lint] Checking PAM C syntax..."
    run_check_step "pam_c_syntax" \
        /usr/bin/xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
        -Wall -Wextra -Werror -fsyntax-only "${REPO_ROOT}/sudo-support/pam_glance.c"

    echo "==> [lint] Checking shell script syntax..."
    run_check_step "shell_syntax" bash -n "${REPO_ROOT}"/tools/*.sh "${REPO_ROOT}"/sudo-support/*.sh
else
    record_result "swiftlint" "-" "SKIP"
    record_result "swift_format" "-" "SKIP"
    record_result "pam_c_syntax" "-" "SKIP"
    record_result "shell_syntax" "-" "SKIP"
fi

# 5. Optional website checks
if [[ "${WITH_WEBSITE}" -eq 1 ]]; then
    echo "==> [website] Running bun test..."
    run_check_step "website_tests" run_in_website bun test

    echo "==> [website] Running bun run lint..."
    run_check_step "website_lint" run_in_website bun run lint

    echo "==> [website] Running bunx tsc --noEmit..."
    run_check_step "website_typecheck" run_in_website bunx tsc --noEmit
fi

# 6. Summary table
echo ""
printf "%-20s | %-5s | %s\n" "Step/Suite" "Build" "Run"
printf "%-20s-+-%-5s-+-%s\n" "--------------------" "-----" "-------------------"
for row in "${SUMMARY_ROWS[@]}"; do
    IFS='|' read -r r_step r_build r_run <<< "${row}"
    printf "%-20s | %-5s | %s\n" "${r_step}" "${r_build}" "${r_run}"
done

if [[ "${HAS_FAILURE}" -ne 0 ]]; then
    echo ""
    echo "OVERALL: FAIL" >&2
    exit 1
fi

echo ""
echo "OVERALL: PASS"

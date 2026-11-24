#!/usr/bin/env bash
#
# Self-contained privileged setup/repair/uninstall helper for Glance Face-for-sudo.
# Uses exclusively native macOS system binaries (zero Xcode CLT dependencies).
#

set -euo pipefail
umask 022
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

readonly EXPECTED_BUNDLE_ID="com.pearleseed.glance"
readonly PAM_MODULE_NAME="pam_glance.so"
readonly TRUSTED_PAM_DEST="/usr/local/lib/pam/pam_glance.so"
readonly PAM_AUTH_LINE="auth       sufficient     ${TRUSTED_PAM_DEST}"

STAGING_APP=""
BACKUP_APP=""
CASING_TMP=""
PAM_TMP=""
CONF_TMP=""
SEED_TMP=""
ORIGINAL_APP_PATH=""
FINAL_APP_PATH=""
SWAP_IN_PROGRESS=0
CASING_RENAME_IN_PROGRESS=0

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup_on_exit() {
    local exit_code=$?
    set +e

    if [[ "${exit_code}" -ne 0 ]]; then
        if [[ "${SWAP_IN_PROGRESS}" -eq 1 && -n "${BACKUP_APP}" && -d "${BACKUP_APP}" && -n "${ORIGINAL_APP_PATH}" && ! -e "${ORIGINAL_APP_PATH}" && ! -e "${FINAL_APP_PATH}" ]]; then
            /bin/mv -f "${BACKUP_APP}" "${ORIGINAL_APP_PATH}" >/dev/null 2>&1 || true
        fi
        if [[ "${CASING_RENAME_IN_PROGRESS}" -eq 1 && -n "${CASING_TMP}" && -d "${CASING_TMP}" && -n "${ORIGINAL_APP_PATH}" && ! -e "${ORIGINAL_APP_PATH}" && ! -e "${FINAL_APP_PATH}" ]]; then
            /bin/mv -f "${CASING_TMP}" "${ORIGINAL_APP_PATH}" >/dev/null 2>&1 || true
        fi
    fi

    if [[ -n "${STAGING_APP}" && ( -e "${STAGING_APP}" || -L "${STAGING_APP}" ) ]]; then
        /bin/rm -rf "${STAGING_APP}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${BACKUP_APP}" && ( -e "${BACKUP_APP}" || -L "${BACKUP_APP}" ) ]]; then
        if [[ -z "${FINAL_APP_PATH}" || -e "${FINAL_APP_PATH}" || ( -n "${ORIGINAL_APP_PATH}" && -e "${ORIGINAL_APP_PATH}" ) ]]; then
            /bin/rm -rf "${BACKUP_APP}" >/dev/null 2>&1 || true
        fi
    fi
    if [[ -n "${CASING_TMP}" && ( -e "${CASING_TMP}" || -L "${CASING_TMP}" ) ]]; then
        if [[ -n "${FINAL_APP_PATH}" && -e "${FINAL_APP_PATH}" ]]; then
            /bin/rm -rf "${CASING_TMP}" >/dev/null 2>&1 || true
        fi
    fi
    if [[ -n "${PAM_TMP}" && ( -e "${PAM_TMP}" || -L "${PAM_TMP}" ) ]]; then
        /bin/rm -f "${PAM_TMP}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${CONF_TMP}" && ( -e "${CONF_TMP}" || -L "${CONF_TMP}" ) ]]; then
        /bin/rm -f "${CONF_TMP}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${SEED_TMP}" && ( -e "${SEED_TMP}" || -L "${SEED_TMP}" ) ]]; then
        /bin/rm -f "${SEED_TMP}" >/dev/null 2>&1 || true
    fi

    return "${exit_code}"
}
trap cleanup_on_exit EXIT

strip_trailing_slashes() {
    local p="$1"
    # Trailing "/" causes [[ -L ... ]] to dereference a symlinked directory; strip it first.
    while [[ "${p}" != "/" && "${p}" == */ ]]; do
        p="${p%/}"
    done
    printf '%s' "${p}"
}

join_path() {
    local dir="$1"
    local name="$2"
    if [[ "${dir}" == "/" ]]; then
        printf '/%s' "${name}"
    else
        printf '%s/%s' "${dir}" "${name}"
    fi
}

# Scans /bin/ls -1 so case-insensitive APFS never hides wrong on-disk casing (e.g. glance.app).
find_entry_in_dir() {
    local dir="$1"
    local target="$2"
    if [[ ! -d "${dir}" || -L "${dir}" ]]; then
        return 0
    fi
    [[ -r "${dir}" ]] || die "Directory is not readable: ${dir}"

    local exact_match=""
    local case_match=""
    local entry=""
    local old_nocasematch=0
    if shopt -q nocasematch; then
        old_nocasematch=1
    fi

    while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        if [[ "${entry}" == "${target}" ]]; then
            exact_match="${entry}"
            break
        fi
        shopt -s nocasematch
        if [[ "${entry}" == "${target}" && -z "${case_match}" ]]; then
            case_match="${entry}"
        fi
        if [[ "${old_nocasematch}" -eq 0 ]]; then
            shopt -u nocasematch
        fi
    done < <(/bin/ls -1 "${dir}")

    if [[ "${old_nocasematch}" -eq 0 ]]; then
        shopt -u nocasematch
    fi

    if [[ -n "${exact_match}" ]]; then
        printf '%s' "${exact_match}"
    elif [[ -n "${case_match}" ]]; then
        printf '%s' "${case_match}"
    fi
}

find_existing_app_name() {
    find_entry_in_dir "$1" "Glance.app"
}

run_chown_tree() {
    local owner="$1"
    local target="$2"
    if [[ -z "${TEST_ROOT}" ]]; then
        /usr/sbin/chown -RP "${owner}" "${target}"
    fi
}

install_dir() {
    local mode="$1"
    local target="$2"
    if [[ -z "${TEST_ROOT}" ]]; then
        /usr/bin/install -d -o root -g wheel -m "${mode}" "${target}"
    else
        /usr/bin/install -d -m "${mode}" "${target}"
    fi
}

install_file() {
    local mode="$1"
    local src="$2"
    local dst="$3"
    if [[ -z "${TEST_ROOT}" ]]; then
        /usr/bin/install -o root -g wheel -m "${mode}" "${src}" "${dst}"
    else
        /usr/bin/install -m "${mode}" "${src}" "${dst}"
    fi
}

read_bundle_id() {
    local bundle="$1"
    local contents="${bundle}/Contents"
    local plist="${contents}/Info.plist"
    [[ ! -L "${contents}" && -d "${contents}" ]] || return 1
    [[ ! -L "${plist}" && -f "${plist}" ]] || return 1
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}" 2>/dev/null
}

validate_glance_bundle() {
    local bundle_raw="$1"
    local require_pam_helper="$2"
    local bundle=""
    bundle="$(strip_trailing_slashes "${bundle_raw}")"

    [[ -n "${bundle}" ]] || die "Bundle path cannot be empty."
    [[ ! -L "${bundle}" ]] || die "Refusing symlinked app bundle: ${bundle}"
    [[ -d "${bundle}" ]] || die "App bundle directory not found: ${bundle}"

    local contents="${bundle}/Contents"
    [[ ! -L "${contents}" && -d "${contents}" ]] || die "Missing or symlinked Contents directory in ${bundle}."

    local plist="${contents}/Info.plist"
    [[ ! -L "${plist}" && -f "${plist}" ]] || die "Missing or symlinked Contents/Info.plist in ${bundle}."

    local macos_dir="${contents}/MacOS"
    [[ ! -L "${macos_dir}" && -d "${macos_dir}" ]] || die "Missing or symlinked Contents/MacOS directory in ${bundle}."

    local executable="${macos_dir}/glance"
    [[ ! -L "${executable}" && -f "${executable}" && -x "${executable}" ]] || die "Missing, symlinked, or non-executable Contents/MacOS/glance in ${bundle}."

    if [[ "${require_pam_helper}" -eq 1 ]]; then
        local helpers_dir="${contents}/Helpers"
        [[ ! -L "${helpers_dir}" && -d "${helpers_dir}" ]] || die "Missing or symlinked Contents/Helpers directory in ${bundle}."

        local helper_so="${helpers_dir}/${PAM_MODULE_NAME}"
        [[ ! -L "${helper_so}" && -f "${helper_so}" && -s "${helper_so}" ]] || die "Missing, symlinked, or empty Contents/Helpers/${PAM_MODULE_NAME} in ${bundle}."
    fi

    local bundle_id=""
    if ! bundle_id="$(read_bundle_id "${bundle}")"; then
        die "Failed to read CFBundleIdentifier from ${plist}."
    fi
    if [[ "${bundle_id}" != "${EXPECTED_BUNDLE_ID}" ]]; then
        die "Unexpected CFBundleIdentifier '${bundle_id}' in ${bundle} (expected '${EXPECTED_BUNDLE_ID}')."
    fi
}

validate_pam_source() {
    local pam_raw="$1"
    local pam=""
    pam="$(strip_trailing_slashes "${pam_raw}")"

    [[ -n "${pam}" ]] || die "--pam-source is required."
    [[ ! -L "${pam}" ]] || die "Refusing symlinked --pam-source: ${pam}"
    [[ -e "${pam}" ]] || die "--pam-source does not exist: ${pam}"
    [[ -f "${pam}" ]] || die "--pam-source is not a regular file: ${pam}"
    [[ -s "${pam}" ]] || die "--pam-source is empty: ${pam}"
    [[ -r "${pam}" ]] || die "--pam-source is not readable: ${pam}"
    PAM_SOURCE="${pam}"
}

harden_installed_app() {
    local app_path="$1"
    /usr/bin/xattr -drs com.apple.quarantine "${app_path}" 2>/dev/null || true
    run_chown_tree "root:wheel" "${app_path}"
    /bin/chmod -RP go-w "${app_path}"
}

install_or_normalize_app() {
    [[ ! -L "${APPS_DIR}" ]] || die "Refusing symlinked Applications directory: ${APPS_DIR}"
    if [[ -e "${APPS_DIR}" && ! -d "${APPS_DIR}" ]]; then
        die "Applications path exists and is not a directory: ${APPS_DIR}"
    fi

    local existing_name=""
    if [[ -d "${APPS_DIR}" ]]; then
        existing_name="$(find_existing_app_name "${APPS_DIR}")"
        if [[ -n "${existing_name}" ]]; then
            local existing_path=""
            existing_path="$(join_path "${APPS_DIR}" "${existing_name}")"
            [[ ! -L "${existing_path}" ]] || die "Refusing symlinked application bundle: ${existing_path}"
            [[ -d "${existing_path}" ]] || die "Existing application path is not a directory: ${existing_path}"
        fi
    fi

    FINAL_APP_PATH="$(join_path "${APPS_DIR}" "Glance.app")"

    if [[ "${APP_SOURCE_SET}" -eq 1 ]]; then
        local src=""
        src="$(strip_trailing_slashes "${APP_SOURCE}")"
        [[ "${src}" == /* ]] || die "--app-source must be an absolute path: ${src}"
        [[ "${src}" == *.app ]] || die "--app-source must end with .app: ${src}"
        [[ ! -L "${src}" ]] || die "Refusing symlinked --app-source: ${src}"
        [[ -d "${src}" ]] || die "--app-source directory not found: ${src}"

        local src_parent="${src%/*}"
        [[ -z "${src_parent}" ]] && src_parent="/"
        local src_base="${src##*/}"
        [[ -d "${src_parent}" ]] || die "Parent directory of --app-source not found: ${src_parent}"

        local src_real_parent=""
        src_real_parent="$(cd -P -- "${src_parent}" && pwd -P)"
        local src_disk_name=""
        src_disk_name="$(find_entry_in_dir "${src_real_parent}" "${src_base}")"
        [[ -n "${src_disk_name}" ]] || die "Unable to locate directory entry for --app-source: ${src}"

        local src_canonical=""
        src_canonical="$(join_path "${src_real_parent}" "${src_disk_name}")"

        local same_as_target=0
        if [[ -d "${APPS_DIR}" ]]; then
            local apps_real_dir=""
            apps_real_dir="$(cd -P -- "${APPS_DIR}" && pwd -P)"
            local target_canonical=""
            target_canonical="$(join_path "${apps_real_dir}" "Glance.app")"
            if [[ "${src_canonical}" == "${target_canonical}" ]]; then
                same_as_target=1
            fi
        fi

        if [[ "${same_as_target}" -eq 1 ]]; then
            validate_glance_bundle "${src}" 0
            harden_installed_app "${FINAL_APP_PATH}"
            return 0
        fi

        validate_glance_bundle "${src}" 1
        if [[ ! -d "${APPS_DIR}" ]]; then
            /bin/mkdir -p "${APPS_DIR}"
        fi

        STAGING_APP="$(join_path "${APPS_DIR}" ".Glance.app.staging.$$")"
        BACKUP_APP="$(join_path "${APPS_DIR}" ".Glance.app.backup.$$")"
        /bin/rm -rf "${STAGING_APP}" "${BACKUP_APP}"

        local ditto_err=""
        local ditto_rc=0
        ditto_err="$(/usr/bin/ditto "${src}" "${STAGING_APP}" 2>&1)" || ditto_rc=$?
        if [[ "${ditto_rc}" -ne 0 || -n "${ditto_err}" ]]; then
            die "Failed to copy bundle to staging directory${ditto_err:+: ${ditto_err}}"
        fi
        harden_installed_app "${STAGING_APP}"
        validate_glance_bundle "${STAGING_APP}" 1

        if [[ -n "${existing_name}" ]]; then
            ORIGINAL_APP_PATH="$(join_path "${APPS_DIR}" "${existing_name}")"
            SWAP_IN_PROGRESS=1
            /bin/mv "${ORIGINAL_APP_PATH}" "${BACKUP_APP}"
            /bin/mv "${STAGING_APP}" "${FINAL_APP_PATH}"
            SWAP_IN_PROGRESS=0
            STAGING_APP=""
            /bin/rm -rf "${BACKUP_APP}"
            BACKUP_APP=""
            ORIGINAL_APP_PATH=""
        else
            /bin/mv "${STAGING_APP}" "${FINAL_APP_PATH}"
            STAGING_APP=""
        fi
    else
        [[ -n "${existing_name}" ]] || die "Glance.app not found in ${APPS_DIR} (pass --app-source to install)."
        local current_path=""
        current_path="$(join_path "${APPS_DIR}" "${existing_name}")"
        validate_glance_bundle "${current_path}" 0

        if [[ "${existing_name}" != "Glance.app" ]]; then
            CASING_TMP="$(join_path "${APPS_DIR}" ".Glance.app.casing-tmp.$$")"
            /bin/rm -rf "${CASING_TMP}"
            ORIGINAL_APP_PATH="${current_path}"
            CASING_RENAME_IN_PROGRESS=1
            /bin/mv "${ORIGINAL_APP_PATH}" "${CASING_TMP}"
            /bin/mv "${CASING_TMP}" "${FINAL_APP_PATH}"
            CASING_RENAME_IN_PROGRESS=0
            CASING_TMP=""
            ORIGINAL_APP_PATH=""
        fi

        harden_installed_app "${FINAL_APP_PATH}"
    fi
}

install_pam_module() {
    [[ ! -L "${PAM_DIR}" ]] || die "Refusing symlinked PAM module directory: ${PAM_DIR}"
    if [[ -e "${PAM_DIR}" && ! -d "${PAM_DIR}" ]]; then
        die "PAM module path exists and is not a directory: ${PAM_DIR}"
    fi
    install_dir 0755 "${PAM_DIR}"

    PAM_TMP="$(/usr/bin/mktemp "${PAM_DIR}/.pam_glance.so.tmp.XXXXXXXX")"
    install_file 0755 "${PAM_SOURCE}" "${PAM_TMP}"
    /bin/mv -f "${PAM_TMP}" "${PAM_DEST}"
    PAM_TMP=""
}

update_sudo_local_for_install() {
    [[ ! -L "${PAM_CONF_DIR}" ]] || die "Refusing symlinked PAM configuration directory: ${PAM_CONF_DIR}"
    if [[ ! -d "${PAM_CONF_DIR}" ]]; then
        install_dir 0755 "${PAM_CONF_DIR}"
    fi
    [[ ! -L "${PAM_CONF}" ]] || die "Refusing symlinked PAM configuration file: ${PAM_CONF}"

    local seed_file=""
    if [[ -f "${PAM_CONF}" ]]; then
        seed_file="${PAM_CONF}"
    elif [[ -f "${PAM_TEMPLATE}" && ! -L "${PAM_TEMPLATE}" ]]; then
        seed_file="${PAM_TEMPLATE}"
    else
        SEED_TMP="$(/usr/bin/mktemp "${PAM_CONF_DIR}/.sudo_local.seed.XXXXXXXX")"
        printf '# sudo_local: local customizations for sudo\n' > "${SEED_TMP}"
        seed_file="${SEED_TMP}"
    fi

    CONF_TMP="$(/usr/bin/mktemp "${PAM_CONF_DIR}/.sudo_local.tmp.XXXXXXXX")"
    /usr/bin/awk -v pam_line="${PAM_AUTH_LINE}" '
        function is_active_auth_mod(mod,    i, suffix, slen, toklen) {
            if ($0 ~ /^[[:space:]]*#/ || $1 != "auth") {
                return 0
            }
            suffix = "/" mod
            slen = length(suffix)
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^#/) {
                    break
                }
                toklen = length($i)
                if ($i == mod || (toklen >= slen && substr($i, toklen - slen + 1) == suffix)) {
                    return 1
                }
            }
            return 0
        }
        BEGIN { inserted = 0 }
        {
            if (is_active_auth_mod("pam_glance.so")) {
                next
            }
            if (!inserted && is_active_auth_mod("pam_tid.so")) {
                print pam_line
                inserted = 1
            }
            print
        }
        END {
            if (!inserted) {
                print pam_line
            }
        }
    ' "${seed_file}" > "${CONF_TMP}"

    if [[ -n "${SEED_TMP}" ]]; then
        /bin/rm -f "${SEED_TMP}"
        SEED_TMP=""
    fi

    /bin/chmod 0644 "${CONF_TMP}"
    if [[ -z "${TEST_ROOT}" ]]; then
        /usr/sbin/chown root:wheel "${CONF_TMP}"
    fi
    /bin/mv -f "${CONF_TMP}" "${PAM_CONF}"
    CONF_TMP=""
}

validate_install_destinations() {
    [[ ! -L "${PAM_DIR}" ]] || die "Refusing symlinked PAM module directory: ${PAM_DIR}"
    if [[ -e "${PAM_DIR}" && ! -d "${PAM_DIR}" ]]; then
        die "PAM module path exists and is not a directory: ${PAM_DIR}"
    fi
    [[ ! -L "${PAM_CONF_DIR}" ]] || die "Refusing symlinked PAM configuration directory: ${PAM_CONF_DIR}"
    if [[ -e "${PAM_CONF_DIR}" && ! -d "${PAM_CONF_DIR}" ]]; then
        die "PAM configuration path exists and is not a directory: ${PAM_CONF_DIR}"
    fi
    [[ ! -L "${PAM_CONF}" ]] || die "Refusing symlinked PAM configuration file: ${PAM_CONF}"
    if [[ -e "${PAM_CONF}" && ! -f "${PAM_CONF}" ]]; then
        die "PAM configuration path exists and is not a regular file: ${PAM_CONF}"
    fi
}

perform_install() {
    validate_pam_source "${PAM_SOURCE}"
    validate_install_destinations
    install_or_normalize_app
    install_pam_module
    update_sudo_local_for_install
}

perform_uninstall() {
    if [[ "${RESTORE_OWNER_SET}" -eq 1 ]]; then
        if [[ ! "${RESTORE_OWNER}" =~ ^[1-9][0-9]*:[0-9]+$ ]]; then
            die "Invalid --restore-owner '${RESTORE_OWNER}': expected <uid>:<gid> with non-zero numeric UID."
        fi
    fi

    if [[ -L "${PAM_CONF}" ]]; then
        die "Refusing symlinked PAM configuration file: ${PAM_CONF}"
    fi

    local restore_target=""
    if [[ "${RESTORE_OWNER_SET}" -eq 1 && -d "${APPS_DIR}" && ! -L "${APPS_DIR}" ]]; then
        local existing_name=""
        existing_name="$(find_existing_app_name "${APPS_DIR}")"
        if [[ -n "${existing_name}" ]]; then
            local candidate_app=""
            candidate_app="$(join_path "${APPS_DIR}" "${existing_name}")"
            [[ ! -L "${candidate_app}" ]] || die "Refusing to restore ownership on symlinked bundle: ${candidate_app}"
            if [[ -d "${candidate_app}" ]]; then
                local bundle_id=""
                if bundle_id="$(read_bundle_id "${candidate_app}")" && [[ "${bundle_id}" == "${EXPECTED_BUNDLE_ID}" ]]; then
                    restore_target="${candidate_app}"
                fi
            fi
        fi
    fi

    if [[ -f "${PAM_CONF}" ]]; then
        CONF_TMP="$(/usr/bin/mktemp "${PAM_CONF_DIR}/.sudo_local.tmp.XXXXXXXX")"
        /usr/bin/awk '!/pam_glance\.so/' "${PAM_CONF}" > "${CONF_TMP}"
        /bin/chmod 0644 "${CONF_TMP}"
        if [[ -z "${TEST_ROOT}" ]]; then
            /usr/sbin/chown root:wheel "${CONF_TMP}"
        fi
        /bin/mv -f "${CONF_TMP}" "${PAM_CONF}"
        CONF_TMP=""
    fi

    if [[ -L "${PAM_DEST}" || -e "${PAM_DEST}" ]]; then
        [[ ! -d "${PAM_DEST}" ]] || die "Unexpected directory at PAM destination: ${PAM_DEST}"
        /bin/rm -f "${PAM_DEST}"
    fi

    if [[ -n "${restore_target}" ]]; then
        run_chown_tree "${RESTORE_OWNER}" "${restore_target}"
        /bin/chmod -RP u+w "${restore_target}"
    fi
}

SUBCOMMAND=""
PAM_SOURCE=""
PAM_SOURCE_SET=0
APP_SOURCE=""
APP_SOURCE_SET=0
RESTORE_OWNER=""
RESTORE_OWNER_SET=0
TEST_ROOT=""
TEST_ROOT_SET=0

parse_args() {
    [[ $# -ge 1 ]] || die "Usage: glance-sudo-setup.sh <install|uninstall> [options]"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|uninstall)
                [[ -z "${SUBCOMMAND}" ]] || die "Unexpected duplicate subcommand '$1'."
                SUBCOMMAND="$1"
                shift
                ;;
            --test-root)
                [[ "${TEST_ROOT_SET}" -eq 0 ]] || die "Duplicate --test-root option."
                [[ $# -ge 2 && -n "$2" ]] || die "--test-root requires a non-empty directory argument."
                TEST_ROOT="$2"
                TEST_ROOT_SET=1
                shift 2
                ;;
            --pam-source)
                [[ "${PAM_SOURCE_SET}" -eq 0 ]] || die "Duplicate --pam-source option."
                [[ $# -ge 2 && -n "$2" ]] || die "--pam-source requires a non-empty path argument."
                PAM_SOURCE="$2"
                PAM_SOURCE_SET=1
                shift 2
                ;;
            --app-source)
                [[ "${APP_SOURCE_SET}" -eq 0 ]] || die "Duplicate --app-source option."
                [[ $# -ge 2 && -n "$2" ]] || die "--app-source requires a non-empty path argument."
                APP_SOURCE="$2"
                APP_SOURCE_SET=1
                shift 2
                ;;
            --restore-owner)
                [[ "${RESTORE_OWNER_SET}" -eq 0 ]] || die "Duplicate --restore-owner option."
                [[ $# -ge 2 && -n "$2" ]] || die "--restore-owner requires a <uid>:<gid> argument."
                RESTORE_OWNER="$2"
                RESTORE_OWNER_SET=1
                shift 2
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done

    [[ -n "${SUBCOMMAND}" ]] || die "Subcommand required: install or uninstall."

    if [[ "${SUBCOMMAND}" == "install" ]]; then
        [[ "${PAM_SOURCE_SET}" -eq 1 ]] || die "install requires --pam-source <path>."
        [[ "${RESTORE_OWNER_SET}" -eq 0 ]] || die "--restore-owner is only valid with uninstall."
    else
        [[ "${PAM_SOURCE_SET}" -eq 0 ]] || die "--pam-source is only valid with install."
        [[ "${APP_SOURCE_SET}" -eq 0 ]] || die "--app-source is only valid with install."
    fi

    if [[ "${TEST_ROOT_SET}" -eq 1 ]]; then
        if [[ "${EUID}" -eq 0 ]]; then
            die "--test-root is forbidden when running as root (EUID == 0)."
        fi
        TEST_ROOT="$(strip_trailing_slashes "${TEST_ROOT}")"
        [[ -n "${TEST_ROOT}" && "${TEST_ROOT}" != "/" ]] || die "Invalid --test-root directory: ${TEST_ROOT}"
        [[ ! -L "${TEST_ROOT}" && -d "${TEST_ROOT}" ]] || die "--test-root must be an existing non-symlink directory: ${TEST_ROOT}"
    else
        if [[ "${EUID}" -ne 0 ]]; then
            die "Root privileges required (EUID == 0); rerun as administrator or pass --test-root as non-root."
        fi
    fi
}

main() {
    parse_args "$@"

    APPS_DIR="${TEST_ROOT}/Applications"
    PAM_DIR="${TEST_ROOT}/usr/local/lib/pam"
    PAM_DEST="${PAM_DIR}/${PAM_MODULE_NAME}"
    PAM_CONF_DIR="${TEST_ROOT}/etc/pam.d"
    PAM_CONF="${PAM_CONF_DIR}/sudo_local"
    PAM_TEMPLATE="${PAM_CONF_DIR}/sudo_local.template"

    if [[ "${SUBCOMMAND}" == "install" ]]; then
        perform_install
    else
        perform_uninstall
    fi
}

main "$@"

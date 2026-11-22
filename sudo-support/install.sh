#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: install.sh must be run as root (for example: sudo bash sudo-support/install.sh)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAM_SRC="${SCRIPT_DIR}/pam_glance.c"
PAM_DIR="/usr/local/lib/pam"
PAM_DEST="${PAM_DIR}/pam_glance.so"
PAM_CONF="/etc/pam.d/sudo_local"
PAM_TEMPLATE="/etc/pam.d/sudo_local.template"
PAM_LINE="auth       sufficient     ${PAM_DEST}"

if [[ ! -f "${PAM_SRC}" ]]; then
    echo "Error: ${PAM_SRC} not found." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

BUILT_SO="${WORK_DIR}/pam_glance.so"
echo "Compiling universal pam_glance.so (arm64 + x86_64)..."
clang -arch arm64 -arch x86_64 -Wall -Wextra -Werror -bundle -lpam "${PAM_SRC}" -o "${BUILT_SO}"

install -d -o root -g wheel -m 0755 "${PAM_DIR}"
install -o root -g wheel -m 0755 "${BUILT_SO}" "${PAM_DEST}"
echo "Installed ${PAM_DEST} (root:wheel 0755)."

TMP_CONF="${WORK_DIR}/sudo_local"
if [[ -f "${PAM_CONF}" ]]; then
    cp "${PAM_CONF}" "${TMP_CONF}"
elif [[ -f "${PAM_TEMPLATE}" ]]; then
    cp "${PAM_TEMPLATE}" "${TMP_CONF}"
else
    printf '# sudo_local: local customizations for sudo\n' > "${TMP_CONF}"
fi

if grep -Eq '^[[:space:]]*auth[[:space:]]+.*pam_glance\.so([[:space:]]|$)' "${TMP_CONF}"; then
    echo "${PAM_CONF} already configures pam_glance.so; leaving PAM config unchanged."
else
    UPDATED_CONF="${WORK_DIR}/sudo_local.updated"
    awk -v pam_line="${PAM_LINE}" '
        BEGIN { inserted = 0 }
        !inserted && /^[[:space:]]*auth[[:space:]]+.*pam_tid\.so([[:space:]]|$)/ {
            print pam_line
            inserted = 1
        }
        { print }
        END {
            if (!inserted) {
                print pam_line
            }
        }
    ' "${TMP_CONF}" > "${UPDATED_CONF}"

    install -o root -g wheel -m 0644 "${UPDATED_CONF}" "${PAM_CONF}"
    echo "Updated ${PAM_CONF} with pam_glance.so (preserving existing rules)."
fi

echo ""
echo "Next steps:"
echo "  1. Ensure Glance is installed at /Applications/Glance.app and owned by root:wheel:"
echo "       sudo chown -R root:wheel /Applications/Glance.app"
echo "  2. Open Glance -> Settings -> Sudo and enable Face authentication for sudo."
echo "  3. Test in a new sudo command; Touch ID / password remains active as fallback."

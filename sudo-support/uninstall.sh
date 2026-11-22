#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: uninstall.sh must be run as root (for example: sudo bash sudo-support/uninstall.sh)." >&2
    exit 1
fi

PAM_DEST="/usr/local/lib/pam/pam_glance.so"
PAM_CONF="/etc/pam.d/sudo_local"

if [[ -f "${PAM_CONF}" ]]; then
    WORK_DIR="$(mktemp -d)"
    trap 'rm -rf "${WORK_DIR}"' EXIT
    TMP_CONF="${WORK_DIR}/sudo_local"

    awk '!/pam_glance\.so/' "${PAM_CONF}" > "${TMP_CONF}"
    install -o root -g wheel -m 0644 "${TMP_CONF}" "${PAM_CONF}"
    echo "Removed pam_glance.so entries from ${PAM_CONF} (other lines preserved)."
else
    echo "${PAM_CONF} does not exist; nothing to edit."
fi

if [[ -f "${PAM_DEST}" ]]; then
    rm -f "${PAM_DEST}"
    echo "Removed ${PAM_DEST}."
else
    echo "${PAM_DEST} is already absent."
fi

#!/bin/bash
# BC-250 40 CU DKMS install for CachyOS — wraps dkms/install.sh by
# temporarily injecting the full amd/ source tree (which linux-cachyos-headers
# does not ship) into the kernel headers tree, runs dkms install, and
# restores headers afterwards.
#
# Usage: sudo ./run-dkms-cachyos.sh
#
# Requirements:
#   - kernel tarball already extracted at ~/bc250-kernel-src/cachyos-<ver>/
#     (must contain drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c)
#   - linux-cachyos-headers installed and matching `uname -r`
#   - dkms, base-devel, zstd, patch installed

set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
    exec sudo -E "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# KVER can be overridden by the caller (e.g. the pacman hook builds for the
# kernel that was just *installed*, which is not necessarily the running one).
KVER="${BC250_KVER:-$(uname -r)}"
HEADERS="/usr/lib/modules/${KVER}/build"
AMD_PATH="${HEADERS}/drivers/gpu/drm/amd"
BAK_PATH="${AMD_PATH}.headers-bak-$$"

if [[ ! -d "${HEADERS}" ]]; then
    echo "ERROR: kernel headers not found at ${HEADERS}" >&2
    echo "       (is linux-cachyos-headers installed and matching ${KVER}?)" >&2
    exit 1
fi

# Search order for an extracted kernel tree containing the amd/ subtree:
#   1. system path written by the pacman hook / bootstrap
#   2. the invoking user's $HOME/bc250-kernel-src/ (manual workflow)
SYSTEM_SRC_BASE="/var/lib/bc250-amdgpu/kernel-src"
ORIG_USER="${SUDO_USER:-$USER}"
ORIG_HOME="$(getent passwd "${ORIG_USER}" | cut -d: -f6)"
USER_SRC_BASE="${ORIG_HOME}/bc250-kernel-src"

SRC_TREE=""
for base in "${SYSTEM_SRC_BASE}" "${USER_SRC_BASE}"; do
    [[ -d "${base}" ]] || continue
    for d in "${base}"/*/; do
        if [[ -f "${d}/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c" ]]; then
            SRC_TREE="${d%/}"
            break 2
        fi
    done
done

if [[ -z "${SRC_TREE}" ]]; then
    echo "ERROR: extracted kernel tree with drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c not found." >&2
    echo "       searched: ${SYSTEM_SRC_BASE}/*/  ${USER_SRC_BASE}/*/" >&2
    echo "       hint: run /usr/local/bin/bc250-fetch-kernel-src first" >&2
    exit 1
fi

echo "[+] kernel tree: ${SRC_TREE}"
echo "[+] headers:     ${HEADERS}"
echo "[+] running as:  $(id -un) (orig: ${ORIG_USER})"

# Idempotent: if a previous run left amd/ as a symlink, undo it first
if [[ -L "${AMD_PATH}" ]]; then
    echo "[!] ${AMD_PATH} is already a symlink from a previous run; removing"
    rm "${AMD_PATH}"
    # Look for any lingering backup and put it back
    LATEST_BAK="$(ls -dt "${AMD_PATH}".headers-bak-* 2>/dev/null | head -1 || true)"
    if [[ -n "${LATEST_BAK}" && -d "${LATEST_BAK}" ]]; then
        mv "${LATEST_BAK}" "${AMD_PATH}"
        echo "[+] restored prior backup ${LATEST_BAK}"
    fi
fi

# Auto-restore on any exit (success, failure, or interrupt)
restore_headers() {
    local rc=$?
    if [[ -L "${AMD_PATH}" ]]; then
        rm -f "${AMD_PATH}"
    fi
    if [[ -d "${BAK_PATH}" && ! -e "${AMD_PATH}" ]]; then
        mv "${BAK_PATH}" "${AMD_PATH}"
        echo "[+] restored original ${AMD_PATH}"
    fi
    exit "${rc}"
}
trap restore_headers EXIT INT TERM

echo "[+] backing up ${AMD_PATH} -> ${BAK_PATH}"
mv "${AMD_PATH}" "${BAK_PATH}"

echo "[+] linking ${SRC_TREE}/drivers/gpu/drm/amd -> ${AMD_PATH}"
ln -s "${SRC_TREE}/drivers/gpu/drm/amd" "${AMD_PATH}"

if [[ ! -f "${AMD_PATH}/amdgpu/gfx_v10_0.c" ]]; then
    echo "ERROR: gfx_v10_0.c not visible through symlink — aborting" >&2
    exit 1
fi
echo "[+] gfx_v10_0.c is reachable through headers"

# Clean any prior failed dkms registration
if dkms status -m bc250-amdgpu -v 1.0 2>/dev/null | grep -q bc250-amdgpu; then
    echo "[+] removing previous dkms registration"
    dkms remove -m bc250-amdgpu -v 1.0 --all || true
fi

echo "[+] running ${REPO_ROOT}/dkms/install.sh"
BC250_KVER="${KVER}" "${REPO_ROOT}/dkms/install.sh"

echo "[+] dkms status:"
dkms status -m bc250-amdgpu

echo
echo "[+] DKMS build done. Next step (after this script returns):"
echo "      sudo mkinitcpio -P"
echo "      sudo reboot"
echo
echo "[+] Then verify with:"
echo "      cat /sys/module/amdgpu/parameters/bc250_cc_write_mode   # expect 3"
echo "      sudo dmesg | grep active_cu_number                       # expect 40"

#!/bin/bash
# bc250-bootstrap.sh — one-shot installer for the BC-250 40 CU unlock on
# a clean CachyOS system.
#
# Does:
#   1. Installs build/runtime dependencies via pacman.
#   2. Copies the repo (this directory) to /usr/local/share/bc250-amdgpu/.
#   3. Installs helpers to /usr/local/bin/ (bc250-fetch-kernel-src,
#      bc250-dkms-rebuild).
#   4. Installs the pacman PostTransaction hook.
#   5. Runs the helpers once now, so the patched amdgpu is built for the
#      kernel that's installed at this very moment.
#   6. Regenerates initramfs.
#
# After it finishes successfully:
#       sudo reboot
#
# From then on, every `pacman -Syu` that bumps linux-cachyos triggers the
# hook, which downloads the matching kernel tarball and rebuilds the DKMS
# module automatically. No manual steps required after kernel updates.
#
# Usage:
#   sudo ./bc250-bootstrap.sh

set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
    exec sudo -E "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUTO_DIR="${REPO_ROOT}/auto"

SHARE_DIR="/usr/local/share/bc250-amdgpu"
BIN_DIR="/usr/local/bin"
HOOK_DIR="/etc/pacman.d/hooks"

log() { printf '\n[bootstrap] %s\n' "$*"; }
die() { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

# Sanity: this script lives in auto/, the repo proper is the parent.
[[ -f "${REPO_ROOT}/run-dkms-cachyos.sh" ]] \
    || die "expected ${REPO_ROOT}/run-dkms-cachyos.sh to exist; run this script from inside the repo's auto/ directory"
[[ -d "${REPO_ROOT}/dkms" ]] \
    || die "expected ${REPO_ROOT}/dkms/ to exist"
[[ -d "${REPO_ROOT}/patch" ]] \
    || die "expected ${REPO_ROOT}/patch/ to exist"

# ---- 1. dependencies --------------------------------------------------------
log "installing dependencies"
pacman -S --needed --noconfirm \
    base-devel dkms zstd patch curl tar \
    linux-cachyos linux-cachyos-headers

# ---- 2. copy repo to /usr/local/share ---------------------------------------
log "installing repo to ${SHARE_DIR}"
rm -rf "${SHARE_DIR}"
mkdir -p "${SHARE_DIR}"
# Copy the meaningful pieces only; skip auto/ to avoid a recursive copy of
# this very directory.
cp -a "${REPO_ROOT}/run-dkms-cachyos.sh" "${SHARE_DIR}/"
cp -a "${REPO_ROOT}/dkms"  "${SHARE_DIR}/"
cp -a "${REPO_ROOT}/patch" "${SHARE_DIR}/"
[[ -d "${REPO_ROOT}/scripts" ]] && cp -a "${REPO_ROOT}/scripts" "${SHARE_DIR}/"
chmod 0755 "${SHARE_DIR}/run-dkms-cachyos.sh" \
           "${SHARE_DIR}/dkms/install.sh" \
           "${SHARE_DIR}/dkms/prepare.sh" \
           "${SHARE_DIR}/dkms/uninstall.sh"

# ---- 3. install helpers to /usr/local/bin -----------------------------------
log "installing helpers to ${BIN_DIR}"
install -m 0755 "${AUTO_DIR}/bc250-fetch-kernel-src" "${BIN_DIR}/bc250-fetch-kernel-src"
install -m 0755 "${AUTO_DIR}/bc250-dkms-rebuild"     "${BIN_DIR}/bc250-dkms-rebuild"

# ---- 4. install pacman hook -------------------------------------------------
log "installing pacman hook to ${HOOK_DIR}"
mkdir -p "${HOOK_DIR}"
install -m 0644 "${AUTO_DIR}/95-bc250-amdgpu.hook" \
    "${HOOK_DIR}/95-bc250-amdgpu.hook"

# ---- 5. first build for the kernel that's installed right now ---------------
log "running first DKMS rebuild via the same path the hook will use"
"${BIN_DIR}/bc250-dkms-rebuild"

# ---- 6. summary -------------------------------------------------------------
cat <<'EOF'

[bootstrap] all set.

  - helpers:      /usr/local/bin/bc250-fetch-kernel-src
                  /usr/local/bin/bc250-dkms-rebuild
  - shared data:  /usr/local/share/bc250-amdgpu/
  - kernel src:   /var/lib/bc250-amdgpu/kernel-src/
  - pacman hook:  /etc/pacman.d/hooks/95-bc250-amdgpu.hook
  - rebuild log:  /var/log/bc250-amdgpu/rebuild.log

next:
    sudo reboot

verify after reboot:
    cat /sys/module/amdgpu/parameters/bc250_cc_write_mode   # expect: 3
    sudo dmesg | grep active_cu_number                      # expect: 40

future linux-cachyos updates rebuild the module automatically.
EOF

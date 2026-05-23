#!/bin/bash
# install.sh — one-shot installer for the BC-250 40 CU unlock on CachyOS.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/mikael2df-ux/bc250-40cu-unlock/main/install.sh | sudo bash
#
# Or after cloning the repo:
#   sudo ./install.sh
#
# What it does:
#   1. Installs dependencies (base-devel, dkms, zstd, patch, curl, tar, git,
#      linux-cachyos-headers).
#   2. Clones this repo into /tmp if not already running from a checkout.
#   3. Delegates to auto/bc250-bootstrap.sh which sets up:
#        - Helpers in /usr/local/bin/
#        - Pacman hook for auto-rebuild on kernel updates
#        - DKMS module bc250-amdgpu
#        - Initial build for the current kernel
#   4. Regenerates initramfs.
#
# After completion: reboot, then verify with:
#   cat /sys/module/amdgpu/parameters/bc250_cc_write_mode   # expect: 3
#   sudo dmesg | grep active_cu_number                      # expect: 40
#
# Requirements:
#   - CachyOS (or Arch with linux-cachyos)
#   - Secure Boot DISABLED in UEFI (DKMS module is unsigned)
#   - Internet access

set -euo pipefail

REPO_URL="https://github.com/mikael2df-ux/bc250-40cu-unlock.git"
REPO_BRANCH="main"

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; }
die()  { err "$@"; exit 1; }

# ---- root check -------------------------------------------------------------
if [[ "$(id -u)" != "0" ]]; then
    exec sudo -E "$0" "$@"
fi

# ---- sanity: not on Secure Boot ---------------------------------------------
if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
        warn "Secure Boot is ENABLED. The DKMS-built module is unsigned and will NOT load."
        warn "Disable Secure Boot in UEFI before rebooting."
        printf "Continue anyway? [y/N] "
        read -r ans
        case "$ans" in y|Y) ;; *) exit 1 ;; esac
    fi
fi

# ---- sanity: this is a BC-250 ------------------------------------------------
if command -v lspci >/dev/null 2>&1; then
    if ! lspci -nn 2>/dev/null | grep -qi "13fe"; then
        warn "No BC-250 (PCI ID 13fe) detected. The patch is a no-op on other hardware."
        printf "Continue anyway? [y/N] "
        read -r ans
        case "$ans" in y|Y) ;; *) exit 1 ;; esac
    fi
fi

# ---- ensure pacman is available ---------------------------------------------
if ! command -v pacman >/dev/null 2>&1; then
    die "pacman not found. This installer targets CachyOS / Arch Linux."
fi

# ---- install dependencies ---------------------------------------------------
log "Installing dependencies..."
pacman -S --needed --noconfirm \
    base-devel dkms zstd patch curl tar git \
    linux-cachyos linux-cachyos-headers

# ---- locate repo: either we're inside a checkout, or clone to /tmp ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -f "${SCRIPT_DIR}/auto/bc250-bootstrap.sh" \
   && -f "${SCRIPT_DIR}/run-dkms-cachyos.sh" \
   && -d "${SCRIPT_DIR}/dkms" \
   && -d "${SCRIPT_DIR}/patch" ]]; then
    REPO_ROOT="${SCRIPT_DIR}"
    log "Using local checkout: ${REPO_ROOT}"
else
    TMP_DIR="$(mktemp -d)"
    log "Cloning ${REPO_URL} (branch ${REPO_BRANCH})..."
    git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${TMP_DIR}/repo"
    REPO_ROOT="${TMP_DIR}/repo"
fi

# ---- delegate to the existing bootstrap -------------------------------------
BOOTSTRAP="${REPO_ROOT}/auto/bc250-bootstrap.sh"
if [[ ! -x "${BOOTSTRAP}" ]]; then
    chmod +x "${BOOTSTRAP}" || die "Cannot make ${BOOTSTRAP} executable"
fi

log "Running bootstrap..."
"${BOOTSTRAP}"

# ---- final message ----------------------------------------------------------
cat <<EOF

[install] All done.

  Reboot to activate 40 CU mode:
      sudo reboot

  Verify after reboot:
      cat /sys/module/amdgpu/parameters/bc250_cc_write_mode   # expect: 3
      sudo dmesg | grep active_cu_number                      # expect: 40

  From now on, every \`pacman -Syu\` that bumps linux-cachyos will rebuild
  the DKMS module automatically. No manual steps required.

EOF

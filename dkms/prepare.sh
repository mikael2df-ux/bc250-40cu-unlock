#!/bin/bash
# DKMS PRE_BUILD for bc250-amdgpu.
#
# Stages the target kernel's drivers/gpu/drm/amd/ subtree into the DKMS build
# directory and applies the BC-250 40 CU patch to gfx_v10_0.c. The full amd/
# tree is needed because amdgpu's Kbuild references sibling directories
# (display, pm, include) via relative paths.
#
# Invoked by DKMS as: PRE_BUILD="prepare.sh ${kernelver} ${kernel_source_dir}"
set -euo pipefail

KVER="${1:-}"
KSRC="${2:-}"

if [[ -z "${KVER}" || -z "${KSRC}" ]]; then
    echo "[bc250-amdgpu] usage: prepare.sh <kernelver> <kernel_source_dir>" >&2
    exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="${HERE}/patch/bc250-40cu-amdgpu.patch"

if [[ ! -f "${PATCH}" ]]; then
    echo "[bc250-amdgpu] patch not found: ${PATCH}" >&2
    exit 1
fi

if [[ ! -d "${KSRC}/drivers/gpu/drm/amd/amdgpu" ]]; then
    echo "[bc250-amdgpu] amd source not found under ${KSRC}/drivers/gpu/drm/amd/" >&2
    echo "[bc250-amdgpu] make sure matching kernel headers (linux-cachyos-headers / linux-headers-${KVER}) are installed" >&2
    exit 1
fi

# run-dkms-cachyos.sh injects drivers/gpu/drm/amd as a symlink into the
# kernel headers tree. `cp -al` carries `-d` (no-dereference) and would just
# clone the symlink instead of recursing into the real source — and then
# patch would write through the symlink and modify the kernel-src tree in
# place. Resolve the symlink so we recurse into the actual directory.
AMD_SRC="${KSRC}/drivers/gpu/drm/amd"
if [[ -L "${AMD_SRC}" ]]; then
    AMD_SRC="$(readlink -f -- "${AMD_SRC}")"
fi

# Clean any prior staging
rm -rf "${HERE}/amd"

echo "[bc250-amdgpu] staging amd/ from ${AMD_SRC} ..."
# Prefer hardlinks for speed; fall back to a full copy if the kernel source
# tree and the DKMS build tree are on different filesystems. GNU patch writes
# to a temporary file and renames over the target, so hardlinks to the
# original source are not modified in place.
if ! cp -al "${AMD_SRC}" "${HERE}/amd" 2>/dev/null; then
    cp -r --dereference "${AMD_SRC}" "${HERE}/amd"
fi

# Patch paths in bc250-40cu-amdgpu.patch are `a/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c`.
# From inside `amdgpu/`, that's 6 leading components to strip.
if grep -q 'bc250_cc_write_mode' "${HERE}/amd/amdgpu/gfx_v10_0.c"; then
    # Already patched (typically because an earlier broken run wrote through
    # the symlink into the real kernel-src tree). Treat as success rather
    # than failing a fresh build.
    echo "[bc250-amdgpu] patch already present in staged source — skipping apply"
else
    echo "[bc250-amdgpu] applying ${PATCH} ..."
    (
        cd "${HERE}/amd/amdgpu"
        patch -p6 --batch < "${PATCH}"
    )
fi

if ! grep -q 'bc250_cc_write_mode' "${HERE}/amd/amdgpu/gfx_v10_0.c"; then
    echo "[bc250-amdgpu] patch applied but bc250_cc_write_mode symbol not found in staged source" >&2
    exit 1
fi

echo "[bc250-amdgpu] sources prepared for kernel ${KVER}"

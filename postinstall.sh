#!/usr/bin/env bash
# Post-installation setup for Cyan Skillfish (AMD) on Arch Linux
# Run as a regular user with sudo privileges. Do NOT run as root directly.

set -euo pipefail

#--- Helpers -------------------------------------------------------------------

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

require_not_root() {
    if [[ $EUID -eq 0 ]]; then
        err "Don't run this script as root. Run as a normal user; sudo will be invoked when needed."
        exit 1
    fi
}

ensure_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Required command '$1' not found. $2"
        exit 1
    fi
}

ask() {
    local prompt="$1" default="${2:-N}" reply
    read -r -p "$prompt [$( [[ $default == Y ]] && echo 'Y/n' || echo 'y/N' )] " reply || true
    reply="${reply:-$default}"
    [[ $reply =~ ^[Yy]$ ]]
}

#--- Steps ---------------------------------------------------------------------

install_yay_if_missing() {
    if command -v yay >/dev/null 2>&1; then
        return 0
    fi
    log "yay not found. Installing yay from AUR..."
    sudo pacman -S --needed --noconfirm base-devel git
    local tmp
    tmp="$(mktemp -d)"
    git clone https://aur.archlinux.org/yay.git "$tmp/yay"
    (cd "$tmp/yay" && makepkg -si --noconfirm)
    rm -rf "$tmp"
}

stop_conflicting_governors() {
    local services=(
        cyan-skillfish-governor-smu.service
        cyan-skillfish-governor-smu-plus.service
        cyan-skillfish-governor-tt.service
        oberon-governor.service
    )
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log "Stopping conflicting service: $svc"
            sudo systemctl stop "$svc"
            sudo systemctl disable "$svc"
        fi
    done
}

install_gpu_governor_smu_plus() {
    log "Installing SMU+ governor (bc250-collective) from source..."

    stop_conflicting_governors

    if ! command -v cargo >/dev/null 2>&1; then
        log "Rust/cargo not found. Installing rustup..."
        sudo pacman -S --needed --noconfirm rustup
        rustup default stable
    fi

    local tmp
    tmp="$(mktemp -d)"
    log "Cloning bc250-collective/cyan-skillfish-governor..."
    git clone https://github.com/bc250-collective/cyan-skillfish-governor.git "$tmp/gov"

    log "Building (cargo build --release)... This may take a minute."
    (cd "$tmp/gov" && cargo build --release)

    log "Installing binary, config, and service..."
    sudo cp "$tmp/gov/target/release/cyan-skillfish-governor-smu-plus" /usr/bin/
    sudo mkdir -p /etc/cyan-skillfish-governor-smu-plus
    if [[ ! -f /etc/cyan-skillfish-governor-smu-plus/config.toml ]]; then
        log "Writing optimized governor config..."
        sudo tee /etc/cyan-skillfish-governor-smu-plus/config.toml >/dev/null << 'GOVCONF'
# us
[timing.intervals]
sample = 500
adjust = 200_000

[gpu-usage]
fix-metrics = true
method = "busy-flag" # "busy-flag" or "process"
flush-every = 10

[gpu]
set-method = "smu"  # "smu" or "kernel"

[dbus]
enabled = true

# MHz/ms
[timing.ramp-rates]
normal = 1
burst = 50

# number of samples
[timing]
burst-samples = 60
down-events = 5

# MHz
[frequency-thresholds]
adjust = 10

# %
[load-target]
upper = 0.80
lower = 0.65

#°C
[temperature]
throttling = 85
throttling_recovery = 75

# Idle: lowest frequency + memory controller in power-saving mode (perf_profile=1)
[[safe-points]]
frequency = 350
voltage = 700
perf_profile = 1

# Load: full frequency + memory controller at max performance (perf_profile=3)
[[safe-points]]
frequency = 1800
voltage = 850
perf_profile = 3
GOVCONF
    else
        warn "Config already exists, keeping /etc/cyan-skillfish-governor-smu-plus/config.toml"
    fi
    sudo cp "$tmp/gov/cyan-skillfish-governor-smu-plus.service" /usr/lib/systemd/system/
    sudo systemctl daemon-reload

    rm -rf "$tmp"

    sudo systemctl enable --now cyan-skillfish-governor-smu-plus.service
    systemctl status cyan-skillfish-governor-smu-plus --no-pager || true
}

install_gpu_governor() {
    log "=== Step 1: GPU Governor ==="
    echo ""
    echo "  1) SMU governor (filippor) [AUR]"
    echo "     Adaptive GPU frequency/voltage control. Stable, well-tested."
    echo "     No memory controller management."
    echo ""
    echo "  2) SMU+ governor (bc250-collective) [built from source]"
    echo "     Same as SMU + memory controller profile switching (perf_profile)."
    echo "     Lowers idle TDP to ~30-35W. Requires Rust/cargo."
    echo ""
    echo "  3) TT governor [AUR, requires patched kernel]"
    echo "     Legacy option. Only use if you have the TT kernel patch."
    echo ""
    echo "  4) Skip"
    echo ""
    local choice
    read -r -p "Select [1/2/3/4] (default 2): " choice
    choice="${choice:-2}"

    case "$choice" in
        1)
            stop_conflicting_governors
            yay -S --needed --noconfirm cyan-skillfish-governor-smu
            sudo systemctl enable --now cyan-skillfish-governor-smu.service
            systemctl status cyan-skillfish-governor-smu --no-pager || true
            ;;
        2)
            install_gpu_governor_smu_plus
            ;;
        3)
            stop_conflicting_governors
            yay -S --needed --noconfirm cyan-skillfish-governor-tt
            sudo systemctl enable --now cyan-skillfish-governor-tt.service
            systemctl status cyan-skillfish-governor-tt --no-pager || true
            ;;
        4)
            warn "Skipping GPU governor installation."
            return
            ;;
        *)
            warn "Unknown choice, skipping."
            return
            ;;
    esac

    log "Verifying GPU governor (looking for the right card)..."
    local card found=0
    for card in /sys/class/drm/card*/device/pp_dpm_sclk; do
        [[ -e "$card" ]] || continue
        echo "--- $card ---"
        cat "$card"
        found=1
    done
    [[ $found -eq 1 ]] || warn "pp_dpm_sclk not found under /sys/class/drm/card*/device/. Check your GPU."
}

install_cu_unlock() {
    log "=== Step 2: BC-250 40 CU Unlock ==="
    echo "  The BC-250 ships with 24 of 40 RDNA2 CUs active."
    echo "  This installs a patched amdgpu DKMS module that re-enables all 40 CUs."
    echo "  After installation, every linux-cachyos kernel update will auto-rebuild."
    echo ""
    warn "REQUIREMENTS: Secure Boot must be DISABLED in UEFI."
    warn "              The DKMS module is unsigned; Secure Boot will reject it."
    echo ""
    if ! ask "Install 40 CU unlock?" N; then
        warn "Skipping 40 CU unlock."
        return
    fi

    if command -v mokutil >/dev/null 2>&1 \
       && mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
        warn "Secure Boot appears to be ENABLED. The patched module will NOT load."
        if ! ask "Continue anyway?" N; then
            return
        fi
    fi

    log "Running CU unlock installer from upstream..."
    curl -sSL https://raw.githubusercontent.com/mikael2df-ux/bc250-40cu-unlock/main/install.sh | sudo bash

    log "40 CU unlock installed. Reboot to activate."
    echo ""
    echo "  Verify after reboot:"
    echo "    cat /sys/module/amdgpu/parameters/bc250_cc_write_mode   # expect: 3"
    echo "    sudo dmesg | grep active_cu_number                      # expect: 40"
    echo ""
}

install_gpu_metrics_fix() {
    log "=== Step 3: GPU Metrics Fix ==="
    echo "  Fixes GPU usage reporting (shows 0%) in MangoHUD, Steam overlay, amdgpu_top."
    echo "  Installs a Python injector as a systemd service that patches gpu_metrics via bind-mount."
    echo ""
    if ! ask "Install GPU metrics fix?" Y; then
        warn "Skipping GPU metrics fix."
        return
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        log "Installing python3..."
        sudo pacman -S --needed --noconfirm python
    fi

    local install_dir="/var/amd_gpu_usage_fix"
    local injector="$install_dir/gpu_injector.py"
    local service="/etc/systemd/system/amd-gpu-usage-fix.service"

    sudo mkdir -p "$install_dir"

    log "Writing GPU metrics injector..."
    sudo tee "$injector" >/dev/null << 'PYEOF'
#!/usr/bin/env python3
import os, glob, struct, time, subprocess, signal, sys

# Hardware paths
REAL_METRICS = "/sys/class/drm/card1/device/gpu_metrics"
REAL_BUSY = "/sys/class/drm/card1/device/gpu_busy_percent"

# Patched files (temporary storage)
PATCHED_METRICS = "/var/amd_gpu_usage_fix/patched_metrics"
PATCHED_BUSY = "/var/amd_gpu_usage_fix/patched_busy"

USAGE_OFFSET = 0x1C # Byte 28 for AMD GPU metrics table

try:
    real_fd = os.open(REAL_METRICS, os.O_RDONLY)
except Exception as e:
    print(f"Failed to open hardware file: {e}")
    sys.exit(1)

# Create placeholder files for bind-mounting
with open(PATCHED_METRICS, "wb") as f: f.write(b'\x00' * 128)
with open(PATCHED_BUSY, "w") as f: f.write("0\n")

# Perform bind-mounts to override system paths
subprocess.run(["mount", "--bind", PATCHED_METRICS, REAL_METRICS])
subprocess.run(["mount", "--bind", PATCHED_BUSY, REAL_BUSY])

def cleanup(signum, frame):
    """Restore original system files on exit."""
    subprocess.run(["umount", REAL_METRICS], stderr=subprocess.DEVNULL)
    subprocess.run(["umount", REAL_BUSY], stderr=subprocess.DEVNULL)
    sys.exit(0)

signal.signal(signal.SIGTERM, cleanup)
signal.signal(signal.SIGINT, cleanup)

def get_gfx_time():
    """Calculate total GPU active time from fdinfo."""
    gfx_times = {}
    for path in glob.glob('/proc/[0-9]*/fdinfo/*'):
        try:
            with open(path, 'r') as f:
                cid, gfx = None, 0
                for line in f:
                    if line.startswith('drm-client-id:'): cid = line.split()[1]
                    elif line.startswith('drm-engine-gfx:'): gfx = int(line.split()[1])
                if cid is not None and gfx > gfx_times.get(cid, 0): gfx_times[cid] = gfx
        except: pass
    return sum(gfx_times.values())

patched_fd = os.open(PATCHED_METRICS, os.O_WRONLY)

# Main Injection Loop
while True:
    t1 = get_gfx_time()
    time.sleep(1)
    t2 = get_gfx_time()

    usage = max(0, min(100, (t2 - t1) // 10000000))

    # Update Binary Metrics (for MangoHud)
    os.lseek(real_fd, 0, os.SEEK_SET)
    raw_data = bytearray(os.read(real_fd, 128))
    if len(raw_data) >= 30:
        struct.pack_into("<H", raw_data, USAGE_OFFSET, usage)
        os.lseek(patched_fd, 0, os.SEEK_SET)
        os.write(patched_fd, raw_data)

    # Update Text Percent (for Steam & CPU-X)
    with open(PATCHED_BUSY, "w") as f:
        f.write(f"{usage}\n")

PYEOF

    sudo chmod +x "$injector"

    log "Creating systemd service..."
    sudo tee "$service" >/dev/null << EOF
[Unit]
Description=AMD GPU Metrics Injector (CachyOS)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $injector

User=root
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_SYS_ADMIN

Restart=always
RestartSec=2

ExecStopPost=/usr/bin/umount /sys/class/drm/card1/device/gpu_metrics

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now amd-gpu-usage-fix.service

    if systemctl is-active --quiet amd-gpu-usage-fix.service; then
        log "GPU Metrics Fix is active and running."
    else
        warn "Service is not active. Check: journalctl -u amd-gpu-usage-fix -n 20"
    fi
}

install_cpu_overclock() {
    log "=== Step 4: CPU Overclocking (bc250_smu_oc) ==="
    echo "  Installs tools for CPU overclocking/undervolting via SMU messages."
    echo "  - bc250-detect: finds stable overclock settings (interactive, ~5-15 min)"
    echo "  - bc250-apply:  applies saved config, can install as systemd service"
    echo ""
    warn "WARNING: CPU voltage must NEVER exceed 1.325V — exceeding this can brick the CPU!"
    echo ""
    if ! ask "Install CPU overclock tools?" N; then
        warn "Skipping CPU overclock tools."
        return
    fi

    log "Installing dependencies..."
    sudo pacman -S --needed --noconfirm stress python-pip

    local tmp
    tmp="$(mktemp -d)"
    log "Cloning bc250_smu_oc..."
    git clone https://github.com/bc250-collective/bc250_smu_oc.git "$tmp/oc"

    log "Installing via pip..."
    (cd "$tmp/oc" && pip install . --break-system-packages)

    rm -rf "$tmp"

    if command -v bc250-detect >/dev/null 2>&1; then
        log "bc250_smu_oc installed successfully."
    else
        warn "bc250-detect not found in PATH. You may need to add ~/.local/bin to PATH."
    fi

    echo ""
    log "=== How to use ==="
    echo "  1. Find stable settings (run manually, takes 5-15 min):"
    echo "     sudo bc250-detect --frequency 4000 --vid 1275 --keep"
    echo ""
    echo "  2. Test stability yourself (OCCT, Prime95, or real workload)"
    echo ""
    echo "  3. Install as boot service:"
    echo "     sudo bc250-apply --install overclock.conf"
    echo "     sudo systemctl enable bc250-smu-oc"
    echo ""
    warn "Max safe voltage: 1.325V. Start with conservative values!"
    echo ""
}

configure_sensors() {
    log "=== Step 5: Sensors (lm_sensors + nct6683) ==="
    sudo pacman -S --needed --noconfirm lm_sensors

    echo 'nct6683' | sudo tee /etc/modules-load.d/nct6683.conf >/dev/null
    echo 'options nct6683 force=true' | sudo tee /etc/modprobe.d/sensors.conf >/dev/null

    log "Rebuilding initramfs..."
    sudo mkinitcpio -P

    log "Loading nct6683 now (a reboot is still recommended later)..."
    sudo modprobe nct6683 force=true || warn "modprobe failed; the module will load after reboot."

    log "Running 'sensors' (output may be empty until reboot):"
    sensors || true

    warn "For PWM fan control, use the nct6687 module instead — see the Sensors Guide."
}

set_kernel_parameters() {
    log "=== Step 6: GRUB kernel parameters ==="
    if [[ ! -f /etc/default/grub ]]; then
        warn "/etc/default/grub not found — are you using GRUB? Skipping."
        return
    fi

    local cmdline="quiet"
    if ask "Enable 'mitigations=off' for extra performance (disables CPU security mitigations)?" N; then
        cmdline="quiet mitigations=off"
    fi

    log "Backing up /etc/default/grub -> /etc/default/grub.bak.$(date +%s)"
    sudo cp /etc/default/grub "/etc/default/grub.bak.$(date +%s)"

    log "Setting GRUB_CMDLINE_LINUX_DEFAULT=\"$cmdline\""
    sudo sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$cmdline\"|" /etc/default/grub

    log "Regenerating grub.cfg..."
    sudo grub-mkconfig -o /boot/grub/grub.cfg
}

install_gaming_stack() {
    log "=== Step 7: Gaming essentials ==="

    # Steam lives in [multilib]; warn if it's disabled.
    if ! grep -qE '^\s*\[multilib\]' /etc/pacman.conf; then
        warn "[multilib] repository looks disabled in /etc/pacman.conf."
        warn "Enable it (uncomment [multilib] and the Include line), then run: sudo pacman -Syu"
        if ! ask "Continue anyway? Steam install will probably fail." N; then
            return
        fi
    fi

    sudo pacman -S --needed --noconfirm \
        steam mangohud goverlay gamemode gamescope \
        nvtop htop fastfetch

    if ask "Install protonup-qt (Proton GE manager) from AUR?" Y; then
        yay -S --needed --noconfirm protonup-qt
    fi
}

prompt_reboot() {
    log "=== Done ==="
    log "A reboot is recommended to apply kernel parameters, nct6683 module,"
    log "and ensure all services (GPU governor, metrics fix, CPU OC) start cleanly."
    if ask "Reboot now?" N; then
        sudo reboot
    fi
}

#--- Main ----------------------------------------------------------------------

main() {
    require_not_root
    ensure_cmd sudo    "Install sudo and add your user to the wheel group."
    ensure_cmd pacman  "This script targets Arch Linux."

    log "Updating system first..."
    sudo pacman -Syu --noconfirm

    install_yay_if_missing
    install_gpu_governor          # Step 1: GPU Governor
    install_cu_unlock             # Step 2: 40 CU Unlock
    install_gpu_metrics_fix       # Step 3: GPU Metrics Fix
    install_cpu_overclock         # Step 4: CPU Overclock
    configure_sensors             # Step 5: Sensors
    set_kernel_parameters         # Step 6: GRUB
    install_gaming_stack          # Step 7: Gaming
    prompt_reboot
}

main "$@"

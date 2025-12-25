#!/usr/bin/env bash
#
# OS Preparation Script for K3s Phase 1 (Raspberry Pi)
#
# Prepares Raspberry Pi OS for edge Kubernetes deployment.
# Focuses on constraints: low memory, SD card longevity, power loss resilience.
#
# This script is idempotent - safe to run multiple times.
#
# Usage:
#   sudo ./os-prep-phase1.sh
#
# What it does:
#   1. Disables swap (Kubernetes requirement)
#   2. Enables cgroup memory accounting (required for kubelet limits)
#   3. Caps journald size (protects SD card from log wear)
#   4. Loads required kernel modules (networking, containers)
#   5. Sets sysctl parameters (Kubernetes networking requirements)
#
# DOES NOT:
#   - Install K3s
#   - Install additional packages (unless strictly required)
#   - Modify network configuration
#   - Create users or change permissions
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Track if reboot is needed
REBOOT_REQUIRED=false

# Logging functions
log_step() {
    echo -e "${BLUE}[STEP]${NC} $*"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_detail() {
    echo -e "       $*"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Step 1: Disable swap
# Why: Kubernetes requires swap to be disabled. Swap causes unpredictable
#      performance on memory-constrained edge devices and breaks kubelet
#      memory accounting.
disable_swap() {
    log_step "Disabling swap"

    # Check if swap is currently active
    if swapon --show | grep -q .; then
        log_info "Swap is active, disabling..."
        swapoff -a
        log_info "✓ Swap disabled (runtime)"
    else
        log_info "✓ Swap already disabled (runtime)"
    fi

    # Disable dphys-swapfile service (Raspberry Pi OS specific)
    if systemctl is-enabled dphys-swapfile &>/dev/null; then
        log_info "Disabling dphys-swapfile service..."
        systemctl disable dphys-swapfile
        systemctl stop dphys-swapfile 2>/dev/null || true
        log_info "✓ dphys-swapfile service disabled"
    else
        log_info "✓ dphys-swapfile already disabled or not present"
    fi

    # Comment out swap entries in /etc/fstab to persist across reboots
    if grep -q "^[^#].*swap" /etc/fstab 2>/dev/null; then
        log_info "Commenting out swap entries in /etc/fstab..."
        sed -i.bak '/^[^#].*swap/s/^/# /' /etc/fstab
        log_info "✓ /etc/fstab updated (backup: /etc/fstab.bak)"
    else
        log_info "✓ No active swap entries in /etc/fstab"
    fi

    # Set swapfile size to 0 in config (if file exists)
    if [[ -f /etc/dphys-swapfile ]]; then
        if grep -q "^CONF_SWAPSIZE=[^0]" /etc/dphys-swapfile; then
            log_info "Setting CONF_SWAPSIZE=0 in /etc/dphys-swapfile..."
            sed -i.bak 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=0/' /etc/dphys-swapfile
            log_info "✓ /etc/dphys-swapfile updated"
        else
            log_info "✓ CONF_SWAPSIZE already set to 0"
        fi
    fi

    log_info "Swap is now disabled and will remain off after reboot"
}

# Step 2: Enable required cgroups in boot parameters
# Why: Kubelet requires cgroup memory accounting to enforce resource limits,
#      eviction policies, and reservations. Without this, kubelet cannot
#      protect the node from OOM conditions.
enable_cgroups() {
    log_step "Enabling cgroup memory accounting"

    # Raspberry Pi OS uses /boot/cmdline.txt or /boot/firmware/cmdline.txt
    CMDLINE_FILE=""
    if [[ -f /boot/firmware/cmdline.txt ]]; then
        CMDLINE_FILE="/boot/firmware/cmdline.txt"
    elif [[ -f /boot/cmdline.txt ]]; then
        CMDLINE_FILE="/boot/cmdline.txt"
    else
        log_warn "Cannot find /boot/cmdline.txt or /boot/firmware/cmdline.txt"
        log_warn "Skipping cgroup configuration"
        return
    fi

    log_detail "Using cmdline file: $CMDLINE_FILE"

    # Required cgroup parameters
    REQUIRED_PARAMS="cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory"

    # Check if already configured
    if grep -q "cgroup_memory=1" "$CMDLINE_FILE" && \
       grep -q "cgroup_enable=memory" "$CMDLINE_FILE"; then
        log_info "✓ cgroup parameters already configured"
        return
    fi

    # Backup original file
    cp "$CMDLINE_FILE" "${CMDLINE_FILE}.bak"
    log_detail "Backup created: ${CMDLINE_FILE}.bak"

    # Read current cmdline (single line)
    CURRENT_CMDLINE=$(cat "$CMDLINE_FILE")

    # Append required parameters (avoid duplicates)
    UPDATED_CMDLINE="$CURRENT_CMDLINE"
    for param in $REQUIRED_PARAMS; do
        if ! echo "$CURRENT_CMDLINE" | grep -q "$param"; then
            UPDATED_CMDLINE="$UPDATED_CMDLINE $param"
        fi
    done

    # Write updated cmdline
    echo "$UPDATED_CMDLINE" > "$CMDLINE_FILE"

    log_info "✓ cgroup parameters added to $CMDLINE_FILE"
    log_warn "REBOOT REQUIRED for cgroup changes to take effect"
    REBOOT_REQUIRED=true
}

# Step 3: Configure journald to cap log size
# Why: Unbounded logs can fill SD card and cause excessive write wear.
#      We cap journald instead of using tmpfs to preserve logs across
#      reboots for debugging (critical for edge troubleshooting).
configure_journald() {
    log_step "Configuring journald size limits"

    JOURNALD_CONF="/etc/systemd/journald.conf"

    if [[ ! -f "$JOURNALD_CONF" ]]; then
        log_warn "journald.conf not found at $JOURNALD_CONF"
        return
    fi

    # Backup original config
    if [[ ! -f "${JOURNALD_CONF}.bak" ]]; then
        cp "$JOURNALD_CONF" "${JOURNALD_CONF}.bak"
        log_detail "Backup created: ${JOURNALD_CONF}.bak"
    fi

    # Target settings:
    # SystemMaxUse=100M     - Total journal size limit (protects SD card)
    # SystemMaxFileSize=10M - Individual journal file size
    NEEDS_UPDATE=false

    # Check SystemMaxUse
    if grep -q "^SystemMaxUse=100M" "$JOURNALD_CONF"; then
        log_info "✓ SystemMaxUse already set to 100M"
    else
        # Remove any existing SystemMaxUse line and add our setting
        sed -i '/^SystemMaxUse=/d' "$JOURNALD_CONF"
        sed -i '/^\[Journal\]/a SystemMaxUse=100M' "$JOURNALD_CONF"
        log_info "✓ Set SystemMaxUse=100M"
        NEEDS_UPDATE=true
    fi

    # Check SystemMaxFileSize
    if grep -q "^SystemMaxFileSize=10M" "$JOURNALD_CONF"; then
        log_info "✓ SystemMaxFileSize already set to 10M"
    else
        sed -i '/^SystemMaxFileSize=/d' "$JOURNALD_CONF"
        sed -i '/^\[Journal\]/a SystemMaxFileSize=10M' "$JOURNALD_CONF"
        log_info "✓ Set SystemMaxFileSize=10M"
        NEEDS_UPDATE=true
    fi

    if $NEEDS_UPDATE; then
        # Restart journald to apply changes
        log_info "Restarting systemd-journald..."
        systemctl restart systemd-journald
        log_info "✓ journald configuration applied"
    else
        log_info "✓ journald already configured correctly"
    fi

    log_detail "Journal size capped at 100MB total (protects SD card from log wear)"
}

# Step 4: Load required kernel modules
# Why: Container networking requires bridge netfilter and overlay filesystem.
#      These must be loaded for K3s networking (Flannel) to function.
configure_kernel_modules() {
    log_step "Configuring required kernel modules"

    # Required modules:
    # - overlay: Container filesystem overlay support
    # - br_netfilter: Bridge netfilter for Kubernetes networking
    MODULES=("overlay" "br_netfilter")

    # Load modules now (runtime)
    for module in "${MODULES[@]}"; do
        if lsmod | grep -q "^$module "; then
            log_info "✓ Module $module already loaded"
        else
            log_info "Loading module $module..."
            modprobe "$module"
            log_info "✓ Module $module loaded"
        fi
    done

    # Persist modules across reboots
    MODULES_CONF="/etc/modules-load.d/k3s.conf"

    if [[ -f "$MODULES_CONF" ]]; then
        log_info "✓ Module persistence config exists: $MODULES_CONF"
    else
        log_info "Creating module persistence config: $MODULES_CONF..."
        cat > "$MODULES_CONF" <<EOF
# Kernel modules required for K3s
# These are loaded at boot to support container networking

# Overlay filesystem for container layers
overlay

# Bridge netfilter for Kubernetes pod networking (Flannel)
br_netfilter
EOF
        log_info "✓ Modules will load on boot: $MODULES_CONF"
    fi
}

# Step 5: Configure sysctl parameters
# Why: Kubernetes requires specific networking parameters to enable
#      bridge traffic filtering and IP forwarding for pod networking.
configure_sysctl() {
    log_step "Configuring sysctl parameters for Kubernetes networking"

    SYSCTL_CONF="/etc/sysctl.d/99-k3s.conf"

    # Required sysctl settings:
    # - net.bridge.bridge-nf-call-iptables: Allow iptables to see bridged traffic
    # - net.bridge.bridge-nf-call-ip6tables: IPv6 variant
    # - net.ipv4.ip_forward: Enable IP forwarding for pod routing

    if [[ -f "$SYSCTL_CONF" ]]; then
        log_info "✓ sysctl config exists: $SYSCTL_CONF"
    else
        log_info "Creating sysctl config: $SYSCTL_CONF..."
        cat > "$SYSCTL_CONF" <<EOF
# sysctl parameters for K3s networking
# These enable bridge traffic filtering and IP forwarding for pod networking

# Allow iptables to see bridged IPv4 traffic (required for Flannel CNI)
net.bridge.bridge-nf-call-iptables = 1

# Allow iptables to see bridged IPv6 traffic
net.bridge.bridge-nf-call-ip6tables = 1

# Enable IP forwarding (required for pod-to-pod and pod-to-service routing)
net.ipv4.ip_forward = 1
EOF
        log_info "✓ sysctl config created"
    fi

    # Apply sysctl settings now (runtime)
    log_info "Applying sysctl settings..."

    # br_netfilter must be loaded for bridge settings to apply
    if ! lsmod | grep -q "^br_netfilter "; then
        modprobe br_netfilter
    fi

    sysctl --system > /dev/null 2>&1 || true

    # Verify key settings
    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]]; then
        log_info "✓ net.ipv4.ip_forward = 1"
    else
        log_warn "net.ipv4.ip_forward may not be set correctly"
    fi

    if [[ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)" == "1" ]]; then
        log_info "✓ net.bridge.bridge-nf-call-iptables = 1"
    else
        log_warn "net.bridge.bridge-nf-call-iptables may not be set correctly"
    fi

    log_detail "Networking parameters configured for container bridge traffic"
}

# Print summary and next steps
print_summary() {
    echo ""
    echo "================================================================"
    log_info "OS Preparation Complete"
    echo "================================================================"
    echo ""

    if $REBOOT_REQUIRED; then
        echo -e "${YELLOW}⚠ REBOOT REQUIRED${NC}"
        echo ""
        echo "Changes made:"
        echo "  - cgroup memory accounting enabled in boot parameters"
        echo ""
        echo "Reboot now to apply all changes:"
        echo "  sudo reboot"
        echo ""
        echo "After reboot, verify with:"
        echo "  cat /proc/cmdline | grep cgroup"
        echo ""
    else
        echo -e "${GREEN}✓ All changes applied (no reboot needed)${NC}"
        echo ""
    fi

    echo "What was configured:"
    echo "  ✓ Swap disabled (Kubernetes requirement)"
    echo "  ✓ cgroup memory accounting enabled (kubelet limits)"
    echo "  ✓ journald size capped at 100MB (SD card protection)"
    echo "  ✓ Kernel modules loaded (overlay, br_netfilter)"
    echo "  ✓ sysctl networking parameters (IP forwarding, bridge filtering)"
    echo ""

    if $REBOOT_REQUIRED; then
        echo "Next steps:"
        echo "  1. Reboot: sudo reboot"
        echo "  2. Install K3s: sudo setup/install-k3s.sh"
        echo "  3. Validate: scripts/validate-phase1.sh"
    else
        echo "Next steps:"
        echo "  1. Install K3s: sudo setup/install-k3s.sh"
        echo "  2. Validate: scripts/validate-phase1.sh"
    fi
    echo ""
    echo "================================================================"
}

# Main execution
main() {
    echo "================================================================"
    echo "Phase 1 OS Preparation - Raspberry Pi for K3s"
    echo "================================================================"
    echo ""
    echo "This script prepares Raspberry Pi OS for edge Kubernetes deployment."
    echo "Focus: low memory, SD card longevity, power loss resilience"
    echo ""

    check_root

    disable_swap
    echo ""

    enable_cgroups
    echo ""

    configure_journald
    echo ""

    configure_kernel_modules
    echo ""

    configure_sysctl
    echo ""

    print_summary
}

main "$@"

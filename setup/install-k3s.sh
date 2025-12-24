#!/usr/bin/env bash
#
# K3s Installation Script for Edge Raspberry Pi Deployment
#
# Usage:
#   sudo ./install-k3s.sh
#
# Environment variables:
#   K3S_VERSION    - K3s version to install (default: stable)
#   K3S_TOKEN      - Cluster token for multi-node setup (optional)
#   K3S_NODE_NAME  - Override node name (optional, defaults to hostname)
#
# Requirements:
#   - Raspberry Pi OS 64-bit (or Ubuntu Server ARM64)
#   - Root/sudo access
#   - Internet connectivity for initial download
#   - Swap disabled, cgroups enabled
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/k3s-config.yaml"
K3S_VERSION="${K3S_VERSION:-stable}"
K3S_TOKEN="${K3S_TOKEN:-}"
K3S_NODE_NAME="${K3S_NODE_NAME:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Pre-flight checks
preflight_checks() {
    log_info "Running pre-flight checks..."

    # Check if K3s is already installed
    if command -v k3s &>/dev/null; then
        log_warn "K3s is already installed. Uninstall with: /usr/local/bin/k3s-uninstall.sh"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            exit 0
        fi
    fi

    # Check swap is disabled
    if swapon --show | grep -q .; then
        log_error "Swap is enabled. Kubernetes requires swap to be disabled."
        log_error "Disable with: sudo dphys-swapfile swapoff && sudo systemctl disable dphys-swapfile"
        exit 1
    fi
    log_info "✓ Swap is disabled"

    # Check cgroup memory is enabled
    if ! grep -q "cgroup_memory=1" /boot/cmdline.txt 2>/dev/null && \
       ! grep -q "cgroup_memory=1" /boot/firmware/cmdline.txt 2>/dev/null; then
        log_warn "cgroup memory may not be enabled"
        log_warn "Add to /boot/cmdline.txt: cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory"
        log_warn "Then reboot before installing K3s"
    else
        log_info "✓ cgroup memory appears to be enabled"
    fi

    # Check config file exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    log_info "✓ Config file found: $CONFIG_FILE"

    # Check architecture
    ARCH=$(uname -m)
    if [[ "$ARCH" != "aarch64" ]] && [[ "$ARCH" != "arm64" ]]; then
        log_warn "This script is optimized for ARM64. Detected: $ARCH"
    else
        log_info "✓ Architecture: $ARCH"
    fi
}

# Install K3s using official script
install_k3s() {
    log_info "Installing K3s version: $K3S_VERSION"
    log_info "Using config: $CONFIG_FILE"

    # Copy config to K3s expected location
    log_info "Copying config to /etc/rancher/k3s/config.yaml"
    mkdir -p /etc/rancher/k3s
    cp "$CONFIG_FILE" /etc/rancher/k3s/config.yaml

    # Set K3s version/channel env var
    if [[ "$K3S_VERSION" == "stable" ]] || [[ "$K3S_VERSION" == "latest" ]]; then
        export INSTALL_K3S_CHANNEL="$K3S_VERSION"
        log_info "Using K3s channel: $INSTALL_K3S_CHANNEL"
    elif [[ "$K3S_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        export INSTALL_K3S_VERSION="$K3S_VERSION"
        log_info "Using K3s version: $INSTALL_K3S_VERSION"
    else
        log_error "Invalid K3S_VERSION: $K3S_VERSION"
        log_error "Must be 'stable', 'latest', or a version starting with 'v' (e.g., v1.28.5+k3s1)"
        exit 1
    fi

    # Export optional token for multi-node
    if [[ -n "$K3S_TOKEN" ]]; then
        export K3S_TOKEN
        log_info "Using provided cluster token"
    fi

    # Export optional node name
    if [[ -n "$K3S_NODE_NAME" ]]; then
        export K3S_NODE_NAME
        log_info "Node name: $K3S_NODE_NAME"
    fi

    # Execute installation
    log_info "Running K3s installer..."
    curl -sfL https://get.k3s.io | sh -

    log_info "✓ K3s installation complete"
}

# Wait for K3s to be ready
wait_for_k3s() {
    log_info "Waiting for K3s service to start..."

    local max_wait=60
    local elapsed=0

    while ! systemctl is-active --quiet k3s; do
        if [[ $elapsed -ge $max_wait ]]; then
            log_error "K3s service did not start within ${max_wait}s"
            log_error "Check logs: sudo journalctl -u k3s -f"
            exit 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_info "✓ K3s service is active"
}

# Print next steps
print_next_steps() {
    echo ""
    echo "================================================================"
    log_info "K3s installation successful!"
    echo "================================================================"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Check K3s service status:"
    echo "   sudo systemctl status k3s"
    echo ""
    echo "2. View K3s logs:"
    echo "   sudo journalctl -u k3s -f"
    echo ""
    echo "3. Access cluster (kubeconfig location):"
    echo "   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
    echo "   kubectl get nodes"
    echo ""
    echo "   Or for non-root access:"
    echo "   mkdir -p ~/.kube"
    echo "   sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config"
    echo "   sudo chown \$(id -u):\$(id -g) ~/.kube/config"
    echo ""
    echo "4. Verify cluster health:"
    echo "   kubectl get nodes -o wide"
    echo "   kubectl get pods -A"
    echo ""
    echo "5. Check resource usage (OS tools):"
    echo "   free -h"
    echo "   sudo systemctl status k3s | grep Memory"
    echo ""
    echo "6. To uninstall K3s:"
    echo "   /usr/local/bin/k3s-uninstall.sh"
    echo ""
    echo "================================================================"
    echo "Kubeconfig: /etc/rancher/k3s/k3s.yaml"
    echo "Data dir:   /var/lib/rancher/k3s"
    echo "Config:     /etc/rancher/k3s/config.yaml"
    echo "================================================================"
    echo ""
}

# Main execution
main() {
    log_info "Starting K3s installation for edge Raspberry Pi deployment"
    echo ""

    check_root
    preflight_checks
    echo ""

    install_k3s
    wait_for_k3s

    print_next_steps
}

main "$@"

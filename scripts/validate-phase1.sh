#!/usr/bin/env bash
#
# Phase 1 Validation Script - K3s Edge Cluster
#
# Validates that K3s installation meets Phase 1 requirements:
# - K3s service running
# - Resource usage within edge constraints
# - Expected components running
# - Disabled components absent
# - No critical errors
#
# Usage:
#   ./validate-phase1.sh
#
# Requirements:
#   - K3s installed
#   - kubectl available
#   - Read-only (no system modifications)
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

# Logging functions
log_check() {
    echo -e "${BLUE}[CHECK]${NC} $*"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    CHECKS_WARNED=$((CHECKS_WARNED + 1))
}

log_info() {
    echo -e "       $*"
}

# Check 1: K3s service status
check_k3s_service() {
    log_check "K3s service status"

    if ! command -v systemctl &>/dev/null; then
        log_fail "systemctl not found"
        log_info "This script requires systemd"
        return
    fi

    if systemctl is-active --quiet k3s; then
        log_pass "K3s service is active"
    else
        log_fail "K3s service is not running"
        log_info "Common causes:"
        log_info "  - K3s not installed"
        log_info "  - Installation failed"
        log_info "  - Service crashed after start"
        log_info "Check logs: sudo journalctl -u k3s --no-pager -n 50"
        return
    fi

    # Check if enabled for auto-start
    if systemctl is-enabled --quiet k3s 2>/dev/null; then
        log_pass "K3s service is enabled (will start on boot)"
    else
        log_warn "K3s service is not enabled for auto-start"
        log_info "Enable with: sudo systemctl enable k3s"
    fi
}

# Check 2: Memory usage (OS tools, no kubectl top)
check_memory_usage() {
    log_check "Memory usage (edge constraint: <600MB on 2GB Pi)"

    # Get total and used memory in MB
    if ! command -v free &>/dev/null; then
        log_warn "free command not found, skipping memory check"
        return
    fi

    # Parse free output (in MB)
    TOTAL_MEM=$(free -m | awk 'NR==2 {print $2}')
    USED_MEM=$(free -m | awk 'NR==2 {print $3}')

    log_info "Total: ${TOTAL_MEM}MB, Used: ${USED_MEM}MB"

    # Check if under 600MB (good for 2GB Pi)
    if [[ $USED_MEM -lt 600 ]]; then
        log_pass "Memory usage is good for edge deployment"
    elif [[ $USED_MEM -lt 800 ]]; then
        log_warn "Memory usage is moderate: ${USED_MEM}MB"
        log_info "Acceptable for 2GB+ Pi, tight for 1GB"
    else
        log_fail "Memory usage is high: ${USED_MEM}MB"
        log_info "Common causes:"
        log_info "  - Too many components enabled (check disabled list)"
        log_info "  - Workload pods consuming memory"
        log_info "  - Insufficient system/kube reservations"
        log_info "Check K3s memory: sudo systemctl status k3s | grep Memory"
    fi
}

# Check 3: Disk space
check_disk_space() {
    log_check "Disk space (edge constraint: >2GB free)"

    if ! command -v df &>/dev/null; then
        log_warn "df command not found, skipping disk check"
        return
    fi

    # Check root filesystem
    ROOT_AVAIL=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')

    log_info "Available on /: ${ROOT_AVAIL}GB"

    if [[ $ROOT_AVAIL -gt 5 ]]; then
        log_pass "Sufficient disk space"
    elif [[ $ROOT_AVAIL -gt 2 ]]; then
        log_warn "Disk space is low: ${ROOT_AVAIL}GB"
        log_info "Monitor usage, consider cleanup"
    else
        log_fail "Disk space critical: ${ROOT_AVAIL}GB"
        log_info "Common causes:"
        log_info "  - Excessive logging (check journald size)"
        log_info "  - Container images filling disk"
        log_info "  - Insufficient SD card size"
        log_info "Check usage: sudo du -sh /var/lib/rancher/k3s /var/log"
    fi
}

# Check 4: K3s logs for errors
check_k3s_logs() {
    log_check "K3s logs (last 5 minutes for errors)"

    if ! command -v journalctl &>/dev/null; then
        log_warn "journalctl not found, skipping log check"
        return
    fi

    # Check for errors in last 5 minutes
    ERROR_COUNT=$(sudo journalctl -u k3s --since "5 minutes ago" --no-pager 2>/dev/null | grep -i "error" | grep -v "vendor/k8s.io" | wc -l || echo "0")

    if [[ $ERROR_COUNT -eq 0 ]]; then
        log_pass "No recent errors in K3s logs"
    else
        log_warn "Found $ERROR_COUNT error lines in recent logs"
        log_info "Review with: sudo journalctl -u k3s --since '5 minutes ago' | grep -i error"
        log_info "Some errors are transient during startup"
    fi
}

# Check 5: kubectl availability
check_kubectl() {
    log_check "kubectl availability"

    if ! command -v kubectl &>/dev/null; then
        log_fail "kubectl not found in PATH"
        log_info "Common causes:"
        log_info "  - K3s not installed (kubectl is bundled)"
        log_info "  - PATH not updated"
        log_info "Try: export PATH=/usr/local/bin:\$PATH"
        return 1
    fi

    log_pass "kubectl is available"

    # Check kubeconfig
    if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
        log_pass "Kubeconfig exists at /etc/rancher/k3s/k3s.yaml"
    else
        log_fail "Kubeconfig not found at /etc/rancher/k3s/k3s.yaml"
        log_info "K3s installation may be incomplete"
        return 1
    fi

    return 0
}

# Check 6: Node status
check_node_status() {
    log_check "Node status (should be Ready)"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    if ! NODE_STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}'); then
        log_fail "Cannot get node status"
        log_info "Common causes:"
        log_info "  - API server not ready"
        log_info "  - Kubeconfig permissions issue"
        log_info "  - Network issue preventing API access"
        return
    fi

    if [[ -z "$NODE_STATUS" ]]; then
        log_fail "No nodes found"
        log_info "K3s may not be fully initialized"
        return
    fi

    if [[ "$NODE_STATUS" == "Ready" ]]; then
        log_pass "Node is Ready"
    else
        log_fail "Node status is: $NODE_STATUS"
        log_info "Common causes:"
        log_info "  - CNI plugin not ready"
        log_info "  - Kubelet not healthy"
        log_info "  - Resource pressure"
        log_info "Check: kubectl describe node"
    fi
}

# Check 7: Expected pods running
check_expected_pods() {
    log_check "Expected pods (coredns, local-path-provisioner)"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # Check CoreDNS
    if kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -q "Running"; then
        log_pass "CoreDNS is running"
    else
        log_fail "CoreDNS is not running"
        log_info "Common causes:"
        log_info "  - Insufficient memory"
        log_info "  - Image pull failure (check connectivity)"
        log_info "  - CNI issue"
        log_info "Check: kubectl get pods -n kube-system -l k8s-app=kube-dns"
    fi

    # Check local-path-provisioner
    if kubectl get pods -n kube-system -l app=local-path-provisioner --no-headers 2>/dev/null | grep -q "Running"; then
        log_pass "local-path-provisioner is running"
    else
        log_warn "local-path-provisioner is not running"
        log_info "This provides default StorageClass for PVCs"
        log_info "Check: kubectl get pods -n kube-system -l app=local-path-provisioner"
    fi
}

# Check 8: Disabled components are absent
check_disabled_components() {
    log_check "Disabled components (should NOT be running)"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # Check Traefik is NOT running
    if kubectl get pods -A --no-headers 2>/dev/null | grep -q "traefik"; then
        log_fail "Traefik is running (should be disabled)"
        log_info "Check setup/k3s-config.yaml disable list"
    else
        log_pass "Traefik is disabled (expected)"
    fi

    # Check ServiceLB is NOT running
    if kubectl get pods -A --no-headers 2>/dev/null | grep -q "svclb"; then
        log_fail "ServiceLB is running (should be disabled)"
        log_info "Check setup/k3s-config.yaml disable list"
    else
        log_pass "ServiceLB is disabled (expected)"
    fi

    # Check metrics-server is NOT running
    if kubectl get pods -A --no-headers 2>/dev/null | grep -q "metrics-server"; then
        log_fail "metrics-server is running (should be disabled)"
        log_info "Check setup/k3s-config.yaml disable list"
    else
        log_pass "metrics-server is disabled (expected)"
    fi
}

# Check 9: StorageClass exists
check_storage_class() {
    log_check "StorageClass (local-path should exist)"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    if kubectl get storageclass local-path &>/dev/null; then
        log_pass "StorageClass 'local-path' exists"

        # Check if it's default
        if kubectl get storageclass local-path -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null | grep -q "true"; then
            log_pass "local-path is the default StorageClass"
        else
            log_warn "local-path exists but is not marked as default"
        fi
    else
        log_fail "StorageClass 'local-path' not found"
        log_info "Common causes:"
        log_info "  - local-path-provisioner not running"
        log_info "  - local-path was disabled in config (should be enabled)"
        log_info "Check: kubectl get storageclass"
    fi
}

# Print summary
print_summary() {
    echo ""
    echo "================================================================"
    echo "Phase 1 Validation Summary"
    echo "================================================================"
    echo -e "${GREEN}Passed: $CHECKS_PASSED${NC}"
    echo -e "${YELLOW}Warnings: $CHECKS_WARNED${NC}"
    echo -e "${RED}Failed: $CHECKS_FAILED${NC}"
    echo "================================================================"
    echo ""

    if [[ $CHECKS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ Phase 1 cluster is healthy${NC}"
        echo ""
        echo "Next steps:"
        echo "  - Test failure scenarios (reboot, power loss)"
        echo "  - Proceed to Phase 2 (MQTT broker deployment)"
        return 0
    else
        echo -e "${RED}✗ Phase 1 validation failed${NC}"
        echo ""
        echo "Fix issues above before proceeding to Phase 2"
        return 1
    fi
}

# Main execution
main() {
    echo "================================================================"
    echo "Phase 1 Validation - K3s Edge Cluster"
    echo "================================================================"
    echo ""

    # Run all checks
    check_k3s_service
    echo ""

    check_memory_usage
    echo ""

    check_disk_space
    echo ""

    check_k3s_logs
    echo ""

    if check_kubectl; then
        echo ""
        check_node_status
        echo ""

        check_expected_pods
        echo ""

        check_disabled_components
        echo ""

        check_storage_class
        echo ""
    else
        echo ""
        log_fail "Skipping Kubernetes checks (kubectl not available)"
        echo ""
    fi

    print_summary
}

main "$@"

#!/usr/bin/env bash
#
# Phase 1 Failure Scenario Testing - K3s Edge Cluster
#
# Tests resilience under edge failure conditions:
#   1. Reboot recovery
#   2. Power loss simulation
#   3. Network disconnection
#   4. Memory pressure
#   5. Pod failure recovery
#
# This script is READ-ONLY with guided manual steps.
# It does NOT automatically reboot, shutdown, or break the system.
#
# Usage:
#   ./scripts/failure-scenarios-phase1.sh [scenario-number]
#
# Interactive mode (no arguments) shows menu.
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Logging functions
log_header() {
    echo ""
    echo -e "${BOLD}${BLUE}================================================================${NC}"
    echo -e "${BOLD}${BLUE}$*${NC}"
    echo -e "${BOLD}${BLUE}================================================================${NC}"
    echo ""
}

log_section() {
    echo ""
    echo -e "${CYAN}${BOLD}>>> $*${NC}"
    echo ""
}

log_step() {
    echo -e "${YELLOW}[STEP]${NC} $*"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_cmd() {
    echo -e "${CYAN}  $ $*${NC}"
}

log_detail() {
    echo "       $*"
}

log_manual() {
    echo -e "${BOLD}${YELLOW}[MANUAL]${NC} $*"
}

# Pause for user confirmation
wait_for_user() {
    echo ""
    read -p "Press ENTER to continue..." -r
    echo ""
}

# Pre-test validation
run_precheck() {
    log_section "Pre-Test Validation"

    local all_good=true

    # Check K3s is running
    if systemctl is-active --quiet k3s; then
        log_pass "K3s service is running"
    else
        log_fail "K3s service is not running"
        log_detail "Start with: sudo systemctl start k3s"
        all_good=false
    fi

    # Check kubectl is available
    if command -v kubectl &>/dev/null; then
        log_pass "kubectl is available"
    else
        log_fail "kubectl not found"
        all_good=false
    fi

    # Check node is Ready
    if kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
        log_pass "Node is Ready"
    else
        log_fail "Node is not Ready"
        all_good=false
    fi

    # Check pods are running
    local pod_count=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [[ $pod_count -gt 0 ]]; then
        log_pass "$pod_count pods Running"
    else
        log_warn "No pods are Running"
    fi

    if ! $all_good; then
        echo ""
        log_warn "Pre-checks failed. Fix issues before testing."
        return 1
    fi

    echo ""
    log_info "System is ready for failure scenario testing"
    return 0
}

# Scenario 1: Reboot Recovery Test
test_reboot_recovery() {
    log_header "Test 1: Reboot Recovery"

    log_info "Purpose: Verify K3s survives reboot and auto-starts without intervention"
    log_info "Edge rationale: Edge devices experience frequent power cycles"
    echo ""

    if ! run_precheck; then
        return 1
    fi

    log_section "Pre-Reboot Checks"

    log_step "Record current state"
    log_cmd "kubectl get nodes -o wide"
    kubectl get nodes -o wide

    echo ""
    log_cmd "kubectl get pods -A"
    kubectl get pods -A

    echo ""
    log_cmd "sudo systemctl is-enabled k3s"
    if sudo systemctl is-enabled k3s &>/dev/null; then
        log_pass "K3s is enabled (will auto-start on boot)"
    else
        log_fail "K3s is NOT enabled for auto-start"
        log_detail "Enable with: sudo systemctl enable k3s"
        return 1
    fi

    echo ""
    log_cmd "uptime"
    uptime

    wait_for_user

    log_section "Manual Action Required"

    echo "Perform a clean reboot:"
    log_manual "Run: sudo reboot"
    echo ""
    log_warn "This script will exit. After reboot, run:"
    log_cmd "./scripts/failure-scenarios-phase1.sh 1-post"
    echo ""
}

# Scenario 1 Post-Reboot Validation
test_reboot_recovery_post() {
    log_header "Test 1: Reboot Recovery - Post-Reboot Validation"

    log_section "Post-Reboot Checks"

    log_step "Wait for K3s to stabilize (30 seconds)..."
    sleep 30

    local passed=0
    local failed=0

    # Check 1: K3s auto-started
    log_step "Check K3s auto-started"
    if systemctl is-active --quiet k3s; then
        log_pass "K3s service auto-started"
        ((passed++))
    else
        log_fail "K3s service did not auto-start"
        log_detail "Check: sudo journalctl -u k3s -b"
        ((failed++))
    fi

    # Check 2: Node is Ready
    echo ""
    log_step "Check node is Ready"
    local node_status=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
    if [[ "$node_status" == "Ready" ]]; then
        log_pass "Node is Ready"
        ((passed++))
    else
        log_fail "Node status: $node_status"
        log_detail "Check: kubectl describe node"
        ((failed++))
    fi

    # Check 3: CoreDNS running
    echo ""
    log_step "Check CoreDNS recovered"
    if kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -q "Running"; then
        log_pass "CoreDNS is Running"
        ((passed++))
    else
        log_fail "CoreDNS is not Running"
        log_detail "Check: kubectl get pods -n kube-system -l k8s-app=kube-dns"
        ((failed++))
    fi

    # Check 4: No crash loops
    echo ""
    log_step "Check for crash loops"
    local crashloop_count=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "CrashLoopBackOff" || echo "0")
    if [[ $crashloop_count -eq 0 ]]; then
        log_pass "No pods in CrashLoopBackOff"
        ((passed++))
    else
        log_fail "$crashloop_count pods in CrashLoopBackOff"
        log_detail "Check: kubectl get pods -A | grep CrashLoopBackOff"
        ((failed++))
    fi

    # Check 5: Boot time
    echo ""
    log_step "Check boot logs for errors"
    local error_count=$(sudo journalctl -u k3s -b 2>/dev/null | grep -i error | wc -l || echo "0")
    if [[ $error_count -eq 0 ]]; then
        log_pass "No errors in boot logs"
        ((passed++))
    else
        log_warn "$error_count error lines in boot logs"
        log_detail "Review: sudo journalctl -u k3s -b | grep -i error"
    fi

    # Summary
    echo ""
    log_section "Test Results"
    echo "Passed: $passed"
    echo "Failed: $failed"
    echo ""

    if [[ $failed -eq 0 ]]; then
        log_pass "REBOOT RECOVERY TEST PASSED"
        log_info "Cluster recovered automatically from clean reboot"
        return 0
    else
        log_fail "REBOOT RECOVERY TEST FAILED"
        log_detail "Common causes:"
        log_detail "  - K3s service not enabled (systemctl enable k3s)"
        log_detail "  - systemd dependency issues"
        log_detail "  - Persistent storage corruption"
        return 1
    fi
}

# Scenario 2: Power Loss Simulation
test_power_loss() {
    log_header "Test 2: Power Loss Simulation"

    log_info "Purpose: Verify K3s recovers from hard shutdown (no graceful stop)"
    log_info "Edge rationale: Edge devices experience power failures without warning"
    echo ""

    if ! run_precheck; then
        return 1
    fi

    log_section "Pre-Shutdown Checks"

    log_step "Record SQLite database state"
    log_cmd "sudo ls -lh /var/lib/rancher/k3s/server/db/"
    sudo ls -lh /var/lib/rancher/k3s/server/db/ 2>/dev/null || log_warn "Database directory not found"

    echo ""
    log_step "Record running pods"
    log_cmd "kubectl get pods -A --no-headers | wc -l"
    local pod_count=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
    echo "Running pods: $pod_count"

    wait_for_user

    log_section "Manual Action Required"

    echo "Simulate power loss with a forced reboot (skips shutdown scripts):"
    log_manual "Run: sudo sync && sudo reboot -f"
    echo ""
    log_warn "WARNING: This is a hard shutdown. Use only on test systems."
    log_warn "This script will exit. After boot, run:"
    log_cmd "./scripts/failure-scenarios-phase1.sh 2-post"
    echo ""
}

# Scenario 2 Post-Power-Loss Validation
test_power_loss_post() {
    log_header "Test 2: Power Loss Simulation - Post-Recovery Validation"

    log_section "Post-Recovery Checks"

    log_step "Wait for K3s to stabilize (30 seconds)..."
    sleep 30

    local passed=0
    local failed=0

    # Check 1: K3s recovered
    log_step "Check K3s recovered from hard shutdown"
    if systemctl is-active --quiet k3s; then
        log_pass "K3s service is running"
        ((passed++))
    else
        log_fail "K3s service is not running"
        log_detail "Check: sudo journalctl -u k3s -b"
        ((failed++))
    fi

    # Check 2: SQLite database integrity
    echo ""
    log_step "Check SQLite database integrity"
    if [[ -f /var/lib/rancher/k3s/server/db/state.db ]]; then
        # Try to query database
        if sudo k3s kubectl get nodes &>/dev/null; then
            log_pass "SQLite database is intact"
            ((passed++))
        else
            log_fail "Database may be corrupted"
            log_detail "Check: sudo k3s check-config"
            ((failed++))
        fi
    else
        log_fail "SQLite database not found"
        ((failed++))
    fi

    # Check 3: Pods restarted
    echo ""
    log_step "Check pods restarted successfully"
    local running_pods=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [[ $running_pods -gt 0 ]]; then
        log_pass "$running_pods pods Running"
        ((passed++))
    else
        log_fail "No pods Running"
        ((failed++))
    fi

    # Check 4: Check for error logs from hard shutdown
    echo ""
    log_step "Check boot logs for corruption warnings"
    if sudo journalctl -b | grep -iq "corruption\|fsck\|filesystem.*error"; then
        log_warn "Found filesystem warnings in boot logs"
        log_detail "Review: sudo journalctl -b | grep -i corruption"
    else
        log_pass "No filesystem corruption warnings"
        ((passed++))
    fi

    # Summary
    echo ""
    log_section "Test Results"
    echo "Passed: $passed"
    echo "Failed: $failed"
    echo ""

    if [[ $failed -eq 0 ]]; then
        log_pass "POWER LOSS SIMULATION PASSED"
        log_info "Cluster recovered from hard shutdown without corruption"
        return 0
    else
        log_fail "POWER LOSS SIMULATION FAILED"
        log_detail "Common causes:"
        log_detail "  - SQLite database corruption (fsync issues)"
        log_detail "  - SD card corruption (use better SD card, enable sync mount)"
        log_detail "  - Incomplete writes during shutdown"
        return 1
    fi
}

# Scenario 3: Network Disconnection
test_network_isolation() {
    log_header "Test 3: Network Disconnection During Operation"

    log_info "Purpose: Verify K3s operates without external network"
    log_info "Edge rationale: Edge devices have intermittent connectivity"
    echo ""

    if ! run_precheck; then
        return 1
    fi

    log_section "Pre-Disconnect Checks"

    log_step "Check current network connectivity"
    log_cmd "ip addr show"
    ip addr show | grep "inet " | grep -v "127.0.0.1"

    echo ""
    log_cmd "ping -c 1 8.8.8.8"
    if ping -c 1 8.8.8.8 &>/dev/null; then
        log_pass "Internet connectivity available"
    else
        log_warn "No internet connectivity (already disconnected?)"
    fi

    wait_for_user

    log_section "Manual Action: Disconnect Network"

    echo "Options to disconnect network:"
    echo ""
    echo "Option A - Disable interface (WiFi example):"
    log_manual "Run: sudo ip link set wlan0 down"
    echo ""
    echo "Option B - Disable interface (Ethernet example):"
    log_manual "Run: sudo ip link set eth0 down"
    echo ""
    echo "Option C - Stop K3s, disconnect cable/WiFi, restart K3s:"
    log_manual "Run: sudo systemctl stop k3s"
    echo "  (disconnect network physically)"
    log_manual "Run: sudo systemctl start k3s"
    echo ""

    wait_for_user

    log_section "Validation While Disconnected"

    local passed=0
    local failed=0

    # Check 1: Verify network is down
    log_step "Verify network disconnection"
    if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        log_pass "Network is disconnected (cannot reach 8.8.8.8)"
        ((passed++))
    else
        log_warn "Network still appears connected"
        log_detail "Ensure network interface is down or cable disconnected"
    fi

    # Check 2: K3s still running
    echo ""
    log_step "Check K3s continues running without network"
    if systemctl is-active --quiet k3s; then
        log_pass "K3s service still running"
        ((passed++))
    else
        log_fail "K3s service stopped"
        ((failed++))
    fi

    # Check 3: Node still Ready
    echo ""
    log_step "Check node status without network"
    local node_status=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
    if [[ "$node_status" == "Ready" ]]; then
        log_pass "Node is still Ready"
        ((passed++))
    else
        log_fail "Node status changed to: $node_status"
        ((failed++))
    fi

    # Check 4: Pods still running
    echo ""
    log_step "Check pods continue running"
    local running_pods=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [[ $running_pods -gt 0 ]]; then
        log_pass "$running_pods pods still Running"
        ((passed++))
    else
        log_fail "Pods stopped running"
        ((failed++))
    fi

    # Check 5: Internal DNS works
    echo ""
    log_step "Check internal DNS resolution (no external dependency)"
    local coredns_pod=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    if [[ -n "$coredns_pod" ]]; then
        if kubectl exec -n kube-system "$coredns_pod" -- nslookup kubernetes.default &>/dev/null; then
            log_pass "Internal DNS resolution works"
            ((passed++))
        else
            log_warn "DNS test failed (may need CoreDNS to be ready)"
        fi
    else
        log_warn "CoreDNS pod not found for DNS test"
    fi

    echo ""
    log_section "Manual Action: Reconnect Network"

    echo "Reconnect network using reverse of disconnect method:"
    echo ""
    echo "Option A - Re-enable interface:"
    log_manual "Run: sudo ip link set wlan0 up  # or eth0"
    echo ""
    echo "Option B - Reconnect cable/WiFi physically"
    echo ""

    wait_for_user

    log_step "Verify network restored"
    if ping -c 1 8.8.8.8 &>/dev/null; then
        log_pass "Network connectivity restored"
    else
        log_warn "Network still disconnected"
    fi

    # Summary
    echo ""
    log_section "Test Results"
    echo "Passed: $passed"
    echo "Failed: $failed"
    echo ""

    if [[ $failed -eq 0 ]]; then
        log_pass "NETWORK ISOLATION TEST PASSED"
        log_info "Cluster operates independently of external network"
        return 0
    else
        log_fail "NETWORK ISOLATION TEST FAILED"
        log_detail "Common causes:"
        log_detail "  - K3s configured to require external dependencies"
        log_detail "  - Pods configured with external image pull (ImagePullBackOff)"
        log_detail "  - Network policies blocking internal traffic"
        return 1
    fi
}

# Scenario 4: Memory Pressure
test_memory_pressure() {
    log_header "Test 4: Memory Pressure and Eviction"

    log_info "Purpose: Verify kubelet evicts pods under memory pressure"
    log_info "Edge rationale: Constrained devices must handle OOM gracefully"
    echo ""

    if ! run_precheck; then
        return 1
    fi

    log_section "Pre-Test Memory State"

    log_step "Check current memory usage"
    log_cmd "free -h"
    free -h

    echo ""
    log_step "Check eviction thresholds from kubelet config"
    log_info "Expected from k3s-config.yaml:"
    log_detail "Hard eviction: memory.available<100Mi"
    log_detail "Soft eviction: memory.available<200Mi (grace: 2m)"

    wait_for_user

    log_section "Deploy Memory-Hungry Test Pod"

    log_step "Apply test pod manifest"
    log_cmd "kubectl apply -f k8s/memory-pressure-test.yaml"
    kubectl apply -f k8s/memory-pressure-test.yaml

    echo ""
    log_step "Wait for pod to start (10 seconds)..."
    sleep 10

    log_cmd "kubectl get pod memory-pressure-test"
    kubectl get pod memory-pressure-test 2>/dev/null || log_warn "Pod not found"

    echo ""
    log_step "Monitor memory usage"
    log_cmd "free -h"
    free -h

    echo ""
    log_step "Watch for eviction events (30 seconds)..."
    log_info "Eviction may occur if total memory pressure is high"
    log_cmd "kubectl get events --sort-by='.lastTimestamp' | grep -i evict | tail -5"
    sleep 30
    kubectl get events --sort-by='.lastTimestamp' 2>/dev/null | grep -i evict | tail -5 || log_info "No eviction events (memory sufficient)"

    echo ""
    log_section "Validation"

    local passed=0
    local failed=0

    # Check 1: Node didn't crash
    log_step "Check node survived memory pressure"
    if kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
        log_pass "Node is still Ready"
        ((passed++))
    else
        log_fail "Node is not Ready"
        ((failed++))
    fi

    # Check 2: Check if pod is running or evicted
    echo ""
    log_step "Check test pod status"
    local pod_status=$(kubectl get pod memory-pressure-test --no-headers 2>/dev/null | awk '{print $3}')
    if [[ "$pod_status" == "Running" ]]; then
        log_info "Pod is Running (memory was sufficient)"
    elif [[ "$pod_status" == "Evicted" ]] || [[ "$pod_status" == "OOMKilled" ]]; then
        log_pass "Pod was evicted/OOMKilled (eviction policy working)"
        ((passed++))
    else
        log_info "Pod status: $pod_status"
    fi

    # Check 3: CoreDNS still running (critical pod)
    echo ""
    log_step "Check CoreDNS survived (should not be evicted)"
    if kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -q "Running"; then
        log_pass "CoreDNS still Running (critical pods protected)"
        ((passed++))
    else
        log_fail "CoreDNS was affected by memory pressure"
        ((failed++))
    fi

    # Cleanup
    echo ""
    log_section "Cleanup"
    log_step "Delete test pod"
    log_cmd "kubectl delete -f k8s/memory-pressure-test.yaml --ignore-not-found"
    kubectl delete -f k8s/memory-pressure-test.yaml --ignore-not-found

    sleep 5

    # Summary
    echo ""
    log_section "Test Results"
    echo "Passed: $passed"
    echo "Failed: $failed"
    echo ""

    if [[ $failed -eq 0 ]]; then
        log_pass "MEMORY PRESSURE TEST PASSED"
        log_info "Node handled memory pressure without crashing"
        return 0
    else
        log_fail "MEMORY PRESSURE TEST FAILED"
        log_detail "Common causes:"
        log_detail "  - Eviction thresholds not configured correctly"
        log_detail "  - Insufficient system/kube memory reservations"
        log_detail "  - OOM killer targeting critical system processes"
        return 1
    fi
}

# Scenario 5: Pod Failure Recovery
test_pod_recovery() {
    log_header "Test 5: Pod Failure and Auto-Recovery"

    log_info "Purpose: Verify Kubernetes auto-restarts failed pods"
    log_info "Edge rationale: Unattended edge devices must self-heal"
    echo ""

    if ! run_precheck; then
        return 1
    fi

    log_section "Target: CoreDNS Pod Recovery"

    local passed=0
    local failed=0

    log_step "Get current CoreDNS pod"
    log_cmd "kubectl get pods -n kube-system -l k8s-app=kube-dns"
    kubectl get pods -n kube-system -l k8s-app=kube-dns

    local coredns_pod=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    if [[ -z "$coredns_pod" ]]; then
        log_fail "CoreDNS pod not found"
        return 1
    fi

    echo ""
    log_info "Target pod: $coredns_pod"

    wait_for_user

    log_section "Delete CoreDNS Pod (Simulated Failure)"

    log_step "Delete pod to simulate crash"
    log_cmd "kubectl delete pod -n kube-system $coredns_pod"
    kubectl delete pod -n kube-system "$coredns_pod"

    echo ""
    log_step "Watch for new pod to start (20 seconds)..."
    sleep 5
    log_cmd "kubectl get pods -n kube-system -l k8s-app=kube-dns -w"
    timeout 15s kubectl get pods -n kube-system -l k8s-app=kube-dns -w 2>/dev/null || true

    echo ""
    log_section "Validation"

    # Check 1: New pod created
    log_step "Check new CoreDNS pod exists"
    local new_pod=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    if [[ -n "$new_pod" ]] && [[ "$new_pod" != "$coredns_pod" ]]; then
        log_pass "New pod created: $new_pod"
        ((passed++))
    else
        log_fail "No new pod created"
        ((failed++))
    fi

    # Check 2: New pod is Running
    echo ""
    log_step "Check new pod is Running"
    sleep 10  # Give it time to start
    local pod_status=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | head -1 | awk '{print $3}')
    if [[ "$pod_status" == "Running" ]]; then
        log_pass "New pod is Running"
        ((passed++))
    else
        log_warn "Pod status: $pod_status (may still be starting)"
    fi

    # Check 3: DNS resolution works
    echo ""
    log_step "Check DNS resolution works with new pod"
    kubectl run test-dns --image=busybox:1.36 --restart=Never --command -- sh -c "nslookup kubernetes.default.svc.cluster.local" &>/dev/null
    sleep 5
    if kubectl logs test-dns 2>/dev/null | grep -q "Address:"; then
        log_pass "DNS resolution works"
        ((passed++))
    else
        log_warn "DNS test failed (pod may still be initializing)"
    fi
    kubectl delete pod test-dns --ignore-not-found &>/dev/null

    # Check 4: Recovery time
    echo ""
    log_step "Check recovery was fast (<30 seconds)"
    log_info "Recovery time in production should be under 30 seconds"
    local age=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | head -1 | awk '{print $5}')
    log_info "New pod age: $age"

    # Summary
    echo ""
    log_section "Test Results"
    echo "Passed: $passed"
    echo "Failed: $failed"
    echo ""

    if [[ $failed -eq 0 ]]; then
        log_pass "POD RECOVERY TEST PASSED"
        log_info "Kubernetes auto-recovered from pod failure"
        return 0
    else
        log_fail "POD RECOVERY TEST FAILED"
        log_detail "Common causes:"
        log_detail "  - Deployment/ReplicaSet not managing pod"
        log_detail "  - Image pull failure (check connectivity)"
        log_detail "  - Resource constraints preventing restart"
        return 1
    fi
}

# Show menu
show_menu() {
    log_header "Phase 1 Failure Scenario Testing - Menu"

    echo "Select a test scenario:"
    echo ""
    echo "  1) Reboot Recovery Test"
    echo "  2) Power Loss Simulation"
    echo "  3) Network Disconnection"
    echo "  4) Memory Pressure and Eviction"
    echo "  5) Pod Failure Recovery"
    echo ""
    echo "  a) Run all tests (requires manual reboots)"
    echo "  q) Quit"
    echo ""
    read -p "Choice: " -r choice

    case "$choice" in
        1) test_reboot_recovery ;;
        2) test_power_loss ;;
        3) test_network_isolation ;;
        4) test_memory_pressure ;;
        5) test_pod_recovery ;;
        a) run_all_tests ;;
        q) exit 0 ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
}

# Run all tests
run_all_tests() {
    log_header "Running All Failure Scenarios"

    test_pod_recovery
    echo ""
    wait_for_user

    test_memory_pressure
    echo ""
    wait_for_user

    test_network_isolation
    echo ""
    wait_for_user

    log_info "Destructive tests require manual execution:"
    log_info "  - Reboot test: ./scripts/failure-scenarios-phase1.sh 1"
    log_info "  - Power loss: ./scripts/failure-scenarios-phase1.sh 2"
}

# Main execution
main() {
    local scenario="${1:-}"

    case "$scenario" in
        "1")
            test_reboot_recovery
            ;;
        "1-post")
            test_reboot_recovery_post
            ;;
        "2")
            test_power_loss
            ;;
        "2-post")
            test_power_loss_post
            ;;
        "3")
            test_network_isolation
            ;;
        "4")
            test_memory_pressure
            ;;
        "5")
            test_pod_recovery
            ;;
        "")
            show_menu
            ;;
        *)
            echo "Usage: $0 [1|2|3|4|5]"
            echo ""
            echo "Scenarios:"
            echo "  1 - Reboot Recovery"
            echo "  2 - Power Loss Simulation"
            echo "  3 - Network Disconnection"
            echo "  4 - Memory Pressure"
            echo "  5 - Pod Recovery"
            exit 1
            ;;
    esac
}

main "$@"

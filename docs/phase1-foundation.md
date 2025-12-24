# Phase 1: Foundation

## Goal

Bootstrap a Raspberry Pi K3s cluster optimized for edge constraints with validated resilience.

## Implementation Guardrails

**IMPORTANT: Phase 1 constraints**

- **Resource monitoring**: Use OS tools (`free -h`, `top`, `systemctl status k3s`) for baseline measurement. Do NOT install `kubectl top` or metrics-server in Phase 1.
- **Storage**: Keep default `local-path` StorageClass for now. We'll evaluate custom storage in later phases if needed.
- **Logging**: Do NOT use tmpfs for `/var/log` in Phase 1. Instead, cap journald size with `SystemMaxUse` configuration to protect SD card.
- **Memory reservations**: Size `system-reserved` and `kube-reserved` based on Pi RAM:
  - 1GB Pi: `system-reserved=128Mi`, `kube-reserved=128Mi`
  - 2GB Pi: `system-reserved=256Mi`, `kube-reserved=256Mi`
  - 4GB+ Pi: `system-reserved=384Mi`, `kube-reserved=384Mi`

---

## 1. OS Choice: Raspberry Pi OS Lite (64-bit)

**Decision: Raspberry Pi OS Lite 64-bit**

**Reasoning:**
- **Lower memory footprint**: ~150MB base RAM vs ~200-250MB for Ubuntu Server
- **Better hardware optimization**: First-party drivers, firmware optimizations for Pi-specific hardware
- **Faster boot time**: Critical for edge scenarios with frequent power cycles
- **Smaller attack surface**: Lite version has minimal packages
- **SD card wear optimization**: Built-in optimizations for flash storage longevity

**Tradeoff acknowledged**: Ubuntu Server ARM64 has better enterprise credibility and LTS support, but for a portfolio demonstrating edge mastery, showing you can optimize for absolute constraints is more impressive.

**Alternative considered**: Ubuntu Server 22.04 LTS ARM64 would be the choice if this were a multi-cloud portfolio piece where standardization matters more than edge optimization.

---

## 2. K3s Installation Approach

**Decision: Official install script with explicit configuration file**

We'll use the official K3s installation script (from get.k3s.io) with a declarative configuration file. This provides reproducibility and version control for cluster settings.

**Key Configuration Decisions:**

### Components to Disable

We'll disable these K3s components to reduce memory footprint by ~100MB:

- **Traefik ingress controller**: Saves ~60-80MB RAM. For edge MQTT workloads, we'll use simpler NodePort or LoadBalancer approaches.
- **ServiceLB**: Saves ~30-40MB. Not needed for initial single-node deployment.
- **Metrics-server**: Per Phase 1 guardrails, we're using OS-level tools (`free`, `top`, `systemctl status`) for resource monitoring. Saves ~20-30MB.

**Storage decision**: Keep default `local-path` StorageClass. Per guardrails, this provides basic PVC support sufficient for Phase 1. We'll evaluate custom storage solutions in later phases only if needed.

### Edge-Tuned Kubelet Settings

**Memory eviction thresholds:**
- Hard eviction at 100Mi available memory (immediate pod termination)
- Soft eviction at 200Mi with 2-minute grace period
- Disk eviction at 10% available (hard) and 15% available (soft)

**Why**: Prevents OOM killer from targeting system or Kubernetes processes. Hard limits ensure node stability under memory pressure.

**System and Kubernetes reservations:**
- Reserve memory for host OS (`system-reserved`)
- Reserve memory for K8s control plane (`kube-reserved`)
- Sized based on Pi RAM (see guardrails: 128Mi each for 1GB Pi, 256Mi for 2GB, 384Mi for 4GB+)

**Why**: Guarantees resources for critical services, prevents workload pods from starving the control plane.

**Pod limits:**
- Max 50 pods per node

**Why**: Prevents runaway pod creation on constrained hardware.

### Logging and Performance

**Reduce API server, controller, and scheduler log verbosity** to minimal (v=1).

**Why**: Reduces disk I/O (critical for SD card longevity) and CPU overhead from excessive logging.

### Data Store

**Use embedded SQLite** (K3s default for single-node).

**Why**: SQLite uses ~15-20MB less memory than embedded etcd. Simpler recovery from corruption. Sufficient durability for single-node edge deployments.

---

## 3. OS-Level Edge Tuning

Before installing K3s, the host OS requires specific configuration to meet Kubernetes requirements and optimize for edge constraints.

### 3.1 Disable Swap

**Requirement**: Kubernetes requires swap to be completely disabled.

**Method**: Disable the swap file service and remove swap configuration.

**Why**: Swap causes unpredictable performance degradation on memory-constrained devices. Kubernetes relies on accurate memory accounting.

### 3.2 Enable cgroup Memory

**Requirement**: Kernel must have cgroup memory accounting enabled for kubelet limits to function.

**Method**: Add cgroup flags to boot command line (`/boot/cmdline.txt`), requires reboot.

**Why**: Without this, kubelet cannot enforce memory reservations or eviction policies.

### 3.3 Cap Journald Size

**Per guardrails**: Do NOT use tmpfs for `/var/log` in Phase 1. Instead, limit systemd journal size.

**Method**: Configure `SystemMaxUse` and `SystemMaxFileSize` in journald.conf to cap total journal at ~100MB.

**Why**: Prevents unbounded log growth that could wear out SD card or fill storage. Maintains logs across reboots for debugging (unlike tmpfs).

### 3.4 Network Stability

**Configuration**: Set static IP address instead of DHCP.

**Why**: Ensures cluster remains accessible even if DHCP server is unreachable during network outages. Critical for edge scenarios with intermittent connectivity.

### 3.5 Watchdog Timer (Optional)

**Configuration**: Enable hardware watchdog to auto-reboot on kernel hang.

**Why**: Edge-specific hardening for unattended operation. Provides automatic recovery from kernel panics or system hangs without manual intervention.

---

## 4. Validation Checklist

**Use OS tools for resource baseline (per guardrails):**

### Pre-K3s Baseline
```bash
# Memory baseline BEFORE K3s
free -h

# Expected: ~150-200MB used on Raspberry Pi OS Lite
```

### After K3s Installation

#### A. Node Health
```bash
kubectl get nodes -o wide
```
**Expected:**
```
NAME      STATUS   ROLES                  AGE   VERSION
pi-edge   Ready    control-plane,master   2m    v1.28.x+k3s1
```

#### B. Core System Pods
```bash
kubectl get pods -A
```
**Expected (with disabled components):**
```
NAMESPACE     NAME                              READY   STATUS    RESTARTS
kube-system   coredns-xxxxx                     1/1     Running   0
kube-system   local-path-provisioner-xxxxx      1/1     Running   0
```
- CoreDNS must be Running
- local-path-provisioner should be present (per guardrails)
- NO traefik or servicelb pods

#### C. Resource Usage (OS Tools)
```bash
# Total memory usage AFTER K3s
free -h

# K3s service memory
sudo systemctl status k3s | grep Memory

# Expected: ~400-500MB total used (K3s + OS)
```

#### D. API Server Responsiveness
```bash
time kubectl get --raw /healthz
```
**Expected:** Response under 100ms

#### E. Container Runtime
```bash
sudo k3s crictl ps
```
**Expected:** All containers in "Running" state

#### F. Storage Validation
```bash
kubectl get storageclass
```
**Expected:**
```
NAME                   PROVISIONER             RECLAIMPOLICY
local-path (default)   rancher.io/local-path   Delete
```

#### G. Systemd Service Health
```bash
sudo systemctl status k3s
```
**Expected:** Active (running)

#### H. Journal Logs
```bash
sudo journalctl -u k3s --since "5 minutes ago" --no-pager | grep -i error
```
**Expected:** No critical errors

---

## 5. Failure Scenarios to Test

### Test 1: Immediate Reboot After Install
**Purpose:** Verify K3s survives restart without manual intervention

**Steps:**
1. Complete installation and validation
2. `sudo reboot`
3. Wait for Pi to come back online
4. Re-run validation checklist

**Expected:**
- K3s service auto-starts
- All pods return to Running state within 60 seconds

**Failure mode:** K3s service not enabled, systemd dependency issue

---

### Test 2: Simulated Power Loss
**Purpose:** Verify no data corruption, clean recovery

**Steps:**
1. While cluster running: `sudo sync && sudo reboot -f`
2. Boot and check for corruption

**Expected:**
- K3s starts cleanly
- SQLite database not corrupted
- All pods restart

**Debug if failed:**
```bash
sudo journalctl -u k3s --boot=-1  # Previous boot logs
sudo k3s check-config             # Verify system config
```

---

### Test 3: Network Disconnection During Startup
**Purpose:** Verify K3s doesn't depend on external network

**Steps:**
1. `sudo systemctl stop k3s`
2. Disconnect ethernet
3. `sudo systemctl start k3s`

**Expected:**
- K3s starts successfully without internet
- Pods start normally

---

### Test 4: Low Memory Pressure
**Purpose:** Verify eviction policies work

**Steps:**
1. Deploy memory-hungry pod:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: memory-eater
spec:
  containers:
  - name: stress
    image: polinux/stress
    command: ["stress", "--vm", "1", "--vm-bytes", "500M"]
```
2. Monitor with OS tools: `free -h` and `kubectl get events`

**Expected:**
- Pod gets OOMKilled if exceeds limits
- Kubelet evicts pod when node memory < 100Mi available
- Node never becomes NotReady

---

### Test 5: CoreDNS Recovery
**Purpose:** Verify critical pods auto-restart

**Steps:**
1. `kubectl delete pod -n kube-system -l k8s-app=kube-dns`
2. Watch: `kubectl get pods -n kube-system -w`

**Expected:**
- New CoreDNS pod starts within 10 seconds
- DNS works: `nslookup kubernetes.default`

---

## 6. Success Criteria

Phase 1 is complete when:

- [ ] K3s cluster is running with chosen configuration
- [ ] All validation checks pass
- [ ] All 5 failure scenarios tested and documented
- [ ] Resource baseline measured with OS tools
- [ ] Memory usage under 500Mi on 2GB Pi (under 800Mi on 4GB Pi)
- [ ] Cluster survives reboot without intervention
- [ ] Documentation updated with actual results

---

## Summary of Decisions

| Decision | Choice | Key Reasoning |
|----------|--------|---------------|
| **OS** | Raspberry Pi OS Lite 64-bit | Lower memory, better Pi optimization |
| **K3s Install** | Official script + config file | Reproducible, declarative |
| **Disabled Components** | Traefik, ServiceLB | Save ~100MB RAM |
| **Storage** | Keep local-path (default) | Sufficient for Phase 1 (per guardrails) |
| **Data Store** | SQLite (default) | Lighter than etcd for single-node |
| **Memory Eviction** | Hard: 100Mi, Soft: 200Mi | Protect node from OOM |
| **Memory Reservation** | Sized to Pi RAM | See guardrails section |
| **Log Management** | Cap journald, no tmpfs | Protect SD card (per guardrails) |
| **Resource Monitoring** | OS tools only | No metrics-server (per guardrails) |

---

## Next Steps

After Phase 1 completion:
- Phase 2: Deploy Mosquitto MQTT broker
- Validate MQTT persistence across restarts
- Test message delivery under network failures

# Troubleshooting Guide

## Phase 1: Foundation

### K3s Installation Issues

#### Symptom: K3s service fails to start

**Possible causes:**

**Solution:**

---

#### Symptom: Node shows NotReady status

**Possible causes:**

**Solution:**

---

### Resource Issues

#### Symptom: High memory usage (>600MB on 2GB Pi)

**Possible causes:**

**Solution:**

---

#### Symptom: Pods being evicted frequently

**Possible causes:**

**Solution:**

---

### Network Issues

#### Symptom: CoreDNS pods not running

**Possible causes:**

**Solution:**

---

#### Symptom: Cannot access kubeconfig

**Possible causes:**

**Solution:**

---

### Recovery Scenarios

#### After power loss: K3s won't start

**Possible causes:**

**Solution:**

---

#### After reboot: Pods stuck in Pending

**Possible causes:**

**Solution:**

---

## Phase 2: Messaging

_To be populated_

---

## Phase 3: Workload

_To be populated_

---

## Phase 4: Observability

_To be populated_

---

## General Debugging Commands

### Check K3s service status
```bash
sudo systemctl status k3s
sudo journalctl -u k3s -f
```

### Check system resources
```bash
free -h
df -h
top
```

### Check Kubernetes cluster state
```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl describe node
kubectl get events -A --sort-by='.lastTimestamp'
```

### Check container runtime
```bash
sudo k3s crictl ps
sudo k3s crictl logs <container-id>
```

### Reset cluster (nuclear option)
```bash
# WARNING: This deletes all data
sudo /usr/local/bin/k3s-uninstall.sh
# Then reinstall from scratch
```

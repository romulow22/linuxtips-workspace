#!/bin/bash

# Cluster Validation Script
# Run this on control-plane to validate cluster health

echo "=========================================="
echo "Kubernetes Cluster Validation"
echo "=========================================="
echo ""

ERRORS=0
WARNINGS=0

# Function to check and report
check_pass() {
    echo "✓ $1"
}

check_fail() {
    echo "✗ $1"
    ERRORS=$((ERRORS + 1))
}

check_warn() {
    echo "⚠ $1"
    WARNINGS=$((WARNINGS + 1))
}

# Check if running on control-plane
echo "=== ENVIRONMENT CHECK ==="
if [ ! -f /etc/kubernetes/admin.conf ]; then
    check_fail "This script must be run on the control-plane node"
    exit 1
fi
check_pass "Running on control-plane"

# Configure kubectl for root if running as root
if [ "$EUID" -eq 0 ]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
fi
echo ""

# Check kubectl access
echo "=== KUBECTL ACCESS ==="
if kubectl cluster-info &>/dev/null; then
    check_pass "kubectl can access the cluster"
else
    check_fail "kubectl cannot access the cluster"
    exit 1
fi
echo ""

# Check nodes
echo "=== NODES STATUS ==="
EXPECTED_NODES=2  # 1 control-plane + 1 worker (adjust if needed)
READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready")
TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

if [ "$READY_NODES" -eq "$EXPECTED_NODES" ]; then
    check_pass "All $EXPECTED_NODES nodes are Ready"
elif [ "$READY_NODES" -gt 0 ]; then
    check_warn "$READY_NODES/$TOTAL_NODES nodes are Ready (expected $EXPECTED_NODES)"
else
    check_fail "No nodes are Ready"
fi

# List nodes
kubectl get nodes -o wide
echo ""

# Check control-plane components
echo "=== CONTROL PLANE COMPONENTS ==="
COMPONENTS=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "etcd")

for component in "${COMPONENTS[@]}"; do
    if kubectl get pods -n kube-system -l component=$component --no-headers 2>/dev/null | grep -q "Running"; then
        check_pass "$component is running"
    else
        check_fail "$component is not running"
    fi
done
echo ""

# Check CoreDNS
echo "=== COREDNS ==="
COREDNS_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running")
if [ "$COREDNS_PODS" -ge 2 ]; then
    check_pass "CoreDNS is running ($COREDNS_PODS pods)"
elif [ "$COREDNS_PODS" -eq 1 ]; then
    check_warn "CoreDNS is running but only 1 pod (expected 2)"
else
    check_fail "CoreDNS is not running"
fi
echo ""

# Check CNI (Calico)
echo "=== CNI (NETWORK PLUGIN) ==="

# Check for Calico
CALICO_PODS=$(kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -c "Running")
if [ "$CALICO_PODS" -gt 0 ]; then
    if [ "$CALICO_PODS" -eq "$TOTAL_NODES" ]; then
        check_pass "Calico is running on all nodes ($CALICO_PODS/$TOTAL_NODES)"
    else
        check_warn "Calico is running on $CALICO_PODS/$TOTAL_NODES nodes"
    fi
fi
echo ""

# Check kube-proxy
echo "=== KUBE-PROXY ==="
PROXY_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers 2>/dev/null | grep -c "Running")
if [ "$PROXY_PODS" -eq "$TOTAL_NODES" ]; then
    check_pass "kube-proxy is running on all nodes ($PROXY_PODS/$TOTAL_NODES)"
elif [ "$PROXY_PODS" -gt 0 ]; then
    check_warn "kube-proxy is running on $PROXY_PODS/$TOTAL_NODES nodes"
else
    check_fail "kube-proxy is not running"
fi
echo ""

# Check system pods
echo "=== SYSTEM PODS STATUS ==="
NOT_RUNNING=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -v "Running" | grep -v "Completed" | wc -l)
if [ "$NOT_RUNNING" -eq 0 ]; then
    check_pass "All system pods are running"
else
    check_warn "$NOT_RUNNING system pods are not running"
    kubectl get pods -n kube-system | grep -v "Running" | grep -v "Completed" | grep -v "NAME"
fi
echo ""

# Check API server health
echo "=== API SERVER HEALTH ==="
if curl -k https://192.168.10.100:6443/healthz &>/dev/null; then
    check_pass "API server /healthz endpoint is responding"
else
    check_fail "API server /healthz endpoint is not responding"
fi
echo ""

# Check cluster info
echo "=== CLUSTER INFO ==="
kubectl cluster-info
echo ""

# Test DNS resolution
echo "=== DNS RESOLUTION TEST ==="
if [ "$READY_NODES" -gt 0 ]; then
    # Create a test pod and check DNS
    kubectl run test-dns --image=busybox:1.28 --restart=Never -- nslookup kubernetes.default > /dev/null 2>&1
    sleep 5
    DNS_TEST=$(kubectl logs test-dns 2>/dev/null)
    kubectl delete pod test-dns --force --grace-period=0 > /dev/null 2>&1
    
    if echo "$DNS_TEST" | grep -q "Address"; then
        check_pass "DNS resolution is working"
    else
        check_warn "DNS resolution test failed (CoreDNS may still be starting)"
    fi
else
    check_warn "Skipping DNS test (no nodes are ready)"
fi
echo ""

# Check for common issues
echo "=== COMMON ISSUES CHECK ==="

# Check if swap is disabled on nodes
SWAP_ENABLED=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="MemoryPressure")].status}' 2>/dev/null | grep -c "True")
if [ "$SWAP_ENABLED" -eq 0 ]; then
    check_pass "No memory pressure detected on nodes"
else
    check_warn "Memory pressure detected on some nodes"
fi

# Check for disk pressure
DISK_PRESSURE=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null | grep -c "True")
if [ "$DISK_PRESSURE" -eq 0 ]; then
    check_pass "No disk pressure detected on nodes"
else
    check_warn "Disk pressure detected on some nodes"
fi

# Check for PID pressure
PID_PRESSURE=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="PIDPressure")].status}' 2>/dev/null | grep -c "True")
if [ "$PID_PRESSURE" -eq 0 ]; then
    check_pass "No PID pressure detected on nodes"
else
    check_warn "PID pressure detected on some nodes"
fi
echo ""

# Check recent events for errors
echo "=== RECENT EVENTS (Last 10) ==="
kubectl get events -A --sort-by='.lastTimestamp' | tail -10
echo ""

# Summary
echo "=========================================="
echo "=== VALIDATION SUMMARY ==="
echo "=========================================="

TOTAL_CHECKS=$((ERRORS + WARNINGS))

if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo "✓ Cluster is healthy! All checks passed."
    echo ""
    echo "You can now deploy applications:"
    echo "  kubectl create deployment nginx --image=nginx"
    echo "  kubectl expose deployment nginx --port=80 --type=NodePort"
    exit 0
elif [ "$ERRORS" -eq 0 ]; then
    echo "⚠ Cluster is mostly healthy with $WARNINGS warning(s)"
    echo ""
    echo "Review the warnings above. The cluster should be usable."
    exit 0
else
    echo "✗ Cluster has issues: $ERRORS error(s), $WARNINGS warning(s)"
    echo ""
    echo "Please review the errors above and run troubleshooting:"
    echo "  sudo /vagrant/scripts/troubleshoot.sh"
    echo ""
    echo "Common fixes:"
    echo "  - Wait a few minutes for pods to start"
    echo "  - Check kubelet logs: sudo journalctl -u kubelet -n 50"
    echo "  - Verify network: kubectl get pods -n kube-flannel"
    echo "  - Check nodes: kubectl describe nodes"
    exit 1
fi

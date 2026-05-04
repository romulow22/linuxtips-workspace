#!/bin/bash

set -e  # Exit on error (except where we handle it)

echo "[NODE.SH] Starting node provisioning script"
echo "[NODE.SH] Hostname: $(hostname)"
echo "[NODE.SH] IP Address: $(hostname -I)"

# Wait for join command to be available
echo "[TASK 1] Waiting for join command from control-plane"
MAX_WAIT=300  # 5 minutes timeout
WAIT_TIME=0

while [ ! -f /vagrant/joincluster.sh ]; do
    if [ $WAIT_TIME -ge $MAX_WAIT ]; then
        echo "[ERROR] Timeout waiting for join command after ${MAX_WAIT} seconds"
        echo "[ERROR] Control-plane may have failed to initialize"
        exit 1
    fi
    echo "Waiting for /vagrant/joincluster.sh to be created... (${WAIT_TIME}s/${MAX_WAIT}s)"
    sleep 5
    WAIT_TIME=$((WAIT_TIME + 5))
done

echo "[TASK 2] Join command found!"
echo "Content of join command:"
cat /vagrant/joincluster.sh
echo ""

# Verify API server is reachable
echo "[TASK 3] Verifying control-plane API server is reachable"
API_SERVER="192.168.10.100"
API_PORT="6443"
MAX_RETRIES=12  # 1 minute with 5 second intervals
RETRY_COUNT=0

while ! nc -z $API_SERVER $API_PORT 2>/dev/null; do
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "[ERROR] API Server at ${API_SERVER}:${API_PORT} is not reachable after ${MAX_RETRIES} attempts"
        echo "[ERROR] Please check control-plane status"
        exit 1
    fi
    echo "Waiting for API server at ${API_SERVER}:${API_PORT}... (attempt $((RETRY_COUNT + 1))/${MAX_RETRIES})"
    sleep 5
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

echo "[SUCCESS] API Server is reachable at ${API_SERVER}:${API_PORT}"

# Join worker nodes to the Kubernetes cluster
echo "[TASK 4] Joining node to Kubernetes Cluster"
set +e  # Don't exit on error for join attempts

JOIN_RETRIES=3
JOIN_SUCCESS=false

for i in $(seq 1 $JOIN_RETRIES); do
    echo "[ATTEMPT $i/$JOIN_RETRIES] Executing kubeadm join..."
    
    if bash /vagrant/joincluster.sh 2>&1 | tee /tmp/kubeadm-join.log; then
      echo "[SUCCESS] Node joined the cluster successfully on attempt $i"
        JOIN_SUCCESS=true
        break
    else
        echo "[WARNING] Join attempt $i failed"
        if [ $i -lt $JOIN_RETRIES ]; then
            echo "[INFO] Waiting 15 seconds before retry..."
            sleep 15
        fi
    fi
done

if [ "$JOIN_SUCCESS" = false ]; then
    echo "[ERROR] Failed to join cluster after $JOIN_RETRIES attempts"
    echo "[ERROR] Last error log:"
    cat /tmp/kubeadm-join.log
    echo ""
    echo "[TROUBLESHOOTING TIPS]"
    echo "1. Check control-plane status: vagrant ssh control-plane -c 'kubectl get nodes'"
    echo "2. Check API server logs: vagrant ssh control-plane -c 'sudo journalctl -u kubelet -n 50'"
    echo "3. Verify network connectivity: vagrant ssh control-plane -c 'sudo systemctl status kubelet'"
    echo "4. Try manual join: vagrant ssh $(hostname) -c 'sudo kubeadm reset -f && sudo bash /vagrant/joincluster.sh'"
    exit 1
fi

set -e  # Re-enable exit on error

echo ""
echo "================================"
echo "[SUCCESS] Node provisioning completed!"
echo "===================================="
echo ""
echo "To verify the cluster status, run:"
echo "  vagrant ssh control-plane -c 'kubectl get nodes -o wide'"
echo ""
echo "To check this node's status:"
echo "  vagrant ssh control-plane -c 'kubectl get node $(hostname) -o wide'"
echo "============================"
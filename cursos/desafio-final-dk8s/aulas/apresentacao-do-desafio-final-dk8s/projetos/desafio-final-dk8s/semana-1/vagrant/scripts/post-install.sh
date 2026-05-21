#!/bin/bash

# Post-installation script
# Run this on control-plane after cluster is up to install useful tools and configurations

echo "====================================="
echo "Kubernetes Cluster Post-Installation"
echo "=========================================="
echo ""

# Check if running on control-plane
if [ ! -f /etc/kubernetes/admin.conf ]; then
    echo "ERROR: This script must be run on the control-plane node"
    exit 1
fi

echo "[1/6] Installing useful tools..."

# Install additional tools
sudo apt-get update -qq
sudo apt-get install -y -qq \
    bash-completion \
    vim \
    htop \
    jq \
    tree \
    git \
    curl \
    wget

echo "✓ Tools installed"
echo ""

echo "[2/6] Configuring kubectl bash completion..."

# Kubectl bash completion
kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc

echo "✓ Kubectl completion configured"
echo ""

echo "[3/6] Creating useful aliases..."

# Add useful aliases
cat >> ~/.bashrc << 'EOF'

# Kubernetes aliases
alias kgp='kubectl get pods'
alias kgn='kubectl get nodes'
alias kgs='kubectl get svc'
alias kgd='kubectl get deployments'
alias kga='kubectl get all'
alias kdp='kubectl describe pod'
alias kdn='kubectl describe node'
alias kds='kubectl describe svc'
alias kl='kubectl logs'
alias klf='kubectl logs -f'
alias kx='kubectl exec -it'
alias kaf='kubectl apply -f'
alias kdf='kubectl delete -f'
alias kgpa='kubectl get pods -A'
alias kgpw='kubectl get pods -o wide'
alias kgpwa='kubectl get pods -A -o wide'
alias kctx='kubectl config current-context'
alias kns='kubectl config set-context --current --namespace'

# Watch aliases
alias watchpods='watch kubectl get pods'
alias watchnodes='watch kubectl get nodes'
alias watchall='watch kubectl get all'

# Vagrant aliases
alias vup='vagrant up'
alias vhalt='vagrant halt'
alias vssh='vagrant ssh'
alias vstatus='vagrant status'
EOF

echo "✓ Aliases created"
echo ""

echo "[4/6] Installing Metrics Server (optional)..."

# Install metrics-server and patch it to skip kubelet TLS verification.
# --kubelet-insecure-tls is required in kubeadm clusters with self-signed certificates.
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml 2>/dev/null

if [ $? -eq 0 ]; then
    kubectl patch deployment metrics-server -n kube-system \
      --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' 2>/dev/null
    echo "Metrics Server installed (may take a few minutes to be ready)"
else
    echo "Metrics Server installation had issues (non-critical)"
fi
echo ""

echo "[5/6] Installing local-path-provisioner (default StorageClass)..."

kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.35/deploy/local-path-storage.yaml 2>/dev/null
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null
echo "local-path StorageClass configured as default"
echo ""

echo "[6/6] Creating example namespace..."

# Create example namespace
kubectl create namespace examples 2>/dev/null || echo "Namespace 'examples' already exists"

echo "✓ Example namespace created"
echo ""

echo "[6/6] Creating helpful scripts..."

# Create a script to quickly check cluster health
cat > ~/check-cluster.sh << 'EOF'
#!/bin/bash
echo "=== Nodes ==="
kubectl get nodes
echo ""
echo "=== System Pods ==="
kubectl get pods -n kube-system
echo ""
echo "=== All Pods ==="
kubectl get pods -A
EOF

chmod +x ~/check-cluster.sh

echo "✓ Helper scripts created"
echo ""

echo "====================================="
echo "Post-installation complete!"
echo "=========================================="
echo ""
echo "📝 What was installed:"
echo "  ✓ Useful CLI tools (vim, htop, jq, etc.)"
echo "  ✓ Kubectl bash completion"
echo "  ✓ Helpful aliases (kgp, kgn, kgs, etc.)"
echo "  ✓ Metrics Server (for kubectl top)"
echo "  ✓ Example namespace"
echo "  ✓ Helper scripts"
echo ""
echo "🚀 Quick start:"
echo "  1. Reload bash: source ~/.bashrc"
echo "  2. Check cluster: ~/check-cluster.sh"
echo "  3. Try aliases: kgp, kgn, kgs"
echo "  4. View metrics: kubectl top nodes (wait 2-3 minutes)"
echo ""
echo "📚 Available aliases:"
echo "  kgp  - kubectl get pods"
echo "  kgn  - kubectl get nodes"
echo "  kgs  - kubectl get svc"
echo "  kgd  - kubectl get deployments"
echo "  kga  - kubectl get all"
echo "  kdp  - kubectl describe pod"
echo "  kl   - kubectl logs"
echo "  kx   - kubectl exec -it"
echo "  kaf  - kubectl apply -f"
echo ""
echo "💡 Tip: Run 'source ~/.bashrc' to activate aliases now!"
echo "=========================================="

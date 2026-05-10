#!/bin/bash

echo "[CONTROLPLANE.SH] Starting control plane provisioning script"

# Initialize Kubernetes
echo "[TASK 1] Initialize Kubernetes Cluster"
kubeadm init --apiserver-advertise-address=192.168.10.100 --pod-network-cidr=10.244.0.0/16 --apiserver-cert-extra-sans=192.168.10.100 >> /root/kubeinit.log 2>&1

# Copy Kube admin config and restart kubelet service
echo "[TASK 2] Copy kube admin config to Vagrant user .kube directory"
mkdir /home/vagrant/.kube
cp /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

# Deploy calico network
echo "[TASK 3] Deploy calico network"
su - vagrant -c "kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.5/manifests/calico.yaml" >> /home/vagrant/calico.log 2>&1

# Generate Cluster join command
echo "[TASK 4] Generate and save cluster join command to /vagrant/joincluster.sh"
kubeadm token create --print-join-command > /vagrant/joincluster.sh 2>/dev/null
chmod +x /vagrant/joincluster.sh

echo "[TASK 5] Verify join command was created"
if [ -f /vagrant/joincluster.sh ]; then
    echo "Join command created successfully:"
    cat /vagrant/joincluster.sh
else
    echo "ERROR: Failed to create join command"
    exit 1
fi
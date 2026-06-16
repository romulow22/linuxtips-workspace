#!/bin/bash

echo "[REQUIREMENTS] Installing requirements for Kubernetes cluster"

# [TASK 0] Mitigação Hyper-V/VBS (host Windows que NÃO pode desligar o Hyper-V por
# usar WSL2/Docker Desktop). Sob coexistência com Hyper-V o VirtualBox cai num modo
# em que o TSC do guest fica instável: a VM congela por dezenas de segundos, o kernel
# acusa "rcu_sched kthread starved" (RCU stall) e o SSH do provisionamento cai
# ("SSH connection unexpectedly closed by the remote end").
# kvm-clock é o clocksource paravirtualizado estável. Aplica em runtime (sem reboot)
# e persiste no GRUB para os próximos boots.
echo "[TASK 0] Mitigacao de clocksource (coexistencia com Hyper-V)"
CS_PATH=/sys/devices/system/clocksource/clocksource0
if grep -qw kvm-clock "$CS_PATH/available_clocksource" 2>/dev/null; then
  echo kvm-clock > "$CS_PATH/current_clocksource"
  echo "  clocksource atual: $(cat $CS_PATH/current_clocksource)"
  if ! grep -q 'clocksource=kvm-clock' /etc/default/grub; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 clocksource=kvm-clock"/' /etc/default/grub
    update-grub
    echo "  clocksource=kvm-clock adicionado ao GRUB (persistente)"
  fi
else
  echo "  kvm-clock indisponivel; mantendo $(cat $CS_PATH/current_clocksource 2>/dev/null)"
fi

echo "[TASK 1] update hosts"
echo '192.168.10.100 controlplane control-plane' | tee -a /etc/hosts
init=1
stop=$1
for (( c=$init; c<=$stop; c++ ))
do
  ip="$((c+1))"
  echo "192.168.10.$ip node$c node$c" | tee -a /etc/hosts
done


echo "[TASK 2] Install docker and utilities"
export DEBIAN_FRONTEND=noninteractive 
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl software-properties-common gpg netcat
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y

apt-cache policy docker-ce
apt-get install docker-ce -y

# # add ccount to the docker group
usermod -aG docker vagrant

# Enable docker service
echo "[TASK 3] Restart docker service"
systemctl restart docker
systemctl status docker

# Disable swap
echo "[TASK 4] Disable SWAP"
sed -i '/swap/d' /etc/fstab
swapoff -a

# Installing Kubernetes
echo "[TASK 5] Kubernetes"
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

# NFS client (required for kubelet to mount NFS PersistentVolumes — etapa 1.6)
echo "[TASK 6a] Install nfs-common"
apt-get install -y nfs-common

# Containerd configuration
echo "[TASK 6] containerd configuration"
mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
systemctl restart containerd
apt-get install -y conntrack

# Restarting services
echo "[TASK 7] restarting services"
systemctl restart containerd
systemctl restart kubelet
systemctl restart docker

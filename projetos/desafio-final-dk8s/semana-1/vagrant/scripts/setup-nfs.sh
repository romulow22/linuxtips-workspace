#!/bin/bash

# Sets up an NFS server on the control-plane node (192.168.10.100).
# Run this ONCE after the cluster is up:
#   vagrant ssh control-plane -- sudo bash /vagrant/scripts/setup-nfs.sh

set -e

NFS_EXPORT_DIR="/srv/nfs/tipsbank-auditoria"
NFS_CLIENT_CIDR="192.168.10.0/24"
NFS_UID=65532  # distroless nonroot uid

echo "=== [1/4] Installing nfs-kernel-server ==="
apt-get update -qq
apt-get install -y -qq nfs-kernel-server nfs-common

echo "=== [2/4] Creating export directory ==="
mkdir -p "$NFS_EXPORT_DIR"
chown "${NFS_UID}:${NFS_UID}" "$NFS_EXPORT_DIR"
chmod 775 "$NFS_EXPORT_DIR"

echo "=== [3/4] Configuring /etc/exports ==="
EXPORT_LINE="${NFS_EXPORT_DIR} ${NFS_CLIENT_CIDR}(rw,sync,no_subtree_check,no_root_squash,no_all_squash)"
if grep -qF "$NFS_EXPORT_DIR" /etc/exports; then
    echo "Entry already exists, skipping"
else
    echo "$EXPORT_LINE" >> /etc/exports
fi

echo "=== [4/4] Starting NFS server ==="
exportfs -ra
systemctl enable --now nfs-kernel-server
exportfs -v

echo ""
echo "NFS server ready:"
echo "  Export : ${NFS_EXPORT_DIR}"
echo "  Clients: ${NFS_CLIENT_CIDR}"
echo "  Owner  : uid=${NFS_UID} (distroless nonroot)"
echo ""
echo "PV reference:"
echo "  server: 192.168.10.100"
echo "  path  : ${NFS_EXPORT_DIR}"

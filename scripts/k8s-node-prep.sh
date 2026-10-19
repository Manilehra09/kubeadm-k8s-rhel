#!/bin/bash
# Kubernetes node prep for RHEL 10 (kubeadm + CRI-O)
# Run as root on EACH node (master and workers).
# Usage:  bash k8s-node-prep.sh            -> node IP auto-detected from hostname
#         bash k8s-node-prep.sh 192.168.2.21  -> node IP given explicitly

set -e

K8S_VERSION=v1.36          # change to v1.37 if v1.36 repos give 404
NODE_IP=${1:-$(getent ahostsv4 "$(hostname)" | awk 'NR==1{print $1}')}

if [[ -z "$NODE_IP" || "$NODE_IP" == 127.* ]]; then
  echo "ERROR: could not detect node IP. Run: bash $0 <node-ip>"
  exit 1
fi
echo ">>> Preparing $(hostname) with node IP $NODE_IP (Kubernetes $K8S_VERSION)"

# --- Swap, SELinux, firewall ---
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab
setenforce 0 || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
systemctl disable --now firewalld || true

# --- Kernel modules ---
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# --- Sysctl ---
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# --- Kubernetes repo ---
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

# --- CRI-O repo (now hosted on download.opensuse.org) ---
cat <<EOF > /etc/yum.repos.d/cri-o.repo
[cri-o]
name=CRI-O
baseurl=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${K8S_VERSION}/rpm/repodata/repomd.xml.key
EOF

# --- Install packages ---
dnf clean all
dnf install -y container-selinux
dnf install -y cri-o kubelet kubeadm kubectl cri-tools bind-utils --disableexcludes=kubernetes

# --- Pin node IP for kubelet ---
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/sysconfig/kubelet

# --- Start services ---
systemctl enable --now crio
systemctl enable kubelet   # restarts in a loop until kubeadm init/join - normal

# --- Verify ---
echo
echo "================ VERIFY ================"
echo "Hostname : $(hostname)"
echo "Node IP  : $NODE_IP"
echo "SELinux  : $(getenforce)"
echo "Swap     : $(free -h | awk '/Swap/{print $2}')"
echo "IP fwd   : $(sysctl -n net.ipv4.ip_forward)"
echo "br_netf  : $(lsmod | grep -q br_netfilter && echo loaded || echo MISSING)"
echo "CRI-O    : $(systemctl is-active crio)"
echo "kubeadm  : $(kubeadm version -o short)"
echo "kubelet  : $(kubelet --version)"
echo "========================================"
echo "OK: $(hostname) is ready for kubeadm init/join"

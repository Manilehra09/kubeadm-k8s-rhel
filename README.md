
# Install Kubernetes Cluster (kubeadm) on RHEL 10

```
In the lab installation I am using VMware Workstation on a Windows host with the following RHEL 10 VMs.
Container runtime: CRI-O | Pod network: Flannel | Kubernetes: v1.36
```

| Hostname | IP address     | Description                       | Hardware Requirement |
| :-------- | :------- | :-------------------------------- | :------------------- |
| `k8s-master.ops.lab`      | `192.168.2.20` | `Control Plane Node` | 4 GB RAM  - 40GB HDD - 2 CPU |
| `k8s-worker1.ops.lab`      | `192.168.2.21` | `Worker Node` | 4 GB RAM  - 40GB HDD - 2 CPU |
| `k8s-worker2.ops.lab`      | `192.168.2.22` | `Worker Node` | 4 GB RAM  - 40GB HDD - 2 CPU |

> **Note:** Replace the domain (`ops.lab`) and IP addresses with your own lab values.

---

## Part 1 – Prepare the VMs

Install RHEL 10 (minimal install is enough) on all three VMs and give them **static IPs** on the same network.

> **Cloned VMs?** If you cloned the VMs from one template, every clone must get a **unique MAC address** and **unique product UUID**, otherwise only one VM will work on the network and `kubeadm` will fail.

Generate a new MAC for each clone (VM powered off):

```
VM Settings → Network Adapter → Advanced → Generate
```

Verify MAC and product UUID are different on every node

```bash
ip -br link show ens160
cat /sys/class/dmi/id/product_uuid
```

If the product UUID is the same, power off the VM, remove the `uuid.bios` line from its `.vmx` file and boot again.

Set the hostname on each node (change per node)

```bash
hostnamectl set-hostname k8s-master.ops.lab
```

Add all nodes in `/etc/hosts` on **every** node

```bash
cat >> /etc/hosts <<EOF
192.168.2.20  k8s-master.ops.lab   k8s-master
192.168.2.21  k8s-worker1.ops.lab  k8s-worker1
192.168.2.22  k8s-worker2.ops.lab  k8s-worker2
EOF
```

Verify each node resolves its own hostname to its real IP (not `::1` / `127.0.0.1`)

```bash
getent ahostsv4 $(hostname)
```

---

## Part 2 – Register Nodes with Red Hat

Register every node so it can download packages from BaseOS and AppStream.

> If the VMs were cloned from an already registered machine, run `subscription-manager clean` first so each node gets its own identity.

```bash
subscription-manager clean
subscription-manager register --username <your-redhat-username>
```

Verify the repositories are enabled

```bash
subscription-manager repos --list-enabled | grep 'Repo ID'
```

```
Repo ID:   rhel-10-for-x86_64-baseos-rpms
Repo ID:   rhel-10-for-x86_64-appstream-rpms
```

---

## Part 3 – Prepare All Nodes

> You can do all steps of this part with one script: [`scripts/k8s-node-prep.sh`](scripts/k8s-node-prep.sh)
>
> ```bash
> bash k8s-node-prep.sh
> ```
>
> Or follow the manual steps below on **all three nodes**.

Disable swap

```bash
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab
```

Set SELinux to permissive

```bash
setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

Stop and disable the firewalld

```bash
systemctl disable --now firewalld
```

Load the kernel modules

```bash
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter
```

Set the sysctl parameters

```bash
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system
```

Add the Kubernetes repository

```bash
K8S_VERSION=v1.36

cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
```

Add the CRI-O repository

> **Note:** CRI-O packages are now hosted on `download.opensuse.org`. The old `pkgs.k8s.io/addons:/cri-o` URL returns **403**.

```bash
cat <<EOF > /etc/yum.repos.d/cri-o.repo
[cri-o]
name=CRI-O
baseurl=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${K8S_VERSION}/rpm/repodata/repomd.xml.key
EOF
```

Install the packages

```bash
dnf install -y container-selinux
dnf install -y cri-o kubelet kubeadm kubectl cri-tools bind-utils --disableexcludes=kubernetes
```

Pin the node IP for kubelet (change the IP per node)

```bash
echo "KUBELET_EXTRA_ARGS=--node-ip=192.168.2.20" > /etc/sysconfig/kubelet
```

Start CRI-O and enable kubelet

```bash
systemctl enable --now crio
systemctl enable kubelet
```

> kubelet will keep restarting until `kubeadm init` / `kubeadm join` is run. This is normal.

Verify

```bash
getenforce
free -h | grep -i swap
sysctl net.ipv4.ip_forward
systemctl is-active crio
kubeadm version -o short
crictl version
```

(Optional) Set the CRI-O pause image to the version kubeadm expects

```bash
cat <<EOF > /etc/crio/crio.conf.d/20-pause.conf
[crio.image]
pause_image = "registry.k8s.io/pause:3.10.2"
EOF

systemctl restart crio
```

---

## Part 4 – Initialize the Control Plane

Run on **k8s-master** only.

> **Important:** Do not use `192.168.0.0/16` as pod network CIDR if your lab network is in `192.168.x.x`. Use `10.244.0.0/16` (Flannel default).

```bash
kubeadm init \
  --apiserver-advertise-address=192.168.2.20 \
  --pod-network-cidr=10.244.0.0/16
```

At the end of the output, copy the `kubeadm join ...` command. It will be used on the worker nodes.

Configure kubectl access

```bash
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
```

Check the node (it will be `NotReady` until the pod network is installed)

```bash
kubectl get nodes
```

---

## Part 5 – Install the Pod Network (Flannel)

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

Watch the Flannel pods until they are `Running`

```bash
kubectl get pods -n kube-flannel -w
```

---

## Part 6 – Join the Worker Nodes

Run the join command (from Part 4) on **k8s-worker1** and **k8s-worker2**

```bash
kubeadm join 192.168.2.20:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

If you lost the join command or the token expired (valid 24 hours), generate a new one on the master

```bash
kubeadm token create --print-join-command
```

(Optional) Label the worker nodes

```bash
kubectl label node k8s-worker1.ops.lab k8s-worker2.ops.lab node-role.kubernetes.io/worker=
```

---

## Part 7 – Verify the Cluster

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

```
NAME                  STATUS   ROLES           VERSION   INTERNAL-IP    CONTAINER-RUNTIME
k8s-master.ops.lab    Ready    control-plane   v1.36.5   192.168.2.20   cri-o://1.36.7
k8s-worker1.ops.lab   Ready    worker          v1.36.5   192.168.2.21   cri-o://1.36.7
k8s-worker2.ops.lab   Ready    worker          v1.36.5   192.168.2.22   cri-o://1.36.7
```

Deploy a test application

```bash
kubectl create deployment web --image=nginx --replicas=2
kubectl expose deployment web --port=80 --type=NodePort
kubectl get pods -o wide
kubectl get svc web
```

Access the application using any node IP and the NodePort

```bash
curl http://192.168.2.21:<nodeport>
```

Clean up the test application

```bash
kubectl delete deploy,svc web
```

> Take a VMware snapshot of all nodes now, so you can always roll back to a working cluster.

---

## Troubleshooting

| Problem | Cause / Fix |
| :------ | :---------- |
| VMs cannot ping each other or the gateway | Cloned VMs with duplicate MAC address. Generate a new MAC for each VM. |
| `This system is already registered` | Cloned registration identity. Run `subscription-manager clean` and register again. |
| CRI-O repo `403` error | Old repo URL. Use `download.opensuse.org/repositories/isv:/cri-o:/stable:/<version>/rpm/`. |
| `crictl: command not found` | Install `cri-tools` package. |
| `kubectl` connects to `localhost:8080` | kubeconfig not set. Copy `/etc/kubernetes/admin.conf` to `$HOME/.kube/config`. |
| Nodes stuck in `NotReady` | Pod network not installed or `br_netfilter` not loaded. |
| kubelet fails after reboot | Swap enabled again. Check `/etc/fstab`. |
| Join fails with certificate/time error | Clocks out of sync. Make sure `chronyd` is running on all nodes. |
| Repo `404` for Kubernetes version | Version no longer published. Change `K8S_VERSION` to a newer version (e.g. `v1.37`). |

---

## Reset a Node (start again)

```bash
kubeadm reset -f
rm -rf /etc/cni/net.d $HOME/.kube
systemctl restart crio
```

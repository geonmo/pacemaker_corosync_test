#!/bin/bash
sudo dnf install -y epel-release
sudo dnf config-manager --set-enabled crb

sudo dnf -y install qemu-kvm libvirt virt-install libvirt-client virt-manager \
  bridge-utils cockpit-machines \
  python3-pip iproute-tc xorriso

sudo systemctl enable --now libvirtd
sudo systemctl status libvirtd --no-pager

sudo usermod -aG libvirt,kvm $USER
newgrp libvirt

# 1) 브리지 생성
sudo nmcli con add type bridge ifname br0 con-name br0 ipv4.addresses 192.168.200.10/24 ipv4.gateway 192.168.200.1 ipv4.method manual
sudo nmcli con mod br0 ipv4.dns "1.1.1.1 8.8.8.8"

# 2) 적용
sudo nmcli con up br0
ip a

ip link show br0


## 골든 이미지 작성
curl -O https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2
sudo cp AlmaLinux-9-GenericCloud-latest.x86_64.qcow2 /var/lib/libvirt/images/
sudo chmod 444 /var/lib/libvirt/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2
sudo qemu-img create -f qcow2 \
  -F qcow2 \
  -b /var/lib/libvirt/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2 \
  /var/lib/libvirt/images/node1-root.qcow2
sudo qemu-img create -f qcow2 \
  -F qcow2 \
  -b /var/lib/libvirt/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2 \
  /var/lib/libvirt/images/node2-root.qcow2

## cloud-init 작성
## ssh 접속용 seed 디렉토리 생성
sudo mkdir -p /var/lib/libvirt/seed/node1
sudo mkdir -p /var/lib/libvirt/seed/node2

## 각 노드 hostname 설정
sudo tee /var/lib/libvirt/seed/node1/meta-data >/dev/null <<'EOF'
instance-id: node1
local-hostname: node1.pacemaker.test
EOF

sudo tee /var/lib/libvirt/seed/node2/meta-data >/dev/null <<'EOF'
instance-id: node2
local-hostname: node2.pacemaker.test
EOF

PUBKEY="$(cat ~/.ssh/authorized_keys)"
sudo tee /var/lib/libvirt/seed/node1/user-data >/dev/null <<EOF
#cloud-config
users:
  - name: clouduser
    groups: wheel
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    shell: /bin/bash
    ssh_authorized_keys:
      - ${PUBKEY}

ssh_pwauth: true
disable_root: false
chpasswd:
  list: |
    clouduser:clouduser
    root:root
  expire: false
EOF

sudo tee /var/lib/libvirt/seed/node1/network-config > /dev/null <<EOF
version: 2
ethernets:
  eth0:
    dhcp4: false
    addresses:
      - 192.168.122.11/24
    gateway4: 192.168.122.1
    nameservers:
      addresses:
        - 8.8.8.8
        - 1.1.1.1
EOF



PUBKEY="$(cat ~/.ssh/authorized_keys)"
sudo tee /var/lib/libvirt/seed/node2/user-data >/dev/null <<EOF
#cloud-config
users:
  - name: clouduser
    groups: wheel
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    shell: /bin/bash
    ssh_authorized_keys:
      - ${PUBKEY}

ssh_pwauth: true
disable_root: false
chpasswd:
  list: |
    clouduser:clouduser
    root:root
  expire: false
EOF

sudo tee /var/lib/libvirt/seed/node2/network-config > /dev/null <<EOF
version: 2
ethernets:
  eth0:
    dhcp4: false
    addresses:
      - 192.168.122.12/24
    gateway4: 192.168.122.1
    nameservers:
      addresses:
        - 8.8.8.8
        - 1.1.1.1
EOF

sudo xorriso -as mkisofs -output /var/lib/libvirt/seed/node1/seed.iso \
  -volid cidata -joliet -rock \
  /var/lib/libvirt/seed/node1/user-data /var/lib/libvirt/seed/node1/meta-data \
  /var/lib/libvirt/seed/node1/network-config

sudo xorriso -as mkisofs -output /var/lib/libvirt/seed/node2/seed.iso \
  -volid cidata -joliet -rock \
  /var/lib/libvirt/seed/node2/user-data /var/lib/libvirt/seed/node2/meta-data \
  /var/lib/libvirt/seed/node2/network-config

## VM 생성
sudo virt-install \
  --name node1 \
  --vcpus 2 \
  --memory 4096 \
  --import \
  --disk path=/var/lib/libvirt/images/node1-root.qcow2,format=qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/node1-data.qcow2,size=30,bus=virtio \
  --disk path=/var/lib/libvirt/seed/node1/seed.iso,device=cdrom \
  --os-variant almalinux9 \
  --network network=default,model=virtio \
  --graphics none \
  --console pty,target_type=serial

sudo virt-install \
  --name node2 \
  --vcpus 2 \
  --memory 4096 \
  --import \
  --disk path=/var/lib/libvirt/images/node2-root.qcow2,format=qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/node2.qcow2,size=30,bus=virtio \
  --disk path=/var/lib/libvirt/seed/node2/seed.iso,device=cdrom \
  --os-variant almalinux9 \
  --network network=default,model=virtio \
  --graphics none \
  --console pty,target_type=serial

## ansible setup
sudo dnf install -y ansible ansible-collection-community-general  ansible-collection-community-libvirt ansible-collection-containers-podman


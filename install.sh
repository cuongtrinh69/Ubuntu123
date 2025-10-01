#!/bin/sh
echo "Code By SNIPA VN"
# Tải package bổ sung (Alpine dùng apk)
apk update && apk add --no-cache \
    qemu-system-x86_64 \
    qemu-img \
    sudo \
    cloud-utils \
    genisoimage \
    novnc \
    websockify \
    curl \
    unzip \
    python3 \
    py3-pip \
    openssh-client \
    net-tools \
    netcat-openbsd

# Tạo thư mục bên trong noVNC
mkdir -p /data /novnc /opt/qemu /cloud-init

# Tải ubuntu 22.04 image
curl -L https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img \
-o /opt/qemu/ubuntu.img

# Viết host
echo "instance-id: servertipacvn\nlocal-hostname: servertipacvn" > /cloud-init/meta-data

# Chỉnh sửa config image ubuntu
printf "#cloud-config\n\
preserve_hostname: false\n\
hostname: servertipacvn\n\
users:\n\
  - name: root\n" > /cloud-init/user-data

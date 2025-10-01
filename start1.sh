#!/bin/sh
set -e

# Simple Alpine-ready VM starter script (QEMU + cloud-init + noVNC + cloudflared quick tunnel).
# Giữ nguyên logic gốc, chỉ chuyển sang apk, pip, và fix 1 vài lệnh để chạy trên Alpine.
#
# Usage:
#   chmod +x setup-vm-alpine.sh
#   ./setup-vm-alpine.sh
#
# Yêu cầu: chạy với quyền root và có Internet.

echo "Code By SNIPA VN"

# ---------- Ask user for disk size ----------
echo "Bạn muốn bao nhiêu disk tùy máy (ví dụ muốn 128G thì nhập 128):"
read disk1
if [ -z "$disk1" ]; then
  echo "Bạn chưa nhập dung lượng. Thoát."
  exit 1
fi

# ---------- Paths & defaults ----------
DISK_DIR="/data"
DISK="$DISK_DIR/vm.raw"
IMG="/opt/qemu/ubuntu.img"       # bạn cần chuẩn bị file qcow2 ở đây (cloud image)
SEED="/opt/qemu/seed.iso"       # optional cloud-init ISO (nếu có tạo)
NOVNC_DIR="/opt/novnc"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
VNC_DISPLAY=":0"
VNC_PORT=5900
NOVNC_PORT=6080

# ---------- Ensure dirs ----------
mkdir -p "$DISK_DIR"
mkdir -p /opt/qemu
mkdir -p "$NOVNC_DIR"
mkdir -p /cloud-init

# ---------- Install dependencies (Alpine) ----------
echo "[*] Cài dependencies bằng apk..."
apk update
apk add --no-cache \
  curl \
  bash \
  git \
  python3 \
  py3-pip \
  qemu-system-x86_64 \
  qemu-img \
  sudo \
  genisoimage \
  coreutils \
  procps \
  openssh-client \
  net-tools \
  netcat-openbsd

# websockify (python) - install via pip if not present
if ! command -v websockify >/dev/null 2>&1; then
  echo "[*] Cài websockify (pip)..."
  pip3 install --no-cache-dir websockify
fi

# noVNC - nếu chưa có thì clone
if [ ! -d "$NOVNC_DIR" ] || [ ! -f "$NOVNC_DIR/vnc.html" ]; then
  echo "[*] Lấy noVNC vào $NOVNC_DIR..."
  rm -rf "$NOVNC_DIR"
  git clone --depth 1 https://github.com/novnc/noVNC.git "$NOVNC_DIR"
fi

# cloudflared - download binary suitable cho kiến trúc nếu chưa có
if [ ! -x "$CLOUDFLARED_BIN" ]; then
  echo "[*] Tải cloudflared binary (nếu có internet và kiến trúc được hỗ trợ)..."
  arch="$(uname -m)"
  cf_bin=""
  case "$arch" in
    x86_64|amd64) cf_bin="cloudflared-linux-amd64" ;;
    aarch64|arm64) cf_bin="cloudflared-linux-arm64" ;;
    armv7*|armv6*) cf_bin="cloudflared-linux-arm" ;;
    *) echo "Không nhận dạng kiến trúc: $arch. Vui lòng cài cloudflared thủ công." && cf_bin="" ;;
  esac

  if [ -n "$cf_bin" ]; then
    curl -L -o "$CLOUDFLARED_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/$cf_bin"
    chmod +x "$CLOUDFLARED_BIN"
  fi
fi

# ---------- Disk creation / resize ----------
DISK2="$disk1"
if [ ! -f "$DISK" ]; then
  if [ ! -f "$IMG" ]; then
    echo "Lỗi: Không tìm thấy file nguồn IMG: $IMG"
    echo "Bạn cần đặt file qcow2 (Ubuntu image) ở $IMG trước khi tiếp tục."
    exit 1
  fi

  echo "[*] Creating VM disk (convert qcow2 -> raw) at $DISK ..."
  qemu-img convert -f qcow2 -O raw "$IMG" "$DISK"
  echo "[*] Resizing disk to ${DISK2}G ..."
  qemu-img resize "$DISK" "${DISK2}G"
else
  echo "[*] Disk $DISK đã tồn tại -> bỏ qua tạo mới"
fi

# ---------- Start VM ----------
echo "[*] Khởi QEMU..."
qemu-system-x86_64 \
    -m 8G \
    -drive file="$DISK",format=raw,if=virtio \
    $( [ -f "$SEED" ] && echo "-drive file=\"$SEED\",format=raw,if=virtio" ) \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net,netdev=net0 \
    -vga virtio \
    -display vnc="$VNC_DISPLAY" \
    -daemonize

# ---------- Start noVNC/websockify ----------
VNC_PORT_CALC=$VNC_PORT
echo "[*] Start websockify to serve noVNC on http://0.0.0.0:$NOVNC_PORT ..."
# kill existing if any on that port (best-effort)
if command -v pgrep >/dev/null 2>&1 && pgrep -f "websockify .*${NOVNC_PORT}" >/dev/null 2>&1; then
  echo "[*] Found existing websockify on port $NOVNC_PORT - killing..."
  pkill -f "websockify .*${NOVNC_PORT}" || true
fi

# start websockify serving the noVNC web files
nohup websockify --web="$NOVNC_DIR" "$NOVNC_PORT" "localhost:$VNC_PORT_CALC" > /var/log/websockify.log 2>&1 &

# ---------- Get host IP for display ----------
# Try to get the primary outbound IP
HOST_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){ if($i==\"src\"){print $(i+1); exit}} }')"
if [ -z "$HOST_IP" ]; then
  # fallback to hostname -I if available
  HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[ -z "$HOST_IP" ] && HOST_IP="127.0.0.1"

# ---------- Output info ----------
echo "================================================"
echo " 🖥️  noVNC: http://${HOST_IP}:${NOVNC_PORT}/vnc.html"
echo " 🔐 SSH: ssh root@${HOST_IP} -p 2222"
echo " 🧾 Login: root / root (nếu OS image dùng mặc định)"
echo " ⚙️  VM disk: $DISK (${DISK2}G)"
echo " Supported Code Sandbox (use ngrok or cloudflared)"
echo "================================================"
echo
echo "Muốn expose noVNC ra public (không mở port) thì chạy ví dụ:"
echo "  cloudflared tunnel --url http://localhost:${NOVNC_PORT}"
echo
echo "Hoặc (quick test) chạy ngay:"
if [ -x "$CLOUDFLARED_BIN" ]; then
  echo "  $CLOUDFLARED_BIN tunnel --url http://localhost:${NOVNC_PORT}"
else
  echo "  (cloudflared chưa có, script đã cố gắng tải; nếu thiếu hãy cài thủ công)"
fi

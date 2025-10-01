#!/bin/sh
set -e

# Alpine-friendly VM starter: create/resize disk, run qemu, start noVNC via websockify,
# and (optionally) download cloudflared for quick tunnels.
#
# Usage: run as root:
#   chmod +x setup-vm-alpine.sh
#   ./setup-vm-alpine.sh

# ---------- Config ----------
echo "Bạn muốn bao nhiêu disk tùy máy (ví dụ muốn 128G thì nhập 128)"
read disk1
DISK_DIR="/data"
DISK="$DISK_DIR/vm.raw"
IMG="/opt/qemu/ubuntu.img"       # bạn phải chuẩn bị file nguồn tại đây (qcow2)
SEED="/opt/qemu/seed.iso"       # optional, nếu không có hãy bỏ
NOVNC_DIR="/opt/novnc"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
TT_PORT=7681
VNC_DISPLAY=":0"
VNC_PORT=5900
NOVNC_PORT=6080

# ---------- Ensure dirs ----------
mkdir -p "$DISK_DIR"
mkdir -p /opt/qemu
mkdir -p "$NOVNC_DIR"

# ---------- Install dependencies (Alpine) ----------
echo "[*] Cài dependencies bằng apk..."
apk update
apk add --no-cache curl bash git python3 py3-pip qemu-system-x86_64 qemu-img

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

# cloudflared - download binary suitable cho kiến trúc
if [ ! -x "$CLOUDFLARED_BIN" ]; then
  echo "[*] Tải cloudflared binary..."
  arch="$(uname -m)"
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
# nếu bạn muốn background, dùng -daemonize (giữ)
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
# websockify expects display port, so map VNC port (5900 + display)
VNC_PORT_CALC=$VNC_PORT
echo "[*] Start websockify to serve noVNC on http://0.0.0.0:$NOVNC_PORT ..."
# kill existing if any on that port (best-effort)
if pgrep -f "websockify .*${NOVNC_PORT}" >/dev/null 2>&1; then
  echo "[*] Found existing websockify on port $NOVNC_PORT - killing..."
  pkill -f "websockify .*${NOVNC_PORT}" || true
fi

# start websockify serving the noVNC web files
# websockify <novnc_port> localhost:<vnc_port>
nohup websockify --web="$NOVNC_DIR" "$NOVNC_PORT" "localhost:$VNC_PORT_CALC" > /var/log/websockify.log 2>&1 &

# ---------- Output info ----------
echo "================================================"
echo " 🖥️  noVNC: http://$(hostname -I | awk '{print $1}'):${NOVNC_PORT}/vnc.html"
echo " 🔐 SSH: ssh root@$(hostname -I | awk '{print $1}') -p 2222"
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

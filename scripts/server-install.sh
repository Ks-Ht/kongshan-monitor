#!/bin/sh
# ============================================================================
# Outpost 哨站 — 服务端一键交互式安装脚本(内置 TLS,免 nginx)
#
#   curl -fsSL https://github.com/Ks-Ht/kongshan-monitor/releases/latest/download/server-install.sh | sh
#
# 会交互询问:公网端口 / 访问地址 / 管理员账号密码;然后:
#   下载并校验二进制 → 生成自签证书 → 写配置 → 建用户/目录/systemd → 创建管理员 → 启动
# 环境变量(可选,设置后对应项不再交互):
#   OP_PORT  OP_HOST  OP_ADMIN_USER  OP_ADMIN_PASS  OP_VERSION(默认 latest)
# ============================================================================
set -eu

REPO="Ks-Ht/kongshan-monitor"
VERSION="${OP_VERSION:-latest}"
PREFIX="/usr/local/bin"
ETC="/etc/outpost"
VAR="/var/lib/outpost"

info() { printf '\033[32m==>\033[0m %s\n' "$1"; }
err()  { printf '\033[31m错误:\033[0m %s\n' "$1" >&2; exit 1; }

# --- 前置检查 ---
[ "$(id -u)" = "0" ] || err "请以 root 运行(sudo sh server-install.sh)"
for c in curl sha256sum openssl; do command -v "$c" >/dev/null 2>&1 || err "缺少依赖:$c"; done
command -v systemctl >/dev/null 2>&1 || err "需要 systemd(systemctl)"

case "$(uname -m)" in
  x86_64)  ARCH="x86_64-unknown-linux-musl" ;;
  aarch64) ARCH="aarch64-unknown-linux-musl" ;;
  *) err "暂不支持的架构:$(uname -m)" ;;
esac

if [ "$VERSION" = "latest" ]; then
  BASE="https://github.com/$REPO/releases/latest/download"
else
  BASE="https://github.com/$REPO/releases/download/$VERSION"
fi

# --- 交互输入(优先环境变量;从 /dev/tty 读,兼容 curl|sh)---
TTY=/dev/tty
ask() { # ask VAR "提示" "默认"
  eval "cur=\${$1:-}"
  if [ -n "${cur:-}" ]; then eval "$1=\"$cur\""; return; fi
  printf '%s [%s]: ' "$2" "$3" > "$TTY"
  read ans < "$TTY" || ans=""
  [ -n "$ans" ] || ans="$3"
  eval "$1=\"\$ans\""
}
ask_secret() { # ask_secret VAR "提示"
  eval "cur=\${$1:-}"
  if [ -n "${cur:-}" ]; then eval "$1=\"$cur\""; return; fi
  printf '%s: ' "$2" > "$TTY"
  stty -echo < "$TTY" 2>/dev/null || true
  read ans < "$TTY" || ans=""
  stty echo < "$TTY" 2>/dev/null || true
  printf '\n' > "$TTY"
  eval "$1=\"\$ans\""
}

info "Outpost 哨站 服务端安装(架构 $ARCH,版本 $VERSION)"
DETECT_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '')"
OP_PORT="${OP_PORT:-}"; ask OP_PORT "面板对外端口" "25510"
OP_HOST="${OP_HOST:-}"; ask OP_HOST "面板访问地址(公网 IP 或域名)" "${DETECT_IP:-127.0.0.1}"
OP_ADMIN_USER="${OP_ADMIN_USER:-}"; ask OP_ADMIN_USER "管理员用户名(3~32 位)" "admin"
if [ -z "${OP_ADMIN_PASS:-}" ]; then
  ask_secret OP_ADMIN_PASS "管理员密码(≥10 位,含字母和数字)"
  ask_secret OP_ADMIN_PASS2 "再次输入密码"
  [ "$OP_ADMIN_PASS" = "${OP_ADMIN_PASS2:-}" ] || err "两次密码不一致"
fi
case "$OP_PORT" in ''|*[!0-9]*) err "端口非法" ;; esac
[ -n "$OP_ADMIN_PASS" ] || err "密码不能为空"

# --- 下载并校验二进制 ---
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM
info "下载成品与校验和"
curl -fsSL --proto '=https' "$BASE/SHA256SUMS" -o "$TMP/SHA256SUMS"
dl() { # dl 资产名
  curl -fsSL --proto '=https' "$BASE/$1" -o "$TMP/$1"
  grep " $1\$" "$TMP/SHA256SUMS" > "$TMP/sum" || err "$1 无校验和记录"
  ( cd "$TMP" && sha256sum -c sum >/dev/null ) || err "$1 SHA-256 校验失败"
}
dl "outpost-server-$ARCH"
dl "outpost-agent-x86_64-unknown-linux-musl"
dl "outpost-agent-aarch64-unknown-linux-musl"

# --- 用户与目录 ---
info "创建用户与目录"
id -u outpost >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin outpost
mkdir -p "$ETC/pki" "$VAR/dist"
install -m 0755 "$TMP/outpost-server-$ARCH" "$PREFIX/outpost-server"
install -m 0755 "$TMP/outpost-agent-x86_64-unknown-linux-musl" "$VAR/dist/outpost-agent-x86_64-unknown-linux-musl"
install -m 0755 "$TMP/outpost-agent-aarch64-unknown-linux-musl" "$VAR/dist/outpost-agent-aarch64-unknown-linux-musl"

# --- 自签证书(内置 TLS)---
info "生成自签证书(内置 TLS)"
cd "$ETC/pki"
umask 077
if [ ! -f ca.key ]; then
  openssl ecparam -genkey -name prime256v1 -out ca.key
  openssl req -x509 -new -key ca.key -sha256 -days 3650 -subj "/CN=Outpost Private CA" -out ca.pem
fi
case "$OP_HOST" in
  *[!0-9.]*) SAN="DNS:$OP_HOST,IP:127.0.0.1,DNS:localhost" ;;  # 含非数字点 → 域名
  *)         SAN="IP:$OP_HOST,IP:127.0.0.1,DNS:localhost" ;;
esac
openssl ecparam -genkey -name prime256v1 -out server.key
openssl req -new -key server.key -subj "/CN=$OP_HOST" -out server.csr
printf 'subjectAltName=%s\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' "$SAN" > server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 825 -sha256 -extfile server.ext -out server.crt
cat server.crt ca.pem > server-fullchain.pem
rm -f server.csr server.ext
chmod 0600 ca.key server.key
chmod 0644 ca.pem server.crt server-fullchain.pem
cd - >/dev/null

# --- 配置 ---
info "写入配置"
HSTS=true
cat > "$ETC/config.toml" <<EOF
[server]
listen = "0.0.0.0:$OP_PORT"
behind_proxy = false
trusted_proxies = []
public_url = "https://$OP_HOST:$OP_PORT"

[server.tls]
enabled = true
cert_path = "$ETC/pki/server-fullchain.pem"
key_path = "$ETC/pki/server.key"

[security]
cookie_secure = true
session_ttl_hours = 24
hsts = $HSTS

[storage]
db_path = "$VAR/outpost.db"

[install]
mode = "pinned_ca"
ca_cert_path = "$ETC/pki/ca.pem"
dist_dir = "$VAR/dist"

[metrics]
ws_max_message_bytes = 262144
ts_skew_secs = 300

[notify]
allow_private_targets = false
EOF
chown -R root:outpost "$ETC"
chmod 0640 "$ETC/config.toml"
chmod 0640 "$ETC/pki/server.key" "$ETC/pki/ca.key" 2>/dev/null || true

# --- 创建管理员(密码经环境变量,不入 argv;DB 随后归属 outpost)---
info "创建管理员账户"
OUTPOST_CONFIG="$ETC/config.toml" OUTPOST_ADMIN_PASSWORD="$OP_ADMIN_PASS" \
  "$PREFIX/outpost-server" admin-create --username "$OP_ADMIN_USER" || err "创建管理员失败"
chown -R outpost:outpost "$VAR"

# --- systemd(低端口才授予 net_bind)---
if [ "$OP_PORT" -lt 1024 ]; then CAPS="AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE"; else CAPS="CapabilityBoundingSet="; fi
cat > /etc/systemd/system/outpost-server.service <<EOF
[Unit]
Description=Outpost monitoring dashboard server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=outpost
Group=outpost
Environment=OUTPOST_CONFIG=$ETC/config.toml
ExecStart=$PREFIX/outpost-server
Restart=always
RestartSec=5
MemoryMax=256M
TasksMax=64
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$VAR
ReadOnlyPaths=$ETC
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
$CAPS
SystemCallFilter=@system-service
SystemCallArchitectures=native
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now outpost-server >/dev/null 2>&1

sleep 2
FPR="$(sha256sum "$ETC/pki/ca.pem" | awk '{print $1}')"
echo
if systemctl is-active --quiet outpost-server; then
  info "安装完成 ✔"
  echo "  面板地址 : https://$OP_HOST:$OP_PORT"
  echo "  管理员   : $OP_ADMIN_USER"
  echo "  证书说明 : 自签证书,浏览器会提示不受信任,点继续访问即可"
  echo "  CA 指纹  : $FPR"
  echo
  echo "  登录后在「总览 → 添加节点」复制命令即可给其他服务器装 agent。"
else
  err "服务未能启动,请查看:journalctl -u outpost-server -n 50"
fi

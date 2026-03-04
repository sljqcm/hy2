#!/usr/bin/env bash
set -euo pipefail

# =========================
# Hysteria2 one-click server installer
# Supports: Alpine(OpenRC), Debian/Ubuntu(Systemd), RHEL/CentOS/Fedora(Systemd)
# Defaults: self-signed TLS, UDP 443, password auth, simple masquerade string
# =========================

# ---- user-tunable via env ----
HY2_PORT="${HY2_PORT:-443}"
HY2_PASS="${HY2_PASS:-}"                 # empty => auto-generate
HY2_SNI="${HY2_SNI:-}"                   # optional; if empty, will use server public IP if possible
HY2_MASQ_TYPE="${HY2_MASQ_TYPE:-string}" # string|proxy|file (script uses string by default)
HY2_MASQ_CONTENT="${HY2_MASQ_CONTENT:-hello}"  # for string masquerade
HY2_PROXY_URL="${HY2_PROXY_URL:-https://news.ycombinator.com/}" # if you switch masq to proxy
HY2_PROXY_REWRITE_HOST="${HY2_PROXY_REWRITE_HOST:-true}"

# If you have a domain+email and want ACME, set:
#   HY2_ACME=1 HY2_ACME_DOMAIN=xxx.example.com HY2_ACME_EMAIL=me@example.com
HY2_ACME="${HY2_ACME:-0}"
HY2_ACME_DOMAIN="${HY2_ACME_DOMAIN:-}"
HY2_ACME_EMAIL="${HY2_ACME_EMAIL:-}"

INSTALL_DIR="/usr/local/bin"
BIN_PATH="${INSTALL_DIR}/hysteria"
CONF_DIR="/etc/hysteria"
CONF_PATH="${CONF_DIR}/config.yaml"
CERT_PATH="${CONF_DIR}/server.crt"
KEY_PATH="${CONF_DIR}/server.key"
LOG_DIR="/var/log/hysteria"

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 执行：sudo -i 后再运行。"
    exit 1
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

detect_init() {
  if cmd_exists systemctl && [ -d /run/systemd/system ]; then
    echo "systemd"
  elif [ -d /etc/init.d ] && cmd_exists rc-service; then
    echo "openrc"
  else
    # best effort
    if cmd_exists systemctl; then echo "systemd"; else echo "openrc"; fi
  fi
}

detect_arch_asset() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "hysteria-linux-amd64" ;;
    aarch64|arm64) echo "hysteria-linux-arm64" ;;
    armv7l|armv7) echo "hysteria-linux-arm" ;;
    i386|i686) echo "hysteria-linux-386" ;;
    riscv64) echo "hysteria-linux-riscv64" ;;
    s390x) echo "hysteria-linux-s390x" ;;
    mipsel|mipsle) echo "hysteria-linux-mipsle" ;;
    *) echo "Unsupported arch: $arch" >&2; exit 1 ;;
  esac
}

install_deps() {
  if [ -f /etc/alpine-release ]; then
    apk add --no-cache curl openssl ca-certificates iproute2 coreutils
  else
    if cmd_exists apt-get; then
      apt-get update -y
      apt-get install -y curl openssl ca-certificates iproute2 coreutils
    elif cmd_exists dnf; then
      dnf install -y curl openssl ca-certificates iproute coreutils
    elif cmd_exists yum; then
      yum install -y curl openssl ca-certificates iproute coreutils
    else
      echo "无法识别包管理器，请手动安装 curl openssl ca-certificates iproute2/coreutils。"
    fi
  fi
}

get_public_ip() {
  # best effort; may fail on some networks
  local ip=""
  if cmd_exists curl; then
    ip="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || true)"
    if [ -z "$ip" ]; then
      ip="$(curl -4 -fsSL https://ip.sb 2>/dev/null || true)"
    fi
  fi
  echo "$ip"
}

gen_password() {
  if [ -n "$HY2_PASS" ]; then
    echo "$HY2_PASS"
  else
    # 24 chars urlsafe-ish
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
  fi
}

download_hysteria() {
  mkdir -p "$INSTALL_DIR"
  local asset
  asset="$(detect_arch_asset)"
  # Official docs list these filenames at download.hysteria.network
  local url="https://download.hysteria.network/${asset}"
  echo "下载：$url"
  curl -fsSL "$url" -o "$BIN_PATH"
  chmod +x "$BIN_PATH"
}

gen_cert_selfsigned() {
  mkdir -p "$CONF_DIR"
  # Determine CN
  local cn="${HY2_SNI:-}"
  if [ -z "$cn" ]; then
    cn="$(get_public_ip)"
  fi
  if [ -z "$cn" ]; then
    cn="example.com"
  fi

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY_PATH" -out "$CERT_PATH" \
    -days 3650 \
    -subj "/CN=${cn}" >/dev/null 2>&1

  chmod 600 "$KEY_PATH"
  chmod 644 "$CERT_PATH"

  # If HY2_SNI empty, set to CN (useful for URI output)
  if [ -z "${HY2_SNI:-}" ]; then
    HY2_SNI="$cn"
  fi
}

write_config() {
  mkdir -p "$CONF_DIR" "$LOG_DIR"

  local pass="$1"

  # Masquerade block
  local masq_block=""
  if [ "$HY2_MASQ_TYPE" = "proxy" ]; then
    masq_block=$(cat <<EOF
masquerade:
  type: proxy
  proxy:
    url: ${HY2_PROXY_URL}
    rewriteHost: ${HY2_PROXY_REWRITE_HOST}
EOF
)
  elif [ "$HY2_MASQ_TYPE" = "file" ]; then
    # serve static dir
    masq_block=$(cat <<'EOF'
masquerade:
  type: file
  file:
    dir: /var/www/html
EOF
)
    mkdir -p /var/www/html
    echo "it works" > /var/www/html/index.html
  else
    masq_block=$(cat <<EOF
masquerade:
  type: string
  string:
    content: ${HY2_MASQ_CONTENT}
    headers:
      content-type: text/plain
    statusCode: 200
EOF
)
  fi

  if [ "$HY2_ACME" = "1" ]; then
    if [ -z "$HY2_ACME_DOMAIN" ] || [ -z "$HY2_ACME_EMAIL" ]; then
      echo "你设置了 HY2_ACME=1，但没提供 HY2_ACME_DOMAIN / HY2_ACME_EMAIL。"
      exit 1
    fi
    cat >"$CONF_PATH" <<EOF
listen: :${HY2_PORT}

acme:
  domains:
    - ${HY2_ACME_DOMAIN}
  email: ${HY2_ACME_EMAIL}

auth:
  type: password
  password: ${pass}

${masq_block}
EOF
  else
    cat >"$CONF_PATH" <<EOF
listen: :${HY2_PORT}

tls:
  cert: ${CERT_PATH}
  key: ${KEY_PATH}

auth:
  type: password
  password: ${pass}

${masq_block}
EOF
  fi
}

setup_service_systemd() {
  cat >/etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} server -c ${CONF_PATH}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now hysteria-server.service
}

setup_service_openrc() {
  cat >/etc/init.d/hysteria <<'EOF'
#!/sbin/openrc-run
name="hysteria2"
description="Hysteria2 Server"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria.pid"
output_log="/var/log/hysteria/hysteria.log"
error_log="/var/log/hysteria/hysteria.err"

depend() {
  need net
}
EOF
  chmod +x /etc/init.d/hysteria
  rc-update add hysteria default >/dev/null 2>&1 || true
  rc-service hysteria restart
}

print_result() {
  local pass="$1"
  local ip
  ip="$(get_public_ip)"
  if [ -z "$ip" ]; then
    ip="<你的服务器IP>"
  fi

  echo ""
  echo "================== 安装完成 =================="
  echo "配置文件: ${CONF_PATH}"
  echo "监听端口: UDP ${HY2_PORT}"
  echo "认证密码: ${pass}"
  echo "SNI(可选): ${HY2_SNI:-<空>}"
  echo ""
  if [ "$HY2_ACME" = "1" ]; then
    echo "ACME 域名: ${HY2_ACME_DOMAIN}"
    echo "提示：客户端一般不需要 insecure=1（使用正规证书）。"
    echo "URI（常用导入格式）："
    echo "hy2://${pass}@${HY2_ACME_DOMAIN}:${HY2_PORT}/"
  else
    echo "提示：你用的是自签证书，客户端需要 insecure=1（或自行做证书固定）。"
    echo "URI（常用导入格式）："
    # include insecure=1 and sni when available
    if [ -n "${HY2_SNI:-}" ]; then
      echo "hy2://${pass}@${ip}:${HY2_PORT}/?insecure=1&sni=${HY2_SNI}"
    else
      echo "hy2://${pass}@${ip}:${HY2_PORT}/?insecure=1"
    fi
  fi
  echo ""
  echo "检查服务状态："
  if cmd_exists systemctl && [ -d /run/systemd/system ]; then
    echo "  systemctl status hysteria-server --no-pager"
    echo "  journalctl -u hysteria-server -e --no-pager"
  else
    echo "  rc-service hysteria status"
    echo "  tail -n 200 /var/log/hysteria/hysteria.err"
  fi
  echo ""
  echo "防火墙：请放行 UDP ${HY2_PORT}"
  echo "=============================================="
}

main() {
  need_root
  install_deps

  local init
  init="$(detect_init)"

  local pass
  pass="$(gen_password)"

  download_hysteria

  if [ "$HY2_ACME" != "1" ]; then
    gen_cert_selfsigned
  fi

  write_config "$pass"

  if [ "$init" = "systemd" ]; then
    setup_service_systemd
  else
    setup_service_openrc
  fi

  print_result "$pass"
}

main "$@"

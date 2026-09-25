#!/usr/bin/env bash
# VPN exit server: Xray (VLESS-Reality + VLESS-XHTTP behind Caddy) + Cloudflare WARP for Google/AI.
# Usage (Ubuntu 22.04/24.04, as root):
#   bash install.sh
# Re-running is safe: existing keys in /etc/vpn/state.env are reused.
set -euo pipefail

REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"   # site Reality impersonates
XHTTP_PORT="${XHTTP_PORT:-8443}"                  # TLS port for XHTTP (for Yandex front / CDN)
STATE=/etc/vpn/state.env

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
mkdir -p /etc/vpn

echo "[1/7] packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl unzip jq openssl ufw debian-keyring debian-archive-keyring apt-transport-https gnupg >/dev/null

echo "[2/7] kernel: BBR"
cat > /etc/sysctl.d/99-vpn.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null

echo "[3/7] xray"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata >/dev/null

# --- persistent secrets ---
[ -f "$STATE" ] && . "$STATE"
IP="${IP:-$(curl -4fsS https://api.ipify.org)}"
UUID="${UUID:-$(xray uuid)}"
if [ -z "${PRIV:-}" ]; then
  KP=$(xray x25519)
  PRIV=$(echo "$KP" | awk -F': ' '/Private/{print $2}')
  PUB=$(echo "$KP" | awk -F': ' '/Public|Password/{print $2}')
fi
SID="${SID:-$(openssl rand -hex 8)}"
XPATH="${XPATH:-/$(openssl rand -hex 6)}"
DOMAIN="${DOMAIN:-${IP//./-}.sslip.io}"
cat > "$STATE" <<EOF
IP=$IP
UUID=$UUID
PRIV=$PRIV
PUB=$PUB
SID=$SID
XPATH=$XPATH
DOMAIN=$DOMAIN
EOF
chmod 600 "$STATE"

echo "[4/7] cloudflare warp (wgcf)"
if [ ! -f /etc/vpn/wgcf-profile.conf ]; then
  ARCH=amd64; [ "$(uname -m)" = aarch64 ] && ARCH=arm64
  VER=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest | jq -r .tag_name)
  curl -fsSL -o /usr/local/bin/wgcf "https://github.com/ViRb3/wgcf/releases/download/${VER}/wgcf_${VER#v}_linux_${ARCH}"
  chmod +x /usr/local/bin/wgcf
  ( cd /etc/vpn && wgcf register --accept-tos >/dev/null && wgcf generate >/dev/null )
fi
W=/etc/vpn/wgcf-profile.conf
WG_PRIV=$(awk -F' = ' '/PrivateKey/{print $2}' $W)
WG_PUB=$(awk -F' = ' '/PublicKey/{print $2}' $W)
WG_ADDR4=$(grep -m1 '^Address' $W | sed 's/.*= *//' | tr ',' '\n' | grep -m1 '\.' | tr -d ' ')
WG_ADDR6=$(grep '^Address' $W | sed 's/.*= *//' | tr ',' '\n' | grep -m1 ':' | tr -d ' ')

echo "[5/7] xray config"
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "reality",
      "listen": "0.0.0.0", "port": 443, "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": {
          "dest": "$REALITY_SNI:443", "serverNames": [ "$REALITY_SNI" ],
          "privateKey": "$PRIV", "shortIds": [ "$SID" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    },
    {
      "tag": "xhttp",
      "listen": "127.0.0.1", "port": 10000, "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "none" },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "path": "$XPATH", "mode": "auto" }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    {
      "tag": "warp", "protocol": "wireguard",
      "settings": {
        "secretKey": "$WG_PRIV",
        "address": [ "$WG_ADDR4", "$WG_ADDR6" ],
        "peers": [ { "publicKey": "$WG_PUB", "endpoint": "engage.cloudflareclient.com:2408" } ],
        "mtu": 1280, "domainStrategy": "ForceIPv4"
      }
    },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "ip": [ "geoip:private" ], "outboundTag": "block" },
      { "protocol": [ "bittorrent" ], "outboundTag": "block" },
      {
        "domain": [
          "geosite:google", "geosite:openai", "domain:anthropic.com", "domain:claude.ai",
          "domain:gemini.google.com", "domain:aistudio.google.com", "domain:generativelanguage.googleapis.com",
          "domain:ipinfo.io", "domain:ifconfig.co"
        ],
        "outboundTag": "warp"
      }
    ]
  }
}
EOF
xray run -test -c /usr/local/etc/xray/config.json >/dev/null

echo "[6/7] caddy (TLS for XHTTP on :$XHTTP_PORT, cert via Let's Encrypt for $DOMAIN)"
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq && apt-get install -y -qq caddy >/dev/null
fi
cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN:$XHTTP_PORT {
  handle $XPATH* {
    reverse_proxy 127.0.0.1:10000 {
      flush_interval -1
      transport http { versions h2c 1.1 }
    }
  }
  handle {
    respond "OK" 200
  }
}
EOF

echo "[7/7] firewall + start"
ufw allow 22/tcp >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw allow ${XHTTP_PORT}/tcp >/dev/null
ufw --force enable >/dev/null
systemctl enable --now xray caddy >/dev/null
systemctl restart xray caddy

REALITY_LINK="vless://$UUID@$IP:443?type=tcp&security=reality&flow=xtls-rprx-vision&sni=$REALITY_SNI&fp=chrome&pbk=$PUB&sid=$SID#Reality-$IP"
XHTTP_LINK="vless://$UUID@$DOMAIN:$XHTTP_PORT?type=xhttp&security=tls&sni=$DOMAIN&path=$(printf %s "$XPATH" | jq -sRr @uri)&mode=auto&alpn=h2#XHTTP-direct"
cat > /root/vpn-links.txt <<EOF
$REALITY_LINK
$XHTTP_LINK
EOF

echo
echo "=== DONE ==="
echo "Links saved to /root/vpn-links.txt"
echo "Send to Claude (no secrets): IP=$IP DOMAIN=$DOMAIN XPATH=$XPATH XHTTP_PORT=$XHTTP_PORT"
systemctl is-active xray caddy

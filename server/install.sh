#!/usr/bin/env bash
# VPN exit server: Xray (VLESS-Reality + VLESS-XHTTP behind Caddy); all traffic exits directly from the VPS IP.
# Usage (Ubuntu 22.04/24.04, as root):
#   DOMAIN=example.com bash install.sh   # A-records for example.com and www must point here
#   bash install.sh                      # without a domain: <ip>.sslip.io
# Reality impersonates our own site (Caddy on :8443), so probes of :443 see a normal website.
# Re-running is safe: existing keys in /etc/vpn/state.env are reused.
set -euo pipefail

DOMAIN_ARG="${DOMAIN:-}"
XHTTP_PORT="${XHTTP_PORT:-8443}"                  # TLS port for XHTTP (for Yandex front / CDN)
STATE=/etc/vpn/state.env

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
mkdir -p /etc/vpn

echo "[1/6] packages"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a   # no "restart services?" dialog
apt-get update -qq
apt-get install -y -qq curl unzip jq openssl ufw apt-transport-https gnupg >/dev/null

echo "[2/6] kernel: BBR"
cat > /etc/sysctl.d/99-vpn.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null

echo "[3/6] xray"
if ! command -v xray >/dev/null || [ -n "${UPDATE_XRAY:-}" ]; then
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata >/dev/null
else
  echo "  already installed: $(xray version | head -1) (set UPDATE_XRAY=1 to update)"
fi

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
SUBTOKEN="${SUBTOKEN:-$(openssl rand -hex 12)}"
DOMAIN="${DOMAIN_ARG:-${DOMAIN:-${IP//./-}.sslip.io}}"
case "$DOMAIN" in *.sslip.io) NAMES="$DOMAIN" ;; *) NAMES="$DOMAIN www.$DOMAIN" ;; esac
cat > "$STATE" <<EOF
IP=$IP
UUID=$UUID
PRIV=$PRIV
PUB=$PUB
SID=$SID
XPATH=$XPATH
SUBTOKEN=$SUBTOKEN
DOMAIN=$DOMAIN
EOF
chmod 600 "$STATE"

echo "[4/6] xray config"
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
          "dest": "127.0.0.1:$XHTTP_PORT", "serverNames": [ $(printf '"%s",' $NAMES | sed 's/,$//') ],
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
        "xhttpSettings": {
          "path": "$XPATH", "mode": "auto",
          "xPaddingObfsMode": true, "xPaddingPlacement": "queryInHeader", "xPaddingKey": "_dc",
          "xPaddingHeader": "X-Request-Context", "xPaddingMethod": "tokenish",
          "serverMaxHeaderBytes": 1048576
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "ip": [ "geoip:private" ], "outboundTag": "block" },
      { "protocol": [ "bittorrent" ], "outboundTag": "block" }
    ]
  }
}
EOF
xray run -test -c /usr/local/etc/xray/config.json >/dev/null

echo "[5/6] caddy (TLS for XHTTP on :$XHTTP_PORT, cert via Let's Encrypt for $DOMAIN)"
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq && apt-get install -y -qq caddy >/dev/null
fi
mkdir -p /var/www/site
[ -f /var/www/site/index.html ] || cat > /var/www/site/index.html <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Wand Legacy</title>
<style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:radial-gradient(circle at 50% 30%,#1d2a3a,#07090d);color:#e8dcb5;font-family:Georgia,serif;text-align:center}
h1{font-size:clamp(2.2rem,8vw,4.5rem);letter-spacing:.08em;margin:0 0 .4em;text-shadow:0 0 24px #c9a64688}
p{opacity:.75;font-size:1.1rem;margin:0 16px}
</style></head>
<body><div><h1>&#10022; Wand Legacy &#10022;</h1><p>The dark arts are being prepared. Return soon.</p></div></body></html>
HTML
SITES=$(for n in $NAMES; do printf '%s:%s, ' "$n" "$XHTTP_PORT"; done | sed 's/, $//')
cat > /etc/caddy/Caddyfile <<EOF
$SITES {
  handle $XPATH* {
    reverse_proxy 127.0.0.1:10000 {
      flush_interval -1
      transport http {
        versions h2c 1.1
      }
    }
  }
  handle {
    root * /var/www/site
    file_server
  }
}
EOF

echo "[6/6] firewall + start"
ufw allow 22/tcp >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw allow ${XHTTP_PORT}/tcp >/dev/null
ufw --force enable >/dev/null
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>/tmp/caddy-validate.log || { cat /tmp/caddy-validate.log; exit 1; }
systemctl enable --now xray caddy >/dev/null
systemctl restart xray caddy

# Yandex CDN forbids POST, so uplink goes as GET (packet-up); padding settings must match the server.
# GET bodies are dropped by the CDN, so uplink data travels in X-Data-N headers of 3-4 KB each;
# scMaxEachPostBytes caps the whole request (the server accepts up to serverMaxHeaderBytes, default only 8 KB).
XEXTRA='{"xPaddingObfsMode":true,"xPaddingPlacement":"queryInHeader","xPaddingKey":"_dc","xPaddingHeader":"X-Request-Context","xPaddingMethod":"tokenish","uplinkHTTPMethod":"GET","uplinkDataPlacement":"header","uplinkChunkSize":"3000-4000","scMaxEachPostBytes":16384,"scMinPostsIntervalMs":30}'
XEXTRA_URI=$(printf %s "$XEXTRA" | jq -sRr @uri)
REALITY_LINK="vless://$UUID@$IP:443?type=tcp&security=reality&flow=xtls-rprx-vision&sni=$DOMAIN&fp=chrome&pbk=$PUB&sid=$SID#Reality-$DOMAIN"
XHTTP_LINK="vless://$UUID@$DOMAIN:$XHTTP_PORT?type=xhttp&security=tls&sni=$DOMAIN&path=$(printf %s "$XPATH" | jq -sRr @uri)&mode=packet-up&alpn=h2&fp=chrome&extra=$XEXTRA_URI#XHTTP-direct"
CDN_HOST="${CDN_HOST:-assets.$DOMAIN}"
CDN_LINK="vless://$UUID@$CDN_HOST:443?type=xhttp&security=tls&sni=$CDN_HOST&host=$CDN_HOST&path=$(printf %s "$XPATH" | jq -sRr @uri)&mode=packet-up&alpn=h2&fp=chrome&extra=$XEXTRA_URI#CDN-Yandex"
cat > /root/vpn-links.txt <<EOF
$REALITY_LINK
$CDN_LINK
$XHTTP_LINK
EOF

# --- subscription for client apps (served by Caddy from the site root) ---
SUBDIR=/var/www/site/s/$SUBTOKEN
rm -rf /var/www/site/s && mkdir -p "$SUBDIR"
# universal: base64 list of links (v2RayTun, Happ, Hiddify, Streisand, Shadowrocket)
base64 -w0 /root/vpn-links.txt > "$SUBDIR/sub"
# full Xray config with auto-switch Reality -> CDN (Happ, v2RayTun, Streisand)
cat > "$SUBDIR/config.json" <<EOF
{
  "remarks": "Wand Legacy auto",
  "log": { "loglevel": "warning" },
  "dns": { "servers": [ "1.1.1.1", "8.8.8.8" ], "queryStrategy": "UseIPv4" },
  "inbounds": [
    { "tag": "socks", "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
      "settings": { "udp": true }, "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] } },
    { "tag": "http", "listen": "127.0.0.1", "port": 10809, "protocol": "http",
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls" ] } }
  ],
  "outbounds": [
    {
      "tag": "reality", "protocol": "vless",
      "settings": { "vnext": [ { "address": "$IP", "port": 443,
        "users": [ { "id": "$UUID", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
      "streamSettings": { "network": "tcp", "security": "reality",
        "realitySettings": { "serverName": "$DOMAIN", "fingerprint": "chrome", "publicKey": "$PUB", "shortId": "$SID" } }
    },
    {
      "tag": "cdn", "protocol": "vless",
      "settings": { "vnext": [ { "address": "$CDN_HOST", "port": 443,
        "users": [ { "id": "$UUID", "encryption": "none" } ] } ] },
      "streamSettings": { "network": "xhttp", "security": "tls",
        "tlsSettings": { "serverName": "$CDN_HOST", "alpn": [ "h2" ], "fingerprint": "chrome" },
        "xhttpSettings": { "host": "$CDN_HOST", "path": "$XPATH", "mode": "packet-up", "extra": $XEXTRA } }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "burstObservatory": {
    "subjectSelector": [ "reality" ],
    "pingConfig": { "destination": "https://connectivitycheck.gstatic.com/generate_204",
      "interval": "15s", "sampling": 2, "timeout": "3s" }
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "balancers": [ { "tag": "auto", "selector": [ "reality" ], "fallbackTag": "cdn", "strategy": { "type": "leastPing" } } ],
    "rules": [
      { "protocol": [ "bittorrent" ], "outboundTag": "direct" },
      { "domain": [ "geosite:category-ru", "geosite:private" ], "outboundTag": "direct" },
      { "ip": [ "geoip:ru", "geoip:private" ], "outboundTag": "direct" },
      { "network": "tcp,udp", "balancerTag": "auto" }
    ]
  }
}
EOF
chmod -R a+rX /var/www/site/s

echo
echo "=== DONE ==="
echo "Links saved to /root/vpn-links.txt"
echo "Subscription (all apps):      https://$DOMAIN/s/$SUBTOKEN/sub"
echo "Auto-switch config (Happ/v2RayTun/Streisand): https://$DOMAIN/s/$SUBTOKEN/config.json"
echo "Same via CDN (under whitelists): https://$CDN_HOST/s/$SUBTOKEN/sub"
systemctl is-active xray caddy

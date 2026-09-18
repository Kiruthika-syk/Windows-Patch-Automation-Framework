#!/bin/bash
# Install nginx and enable HTTPS for the Windows Patch docs site.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT_DIR="${HOME}"
SSL_DIR="/etc/nginx/ssl"
NGINX_CONF="/etc/nginx/conf.d/windows-patch-docs.conf"

SERVER_CRT="${CERT_DIR}/blr-kiruthika.strykercorp.com.crt"
INTERMEDIATE_CRT="${CERT_DIR}/blr-kiruthika_intermediate_ca.crt"
PRIVATE_KEY="${CERT_DIR}/blr-kiruthika.strykercorp.com.key"

for f in "$SERVER_CRT" "$INTERMEDIATE_CRT" "$PRIVATE_KEY"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing certificate file: $f" >&2
    exit 1
  fi
done

echo "Installing nginx..."
sudo dnf install -y nginx

echo "Installing TLS certificates..."
sudo mkdir -p "$SSL_DIR"
# Intermediate CA is SHA-1 signed; OpenSSL 3 rejects it in nginx chain files.
sudo cp "$SERVER_CRT" "$SSL_DIR/blr-kiruthika-server.crt"
sudo cp "$PRIVATE_KEY" "$SSL_DIR/blr-kiruthika.strykercorp.com.key"
sudo chmod 644 "$SSL_DIR/blr-kiruthika-server.crt"
sudo chmod 600 "$SSL_DIR/blr-kiruthika.strykercorp.com.key"

echo "Allowing nginx to traverse docs path..."
chmod o+x "${HOME}" "${HOME}/.cursor-server" "${ROOT}"
sudo setsebool -P httpd_read_user_content 1
sudo chcon -R -t httpd_sys_content_t "${ROOT}/docs"

echo "Deploying nginx config..."
sudo cp "${ROOT}/deploy/nginx-windows-patch-docs-https.conf" "$NGINX_CONF"

echo "Stopping Python docs server (nginx will serve on 8080 and 443)..."
if [[ -x "${ROOT}/scripts/serve-docs.sh" ]]; then
  "${ROOT}/scripts/serve-docs.sh" stop || true
fi

echo "Opening firewall ports..."
sudo firewall-cmd --add-service=https --permanent 2>/dev/null || true
sudo firewall-cmd --add-port=8080/tcp --permanent 2>/dev/null || true
sudo firewall-cmd --reload 2>/dev/null || true

echo "Starting nginx..."
sudo nginx -t
sudo systemctl enable --now nginx

echo ""
echo "HTTPS docs site ready:"
echo "  https://blr-kiruthika.strykercorp.com/"
echo "  http://10.90.105.221:8080/  (HTTP by IP, unchanged)"
echo ""
echo "Verify: curl -sI https://blr-kiruthika.strykercorp.com/ | head"

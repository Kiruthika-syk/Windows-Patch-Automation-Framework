# Internal web server — documentation site

Serve the interactive guide (`docs/index.html`) on your internal network.

## Quick start (Python — no root required)

```bash
cd /home/tpx-admin/.cursor-server/Windows-Patch-Automation-Framework
chmod +x scripts/serve-docs.sh
./scripts/serve-docs.sh start
```

Open in a browser (from any machine that can reach this host):

| URL | Page |
|-----|------|
| http://10.90.105.221:8080/ | Main guide (index.html) |
| http://blr-kiruthika.strykercorp.com:8080/ | Same (if DNS resolves) |

```bash
./scripts/serve-docs.sh status   # check if running
./scripts/serve-docs.sh stop     # stop server
./scripts/serve-docs.sh restart  # restart after doc updates
```

**Log:** `output/docs-server.log`

**Environment overrides:**

```bash
export PATCH_DOCS_PORT=9080
export PATCH_DOCS_HOST=0.0.0.0
./scripts/serve-docs.sh restart
```

## Auto-start on login (systemd user service)

```bash
mkdir -p ~/.config/systemd/user
cp deploy/windows-patch-docs.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now windows-patch-docs.service
systemctl --user status windows-patch-docs.service
```

## Optional: nginx (IT-managed)

If your team installs nginx on RHEL:

```bash
sudo dnf install -y nginx
sudo cp deploy/nginx-windows-patch-docs.conf /etc/nginx/conf.d/windows-patch-docs.conf
sudo nginx -t
sudo systemctl enable --now nginx
```

Then open http://10.90.105.221:8080/

## Firewall

Allow inbound TCP on the chosen port from your corporate network:

```bash
sudo firewall-cmd --add-port=8080/tcp --permanent
sudo firewall-cmd --reload
```

## Share with colleagues

Send them:

> Windows Patch Automation guide: **http://10.90.105.221:8080/**

No VPN changes needed if they already reach the BLR management network.

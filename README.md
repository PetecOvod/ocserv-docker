# OpenConnect VPN (ocserv) in Docker (Alpine-based)

A fully-featured Docker container for OpenConnect VPN server (ocserv) `v1.3.0`, including:

- ✅ Password-based and certificate-based authentication
- ✅ Auto-generation of self-signed certificates
- ✅ Let's Encrypt integration via `certbot`
- ✅ User management via shell script
- ✅ Support for `occtl` admin CLI (via `readline-dev`)
- ✅ Dynamic certificate templating with `envsubst`
- ✅ Docker Compose support with environment variables

---

## 🚀 Quick Start

```bash
docker compose up -d --build
```

---

## 📁 Project Structure

```
.
├── config/                # Contains ocserv.conf, passwd, generated certs
├── scripts/               # Shell scripts for startup, user mgmt, Let's Encrypt
├── templates/             # envsubst-enabled cert templates (ca.tmpl, server.tmpl)
├── Dockerfile             # Alpine-based build for ocserv 1.3.0
├── docker-compose.yml     # Deployment configuration
└── README.md              # This file
```

---

## 🐳 Example `docker-compose.yml`

```yaml
version: '3.8'

services:
  ocserv:
    build: .
    container_name: ocserv
    ports:
      - "443:443"
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - ./config:/etc/ocserv
    environment:
      - TZ=Europe/Moscow
      - SRV_CN=vpn.example.com
      - SRV_CA=MyVPN CA
    restart: unless-stopped
```

---

## 🌍 Environment Variables

- `TZ` — Time zone of the container (for logging, certs, etc.)
- `SRV_CN` — Common Name for VPN server TLS cert
- `SRV_CA` — Issuer (CA) name for self-signed cert

These are used dynamically when generating TLS certificates on first run.

---

## 🔐 Certificate Support

### ✔️ Self-Signed (Auto)

Will be generated automatically using `/etc/ocserv/*.tmpl` templates.

### 🌐 Let's Encrypt (Manual)

Run this inside the container:

```bash
docker exec -it ocserv ./scripts/get-cert.sh vpn.example.com you@email.com
```

---

## 👤 User Management

### Add user (password auth)

```bash
docker exec -it ocserv ./scripts/add-user.sh alice secret123
```

### Manual edit

```bash
nano config/passwd
```

Format:

```
username:password
```

---

## 🧰 Admin Console Support (`occtl`)

The container includes support for `occtl` CLI tool via `readline-dev`.  
You can use it for managing users, sessions, status:

```bash
docker exec -it ocserv occtl
```

---

## 🔎 Connect from Client

Use `openconnect` CLI or Cisco AnyConnect app.

```bash
openconnect https://your.server.com
```

Supports both username/password and client certificate modes.

---

## 🛡 Security Notes

- Make sure port 443 is reachable and not used by other services (like NGINX).
- For production, generate and mount real TLS certificates, or use Let's Encrypt.
- Use firewall rules to restrict access if needed.

---

MIT License — use freely and improve ✨

# OpenConnect VPN (ocserv) — Final Stable Docker Edition

A production-ready Docker build for OpenConnect VPN Server (`ocserv`) with certificate and password authentication, built on Alpine with secure multi-stage build.

---

## ✅ Features

- Clean `multi-stage` Dockerfile
- Secure Alpine base image
- TLS auto-generation on first launch (via `certtool`)
- Password + certificate authentication
- Admin socket enabled (works with `occtl`)
- Let's Encrypt support via `get-cert.sh`
- Tun device support for real VPN routing
- Organized project layout (config, scripts, templates)

---

## 🚀 Quick Start

```bash
docker compose up -d --build
```

Access the VPN at:

```
https://your-server-ip:43443
```

Test user (default):
```
Username: vpnuser
Password: password
```

---

## 📁 Folder Structure

```
.
├── config/             # Main ocserv config file
│   └── ocserv.conf
├── auth/               # User credentials
│   └── passwd
├── templates/          # Certtool templates
│   ├── ca.tmpl
│   └── server.tmpl
├── scripts/            # Automation and helpers
│   ├── start.sh        # Autogenerates TLS certs on first run
│   ├── get-cert.sh     # Get Let's Encrypt certificate
│   └── add-user.sh     # Add new user (login+password)
├── Dockerfile
├── docker-compose.yml
└── README.md
```

---

## ⚙️ Environment Variables (used in TLS generation)

Define in `docker-compose.yml` under `environment:`:

```yaml
    environment:
      - TZ=Europe/Moscow
      - SRV_CN=vpn.example.com
      - SRV_CA=My VPN CA
```

---

## 🔐 User Management

To add a new user:

```bash
docker exec -it ocserv ./scripts/add-user.sh username password
```

---

## 🔒 Let's Encrypt TLS (manual)

To get a real certificate:

```bash
docker exec -it ocserv ./scripts/get-cert.sh vpn.example.com you@example.com
```

This replaces the self-signed certificate in `/etc/ocserv/cert/`.

---

## 🧠 Notes

- Certificates are stored in: `/etc/ocserv/cert/`
- Users/password file: `/etc/ocserv/auth/passwd`
- Default socket: `/var/run/ocserv-socket` (used by `occtl`)
- All scripts run inside container

---

## ✅ Recommended ocserv.conf values

Ensure these are set:

```ini
auth = "certificate"
auth = "plain[passwd=/etc/ocserv/auth/passwd]"
socket-file = /var/run/ocserv-socket
tcp-port = 443
udp-port = 443
route = default
seccomp = true
dtls-legacy = false
tcp-wrappers = false
run-as-user = nobody
run-as-group = nobody
```

---

MIT License — use, fork, build your secure VPN!

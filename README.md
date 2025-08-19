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

---

## 📁 Folder Structure

```
.
├── config/            
│   └── ocserv.conf     # Main ocserv config file
├── templates/          # Certtool templates
│   ├── ca.tmpl
│   └── server.tmpl
├── scripts/            # Automation and helpers
│   ├── start.sh        # Autogenerates TLS certs on first run
│   ├── get-cert.sh     # Get Let's Encrypt certificate
├── Dockerfile
├── docker-compose.yml
└── README.md
```

---

## ⚙️ Environment Variables (used in TLS generation)

Define in `docker-compose.yml` under `environment:`:

```yaml
    environment:
      - SRV_CN=vpn.example.com
      - SRV_CA=My VPN CA
```

---

## 🔐 User Management

To add a new user:

```bash
docker exec -it ocserv ocpasswd -c ./etc/ocserv/ocpasswd vpnuser
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
- Users/password file: `/etc/ocserv/passwd`
- All scripts run inside container

---

MIT License — use, fork, build your secure VPN!

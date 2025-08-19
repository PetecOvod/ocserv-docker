# OpenConnect VPN (ocserv) — Final Stable Docker Edition

A production-ready Docker build for OpenConnect VPN Server (ocserv) with password and certificate authentication, based on Alpine.

## ✅ Features

- Uses modern ocserv.conf with `socket-file` and security options
- TLS auto-generation on first start (via certtool and templates)
- Supports Let's Encrypt (manual run)
- Password-based and certificate-based authentication
- Works with occtl (admin socket support)
- Minimal Alpine image, hardened with seccomp/net_raw
- Tun interface support for real VPN routing

---

## 🚀 Quick Start

```bash
docker compose up -d --build
```

Connect to: `https://your-ip:43443`

Username: `vpnuser`  
Password: `password`

---

## ⚙️ Folder Structure

```
.
├── config/
│   ├── ocserv.conf        # Custom server config
│   └── passwd             # User credentials
├── templates/             # Certificate templates
├── scripts/               # Shell helpers (start, add-user, get-cert)
├── Dockerfile
├── docker-compose.yml
└── README.md
```

---

## 🔐 Let's Encrypt

To issue a valid TLS cert (manually):

```bash
docker exec -it ocserv ./scripts/get-cert.sh vpn.example.com your@email.com
```

---

## 👤 Add user

```bash
docker exec -it ocserv ./scripts/add-user.sh alice s3cret
```

---

## 🛠 Admin shell

```bash
docker exec -it ocserv occtl
```

---

## 📌 Notes

- Uses `devices: /dev/net/tun` — required for VPN
- Uses `ocserv-data` named volume to persist certs and config
- Certs are only generated on first run

MIT Licensed — use and improve!

# OpenConnect VPN (ocserv) in Docker (Alpine-based)

A lightweight Docker container for OpenConnect VPN server (ocserv), supporting both password and certificate-based authentication.

---

## 🚀 Build and Run

```bash
docker compose up -d
```

---

## 🐳 Example docker-compose.yml

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

## 🔐 Self-Signed Certificate Generation

Certificates will be auto-generated at first run using environment values:

- `SRV_CN` → Common Name (CN) in server cert
- `SRV_CA` → Organization/Issuer name in CA and server cert

---

## 🔐 Let's Encrypt Support

```bash
docker exec -it ocserv ./scripts/get-cert.sh vpn.example.com email@example.com
```

---

## 👤 Password-based Users

Add users manually to `config/passwd` or use:

```bash
docker exec -it ocserv ./scripts/add-user.sh username password
```

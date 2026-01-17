# OpenConnect VPN Server (ocserv) — Docker (Alpine)

A production-ready Docker build for OpenConnect VPN Server (`ocserv`) with certificate and password authentication, built on Alpine with secure multi-stage build.

---

## ✅ Features
- Builds **ocserv 1.3.0** from source
- Self-signed certificates on first start (via `certtool`)
- Public certificates via **acme.sh** (HTTP-01 or DNS-01)
- No `--privileged` (uses only `NET_ADMIN`, and `/dev/net/tun`)
- NAT/forwarding rules in dedicated chains (`OCSERV_NAT`, `OCSERV_FWD`) with **automatic cleanup** on stop
- Supports both nft and legacy iptables backends

---

## 📁 Directory layout

```
.
├─ Dockerfile
├─ scripts/
│  ├─ start.sh         # self-signed bootstrap, iptables setup/cleanup, start ocserv
│  └─ get-cert.sh      # issue/renew Let's Encrypt certs via acme.sh (HTTP-01 / DNS-01)
├─ templates/
│  ├─ ca.tmpl
│  ├─ ocserv.conf.tmpl
│  └─ server.tmpl
```

---

---

## 🧰 Config file (`ocserv.conf`)

The container uses `/etc/ocserv/config/ocserv.conf`. Mount a host folder to keep and edit it:

```yaml
volumes:
  - ./ocserv/config:/etc/ocserv/config
```

- First start: `ocserv.conf` is generated from `templates/ocserv.conf.tmpl`.
- Next starts: if `ocserv.conf` already exists, it won’t be overwritten.

---

## 🧩 Environment (compose)

Add under `services.ocserv.environment`:

```yaml
environment:
  # Base
  - VPN_SUBNET=10.10.10.0/24
  - USE_IPTABLES_NFT=true      # set false on legacy hosts (e.g. Synology)
  - ENABLE_DTLS=true           # set false to force TCP-only (DTLS/UDP disabled)
  # Self-signed bootstrap
  - SRV_CN=vpn.example.com   # server CN
  - SRV_CA=VPN CA            # self-signed CA name
  # ACME (used by scripts/get-cert.sh)
  - ACME_ACCOUNT_EMAIL=admin@example.com
  - ACME_SERVER=letsencrypt
```

Recommended volumes:
```yaml
volumes:
  - ./ocserv/cert/:/etc/ocserv/cert
  - ./ocserv/auth:/etc/ocserv/auth
  - ./ocserv/acme:/etc/acme
  - ./ocserv/config:/etc/ocserv/config   # generated ocserv.conf lives here
```

On first start the container will generate `./ocserv/config/ocserv.conf` from the template.
If the file already exists, it will be used as-is.

Ports (example when host 443 is busy):
```yaml
ports:
  - "43443:443/tcp"
  # Optional but recommended for better performance (DTLS over UDP):
  - "43443:443/udp"
```

Capabilities & device:
```yaml
devices:
  - /dev/net/tun
cap_add:
  - NET_ADMIN
```

## 🧩 Docker Compose
```yaml
services:
  ocserv:
    image: docker.io/petecovod/ocserv:latest
    container_name: ocserv
    ports:
      - "43443:443/tcp"
      - "43443:443/udp"   # optional (DTLS)
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    volumes:
      - ./ocserv/cert/:/etc/ocserv/cert
      - ./ocserv/auth:/etc/ocserv/auth
      - ./ocserv/acme:/etc/acme
      - ./ocserv/config:/etc/ocserv/config
    environment:
      - PUID=1027 # Change me use id $user for check
      - PGID=100 # Change me use id $user for check
      - TZ=Europe/Moscow
      - SRV_CN=vpn.example.com # Change me
      - SRV_CA=VPN
      - VPN_SUBNET=10.10.10.0/24
      - ENABLE_DTLS=true
      # ACME (for get-cert.sh)
      - ACME_ACCOUNT_EMAIL=admin@example.com # Change me
      - ACME_SERVER=letsencrypt #zerossl/buypass
    restart: unless-stopped
    network_mode: "bridge"
```

---

## ⚡ DTLS (UDP) and `ENABLE_DTLS`

OpenConnect uses TCP (CSTP) for control and can use DTLS over UDP for data when available.
UDP is **optional**: if it’s blocked on a network, clients will fall back to TCP automatically.
Note: TCP BBR affects only TCP traffic; DTLS uses UDP and is not governed by TCP congestion control.

Toggle DTLS/UDP with:

- `ENABLE_DTLS=true` (default): DTLS enabled, `udp-port` is set to `443` by default.
- `ENABLE_DTLS=false`: DTLS disabled, `udp-port` is set to `0` (TCP-only).

If you set `ENABLE_DTLS=false`, you can also omit the UDP port mapping (`443/udp`).

---

## 🚀 First run

```bash
docker compose up -d ocserv
```

On first boot `start.sh` will:
- render templates with env (`SRV_CN`, `SRV_CA`, etc.) via `envsubst` and write `/etc/ocserv/config/ocserv.conf`,
- generate a self-signed CA and server certificate under `/etc/ocserv/cert`,
- configure iptables in dedicated chains and attach to `POSTROUTING`/`FORWARD`,
- start ocserv (PID 1) and **auto-clean iptables** on exit.


---

## 🔐 Users

### Password auth

Add a user:
```bash
docker exec -it ocserv ocpasswd -c /etc/ocserv/auth/passwd vpnuser
```
Delete a user:
```bash
docker exec -it ocserv ocpasswd -c /etc/ocserv/auth/passwd -d vpnuser
```

### Certificate auth

```bash
docker exec -it ocserv ./scripts/make-client.sh alice export
```
Files will be stored under `/etc/ocserv/auth/clients/`:
- `alice-key.pem`, `alice-cert.pem`
- optional `alice.p12` (if you passed `export`)

---

## 🔒 Let’s Encrypt via acme.sh

### HTTP-01 (standalone)

Requirements:
- Public **port 80** must reach this container (map `80:80` or forward via reverse proxy).
- DNS A/AAAA records point to your public IP.

Issue:
```bash
docker exec -it ocserv ./scripts/get-cert.sh http
docker restart ocserv
```

### DNS-01 (no port 80)

Full provider list & required variables:  
https://github.com/acmesh-official/acme.sh/wiki/dnsapi

1) Put provider secrets in `/etc/acme/provider.env` (mounted from `./acme`). Example (Cloudflare):
```
ACME_DNS=dns_cf
CF_Token=YOUR_CF_API_TOKEN
CF_Account_ID=YOUR_CF_ACCOUNT_ID
```
2) Issue:
```bash
docker exec -it ocserv ./scripts/get-cert.sh dns
docker restart ocserv
```
---

Apache License 2.0

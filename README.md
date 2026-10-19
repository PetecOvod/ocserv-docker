# OpenConnect VPN Server (ocserv) — Docker (Alpine)

A production-ready Docker build for OpenConnect VPN Server (`ocserv`) with certificate and password authentication, built on Alpine with secure multi-stage build.

---

## ✅ Features
- Builds **ocserv 1.5.0** from source (meson), on a pinned Alpine base
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
  - AUTH_MODE=password-or-cert # see "Authentication modes" below
  - CLIENT_CERT_DAYS=3650      # validity of new client certificates
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
    image: docker.io/petecovod/ocserv:0.3
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

## 🛠️ `ocs` — management CLI

The image ships `ocs`, a small CLI that wraps the common operations with
validation, clear errors and `--help`, so you don't have to remember long
`ocpasswd` / `occtl` invocations.

```bash
docker exec -it ocserv ocs help
```

Handy host alias:

```bash
alias ocs='docker exec -it ocserv ocs'
# then simply:  ocs user add alice
```

Commands:

```
ocs user list                 # list password-auth users
ocs user add <name>           # create a user (prompts for password)
ocs user passwd <name>        # change a user's password
ocs user del <name>           # delete a user
ocs client list               # client certs: expiry, serial, status
ocs client issue <name> --p12 # issue a client cert (+ .p12 for device import)
ocs client renew <name>       # new client cert; the old one is revoked
ocs client revoke <name>      # revoke a client cert, close its sessions
ocs cert issue <http|dns>     # issue/renew the server cert (acme.sh)
ocs cert info                 # server cert subject/issuer/expiry + status
ocs session list              # active VPN sessions
ocs session kill <name>       # disconnect a user
ocs status                    # server status (uptime, sessions, bans)
```

> The underlying scripts (`get-cert.sh`, `make-client.sh`) and raw tools
> (`ocpasswd`, `occtl`) still work directly for backward compatibility; `ocs`
> is just the friendlier front door.

## 🔑 Authentication modes

`AUTH_MODE` sets how users log in:

| `AUTH_MODE` | A user needs |
|---|---|
| `password` | a password |
| `cert` | a client certificate |
| `password-or-cert` (default) | a password **or** a client certificate (either one is enough; this is not two-factor) |
| `password-and-cert` | a client certificate **and** the password of the user named in its CN |

The mode is written into `ocserv.conf` on the first start, and the log shows it
on every start (`Authentication: ...`). `ocserv.conf` is never rewritten: if
`AUTH_MODE` is set and the existing file uses another mode, the container
stops with an error that shows the lines to change. To switch the mode later,
edit the `auth` / `enable-auth` lines in `ocserv.conf` (or set `AUTH_MODE` to
see what they should be) and restart the container; a reload does not change
authentication methods.

## 🔐 Users

### Password auth

```bash
docker exec -it ocserv ocs user add vpnuser     # add (prompts for password)
docker exec -it ocserv ocs user del vpnuser     # remove
docker exec -it ocserv ocs user list            # list
```

Raw equivalent: `ocpasswd -c /etc/ocserv/auth/passwd [-d] vpnuser`.

### Certificate auth

```bash
docker exec -it ocserv ocs client issue alice --p12
```
Files are stored under `/etc/ocserv/auth/clients/`:
- `alice-key.pem`, `alice-cert.pem`
- optional `alice.p12` (with `--p12`)

A certificate is valid for `CLIENT_CERT_DAYS` days (default 3650), or for
`--days N` given to `issue` / `renew`.

```bash
docker exec ocserv ocs client list              # expiry, serial, status
docker exec ocserv ocs client renew alice --p12 # new certificate; the old one is revoked
docker exec ocserv ocs client revoke alice      # lost device: revoke it
```

`revoke` adds the certificate to the revocation list
(`/etc/ocserv/cert/crl.pem`), closes the user's sessions and deletes the key.
`renew` revokes the previous certificate but keeps active sessions connected.
The list is enforced by the `crl = /etc/ocserv/cert/crl.pem` line of
`ocserv.conf`; the log shows on every start whether revocation is on.

Certificates issued by earlier image versions all have serial number 01, so
one of them cannot be revoked alone. Renew each of them, then block all of
them at once with `ocs client revoke-legacy`.

---

## 🔒 Let’s Encrypt via acme.sh

### HTTP-01 (standalone)

Requirements:
- Public **port 80** must reach this container (map `80:80` or forward via reverse proxy).
- DNS A/AAAA records point to your public IP.

Issue (`ocs cert issue http` is equivalent):
```bash
docker exec -it ocserv ocs cert issue http
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
2) Issue (`ocs cert issue dns` is equivalent):
```bash
docker exec -it ocserv ocs cert issue dns
```

The DNS plugin is downloaded on first use from the same acme.sh release as the one
in the image (`ACME_VERSION`), not from `master`. To pin the exact file, put its
sha256 into `ACME_DNS_SHA256` (in `provider.env` or the compose `environment`):
a mismatch stops the script. The hash is checked on every run, also for a plugin
that is already there, for example one mounted read-only as
`/usr/local/share/dnsapi/<name>.sh`.

Provider secrets are saved by acme.sh into `/etc/acme/account.conf` (the
`./acme` volume), so they persist and are reused automatically on renewal.
Files in `/etc/acme` are run as shell code, so the script refuses to work if any
of them is writable by group or others.

A new certificate is checked (valid, matches its key) and then loaded by the
running ocserv in place (`occtl reload`): connected users stay connected, and
no container restart is needed.

### Auto-renewal

`get-cert.sh` is safe to run on a schedule: `acme.sh` skips when the cert is not
yet due (no CA request, no DNS challenge) and only reissues within the renewal
window (~30 days before expiry). A skipped renewal exits with code 0. Schedule
it (e.g. every two weeks) with any host scheduler (cron, systemd timer, Synology
Task Scheduler), **without the `-it` flags**:

```bash
docker exec ocserv /scripts/get-cert.sh dns   # or: http
```

Example crontab entry (every two weeks):

```cron
0 4 1,15 * * docker exec ocserv /scripts/get-cert.sh dns
```

---

Apache License 2.0

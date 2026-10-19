# === Stage 1: Build ocserv from source ===
# Base image pinned by tag and multi-arch index digest; bump both together.
FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS builder

# To update: bump OCSERV_VERSION and put the sha256 of the new tarball into
# OCSERV_SHA256 (check the tarball's .sig against the maintainer's GPG key).
ENV OCSERV_VERSION=1.5.0
ARG OCSERV_SHA256=42ced08958b9576ab134fcb7bdc7f8df5e13214fd147855f99021fedcf0eedbe

RUN apk add --no-cache \
    build-base \
    meson \
    gnutls-dev \
    libev-dev \
    nettle-dev \
    readline-dev \
    libseccomp-dev \
    linux-headers \
    pkgconfig \
    curl

WORKDIR /tmp

# Optional features (PAM, RADIUS, GSSAPI, OTP, GeoIP, ...) are disabled and
# the ones we use are enabled explicitly, so the build does not change with
# whatever -dev packages happen to be installed: sock-diag (adaptive rate
# limiting) fails the build without linux-headers, and talloc/protobuf-c are
# always the bundled copies (the runtime stage ships no shared ones).
# ocserv-fw (restrict-user-to-routes/ports) uses iptables, which the image
# ships; the upstream default is nftables.
# Retries cover dropped connections to the download servers.
# patches/: fixes not released upstream yet (see the header of each file).
COPY patches /tmp/patches
RUN curl -fLO --retry 5 --retry-all-errors https://www.infradead.org/ocserv/download/ocserv-${OCSERV_VERSION}.tar.xz && \
    echo "${OCSERV_SHA256}  ocserv-${OCSERV_VERSION}.tar.xz" | sha256sum -c - && \
    tar -xf ocserv-${OCSERV_VERSION}.tar.xz && \
    cd ocserv-${OCSERV_VERSION} && \
    for p in /tmp/patches/*.patch; do patch -p1 < "$p" || exit 1; done && \
    meson setup build \
      --prefix=/usr --sysconfdir=/etc --buildtype=release \
      -Dpam=disabled -Dradius=disabled -Dgssapi=disabled -Dliboath=disabled \
      -Dlibnl=disabled -Dmaxmind=disabled -Dgeoip=disabled -Dlz4=disabled \
      -Dsystemd=disabled -Dutmp=disabled -Dlibwrap=disabled \
      -Dseccomp=enabled -Dsock-diag=enabled -Dlocal-talloc=true -Dlocal-protobuf=true \
      -Dpager= -Dfirewall-script=iptables && \
    meson compile -C build && \
    DESTDIR=/tmp/build-output meson install -C build --no-rebuild

# === Stage 2: Final runtime image ===
FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

LABEL maintainer="Yaroslav Minaev <mail@minaev.pro>"

# Runtime deps:
# - gnutls, nettle, libev, libseccomp, readline: shared libraries of ocserv,
#   ocserv-worker, occtl and ocpasswd (checked with ldd)
# - gnutls-utils: certtool (self-signed on first run)
# - iptables(+legacy) & iproute2: NAT rules and route detection
# - gettext: envsubst for templating configs
# - curl/openssl/ca-certificates/tzdata/socat: acme.sh + TLS + logs
# apk upgrade picks up fixes released after the base image was built.
RUN apk upgrade --no-cache \
 && apk add --no-cache \
    gnutls \
    nettle \
    libev \
    libseccomp \
    readline \
    gnutls-utils \
    iptables \
    iptables-legacy \
    iproute2 \
    gettext \
    curl \
    openssl \
    socat \
    ca-certificates \
    tzdata \
 && update-ca-certificates

# Install acme.sh from a pinned release (no cron, no profile).
# To update: bump ACME_VERSION and put the sha256 of the new acme.sh into ACME_SHA256.
# get-cert.sh fetches DNS plugins from the same release tag (ACME_VERSION), never from master.
ARG ACME_VERSION=3.1.6
ARG ACME_SHA256=c7d68b021cfd6380ea83a82962abde5b484779fee0b97d38681dfa1396bbc8d7
ENV ACME_VERSION=${ACME_VERSION}
RUN set -eux; \
    ACME_INSTALL=/usr/local/share; \
    ACME_CONFIG=/etc/acme; \
    mkdir -p "$ACME_INSTALL" "$ACME_CONFIG"; \
    curl -fsSLo /tmp/acme.sh --retry 5 --retry-all-errors "https://raw.githubusercontent.com/acmesh-official/acme.sh/${ACME_VERSION}/acme.sh"; \
    echo "${ACME_SHA256}  /tmp/acme.sh" | sha256sum -c -; \
    chmod +x /tmp/acme.sh; \
    cd /tmp; \
    ./acme.sh --install --home "$ACME_INSTALL" --config-home "$ACME_CONFIG" --nocron --noprofile; \
    ln -sf "$ACME_INSTALL/acme.sh" /usr/local/bin/acme.sh;
    
# Create runtime directories (workers run as nobody, see run-as-user)
RUN mkdir -p /etc/ocserv/cert /etc/ocserv/auth

# Copy ocserv from builder
COPY --from=builder /tmp/build-output /

# Copy project files
COPY templates /etc/ocserv/templates
COPY scripts /scripts
RUN chmod +x /scripts/start.sh /scripts/ocs \
 && ln -sf /scripts/ocs /usr/local/bin/ocs

CMD ["sh", "/scripts/start.sh"]

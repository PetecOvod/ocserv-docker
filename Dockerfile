# === Stage 1: Build ocserv from source ===
FROM alpine:latest AS builder

ENV OCSERV_VERSION=1.3.0

RUN apk add --no-cache \
    build-base \
    gnutls-dev \
    libev-dev \
    nettle-dev \
    readline-dev \
    libseccomp-dev \
    gettext-dev \
    intltool \
    autoconf \
    automake \
    libtool \
    pkgconfig \
    curl

WORKDIR /tmp

RUN curl -LO https://www.infradead.org/ocserv/download/ocserv-${OCSERV_VERSION}.tar.xz && \
    tar -xf ocserv-${OCSERV_VERSION}.tar.xz && \
    cd ocserv-${OCSERV_VERSION} && \
    ./configure --prefix=/usr --sysconfdir=/etc && \
    make -j$(nproc) && \
    make DESTDIR=/tmp/build-output install

# === Stage 2: Final runtime image ===
FROM alpine:latest

LABEL maintainer="Yaroslav Minaev <mail@minaev.pro>"

# Runtime deps:
# - gnutls-utils: certtool (self-signed on first run)
# - iptables(+legacy) & iproute2: NAT rules and route detection
# - gettext: envsubst for templating configs
# - curl/openssl/ca-certificates/tzdata/socat: acme.sh + TLS + logs
# - shadow (useradd)
RUN apk add --no-cache \
    gnutls-utils \
    libev \
    libseccomp \
    iptables \
    iptables-legacy \
    iproute2 \
    gettext \
    curl \
    openssl \
    socat \
    ca-certificates \
    tzdata \
    shadow \
 && update-ca-certificates

# Install acme.sh (no cron, no profile)
RUN set -eux; \
    ACME_INSTALL=/usr/local/share; \
    ACME_CONFIG=/etc/acme; \
    mkdir -p "$ACME_INSTALL" "$ACME_CONFIG"; \
    curl -fsSLo /tmp/acme.sh https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh; \
    chmod +x /tmp/acme.sh; \
    cd /tmp; \
    ./acme.sh --install --home "$ACME_INSTALL" --config-home "$ACME_CONFIG" --nocron --noprofile; \
    ln -sf "$ACME_INSTALL/acme.sh" /usr/local/bin/acme.sh;
    
# Create runtime directories and user
RUN useradd -u 1000 -s /bin/false vpnuser && \
    mkdir -p /etc/ocserv/cert && \
    mkdir -p /etc/ocserv/auth

# Copy ocserv from builder
COPY --from=builder /tmp/build-output /

# Copy project files
COPY templates /etc/ocserv/templates
COPY scripts /scripts
RUN chmod +x /scripts/start.sh

CMD ["sh", "/scripts/start.sh"]

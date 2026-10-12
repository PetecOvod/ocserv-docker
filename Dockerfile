# === Stage 1: Build ocserv from source ===
FROM alpine:latest AS builder

ENV OCSERV_VERSION=1.3.0
ARG OCSERV_SHA256=5c562c3ea1032065ef43d6075e5722f94ce6a7a780d6a2b4c6d54c1ce3921965

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

RUN curl -fLO https://www.infradead.org/ocserv/download/ocserv-${OCSERV_VERSION}.tar.xz && \
    echo "${OCSERV_SHA256}  ocserv-${OCSERV_VERSION}.tar.xz" | sha256sum -c - && \
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
    curl -fsSLo /tmp/acme.sh "https://raw.githubusercontent.com/acmesh-official/acme.sh/${ACME_VERSION}/acme.sh"; \
    echo "${ACME_SHA256}  /tmp/acme.sh" | sha256sum -c -; \
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
RUN chmod +x /scripts/start.sh /scripts/ocs \
 && ln -sf /scripts/ocs /usr/local/bin/ocs

CMD ["sh", "/scripts/start.sh"]

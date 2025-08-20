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

RUN apk add --no-cache \
    gnutls-utils \
    libev \
    libseccomp \
    certbot \
    shadow \
    bash \
    iptables \
    envsubst

# Create runtime directories and user
RUN useradd -u 1000 -s /bin/false vpnuser && \
    mkdir -p /etc/ocserv/cert

# Copy ocserv from builder
COPY --from=builder /tmp/build-output /

# Copy project files
COPY config/ocserv.conf /etc/ocserv/ocserv.conf
COPY templates /etc/ocserv/templates
COPY scripts /scripts
RUN chmod +x /scripts/start.sh

CMD ["sh", "/scripts/start.sh"]

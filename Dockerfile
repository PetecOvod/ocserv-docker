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
    make install

# === Stage 2: Final runtime image ===
FROM alpine:latest

LABEL maintainer="you@example.com"

RUN apk add --no-cache \
    gnutls-utils \
    certbot \
    shadow \
    bash \
    curl \
    iproute2 \
    iptables \
    envsubst

# Create runtime directories and user
RUN useradd -u 1000 -s /bin/false vpnuser && \
    mkdir -p /etc/ocserv/templates && \
    mkdir -p /etc/ocserv/cert

# Copy ocserv from builder
COPY --from=builder /usr /usr
COPY --from=builder /etc /etc

# Copy project files
COPY config/ocserv.conf /etc/ocserv/ocserv.conf
COPY auth/passwd /etc/ocserv/auth/passwd
COPY templates /etc/ocserv/templates
COPY scripts/start.sh /start.sh
RUN chmod +x /start.sh

CMD ["sh", "/start.sh"]
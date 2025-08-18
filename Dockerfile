FROM alpine:latest

LABEL maintainer="you@example.com"

ENV OCSERV_VERSION=1.3.0 \
    DEBIAN_FRONTEND=noninteractive

RUN apk add --no-cache \
    build-base \
    libev-dev \
    gnutls-dev \
    nettle-dev \
    gmp-dev \
    linux-headers \
    libnl3-dev \
    libseccomp-dev \
    gettext-dev \
    intltool \
    autoconf \
    automake \
    libtool \
    pkgconfig \
    curl \
    git \
    iproute2 \
    iptables \
    libxml2-dev \
    libnl3 \
    gnutls-utils \
    shadow \
    bash \
    certbot \
    envsubst \
    readline-dev

RUN cd /tmp && \
    curl -LO https://www.infradead.org/ocserv/download/ocserv-${OCSERV_VERSION}.tar.xz && \
    tar -xf ocserv-${OCSERV_VERSION}.tar.xz && \
    cd ocserv-${OCSERV_VERSION} && \
    ./configure --prefix=/usr --sysconfdir=/etc && \
    make -j$(nproc) && \
    make install && \
    cd / && rm -rf /tmp/*

RUN useradd -u 1000 -s /bin/false vpnuser

COPY config/ocserv.conf /etc/ocserv/ocserv.conf
COPY config/passwd /etc/ocserv/passwd
COPY templates /etc/ocserv/
COPY scripts/start.sh /start.sh
RUN chmod +x /start.sh

CMD ["sh", "/start.sh"]

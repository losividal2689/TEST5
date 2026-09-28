# syntax=docker/dockerfile:1
# ==============================================================================
# BERMUDA Stealth Gateway NG — Production Multi-Stage Dockerfile
# ZERO-APK ARCHITECTURE (100% Immune to Alpine repository downtime)
# ==============================================================================

ARG GO_VERSION=1.24
ARG ALPINE_VERSION=3.21

# ------------------------------------------------------------------------------
# Stage 1 — Go Gateway Builder & Direct Xray Fetcher (Zero APK Dependency)
# ------------------------------------------------------------------------------
FROM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS builder

WORKDIR /src

# 1. Copy source files
COPY go.mod ./
COPY *.go ./

# 2. Compile static gateway binary with AVX2 vector acceleration
RUN set -eux; \
    export GOAMD64=v3; \
    CGO_ENABLED=0 GOOS=linux go build \
        -trimpath \
        -tags netgo,osusergo \
        -ldflags="-s -w -buildid=" \
        -o /out/bermuda-gateway .; \
    chmod 0555 /out/bermuda-gateway

# 3. Download official Xray-core directly using built-in wget and unzip
# (Zero apk repository calls — completely immune to dl-cdn.alpinelinux.org issues)
RUN set -eux; \
    mkdir -p /out/bin /out/assets /tmp/xray; \
    echo "Downloading official Xray-core v26.9.9 from GitHub..."; \
    wget -q -O /tmp/xray/xray.zip \
        "https://github.com/XTLS/Xray-core/releases/download/v26.9.9/Xray-linux-64.zip"; \
    unzip -q /tmp/xray/xray.zip xray -d /out/bin; \
    unzip -q /tmp/xray/xray.zip geoip.dat geosite.dat -d /out/assets; \
    chmod 0555 /out/bin/xray; \
    chmod 0444 /out/assets/*.dat; \
    rm -rf /tmp/xray

# ------------------------------------------------------------------------------
# Stage 2 — Hardened Rootless Runtime (Zero APK Dependency)
# ------------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION}

LABEL org.opencontainers.image.title="BERMUDA Stealth Gateway NG" \
      org.opencontainers.image.description="Railway VLESS XHTTP/WS & Trojan Stealth Gateway with Supervised Xray-core" \
      org.opencontainers.image.version="2.0-production" \
      org.opencontainers.image.licenses="MIT"

# 1. Setup unprivileged user using built-in busybox utilities (no apk needed)
RUN set -eux; \
    addgroup -g 10001 -S bermuda; \
    adduser -u 10001 -S -D -H -G bermuda -h /app -s /sbin/nologin bermuda; \
    mkdir -p /app /usr/local/share/xray /usr/local/bin /etc/ssl/certs; \
    chown -R bermuda:bermuda /app /usr/local/share/xray; \
    chmod 1777 /tmp

# 2. Copy artifacts and SSL certificates directly from builder stage
COPY --from=builder --chown=bermuda:bermuda /out/bermuda-gateway /usr/local/bin/bermuda-gateway
COPY --from=builder --chown=bermuda:bermuda /out/bin/xray /usr/local/bin/xray
COPY --from=builder --chown=bermuda:bermuda /out/assets/geoip.dat /usr/local/share/xray/geoip.dat
COPY --from=builder --chown=bermuda:bermuda /out/assets/geosite.dat /usr/local/share/xray/geosite.dat
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --chown=bermuda:bermuda config.json /app/config.json

# 3. Apply immutable file permissions
RUN set -eux; \
    chmod 0555 /usr/local/bin/bermuda-gateway /usr/local/bin/xray; \
    chmod 0444 /app/config.json /usr/local/share/xray/geoip.dat /usr/local/share/xray/geosite.dat /etc/ssl/certs/ca-certificates.crt; \
    test -s /usr/local/bin/bermuda-gateway; \
    test -s /usr/local/bin/xray; \
    test -s /app/config.json; \
    test -s /usr/local/share/xray/geoip.dat; \
    test -s /usr/local/share/xray/geosite.dat

ENV XRAY_LOCATION_ASSET=/usr/local/share/xray \
    BERMUDA_XRAY_BIN=/usr/local/bin/xray \
    BERMUDA_XRAY_CONFIG=/app/config.json \
    BERMUDA_BACKEND_XH=127.0.0.1:18443 \
    BERMUDA_BACKEND_WS=127.0.0.1:18444 \
    BERMUDA_BACKEND_TR=127.0.0.1:18445 \
    BERMUDA_PATH_XH=/bermuda-xhttp \
    BERMUDA_PATH_WS=/bermuda-ws \
    BERMUDA_PATH_TR=/bermuda-tr \
    GODEBUG=madvdontneed=1 \
    GOGC=100 \
    GOMEMLIMIT=640MiB \
    TZ=UTC \
    PORT=8080

USER bermuda:bermuda
WORKDIR /app

EXPOSE 8080
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD wget -q -T 3 -O /dev/null "http://127.0.0.1:${PORT:-8080}/healthz" || exit 1

CMD ["/usr/local/bin/bermuda-gateway"]

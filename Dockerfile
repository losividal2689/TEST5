# syntax=docker/dockerfile:1
# ==============================================================================
# BERMUDA Stealth Gateway NG — Bulletproof Zero-APK Production Dockerfile
#
# Eliminates all external apk repository dependencies (immune to dl-cdn timeouts).
# Uses Go toolchain image with pre-installed SSL certs and native utilities.
# ==============================================================================

ARG GO_VERSION=1.24
ARG ALPINE_VERSION=3.21
ARG XRAY_VERSION=v26.9.9

# ------------------------------------------------------------------------------
# Stage 1 — Unified Builder & Xray Downloader (Pre-installed SSL, Zero-APK)
# ------------------------------------------------------------------------------
FROM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS builder

ARG TARGETARCH=amd64
ARG XRAY_VERSION=v26.9.9

WORKDIR /src

# 1. Copy Go module and source files
COPY go.mod ./
COPY *.go ./

# 2. Compile static gateway binary with AVX2 vector acceleration
RUN set -eux; \
    mkdir -p /out/bin /out/assets; \
    case "${TARGETARCH}" in \
        amd64) GO_ARCH_FLAGS="GOAMD64=v3" ;; \
        arm64) GO_ARCH_FLAGS="GOARM64=v8.0" ;; \
        *) GO_ARCH_FLAGS="" ;; \
    esac; \
    export ${GO_ARCH_FLAGS}; \
    CGO_ENABLED=0 GOOS=linux go build \
        -trimpath \
        -tags netgo,osusergo \
        -ldflags="-s -w -buildid=" \
        -o /out/bin/bermuda-gateway .; \
    chmod 0555 /out/bin/bermuda-gateway

# 3. Download and verify official Xray release using built-in wget and unzip
# (Zero apk repository calls — completely immune to dl-cdn.alpinelinux.org issues)
RUN set -eux; \
    case "${XRAY_VERSION}:${TARGETARCH}" in \
        v26.9.9:amd64) \
            XRAY_ARCH="64"; \
            XRAY_SHA256="1eb9175d0f0a8f8149c9230a7fc5ae66ce332ed20a53155ce61fe62e3f58b7df" \
            ;; \
        v26.9.9:arm64) \
            XRAY_ARCH="arm64-v8a"; \
            XRAY_SHA256="3e38d72dfc5eb65c91df0e5583e9b6676c32232041da47de6ae73946b526d66c" \
            ;; \
        *) \
            case "${TARGETARCH}" in \
                amd64) XRAY_ARCH="64" ;; \
                arm64) XRAY_ARCH="arm64-v8a" ;; \
                *) echo "Unsupported target architecture: ${TARGETARCH}" >&2; exit 1 ;; \
            esac; \
            XRAY_SHA256="" \
            ;; \
    esac; \
    archive="Xray-linux-${XRAY_ARCH}.zip"; \
    mkdir -p /tmp/xray; \
    wget -q -O "/tmp/xray/${archive}" \
        "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${archive}"; \
    if [ -n "${XRAY_SHA256}" ]; then \
        printf '%s  %s\n' "${XRAY_SHA256}" "/tmp/xray/${archive}" | sha256sum -c -; \
    fi; \
    unzip -q "/tmp/xray/${archive}" xray geoip.dat geosite.dat -d /tmp/xray/ext; \
    mv /tmp/xray/ext/xray /out/bin/xray; \
    mv /tmp/xray/ext/geoip.dat /out/assets/geoip.dat; \
    mv /tmp/xray/ext/geosite.dat /out/assets/geosite.dat; \
    chmod 0555 /out/bin/xray; \
    chmod 0444 /out/assets/*.dat; \
    rm -rf /tmp/xray

# ------------------------------------------------------------------------------
# Stage 2 — Minimal Hardened Rootless Runtime (Zero-APK)
# ------------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS runtime

LABEL org.opencontainers.image.title="BERMUDA Stealth Gateway NG" \
      org.opencontainers.image.description="Railway VLESS XHTTP/WS & Trojan Stealth Gateway with Supervised Xray-core" \
      org.opencontainers.image.version="2.0-production"

# Setup unprivileged user (UID 10001) using built-in busybox utilities (no apk needed)
RUN set -eux; \
    addgroup -S -g 10001 bermuda; \
    adduser -u 10001 -S -D -H -G bermuda -h /app -s /sbin/nologin bermuda; \
    mkdir -p /app /tmp /usr/local/share/xray /usr/local/bin /etc/ssl/certs; \
    chown -R bermuda:bermuda /app /usr/local/share/xray; \
    chmod 1777 /tmp

# Copy artifacts from builder stage (including verified SSL CA root certs)
COPY --from=builder --chown=bermuda:bermuda /out/bin/bermuda-gateway /usr/local/bin/bermuda-gateway
COPY --from=builder --chown=bermuda:bermuda /out/bin/xray /usr/local/bin/xray
COPY --from=builder --chown=bermuda:bermuda /out/assets/geoip.dat /usr/local/share/xray/geoip.dat
COPY --from=builder --chown=bermuda:bermuda /out/assets/geosite.dat /usr/local/share/xray/geosite.dat
COPY --from=builder --chown=0:0 /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --chown=bermuda:bermuda config.json /app/config.json

# Apply immutable permissions
RUN set -eux; \
    chmod 0555 /usr/local/bin/bermuda-gateway /usr/local/bin/xray; \
    chmod 0444 /app/config.json /usr/local/share/xray/geoip.dat /usr/local/share/xray/geosite.dat /etc/ssl/certs/ca-certificates.crt; \
    test -s /usr/local/bin/bermuda-gateway; \
    test -s /usr/local/bin/xray; \
    test -s /app/config.json; \
    test -s /usr/local/share/xray/geoip.dat; \
    test -s /usr/local/share/xray/geosite.dat; \
    test -s /etc/ssl/certs/ca-certificates.crt

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

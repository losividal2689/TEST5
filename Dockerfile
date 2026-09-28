# syntax=docker/dockerfile:1
# ============================================================================
# BERMUDA Stealth Gateway NG — Production Hardened Multi-Stage Dockerfile
#
# Stage 1 (builder) : Go static compilation (AVX2) + Xray fetcher (Sequential)
# Stage 2 (runtime) : Minimal Alpine 3.21 rootless runtime (UID 10001)
# ============================================================================

ARG GO_VERSION=1.24
ARG ALPINE_VERSION=3.21
ARG XRAY_VERSION=v26.9.9

# ---------------------------------------------------------------------------
# Stage 1 — Unified Static Builder & Verified Xray Fetcher
# ---------------------------------------------------------------------------
FROM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS builder

ARG TARGETARCH=amd64
ARG XRAY_VERSION=v26.9.9

WORKDIR /src

# 1. Copy Go sources and build stripped binary with AVX2 vector optimization
COPY go.mod ./
COPY *.go ./

RUN set -eux; \
    mkdir -p /out/bin /out/assets; \
    case "${TARGETARCH}" in \
        amd64) export GOAMD64=v3 ;; \
        arm64) export GOARM64=v8.0 ;; \
        *) export GOAMD64="" ;; \
    esac; \
    export GOOS=linux GOARCH="${TARGETARCH}" CGO_ENABLED=0; \
    go build \
        -trimpath \
        -tags netgo,osusergo \
        -ldflags="-s -w -buildid=" \
        -o /out/bin/bermuda-gateway \
        .; \
    chmod 0555 /out/bin/bermuda-gateway

# 2. Download and verify official Xray-core binary and geo assets sequentially
RUN set -eux; \
    apk add --no-cache ca-certificates curl unzip; \
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
    curl -fsSL --retry 5 --retry-delay 2 \
        -o "/tmp/xray/${archive}" \
        "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${archive}"; \
    if [ -n "${XRAY_SHA256}" ]; then \
        printf '%s  %s\n' "${XRAY_SHA256}" "/tmp/xray/${archive}" | sha256sum -c -; \
    fi; \
    unzip -q "/tmp/xray/${archive}" xray geoip.dat geosite.dat -d /tmp/xray/ext; \
    mv /tmp/xray/ext/xray /out/bin/xray; \
    mv /tmp/xray/ext/geoip.dat /out/assets/geoip.dat; \
    mv /tmp/xray/ext/geosite.dat /out/assets/geosite.dat; \
    cp /etc/ssl/certs/ca-certificates.crt /out/ca-certificates.crt; \
    chmod 0555 /out/bin/xray; \
    chmod 0444 /out/assets/*.dat /out/ca-certificates.crt; \
    rm -rf /tmp/xray

# ---------------------------------------------------------------------------
# Stage 2 — Minimal Hardened Rootless Runtime
# ---------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS runtime

LABEL org.opencontainers.image.title="BERMUDA Stealth Gateway NG" \
      org.opencontainers.image.description="Rootless Go 1.24 L7 gateway with supervised Xray-core" \
      org.opencontainers.image.version="2.0-production"

RUN set -eux; \
    addgroup -S -g 10001 bermuda; \
    adduser -S -D -H -u 10001 -G bermuda -s /sbin/nologin bermuda; \
    mkdir -p /app /tmp /usr/local/bin /usr/local/share/xray /etc/ssl/certs; \
    chown 0:0 /app /usr/local/bin /usr/local/share/xray /etc/ssl/certs; \
    chmod 0555 /app /usr/local/bin /usr/local/share/xray; \
    chmod 1777 /tmp

COPY --from=builder --chown=0:0 /out/bin/bermuda-gateway /usr/local/bin/bermuda-gateway
COPY --from=builder --chown=0:0 /out/bin/xray /usr/local/bin/xray
COPY --from=builder --chown=0:0 /out/assets/geoip.dat /usr/local/share/xray/geoip.dat
COPY --from=builder --chown=0:0 /out/assets/geosite.dat /usr/local/share/xray/geosite.dat
COPY --from=builder --chown=0:0 /out/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

RUN set -eux; \
    test -s /usr/local/bin/bermuda-gateway; \
    test -s /usr/local/bin/xray; \
    test -s /usr/local/share/xray/geoip.dat; \
    test -s /usr/local/share/xray/geosite.dat; \
    test -s /etc/ssl/certs/ca-certificates.crt

ENV XRAY_LOCATION_ASSET=/usr/local/share/xray \
    BERMUDA_XRAY_BIN=/usr/local/bin/xray \
    BERMUDA_XRAY_CONFIG=/run/secrets/bermuda-xray-config.json \
    BERMUDA_BACKEND_XH=127.0.0.1:18443 \
    BERMUDA_BACKEND_WS=127.0.0.1:18444 \
    BERMUDA_BACKEND_TR=127.0.0.1:18445 \
    BERMUDA_PATH_XH=/bermuda-xhttp \
    BERMUDA_PATH_WS=/bermuda-ws \
    BERMUDA_PATH_TR=/bermuda-tr \
    BERMUDA_GOMAXPROCS=2 \
    GOMEMLIMIT=640MiB \
    GODEBUG=madvdontneed=1 \
    GOGC=100 \
    TZ=UTC \
    PORT=8080 \
    HOME=/nonexistent \
    TMPDIR=/tmp

USER bermuda:bermuda
WORKDIR /app

EXPOSE 8080
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD wget -q -T 3 -O /dev/null "http://127.0.0.1:${PORT:-8080}/healthz" || exit 1

CMD ["/usr/local/bin/bermuda-gateway"]

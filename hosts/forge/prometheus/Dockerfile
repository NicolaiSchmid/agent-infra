# cli-proxy-api + pinned plugins. Plugins are trusted in-process code (they
# see every credential), so each one is pinned by version + sha256 and was
# source-reviewed before bumping.
ARG CLI_PROXY_VERSION=v8.0.45

FROM debian:bookworm-slim AS plugins
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip && rm -rf /var/lib/apt/lists/*
# Fwindy/cpa-usage-statistics: persists per-request usage to SQLite and adds
# /v0/management/plugins/usage-statistics/* (management-key gated).
ARG USAGE_STATS_VERSION=0.2.0
ARG USAGE_STATS_SHA256_arm64=b9b6ae5301da6d69e588a97af2241fa6fd46e885f51623f068e88e9673790c0e
ARG USAGE_STATS_SHA256_amd64=9bfe130380db8c80257a700b2cffea826ba662da933ce3eedf22c97ab12a500a
RUN set -eu; \
    case "$TARGETARCH" in arm64) sha="$USAGE_STATS_SHA256_arm64" ;; amd64) sha="$USAGE_STATS_SHA256_amd64" ;; *) exit 1 ;; esac; \
    zip="usage-statistics_${USAGE_STATS_VERSION}_linux_${TARGETARCH}.zip"; \
    curl -fsSLo "/tmp/$zip" "https://github.com/Fwindy/cpa-usage-statistics/releases/download/v${USAGE_STATS_VERSION}/$zip"; \
    echo "$sha  /tmp/$zip" | sha256sum -c -; \
    mkdir -p "/plugins/linux/$TARGETARCH"; \
    unzip -j "/tmp/$zip" usage-statistics.so -d "/plugins/linux/$TARGETARCH"

# Fwindy/Cli-Proxy-API-Management-Center: upstream panel + usage/cost pages for
# the usage-statistics plugin. Reviewed release pinned here; auto-update is off
# in config.yaml because the fork auto-publishes upstream merges every 6 h.
# Only extra outbound fetch: models.dev, on "sync prices" click.
ARG PANEL_RELEASE=v20261028-build1
ARG PANEL_SHA256=d8c1e6496084d438e1fea0fdaba37a4f3cc13e1a810917ce41aedc1856305674
RUN set -eu; mkdir -p /static; \
    curl -fsSLo /static/management.html "https://github.com/Fwindy/Cli-Proxy-API-Management-Center/releases/download/${PANEL_RELEASE}/management.html"; \
    echo "$PANEL_SHA256  /static/management.html" | sha256sum -c -

FROM eceasy/cli-proxy-api:${CLI_PROXY_VERSION}
COPY --from=plugins /plugins /CLIProxyAPI/plugins
COPY --from=plugins /static/management.html /CLIProxyAPI/static/management.html

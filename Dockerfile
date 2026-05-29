# Self-contained image for the poller half of the worker. Builds claude-worker
# from source, bundles Anthropic's pinned `ant` CLI + spawn.sh. Needs NO KVM and
# no privileges: it polls Anthropic and calls the OmniRun API (OMNIRUN_API) over
# HTTP. The microVMs boot on whatever OmniRun endpoint that points at.
#
#   docker build -t omnirun-claude-worker .
#   docker run -d \
#     -e ANTHROPIC_ENVIRONMENT_KEY=... -e ANTHROPIC_ENVIRONMENT_ID=env_... \
#     -e OMNIRUN_API=https://api.omnirun.io -e OMNIRUN_API_KEY=omr_... \
#     omnirun-claude-worker

FROM golang:1.26-bookworm AS build
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -o /out/claude-worker ./cmd/claude-worker

FROM debian:stable-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq \
 && rm -rf /var/lib/apt/lists/*

# Pinned official Anthropic `ant` CLI, verified by checksum.
ARG ANT_VERSION=1.10.0
ARG ANT_SHA256=6d8145901edc81276d5ca803ea823ddcf18452b0449354283b91fe448984b215
RUN curl -fsSL "https://github.com/anthropics/anthropic-cli/releases/download/v${ANT_VERSION}/ant_${ANT_VERSION}_linux_amd64.tar.gz" -o /tmp/ant.tar.gz \
 && echo "${ANT_SHA256}  /tmp/ant.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/ant.tar.gz -C /usr/local/bin ant \
 && rm /tmp/ant.tar.gz

COPY --from=build /out/claude-worker /usr/local/bin/claude-worker
COPY scripts/spawn.sh /opt/omnirun/scripts/spawn.sh
RUN chmod +x /opt/omnirun/scripts/spawn.sh

# Required env at runtime: ANTHROPIC_ENVIRONMENT_KEY, ANTHROPIC_ENVIRONMENT_ID,
# OMNIRUN_API, OMNIRUN_API_KEY. Never set ANTHROPIC_API_KEY (the worker refuses).
ENTRYPOINT ["/usr/local/bin/claude-worker", "-spawn", "/opt/omnirun/scripts/spawn.sh"]

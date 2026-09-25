# Build Docker. ONE image, THREE entrypoints: /bin/procgen (the game server
# and legacy prompt policy), /bin/procgen-player (the seat policy), and
# /bin/procgen-numeric-bridge (the headless training adapter). The policy set is
# env-switched inside this same image.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/procgen
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# Mummy's shutdown crashes in ORC cycle cleanup under amd64 certification.
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on --mm:arc"
RUN nim c \
  $NimFlags \
  --nimcache:/tmp/procgen-nimcache \
  --out:procgen \
  src/procgen.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/procgen-player-nimcache \
  --out:procgen-player \
  src/procgen_player.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/procgen-numeric-bridge-nimcache \
  --out:procgen-numeric-bridge \
  src/procgen/numeric_bridge.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/procgen
COPY --from=build /workspace/procgen/procgen /bin/procgen
COPY --from=build /workspace/procgen/procgen-player /bin/procgen-player
COPY --from=build /workspace/procgen/procgen-numeric-bridge /bin/procgen-numeric-bridge
COPY --from=build /workspace/procgen/*.json ./
COPY --from=build /workspace/procgen/data ./data
COPY --from=build /workspace/procgen/client ./client

CMD ["/bin/procgen"]

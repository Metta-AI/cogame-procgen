# Build Docker. ONE image, TWO entrypoints: /bin/procgen (the game server,
# which also makes every LLM call, because the game pod is the only container
# the platform injects the anthropic_api_key coworld secret into) and
# /bin/procgen-player (the thin procgen seat registrar). The policy set is
# env-switched inside this same image (PLAYER_PROMPT vs PLAYER_SCRIPTED), which
# is what keeps a champion and a scripted filler byte-identical apart from
# their environment.
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
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c \
  $NimFlags \
  --nimcache:/tmp/procgen-nimcache \
  --out:procgen \
  src/procgen.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/procgen-player-nimcache \
  --out:procgen-player \
  src/procgen_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/procgen
COPY --from=build /workspace/procgen/procgen /bin/procgen
COPY --from=build /workspace/procgen/procgen-player /bin/procgen-player
COPY --from=build /workspace/procgen/*.json ./
COPY --from=build /workspace/procgen/data ./data
COPY --from=build /workspace/procgen/client ./client

CMD ["/bin/procgen"]

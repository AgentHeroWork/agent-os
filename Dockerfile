# Stage 1: Build the Elixir release
FROM elixir:1.17-otp-27-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    make \
    gcc \
    libc6-dev \
  && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Copy source tree
COPY src/ src/

# Fetch deps, compile, and build release from the root app
WORKDIR /app/src/agent_os
RUN mix deps.get --only prod
RUN mix compile
RUN mix release agent_os

# Stage 2: Minimal runtime image
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 \
    openssl \
    tectonic \
    git \
    ca-certificates \
    curl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the built release from the builder stage
COPY --from=builder /app/src/agent_os/_build/prod/rel/agent_os/ ./

# Create Mnesia persistence directory
RUN mkdir -p /data/mnesia

ENV AGENT_OS_PORT=4000
ENV RELEASE_NODE=agent_os@127.0.0.1
ENV RELEASE_DISTRIBUTION=sname
ENV MNESIA_DIR=/data/mnesia

EXPOSE 4000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:4000/api/v1/health || exit 1

CMD ["bin/agent_os", "start"]

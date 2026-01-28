# Build stage - Elixir 1.19.5 with Erlang 28
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.3.1
ARG ALPINE_VERSION=3.23.3

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-alpine-${ALPINE_VERSION}"
ARG RUNNER_IMAGE="alpine:${ALPINE_VERSION}"

FROM ${BUILDER_IMAGE} AS build

# Install build dependencies
RUN apk add --no-cache build-base git curl

# Set build environment
ENV MIX_ENV=prod

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Create app directory
WORKDIR /app

# Copy config and dependency files
COPY mix.exs mix.lock ./
COPY config config

# Install dependencies
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy application code
COPY lib lib
COPY priv priv
COPY assets assets
COPY rel rel
COPY test test

# Compile application first (generates colocated hooks for assets)
RUN mix compile

# Run tests - build fails if tests fail (prevents broken code in production)
RUN MIX_ENV=test mix deps.get && MIX_ENV=test mix test

# Then compile assets
RUN mix assets.deploy

# Build release
RUN mix release

# Runtime stage
FROM ${RUNNER_IMAGE} AS runtime

# Install runtime dependencies
RUN apk add --no-cache libstdc++ openssl ncurses-libs curl

# Create app user
RUN adduser -D -h /home/app app
USER app
WORKDIR /home/app

# Copy release from build stage
COPY --from=build --chown=app:app /app/_build/prod/rel/app ./

# Set runtime environment
ENV HOME=/home/app
ENV MIX_ENV=prod
ENV PHX_SERVER=true

# Koyeb uses port 8000 by default
ENV PORT=8000
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:${PORT}/health || exit 1

# Start the application (runs migrations then starts server)
CMD ["bin/server"]

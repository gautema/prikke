# Build stage - Elixir 1.17 with Erlang 26 (stable for cross-compilation)
ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=26.2.5.6
ARG ALPINE_VERSION=3.20.3

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-alpine-${ALPINE_VERSION}"
ARG RUNNER_IMAGE="alpine:${ALPINE_VERSION}"

FROM ${BUILDER_IMAGE} AS build

# Install build dependencies
RUN apk add --no-cache build-base git curl

# Set build environment - TERM=dumb prevents TTY issues in cross-compilation
ENV MIX_ENV=prod
ENV TERM=dumb
ENV ERL_FLAGS="+B -noinput"

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

# Compile application first (generates colocated hooks for assets)
RUN mix compile

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

# Default port (can be overridden by environment)
ENV PORT=4000
EXPOSE 4000

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:${PORT}/health || exit 1

# Start the application (runs migrations then starts server)
CMD ["bin/server"]

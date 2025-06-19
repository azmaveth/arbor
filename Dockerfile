# Arbor - Distributed AI Agent Orchestration System
# Multi-stage Docker build for production deployment

# Build stage
FROM hexpm/elixir:1.15.7-erlang-26.1.2-alpine-3.18.4 AS builder

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    git \
    curl

# Set build environment
ENV MIX_ENV=prod
ENV MIX_HOME=/opt/mix
ENV HEX_HOME=/opt/hex

# Create build directory
WORKDIR /app

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency files
COPY mix.exs mix.lock ./
COPY apps/*/mix.exs apps/*/
COPY config/config.exs config/prod.exs config/

# Install and compile dependencies
RUN mix deps.get --only=prod && \
    mix deps.compile

# Copy application source
COPY . .

# Build release
RUN mix compile && \
    mix release

# Runtime stage
FROM alpine:3.18.4 AS runtime

# Install runtime dependencies
RUN apk add --no-cache \
    openssl \
    ncurses-libs \
    libstdc++ \
    curl \
    ca-certificates

# Create runtime user
RUN addgroup -g 1001 -S arbor && \
    adduser -S -D -H -u 1001 -h /app -s /sbin/nologin -G arbor -g arbor arbor

# Set runtime environment
ENV MIX_ENV=prod
ENV PORT=4000
ENV BEAM_PORT=9001
ENV ERL_EPMD_PORT=4369

# Create application directory
WORKDIR /app

# Copy release from builder stage
COPY --from=builder --chown=arbor:arbor /app/_build/prod/rel/arbor ./

# Create required directories
RUN mkdir -p /app/tmp /app/log && \
    chown -R arbor:arbor /app

# Health check script
COPY --from=builder --chown=arbor:arbor /app/scripts/health_check.sh ./bin/
RUN chmod +x ./bin/health_check.sh

# Switch to runtime user
USER arbor

# Expose ports
EXPOSE $PORT $BEAM_PORT $ERL_EPMD_PORT

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ["./bin/health_check.sh"]

# Default command
CMD ["./bin/arbor", "start"]

# Production stage with development tools (for debugging)
FROM runtime AS debug

USER root

# Install debugging tools
RUN apk add --no-cache \
    htop \
    strace \
    lsof \
    tcpdump \
    procps

# Switch back to runtime user
USER arbor

# Labels for metadata
LABEL maintainer="azmaveth" \
      version="1.0.0" \
      description="Arbor - Distributed AI Agent Orchestration System" \
      org.opencontainers.image.title="Arbor" \
      org.opencontainers.image.description="Distributed AI Agent Orchestration System built with Elixir/OTP" \
      org.opencontainers.image.vendor="Arbor Project" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.schema-version="1.0"
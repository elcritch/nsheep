# Build stage
FROM nimlang/nim:2.2.0-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git openssl-dev pcre-dev perl

# Copy project files (.dockerignore excludes local artifacts)
COPY . .

# Install dependencies
RUN nimble install slim -y
RUN slim install -y --depsOnly

# Build binaries
RUN slim build -d:release -d:strip --path:src

# Build frontend (slim frontend task installs karax and copies assets)
RUN slim frontend

# Runtime stage
FROM alpine:latest

WORKDIR /app

# Install runtime dependencies
RUN apk add --no-cache openssl pcre libgcc libstdc++ git docker-cli

# Copy binaries
COPY --from=builder /app/nsheep .
COPY --from=builder /app/nsheep-fetcher .

# Copy static files
COPY --from=builder /app/public ./public

# Copy default config
COPY --from=builder /app/cfg.example.yaml ./cfg.yaml

# Create data directories
RUN mkdir -p /app/data/tarballs

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

# Default command
CMD ["./nsheep", "/app/cfg.yaml"]

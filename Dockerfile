# Build stage
FROM nimlang/nim:2.0.0-alpine AS builder

WORKDIR /app

# Install dependencies
RUN apk add --no-cache git openssl-dev pcre-dev

# Copy project files
COPY nsheep.nimble .
COPY cfg.example.yaml .
COPY src/ ./src/

# Install dependencies and build
RUN nimble install -y --depsOnly
RUN nim c -d:release -o:nsheep src/nsheep.nim
RUN nim c -d:release -o:nsheep-fetcher src/nsheep_fetcher.nim

# Runtime stage
FROM alpine:latest

WORKDIR /app

# Install runtime dependencies
RUN apk add --no-cache openssl pcre libgcc git docker-cli

# Copy binaries
COPY --from=builder /app/nsheep .
COPY --from=builder /app/nsheep-fetcher .

# Create data directories
RUN mkdir -p /app/data/tarballs

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

# Default command (can be overridden)
CMD ["./nsheep", "/app/cfg.yaml"]

# Build stage
FROM nimlang/nim:2.2.0-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git openssl-dev pcre-dev nodejs npm

# Copy project files (.dockerignore excludes local artifacts like nimble.paths, binaries, data/)
COPY . .

# Install dependencies (generates nimble.paths inside the container)
RUN nimble install -y --depsOnly

# Build binaries
RUN nimble build -d:release -d:strip --path:src

# Build frontend
RUN nim js -d:release -o:public/app.js frontend/app.nim
RUN cp frontend/index.html public/ && cp frontend/app.css public/

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

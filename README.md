# NSheep

A centralized Nim package registry with strict engineering standards.

## Architecture

```
src/
├── nsheep.nim           # Entry point
└── nsheep/
    ├── types.nim        # Domain types with invariants
    ├── config.nim       # Strict configuration loading
    ├── storage.nim      # Local filesystem storage
    ├── github.nim       # GitHub API client with ETag caching
    ├── ingest.nim       # Package ingestion logic
    ├── fetcher.nim      # Background fetcher from nimble packages
    └── server.nim       # HTTP server (mummy)
```

### Architecture

NSheep consists of two separate binaries:

1. **`nsheep`** - HTTP server that serves package metadata and tarballs
2. **`nsheep-fetcher`** - Background process that ingests packages from nimble registry

They communicate through the shared storage directory (local filesystem or Cloudflare R2).

### Background Fetcher

The fetcher:
1. Fetches the official [nimble packages.json](https://github.com/nim-lang/packages) periodically
2. Validates packages by compiling them in Docker
3. Ingests all GitHub-hosted packages
4. Runs on a configurable interval (default: 1 hour)
5. Is resilient to individual package failures

The HTTP server is read-only - it only serves package data.


## Building

```bash
nimble build          # Debug build
nimble release        # Release build
```

## Running

```bash
# 1. Create config
cp cfg.example.yaml cfg.yaml
# Edit cfg.yaml

# 2. Run the server (serves packages)
./nsheep cfg.yaml

# 3. In another terminal, run the fetcher (ingests packages)
./nsheep-fetcher cfg.yaml
```

Or use Docker Compose to run both:

## Configuration

```yaml
server:
  bindAddr: "127.0.0.1"
  port: 8080

github:
  token: ""  # Optional: GitHub API token for higher rate limits

local:
  tarballDir: "./data/tarballs"
  metadataDir: "./data/metadata"

cloudflare:
  accountId: ""
  r2AccessKeyId: ""
  r2SecretKey: ""
  r2Bucket: "nsheep-packages"
  kvNamespaceId: ""
  apiToken: ""

storage: local  # "local" or "cloudflare"
```

| Section | Description |
|---------|-------------|
| `server` | HTTP server bind address and port |
| `github` | GitHub API token (optional) |
| `local` | Local filesystem storage paths |
| `cloudflare` | Cloudflare R2/KV credentials |
| `storage` | Which backend to use: `local` or `cloudflare` |

## API

### GET /health
Health check.

### GET /api/v1/packages
List all packages.

### GET /api/v1/packages/:name
Get package details.

### GET /download/:name/:version
Download tarball.

## Error Handling

All errors are explicit:

- `StorageError` - File I/O failures
- `NotFoundError` - Resource doesn't exist  
- `CorruptionError` - Invalid data on disk
- `GitHubError` - API failures
- `IngestError` - Ingestion failures

No silent failures. No ignored return values.

# NimPack Architecture

This document describes the technical architecture and design decisions behind NimPack.

## Design Goals

1. **Speed**: Fast local caching for all package operations
2. **Reliability**: Decoupled from GitHub availability
3. **Simplicity**: Minimal dependencies, clear separation of concerns
4. **Quality**: Docker-based validation before ingestion

## System Components

### 1. HTTP Server (`nsheep` binary)

**Responsibility**: Handle HTTP requests for package queries and downloads

**Implementation**:
- [Mummy](https://github.com/guzba/mummy) - High-performance HTTP server
- Router-based request handling
- CORS support for cross-origin requests

**Endpoints**:

| Endpoint | Method | Description | Cache |
|----------|--------|-------------|-------|
| `/health` | GET | Health check | none |
| `/packages.json` | GET | Nimble-compatible package list | 5 min |
| `/api/v1/packages` | GET | List all packages | 5 min |
| `/api/v1/packages/:name` | GET | Get package details | 1 hour |
| `/download/:name/:version` | GET | Download tarball | 1 year (immutable) |

Note: Package ingestion is handled automatically by the background fetcher, not via API.

### 2. Background Fetcher (`nsheep-fetcher` binary)

**Responsibility**: Periodically fetch and ingest packages from nim-lang/packages

**Flow**:
1. Fetch `packages.json` from nim-lang/packages repo
2. Parse GitHub repository URLs
3. Validate each package (if enabled)
4. Ingest valid packages into storage
5. Sleep for configured interval, repeat

**Configuration**:
- `interval`: Seconds between fetch cycles (default: 3600)
- `maxPackages`: Limit packages per cycle (0 = unlimited)
- `filterPatterns`: Only fetch matching packages

### 3. GitHub Client

**Responsibility**: Interact with GitHub API with caching

**Features**:
- ETag-based caching (1 hour TTL)
- Rate limit tracking
- Tarball downloading
- Optional token authentication

**Caching Strategy**:
```
Request: GET /repos/owner/repo
Headers: If-None-Match: "abc123"

Response 304: Use cache (zero cost)
Response 200: Update cache with new ETag
```

### 4. Storage Layer

**Responsibility**: Persistent storage for packages and metadata

**Architecture**: Hybrid SQLite + Filesystem

**SQLite Schema**:
```sql
-- Package metadata
packages (id, name, description, author, license, url, tags, created_at, updated_at)

-- Version metadata (no tarball blobs)
versions (id, package_id, major, minor, patch, tarball_path, tarball_size, checksum, published_at)

-- Validation history
validation_results (id, package_name, version, success, output, duration_ms, tested_at)
```

**Filesystem Layout**:
```
data/
├── nsheep.db           # SQLite database
├── tarballs/           # Package tarballs
│   ├── pkgname-1.0.0.tar.gz
│   └── pkgname-1.1.0.tar.gz
└── github-cache/       # ETag cache for GitHub API
    └── repo_owner_name.cache
```

### 5. Package Validator

**Responsibility**: Validate packages compile before ingestion

**Implementation**:
- Docker-based builds using `nimlang/nim` image
- Tests default branch + latest 2 tagged versions
- Stores results in SQLite for audit trail

**Configuration**:
- `enabled`: Enable validation
- `dockerImage`: Image to use for building
- `timeout`: Build timeout in seconds
- `required`: Skip ingestion if validation fails

## Data Flow

### Package Installation Flow

```
User: nimble install jester
       │
       ▼
Nimble: GET nimpack.org/packages.json
        │
        ▼
Nimble: GET nimpack.org/download/jester/0.6.0
        │
        ▼
NimPack: 1. Look up version in SQLite
        2. Read tarball from filesystem
        3. Return with immutable cache headers
```

### Package Ingestion Flow

```
Fetcher: 1. Fetch packages.json from nim-lang/packages
         2. For each GitHub repo:
            │
            ├── If validation enabled:
            │   └── Docker build (default + 2 latest tags)
            │   └── Store results in validation_results
            │   └── Skip if required and failed
            │
            ├── Fetch repo metadata (cached)
            ├── Fetch releases (GitHub API)
            ├── Download tarballs
            ├── Compute checksums
            └── Store:
                - Metadata in SQLite (packages table)
                - Version info in SQLite (versions table)
                - Tarball in filesystem
```

## Concurrency Model

### Server (`nsheep`)
- Mummy handles HTTP concurrency (one thread per request)
- SQLite handles concurrent reads
- No background threads in server binary

### Fetcher (`nsheep-fetcher`)
- Single-threaded loop with sleep intervals
- Can be run as:
  - Standalone binary (recommended)
  - Background thread (when server starts fetcher)

## Configuration

YAML-based configuration (`cfg.yaml`):

```yaml
server:
  bindAddr: "127.0.0.1"
  port: 8080

github:
  token: ""  # Optional, for higher rate limits

local:
  dbPath: "./data/nsheep.db"
  tarballDir: "./data/tarballs"

fetcher:
  interval: 3600
  maxPackages: 0
  filterPatterns: []

validator:
  enabled: true
  dockerImage: "nimlang/nim:latest"
  timeout: 300
  required: false

storage: "local"
```

## Performance Characteristics

### Throughput
- **List packages**: ~10,000 req/s (SQLite indexed)
- **Get package**: ~5,000 req/s (SQLite query)
- **Download**: ~1,000 req/s (filesystem I/O bound)

### Latency
- **Cached read**: < 1ms (SQLite + filesystem)
- **GitHub fetch**: 100-500ms (background only)

### Storage
- **Database**: ~10KB per package
- **Tarballs**: Same size as GitHub releases
- **GitHub cache**: ~100KB per repository

## Security Considerations

1. **GitHub Token**: Stored in memory only, never logged
2. **File Paths**: Sanitized to prevent directory traversal
3. **Package Names**: Validated (alphanumeric, hyphen, underscore, must start with letter)
4. **CORS**: `*` allowed for API endpoints (configurable)
5. **Docker**: Validation runs in isolated containers

## Binaries

| Binary | Purpose | Runs As |
|--------|---------|---------|
| `nsheep` | HTTP server | Long-running daemon |
| `nsheep-fetcher` | Background ingestion | Cron job or daemon |

## Dependencies

- **mummy**: HTTP server
- **puppy**: HTTP client
- **chronicles**: Structured logging
- **yaml**: Configuration parsing
- **tiny_sqlite**: SQLite bindings

## Future Enhancements

1. **Webhook Support**: GitHub webhooks for real-time updates
2. **CDN Caching**: Cloudflare edge caching for tarball downloads
3. **Analytics**: Download statistics
4. **Private Packages**: Support for private registries
5. **Binary Caching**: Cache compiled binaries per platform
6. **Admin UI**: Web interface for management

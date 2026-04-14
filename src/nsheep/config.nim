##
## Configuration - single source of truth, no fallbacks
## Configuration is loaded once at startup and is immutable
##

import yaml

type
  StorageBackend* = enum
    sbLocal
    sbCloudflare

  ServerConfig* = object
    bindAddr*: string
    port*: int
    publicDir*: string

  GitHubConfig* = object
    token*: string

  LocalStorageConfig* = object
    dbPath*: string       # SQLite database path
    tarballDir*: string   # Directory for tarballs

  CloudflareConfig* = object
    accountId*: string
    r2AccessKeyId*: string
    r2SecretKey*: string
    r2Bucket*: string
    kvNamespaceId*: string
    apiToken*: string

  FetcherConfig* = object
    interval*: int           # Seconds between fetches (default: 3600)
    maxPackages*: int        # Max packages to ingest per cycle (0 = unlimited)
    filterPatterns*: seq[string]  # Only fetch packages matching these patterns

  ValidatorConfig* = object
    enabled*: bool           # Enable Docker validation
    dockerImage*: string     # Docker image to use for building
    timeout*: int            # Build timeout in seconds
    required*: bool          # Require validation to pass before storing

  RawConfig* = object
    ## Config as loaded from YAML (with string storage field)
    server*: ServerConfig
    github*: GitHubConfig
    local*: LocalStorageConfig
    cloudflare*: CloudflareConfig
    fetcher*: FetcherConfig
    validator*: ValidatorConfig
    storage*: string

  Config* = object
    ## Immutable configuration - all fields must be explicitly set
    server*: ServerConfig
    github*: GitHubConfig
    local*: LocalStorageConfig
    cloudflare*: CloudflareConfig
    fetcher*: FetcherConfig
    validator*: ValidatorConfig
    storage*: StorageBackend

# --- Validation ---

proc validate(cfg: Config) =
  ## Fail fast on invalid configuration
  if cfg.server.port < 1 or cfg.server.port > 65535:
    raise newException(ValueError, "invalid port: " & $cfg.server.port)
  
  if cfg.server.bindAddr.len == 0:
    raise newException(ValueError, "bind address cannot be empty")
  
  if cfg.server.publicDir.len == 0:
    raise newException(ValueError, "server.publicDir cannot be empty")
  
  case cfg.storage
  of sbLocal:
    if cfg.local.dbPath.len == 0:
      raise newException(ValueError, "local.dbPath cannot be empty")
    if cfg.local.tarballDir.len == 0:
      raise newException(ValueError, "local.tarballDir cannot be empty")
  of sbCloudflare:
    if cfg.cloudflare.accountId.len == 0:
      raise newException(ValueError, "cloudflare.accountId cannot be empty")
    if cfg.cloudflare.r2AccessKeyId.len == 0:
      raise newException(ValueError, "cloudflare.r2AccessKeyId cannot be empty")
    if cfg.cloudflare.r2SecretKey.len == 0:
      raise newException(ValueError, "cloudflare.r2SecretKey cannot be empty")
    if cfg.cloudflare.r2Bucket.len == 0:
      raise newException(ValueError, "cloudflare.r2Bucket cannot be empty")
    if cfg.cloudflare.kvNamespaceId.len == 0:
      raise newException(ValueError, "cloudflare.kvNamespaceId cannot be empty")
    if cfg.cloudflare.apiToken.len == 0:
      raise newException(ValueError, "cloudflare.apiToken cannot be empty")

# --- Loading - explicit, no guessing ---

proc loadConfig*(path: string): Config =
  ## Load configuration from YAML file
  ## Fails if file doesn't exist or is invalid
  
  let content = readFile(path)
  
  # Load raw config with string storage field
  let raw = loadAs[RawConfig](content)
  
  # Parse storage backend
  var storage: StorageBackend
  case raw.storage
  of "local":
    storage = sbLocal
  of "cloudflare":
    storage = sbCloudflare
  else:
    raise newException(ValueError, "unknown storage: " & raw.storage & ", expected 'local' or 'cloudflare'")
  
  # Set fetcher defaults if not provided
  var fetcherConfig = raw.fetcher
  if fetcherConfig.interval == 0:
    fetcherConfig.interval = 3600  # 1 hour default
  
  # Set server defaults
  var serverConfig = raw.server
  if serverConfig.publicDir == "":
    serverConfig.publicDir = "./public"
  
  # Set validator defaults
  var validatorConfig = raw.validator
  if validatorConfig.dockerImage == "":
    validatorConfig.dockerImage = "nimlang/nim:latest"
  if validatorConfig.timeout == 0:
    validatorConfig.timeout = 300  # 5 minutes
  
  # Build final config
  var cfg = Config(
    server: serverConfig,
    github: raw.github,
    local: raw.local,
    cloudflare: raw.cloudflare,
    fetcher: fetcherConfig,
    validator: validatorConfig,
    storage: storage
  )
  
  # Validate
  validate(cfg)
  result = cfg

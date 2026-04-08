##
## Background fetcher - periodically ingests from nimble packages list
## Runs in separate thread, resilient to individual failures
##

import std/[json, strutils, options, os]
import chronicles
import nsheep/[types, storage, ingest, github, config, validator], puppy

const
  NimblePackagesUrl = "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"
  DefaultFetchInterval = 60 * 60  # 1 hour in seconds
  MaxRetries = 3

type
  Fetcher* = ref object
    gh*: GitHubClient
    store*: DbStorage
    fetcherConfig*: FetcherConfig
    validatorConfig*: validator.ValidatorConfig
    running*: bool
    thread*: Thread[Fetcher]

proc defaultFetcherConfig*(): FetcherConfig =
  FetcherConfig(
    interval: DefaultFetchInterval,
    filterPatterns: @[],
    maxPackages: 0
  )

proc parseRepositoryUrl(url: string): Option[Repository] =
  ## Parse GitHub URL into owner/repo
  if not url.startsWith("https://github.com/"):
    return none(Repository)
  
  let parts = url[19..^1].split('/')
  if parts.len < 2:
    return none(Repository)
  
  var repo: Repository
  repo.owner = parts[0]
  repo.name = parts[1].replace(".git", "")
  return some(repo)

proc fetchNimblePackages(): seq[Repository] =
  ## Fetch and parse nimble packages.json
  info "Fetching nimble packages list"
  
  let response = get(NimblePackagesUrl)
  if response.code != 200:
    raise newException(IOError, "failed to fetch packages.json: HTTP " & $response.code)
  
  let json = parseJson(response.body)
  if json.kind != JArray:
    raise newException(ValueError, "packages.json is not an array")
  
  result = @[]
  for pkg in json:
    try:
      if pkg.hasKey("alias"):
        continue
      
      let url = pkg["url"].getStr()
      let repoOpt = parseRepositoryUrl(url)
      if repoOpt.isSome:
        result.add(repoOpt.get())
    except:
      continue
  
  info "Parsed packages", count = result.len

proc ingestPackage(fetcher: Fetcher, repo: Repository): bool =
  ## Ingest a single package with validation, return true on success
  
  # First validate if enabled
  if fetcher.validatorConfig.enabled:
    info "Validating package", repo = repo.owner & "/" & repo.name
    let validationResult = validatePackage(fetcher.store, repo.owner, repo.name, fetcher.validatorConfig)
    
    if not validationResult.overallSuccess:
      if fetcher.validatorConfig.required:
        error "Validation failed, skipping ingest", repo = repo.owner & "/" & repo.name
        return false
      else:
        warn "Validation failed but not required, continuing", repo = repo.owner & "/" & repo.name
    else:
      info "Validation passed", repo = repo.owner & "/" & repo.name
  
  # Then ingest
  for attempt in 1..MaxRetries:
    try:
      discard ingest(fetcher.gh, fetcher.store, repo)
      return true
    except CatchableError as e:
      warn "Ingest failed", repo = repo.owner & "/" & repo.name, attempt = attempt, error = e.msg
      if attempt < MaxRetries:
        sleep(1000 * attempt)
  
  error "Ingest failed permanently", repo = repo.owner & "/" & repo.name
  return false

proc shouldFetch(fetcher: Fetcher, repo: Repository): bool =
  if fetcher.fetcherConfig.filterPatterns.len == 0:
    return true
  
  let fullName = repo.owner & "/" & repo.name
  for pattern in fetcher.fetcherConfig.filterPatterns:
    if fullName.contains(pattern):
      return true
  return false

proc runOnce(fetcher: Fetcher) =
  info "Starting fetch cycle"
  
  let repos = fetchNimblePackages()
  var successCount = 0
  var failCount = 0
  var skippedCount = 0
  var processedCount = 0
  
  for repo in repos:
    if fetcher.fetcherConfig.maxPackages > 0 and processedCount >= fetcher.fetcherConfig.maxPackages:
      break
    
    if not fetcher.shouldFetch(repo):
      skippedCount.inc
      continue
    
    processedCount.inc
    
    if ingestPackage(fetcher, repo):
      successCount.inc
    else:
      failCount.inc
  
  info "Fetch cycle complete", success = successCount, failed = failCount, skipped = skippedCount, total = processedCount

proc fetcherLoop(fetcher: Fetcher) {.thread.} =
  info "Fetcher thread started", interval = fetcher.fetcherConfig.interval
  
  while fetcher.running:
    try:
      runOnce(fetcher)
    except CatchableError as e:
      error "Fetch cycle error", error = e.msg
    
    var slept = 0
    while fetcher.running and slept < fetcher.fetcherConfig.interval:
      sleep(1000)
      slept.inc
  
  info "Fetcher thread stopped"

proc runFetcher*(fetcher: Fetcher) =
  ## Run fetcher in current thread (blocking)
  fetcher.running = true
  info "Fetcher started", interval = fetcher.fetcherConfig.interval
  
  while fetcher.running:
    try:
      runOnce(fetcher)
    except CatchableError as e:
      error "Fetch cycle error", error = e.msg
    
    var slept = 0
    while fetcher.running and slept < fetcher.fetcherConfig.interval:
      sleep(1000)
      slept.inc
  
  info "Fetcher stopped"

proc startFetcher*(fetcher: Fetcher) =
  ## Start fetcher in background thread
  fetcher.running = true
  createThread(fetcher.thread, fetcherLoop, fetcher)

proc stopFetcher*(fetcher: Fetcher) =
  fetcher.running = false

proc initFetcher*(
  gh: GitHubClient, 
  store: DbStorage, 
  fetcherConfig: FetcherConfig = defaultFetcherConfig(),
  validatorConfig: validator.ValidatorConfig = validator.defaultValidatorConfig()
): Fetcher =
  result = Fetcher(
    gh: gh,
    store: store,
    fetcherConfig: fetcherConfig,
    validatorConfig: validatorConfig,
    running: false
  )

# --- Main entry point when run as standalone binary ---

when isMainModule:
  proc main() =
    ## NSheep fetcher - background package ingestion
    
    if paramCount() < 1:
      stderr.writeLine("usage: nsheep-fetcher <cfg.yaml>")
      quit(1)
    
    let configPath = paramStr(1)
    if not fileExists(configPath):
      stderr.writeLine("config file not found: ", configPath)
      quit(1)
    
    let cfg = try:
      loadConfig(configPath)
    except CatchableError as e:
      stderr.writeLine("failed to load config: ", e.msg)
      quit(1)
    
    # Initialize storage
    var store: DbStorage
    case cfg.storage
    of sbLocal:
      store = initStorage(cfg.local.dbPath, cfg.local.tarballDir)
    of sbCloudflare:
      stderr.writeLine("Cloudflare storage not yet implemented")
      quit(1)
    
    # Initialize GitHub client
    var gh = initGitHubClient(cfg.github.token, "/tmp/nsheep/github-cache")
    
    # Create and run fetcher
    var f = initFetcher(gh, store, cfg.fetcher, cfg.validator)
    
    info "Fetcher starting", interval = cfg.fetcher.interval, validation = cfg.validator.enabled
    
    try:
      f.runFetcher()
    except CatchableError as e:
      error "Fetcher error", error = e.msg
      quit(1)
  
  main()

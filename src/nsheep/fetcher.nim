##
## Background fetcher - periodically ingests from nimble packages list
## Runs in separate thread, resilient to individual failures
##

import std/[json, strutils, options, os]
import chronicles
import nsheep/[storage, ingest, vcs, config, validator], puppy

const
  NimblePackagesUrl = "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"
  DefaultFetchInterval = 60 * 60 # 1 hour in seconds
  MaxRetries = 3

type
  IngestResult* = enum
    irSuccess
    irFailed
    irSkipped

  Fetcher* = ref object
    vcs*: VcsClient
    store*: DbStorage
    fetcherConfig*: FetcherConfig
    validatorConfig*: validator.ValidatorConfig
    running*: bool
    thread*: Thread[Fetcher]

  NimblePkg* = object
    ## Entry from nimble packages.json — carries the canonical name
    repo*: RepoRef
    name*: string
    tags*: seq[string]

proc parseTags*(pkg: JsonNode): seq[string] =
  ## Parse tags array from a nimble packages.json entry.
  ## Returns empty seq if tags field is missing, null, or malformed.
  result = @[]
  if not pkg.hasKey("tags"):
    return
  let tagsNode = pkg["tags"]
  if tagsNode.kind != JArray:
    return
  for tag in tagsNode:
    if tag.kind == JString:
      let s = tag.getStr().strip()
      if s.len > 0:
        result.add(s)

proc defaultFetcherConfig*(): FetcherConfig =
  FetcherConfig(
    interval: DefaultFetchInterval,
    filterPatterns: @[],
    maxPackages: 0
  )

proc fetchNimblePackages(): seq[NimblePkg] =
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
    var name = ""
    try:
      if pkg.hasKey("alias"):
        continue

      name = pkg["name"].getStr()
      let url = pkg["url"].getStr()
      let tags = parseTags(pkg)
      let repoOpt = vcs.parseRepoUrl(url)
      if repoOpt.isSome:
        result.add(NimblePkg(repo: repoOpt.get(), name: name, tags: tags))
    except KeyError as e:
      warn "Skipping package with missing field", name = name, field = e.msg
    except CatchableError as e:
      warn "Skipping package due to error", name = name, error = e.msg

  info "Parsed packages", count = result.len

proc ingestPackage(fetcher: Fetcher, pkg: NimblePkg): IngestResult =
  ## Ingest a single package with validation

  # Skip if processed since last fetcher cycle
  if packageProcessedRecently(fetcher.store, pkg.name, fetcher.fetcherConfig.interval):
    info "Skipping recently processed package", repo = pkg.repo.path
    return irSkipped

  # First validate if enabled and Docker is available
  if fetcher.validatorConfig.enabled:
    if not isDockerAvailable():
      warn "Docker not available, skipping validation", repo = pkg.repo.path
      return irSkipped
    if validationDoneRecently(fetcher.store, pkg.name, fetcher.fetcherConfig.interval):
      info "Skipping recently validated package", repo = pkg.repo.path
      return irSkipped
    info "Validating package", repo = pkg.repo.path
    let validationResult = validatePackage(fetcher.store, pkg.repo.url, pkg.repo.path, fetcher.validatorConfig)

    if not validationResult.overallSuccess:
      if fetcher.validatorConfig.required:
        error "Validation failed, skipping ingest", repo = pkg.repo.path
        return irFailed
      else:
        warn "Validation failed but not required, continuing", repo = pkg.repo.path
    else:
      info "Validation passed", repo = pkg.repo.path

  # Then ingest
  for attempt in 1..MaxRetries:
    try:
      discard ingest(fetcher.vcs, fetcher.store, pkg.repo, pkg.name, pkg.tags)
      return irSuccess
    except VcsNotFoundError as e:
      warn "Repository not found, giving up", repo = pkg.repo.path, error = e.msg
      return irFailed
    except CatchableError as e:
      warn "Ingest failed", repo = pkg.repo.path, attempt = attempt, error = e.msg
      if attempt < MaxRetries:
        sleep(1000 * attempt)

  error "Ingest failed permanently", repo = pkg.repo.path
  return irFailed

proc shouldFetch(fetcher: Fetcher, pkg: NimblePkg): bool =
  if fetcher.fetcherConfig.filterPatterns.len == 0:
    return true

  let fullName = pkg.repo.path
  for pattern in fetcher.fetcherConfig.filterPatterns:
    if fullName.contains(pattern):
      return true
  return false

proc runOnce(fetcher: Fetcher) =
  info "Starting fetch cycle"

  let pkgs = fetchNimblePackages()
  var successCount = 0
  var failCount = 0
  var skipCount = 0
  var processedCount = 0

  for pkg in pkgs:
    if fetcher.fetcherConfig.maxPackages > 0 and processedCount >= fetcher.fetcherConfig.maxPackages:
      break

    if not fetcher.shouldFetch(pkg):
      continue

    processedCount.inc

    case ingestPackage(fetcher, pkg):
    of irSuccess: successCount.inc
    of irFailed: failCount.inc
    of irSkipped: skipCount.inc

  info "Fetch cycle complete", success = successCount, failed = failCount, skipped = skipCount,
      total = processedCount

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
  vcsClient: VcsClient,
  store: DbStorage,
  fetcherConfig: FetcherConfig = defaultFetcherConfig(),
  validatorConfig: validator.ValidatorConfig = validator.defaultValidatorConfig()
): Fetcher =
  result = Fetcher(
    vcs: vcsClient,
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

    # Initialize VCS client
    var vcsClient = initVcsClient(
      cfg.github.token,
      cfg.gitlab.token,
      cfg.codeberg.token,
      cfg.bitbucket.token,
      cfg.sourcehut.token,
      "/tmp/nsheep/vcs-cache"
    )

    # Create and run fetcher
    var f = initFetcher(vcsClient, store, cfg.fetcher, cfg.validator)

    info "Fetcher starting", interval = cfg.fetcher.interval, validation = cfg.validator.enabled

    try:
      f.runFetcher()
    except CatchableError as e:
      error "Fetcher error", error = e.msg
      quit(1)

  main()

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

  FetcherData = object
    vcs*: VcsClient
    store*: DbStorage
    fetcherConfig*: FetcherConfig
    validatorConfig*: validator.ValidatorConfig
    running*: bool
    thread*: Thread[ptr FetcherData]

  Fetcher* = ref FetcherData

  ValidatorData = object
    store*: DbStorage
    config*: validator.ValidatorConfig
    interval*: int
    running*: bool
    thread*: Thread[ptr ValidatorData]

  Validator* = ref ValidatorData

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

  let response = get(NimblePackagesUrl, timeout = 30)
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

proc ingestPackage(fetcher: ptr FetcherData, pkg: NimblePkg): IngestResult =
  ## Ingest a single package

  # Skip if processed since last fetcher cycle
  if packageProcessedRecently(fetcher.store, pkg.name, fetcher.fetcherConfig.interval):
    info "Skipping recently processed package", repo = pkg.repo.path
    return irSkipped

  for attempt in 1..MaxRetries:
    try:
      discard ingest(fetcher.vcs, fetcher.store, pkg.repo, pkg.name, pkg.tags)
      return irSuccess
    except VcsNotFoundError as e:
      warn "Repository not found, giving up", repo = pkg.repo.path, error = e.msg
      recordFailedPackage(fetcher.store, pkg.name, "repo not found: " & e.msg)
      return irFailed
    except CatchableError as e:
      warn "Ingest failed", repo = pkg.repo.path, attempt = attempt, error = e.msg
      if attempt < MaxRetries:
        sleep(1000 * attempt)

  error "Ingest failed permanently", repo = pkg.repo.path
  recordFailedPackage(fetcher.store, pkg.name, "permanent ingest failure")
  return irFailed

proc shouldFetch(fetcher: ptr FetcherData, pkg: NimblePkg): bool =
  if fetcher.fetcherConfig.filterPatterns.len == 0:
    return true

  let fullName = pkg.repo.path
  for pattern in fetcher.fetcherConfig.filterPatterns:
    if fullName.contains(pattern):
      return true
  return false

proc runOnce(fetcher: ptr FetcherData) =
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

proc fetcherLoop(fetcher: ptr FetcherData) {.thread.} =
  info "Fetcher thread started", interval = fetcher.fetcherConfig.interval

  try:
    while fetcher.running:
      try:
        runOnce(fetcher)
      except CatchableError as e:
        error "Fetch cycle error", error = e.msg

      var slept = 0
      while fetcher.running and slept < fetcher.fetcherConfig.interval:
        sleep(1000)
        slept.inc
  finally:
    fetcher.running = false

  info "Fetcher thread stopped"

proc runFetcher*(fetcher: Fetcher) =
  ## Run fetcher in current thread (blocking)
  fetcher.running = true
  info "Fetcher started", interval = fetcher.fetcherConfig.interval

  while fetcher.running:
    try:
      runOnce(unsafeAddr fetcher[])
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
  createThread(fetcher.thread, fetcherLoop, unsafeAddr fetcher[])

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

# --- Validator thread ---

proc validatorLoop(v: ptr ValidatorData) {.thread.} =
  info "Validator thread started", interval = v.interval

  try:
    while v.running:
      if not v.config.enabled or not isDockerAvailable():
        info "Validator disabled or Docker unavailable, sleeping"
        var slept = 0
        while v.running and slept < v.interval:
          sleep(1000)
          slept.inc
        continue

      try:
        let pkgs = fetchNimblePackages()
        for pkg in pkgs:
          if not v.running:
            break
          if isFailedPackage(v.store, pkg.name):
            continue
          if validationDoneRecently(v.store, pkg.name, v.interval):
            continue
          info "Validating package", repo = pkg.repo.path
          let result = validatePackage(v.store, pkg.repo.url, pkg.name, v.config)
          if result.overallSuccess:
            info "Validation passed", repo = pkg.repo.path
          else:
            warn "Validation failed", repo = pkg.repo.path
      except CatchableError as e:
        error "Validator cycle error", error = e.msg

      var slept = 0
      while v.running and slept < v.interval:
        sleep(1000)
        slept.inc
  finally:
    v.running = false

  info "Validator thread stopped"

proc startValidator*(v: Validator) =
  v.running = true
  createThread(v.thread, validatorLoop, unsafeAddr v[])

proc stopValidator*(v: Validator) =
  v.running = false

proc initValidator*(
  store: DbStorage,
  interval: int = DefaultFetchInterval,
  config: validator.ValidatorConfig = validator.defaultValidatorConfig()
): Validator =
  result = Validator(
    store: store,
    interval: interval,
    config: config,
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

    # Create fetcher and validator with separate DB connections
    var f = initFetcher(vcsClient, store, cfg.fetcher, cfg.validator)
    var v = initValidator(initStorage(cfg.local.dbPath, cfg.local.tarballDir), cfg.fetcher.interval, cfg.validator)

    info "Fetcher starting", interval = cfg.fetcher.interval, validation = cfg.validator.enabled

    f.startFetcher()
    if cfg.validator.enabled:
      v.startValidator()

    try:
      # Block main thread, let background threads run
      while f.running:
        sleep(1000)
    except CatchableError as e:
      error "Fetcher error", error = e.msg
      quit(1)

    f.stopFetcher()
    v.stopValidator()

    joinThread(f.thread)
    if cfg.validator.enabled:
      joinThread(v.thread)

  main()

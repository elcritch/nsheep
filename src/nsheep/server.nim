##
## HTTP server - Mummy-based, explicit error handling
## No async - one thread per request is fine for this workload
##

import std/[json, strutils, options, times, os]
import mummy, mummy/routers
import chronicles
import nsheep/[types, storage, github, config]

# --- State ---

type
  ServerState* = object
    cfg*: Config
    store*: DbStorage
    gh*: GitHubClient

# --- Helpers ---

proc sendError(request: Request, status: int, error, message: string) =
  var headers = emptyHttpHeaders()
  headers["Content-Type"] = "application/json"
  headers["Cache-Control"] = "no-store"
  
  let body = %*{
    "error": error,
    "message": message,
    "timestamp": $now()
  }
  
  request.respond(status, headers, pretty(body))

proc sendJson(request: Request, data: JsonNode, cacheSeconds: int = 0) =
  var headers = emptyHttpHeaders()
  headers["Content-Type"] = "application/json"
  headers["Access-Control-Allow-Origin"] = "*"
  
  if cacheSeconds > 0:
    headers["Cache-Control"] = "public, max-age=" & $cacheSeconds
  else:
    headers["Cache-Control"] = "no-store"
  
  request.respond(200, headers, pretty(data))

# --- Handlers ---

proc handleHealth(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let body = %*{
      "status": "ok",
      "version": Version,
      "timestamp": $now()
    }
    sendJson(request, body)

proc handleGetPackage(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let nameStr = request.pathParams["name"]
    
    # Validate name
    let name = try:
      initPackageName(nameStr)
    except ValueError as e:
      sendError(request, 400, "invalid_name", e.msg)
      return
    
    # Load from storage
    let pkg = try:
      loadPackage(state.store, name)
    except storage.NotFoundError:
      sendError(request, 404, "not_found", "package not found: " & nameStr)
      return
    except storage.StorageError as e:
      sendError(request, 500, "storage_error", e.msg)
      return
    
    # Build response
    var versionsJson = newJArray()
    for v in pkg.versions:
      versionsJson.add(%*{
        "version": $v.version.major & "." & $v.version.minor & "." & $v.version.patch,
        "size": v.size,
        "checksum": $v.checksum,
        "publishedAt": $v.publishedAt
      })
    
    let body = %*{
      "name": $pkg.name,
      "description": pkg.description,
      "author": pkg.author,
      "license": pkg.license,
      "url": pkg.url,
      "tags": pkg.tags,
      "versions": versionsJson,
      "updatedAt": $pkg.updatedAt
    }
    
    sendJson(request, body, cacheSeconds = 3600)  # 1 hour cache

proc handleListPackages(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    var page = 1
    var limit = 50

    try:
      if "page" in request.queryParams:
        page = parseInt(request.queryParams["page"])
      if "limit" in request.queryParams:
        limit = parseInt(request.queryParams["limit"])
    except ValueError:
      sendError(request, 400, "invalid_params", "page and limit must be integers")
      return

    if page < 1:
      page = 1
    if limit < 1:
      limit = 1
    elif limit > 200:
      limit = 200

    let offset = (page - 1) * limit

    let summaries = listPackageSummariesPaged(state.store, offset, limit)
    let total = countPackages(state.store)

    var arr = newJArray()
    for s in summaries:
      var tags = newJArray()
      for t in s.tags:
        tags.add(% t)
      arr.add(%*{
        "name": s.name,
        "description": s.description,
        "author": s.author,
        "license": s.license,
        "url": s.url,
        "tags": tags,
        "latestVersion": s.latestVersion,
        "createdAt": s.createdAt,
        "updatedAt": s.updatedAt,
        "latestVersionPublishedAt": s.latestVersionPublishedAt
      })

    let body = %*{
      "packages": arr,
      "total": total,
      "page": page,
      "limit": limit
    }

    sendJson(request, body, cacheSeconds = 0)

proc handleValidations(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let nameStr = request.pathParams["name"]
    
    # Parse name
    let name = try:
      initPackageName(nameStr)
    except ValueError as e:
      sendError(request, 400, "invalid_name", e.msg)
      return
    
    # Load validations
    let results = getLatestValidationResults(state.store, nameStr)
    
    var arr = newJArray()
    for r in results:
      arr.add(%*{
        "version": r.version,
        "success": r.success,
        "testedAt": $r.testedAt
      })
    
    sendJson(request, arr, cacheSeconds = 300)

proc handleReadme(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let nameStr = request.pathParams["name"]
    
    # Parse name
    let name = try:
      initPackageName(nameStr)
    except ValueError as e:
      sendError(request, 400, "invalid_name", e.msg)
      return
    
    # Load package
    let pkg = try:
      loadPackage(state.store, name)
    except storage.NotFoundError:
      sendError(request, 404, "not_found", "package not found: " & nameStr)
      return
    except storage.StorageError as e:
      sendError(request, 500, "storage_error", e.msg)
      return
    
    # Parse repository URL
    let repo = try:
      parseRepositoryUrl(pkg.url)
    except ValueError:
      sendError(request, 400, "invalid_repo", "package URL is not a valid GitHub repository")
      return
    
    # Fetch README
    let readme = fetchReadme(state.gh, repo.owner, repo.name)
    
    var headers = emptyHttpHeaders()
    headers["Content-Type"] = "text/markdown; charset=utf-8"
    headers["Access-Control-Allow-Origin"] = "*"
    request.respond(200, headers, readme)

proc handleDownloads(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let nameStr = request.pathParams["name"]
    
    # Parse name
    let name = try:
      initPackageName(nameStr)
    except ValueError as e:
      sendError(request, 400, "invalid_name", e.msg)
      return
    
    # Load download stats
    let stats = getDownloadStats(state.store, name.string)
    
    var arr = newJArray()
    for s in stats:
      arr.add(%*{
        "version": s.version,
        "downloads": s.downloads
      })
    
    sendJson(request, arr, cacheSeconds = 0)

proc handleDownload(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let nameStr = request.pathParams["name"]
    let versionStr = request.pathParams["version"]
    
    # Parse name
    let name = try:
      initPackageName(nameStr)
    except ValueError as e:
      sendError(request, 400, "invalid_name", e.msg)
      return
    
    # Parse version
    let optVer = parseSemVer(versionStr)
    if optVer.isNone:
      sendError(request, 400, "invalid_version", "expected semver: " & versionStr)
      return
    let version = optVer.get()
    
    # Record download
    try:
      recordDownload(state.store, nameStr, versionStr)
    except storage.StorageError as e:
      error "Failed to record download", package = nameStr, version = versionStr, error = e.msg
    
    # Load tarball
    let data = try:
      loadTarball(state.store, name, version)
    except storage.NotFoundError:
      sendError(request, 404, "not_found", "tarball not found: " & nameStr & "@" & versionStr)
      return
    except storage.StorageError as e:
      sendError(request, 500, "storage_error", e.msg)
      return
    
    # Serve with appropriate headers
    var headers = emptyHttpHeaders()
    headers["Content-Type"] = "application/gzip"
    headers["Content-Disposition"] = "attachment; filename=\"" & $name & "-" & versionStr & ".tar.gz\""
    headers["Cache-Control"] = "public, max-age=31536000, immutable"  # 1 year
    headers["Access-Control-Allow-Origin"] = "*"
    
    # Convert bytes to string for mummy
    var strData = newString(data.len)
    if data.len > 0:
      copyMem(addr strData[0], unsafeAddr data[0], data.len)
    
    request.respond(200, headers, strData)

# --- Static Files ---

proc serveStaticFile(state: ptr ServerState, fileName: string): RequestHandler =
  result = proc(request: Request) =
    let filePath = state.cfg.server.publicDir / fileName
    if not fileExists(filePath):
      request.respond(404, emptyHttpHeaders(), "not found")
      return
    
    let ext = splitFile(filePath).ext
    let contentType = case ext
    of ".js": "application/javascript"
    of ".css": "text/css"
    of ".html": "text/html"
    else: "application/octet-stream"
    
    let data = readFile(filePath)
    var headers = emptyHttpHeaders()
    headers["Content-Type"] = contentType
    request.respond(200, headers, data)

proc serveIndex(state: ptr ServerState): RequestHandler =
  result = serveStaticFile(state, "index.html")

# --- Setup ---

proc setupRoutes*(router: var Router, state: ptr ServerState) =
  router.get("/health", handleHealth(state))
  router.get("/api/v1/packages", handleListPackages(state))
  router.get("/api/v1/packages/@name", handleGetPackage(state))
  # Note: Ingestion is now handled automatically by background fetcher
  router.get("/api/v1/packages/@name/validations", handleValidations(state))
  router.get("/api/v1/packages/@name/readme", handleReadme(state))
  router.get("/api/v1/packages/@name/downloads", handleDownloads(state))
  router.get("/download/@name/@version", handleDownload(state))
  
  # Static frontend assets
  router.get("/", serveIndex(state))
  router.get("/app.js", serveStaticFile(state, "app.js"))
  router.get("/app.css", serveStaticFile(state, "app.css"))
  
  # CORS preflight
  router.options("/*", proc(request: Request) =
    var headers = emptyHttpHeaders()
    headers["Access-Control-Allow-Origin"] = "*"
    headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    headers["Access-Control-Allow-Headers"] = "Content-Type"
    request.respond(204, headers, "")
  )

# --- Main ---

proc runServer*(cfg: Config) =
  ## Run the HTTP server
  
  # Initialize state
  var state: ServerState
  state.cfg = cfg
  
  case cfg.storage
  of sbLocal:
    state.store = initStorage(cfg.local.dbPath, cfg.local.tarballDir)
  of sbCloudflare:
    raise newException(ValueError, "Cloudflare storage not yet implemented")
  
  state.gh = initGitHubClient(cfg.github.token, "/tmp/nsheep/github-cache")
  
  # Setup router
  var router = Router()
  setupRoutes(router, addr state)
  
  # Start server
  let server = newServer(router)
  info "Server starting", address = cfg.server.bindAddr, port = cfg.server.port
  info "Server listening", address = cfg.server.bindAddr, port = cfg.server.port
  server.serve(Port(cfg.server.port), cfg.server.bindAddr)

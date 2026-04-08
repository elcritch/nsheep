##
## HTTP server - Mummy-based, explicit error handling
## No async - one thread per request is fine for this workload
##

import std/[json, strutils, options, times]
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
    let names = listPackages(state.store)
    
    var arr = newJArray()
    for name in names:
      arr.add(% $name)
    
    sendJson(request, arr, cacheSeconds = 300)  # 5 min cache

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

# --- Setup ---

proc setupRoutes*(router: var Router, state: ptr ServerState) =
  router.get("/health", handleHealth(state))
  router.get("/api/v1/packages", handleListPackages(state))
  router.get("/api/v1/packages/@name", handleGetPackage(state))
  # Note: Ingestion is now handled automatically by background fetcher
  router.get("/download/@name/@version", handleDownload(state))
  
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

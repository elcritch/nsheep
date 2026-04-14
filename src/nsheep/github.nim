##
## GitHub API client - sync, explicit errors, ETag caching
## No async - simple blocking I/O is predictable
##

import std/[json, times, strutils, base64, os, options]
import chronicles
import puppy
import nsheep/types

# --- Types ---

type
  GitHubClient* = object
    token*: string
    cacheDir*: string

  RateLimit* = object
    limit*: int
    remaining*: int
    resetAt*: DateTime

  GitHubError* = object of CatchableError
  UnauthorizedError* = object of GitHubError
  RateLimitError* = object of GitHubError
  NotFoundError* = object of GitHubError

# --- ETag Cache ---

type
  CachedResponse* = object
    etag*: string
    body*: string
    cachedAt*: DateTime

proc cachePath(cacheDir, key: string): string =
  ## Safe cache key to filename
  let safeKey = key.replace("/", "_")
  cacheDir / safeKey & ".cache"

proc loadCache(cacheDir, key: string): Option[CachedResponse] =
  let path = cachePath(cacheDir, key)
  if not fileExists(path):
    return none(CachedResponse)
  
  try:
    let content = readFile(path)
    let lines = content.split('\n', 2)
    if lines.len < 3:
      return none(CachedResponse)
    
    let etag = lines[0]
    let timestamp = parseInt(lines[1])
    let body = lines[2]
    
    # TTL: 1 hour
    if (getTime() - fromUnix(timestamp)).inHours > 1:
      return none(CachedResponse)
    
    result = some(CachedResponse(
      etag: etag,
      body: body,
      cachedAt: fromUnix(timestamp).utc()
    ))
  except:
    return none(CachedResponse)

proc saveCache(cacheDir, key: string, etag, body: string) =
  createDir(cacheDir)
  let path = cachePath(cacheDir, key)
  let content = etag & "\n" & $getTime().toUnix & "\n" & body
  writeFile(path, content)

# --- Client ---

proc initGitHubClient*(token, cacheDir: string): GitHubClient =
  result.token = token
  result.cacheDir = cacheDir

proc makeRequest(
  client: GitHubClient,
  httpMethod: string,
  url: string,
  etag: string = ""
): tuple[code: int, body: string, etag: string] {.raises: [GitHubError, PuppyError, CatchableError].} =
  ## Make HTTP request with error handling
  
  var headers: seq[Header] = @[
    Header(key: "Accept", value: "application/vnd.github.v3+json"),
    Header(key: "User-Agent", value: "nsheep-" & Version)
  ]
  
  if client.token.len > 0:
    headers.add(Header(key: "Authorization", value: "Bearer " & client.token))
  
  if etag.len > 0:
    headers.add(Header(key: "If-None-Match", value: etag))
  
  let response = get(url, headers)
  
  # Check rate limit
  for (key, value) in response.headers:
    if key.toLowerAscii == "x-ratelimit-remaining":
      let remaining = parseInt(value)
      if remaining == 0:
        raise newException(RateLimitError, "GitHub API rate limit exceeded")
    if key.toLowerAscii == "x-ratelimit-reset":
      discard  # Could store this for retry logic
  
  case response.code
  of 200..299:
    var respEtag = ""
    for (key, value) in response.headers:
      if key.toLowerAscii == "etag":
        respEtag = value
        break
    debug "GitHub API request", url = url, status = response.code, cached = false
    result = (code: response.code, body: response.body, etag: respEtag)
  of 304:
    debug "GitHub API request", url = url, status = 304, cached = true
    result = (code: 304, body: "", etag: "")
  of 401:
    warn "GitHub authentication failed"
    raise newException(UnauthorizedError, "invalid GitHub token")
  of 404:
    raise newException(NotFoundError, "resource not found: " & url)
  of 403:
    warn "GitHub rate limit exceeded"
    raise newException(RateLimitError, "rate limited or forbidden")
  else:
    error "GitHub API error", url = url, status = response.code
    raise newException(GitHubError, "HTTP " & $response.code & ": " & response.body[0..<min(200, response.body.len)])

# --- API Methods ---

proc fetchRepository*(
  client: GitHubClient,
  repo: Repository
): tuple[description: string, stars: int, updatedAt: DateTime] {.raises: [GitHubError, PuppyError, CatchableError].} =
  ## Fetch repository metadata with ETag caching
  
  let url = "https://api.github.com/repos/" & repo.owner & "/" & repo.name
  let cacheKey = "repo:" & repo.owner & "/" & repo.name
  
  let cached = loadCache(client.cacheDir, cacheKey)
  var etag = ""
  if cached.isSome:
    etag = cached.get.etag
  
  let (code, body, respEtag) = makeRequest(client, "GET", url, etag)
  
  if code == 304:
    # Not modified - use cache
    if cached.isSome:
      let json = parseJson(cached.get.body)
      result.description = json["description"].getStr("")
      result.stars = json["stargazers_count"].getInt(0)
      result.updatedAt = parse(json["updated_at"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'")
      return
    else:
      raise newException(GitHubError, "304 without cache")
  
  # Parse fresh response
  let json = parseJson(body)
  
  if not json.hasKey("updated_at"):
    raise newException(GitHubError, "invalid GitHub response: missing updated_at")
  
  result.description = if json.hasKey("description") and json["description"].kind != JNull:
    json["description"].getStr()
  else:
    ""
  result.stars = json["stargazers_count"].getInt(0)
  result.updatedAt = parse(json["updated_at"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'")
  
  # Save to cache
  if respEtag.len > 0:
    saveCache(client.cacheDir, cacheKey, respEtag, body)

proc fetchReleases*(
  client: GitHubClient,
  repo: Repository
): seq[GitHubRelease] {.raises: [GitHubError, PuppyError, CatchableError].} =
  ## Fetch releases (not tags - releases only)
  
  let url = "https://api.github.com/repos/" & repo.owner & "/" & repo.name & "/releases?per_page=100"
  let (code, body, _) = makeRequest(client, "GET", url)
  
  let json = parseJson(body)
  if json.kind != JArray:
    raise newException(GitHubError, "expected array of releases")
  
  result = newSeq[GitHubRelease](json.len)
  for i in 0 ..< json.len:
    let item = json[i]
    if not item.hasKey("tag_name") or not item.hasKey("published_at"):
      raise newException(GitHubError, "release missing required fields")
    
    result[i] = GitHubRelease(
      tag: item["tag_name"].getStr(),
      tarballUrl: item["tarball_url"].getStr(),
      publishedAt: parse(item["published_at"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'")
    )

proc downloadTarball*(
  client: GitHubClient,
  url: string
): seq[byte] {.raises: [GitHubError, PuppyError, CatchableError].} =
  ## Download tarball bytes
  
  var headers: seq[Header] = @[Header(key: "User-Agent", value: "nsheep-" & Version)]
  if client.token.len > 0:
    headers.add(Header(key: "Authorization", value: "Bearer " & client.token))
  
  let response = get(url, headers)
  
  if response.code != 200:
    raise newException(GitHubError, "download failed: HTTP " & $response.code)
  
  # Convert string to bytes
  result = newSeq[byte](response.body.len)
  if result.len > 0:
    copyMem(addr result[0], unsafeAddr response.body[0], response.body.len)

proc fetchNimbleFile*(
  client: GitHubClient,
  repo: Repository,
  gitRef: string
): Option[string] {.raises: [GitHubError, PuppyError, CatchableError].} =
  ## Fetch nimble file content - returns none if not found (valid case)
  
  let url = "https://api.github.com/repos/" & repo.owner & "/" & repo.name & 
          "/contents/" & repo.name & ".nimble?ref=" & gitRef
  
  try:
    let (code, body, _) = makeRequest(client, "GET", url)
    let json = parseJson(body)
    
    if not json.hasKey("content"):
      return none(string)
    
    let content = json["content"].getStr().replace("\n", "")
    try:
      result = some(decode(content))
    except:
      raise newException(GitHubError, "invalid base64 in nimble file")
  except NotFoundError:
    # File doesn't exist - valid case
    result = none(string)

proc fetchReadme*(client: GitHubClient, owner, name: string): string =
  ## Fetch README.md from GitHub raw content. Returns empty string on failure.
  let url = "https://raw.githubusercontent.com/" & owner & "/" & name & "/HEAD/README.md"
  var headers: seq[Header] = @[Header(key: "User-Agent", value: "nsheep-" & Version)]
  if client.token.len > 0:
    headers.add(Header(key: "Authorization", value: "Bearer " & client.token))
  
  try:
    let response = get(url, headers)
    if response.code == 200:
      result = response.body
    else:
      debug "README fetch failed", url = url, status = response.code
      result = ""
  except:
    warn "README fetch error", url = url, error = getCurrentExceptionMsg()
    result = ""

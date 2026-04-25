##
## VCS abstraction - GitHub, GitLab, Codeberg, SourceHut, Bitbucket, and generic git
## Host-specific APIs where available; git CLI fallback for everything else.
##

import std/[json, times, strutils, base64, os, options, osproc, tempfiles, algorithm]
import chronicles
import puppy
import nsheep/types

# --- Types ---

type
  VcsHost* = enum
    vhGitHub
    vhGitLab
    vhCodeberg
    vhSourceHut
    vhBitbucket
    vhGenericGit

  RepoRef* = object
    host*: VcsHost
    url*: string        # Canonical HTTPS URL
    path*: string       # Normalized path for APIs
    apiBase*: string    # For self-hosted GitLab instances

  VersionInfo* = object
    tag*: string
    tarballUrl*: string
    publishedAt*: DateTime

  VcsError* = object of CatchableError
  VcsNotFoundError* = object of VcsError
  VcsRateLimitError* = object of VcsError

  VcsClient* = object
    token*: string
    cacheDir*: string

# --- URL Parsing ---

proc parseRepoUrl*(url: string): Option[RepoRef] =
  ## Parse any git hosting URL into a RepoRef.
  ## Returns none if the URL doesn't look like a git repository.
  
  var input = url.strip()
  if input.len == 0:
    return none(RepoRef)
  
  # Remove .git suffix
  if input.endsWith(".git"):
    input = input[0..^5]
  
  # Convert SSH format: git@host.com:path/to/repo
  if input.startsWith("git@"):
    let atIdx = input.find('@')
    let colonIdx = input.find(':', atIdx)
    if atIdx >= 0 and colonIdx > atIdx:
      let hostPart = input[atIdx+1..colonIdx-1]
      let pathPart = input[colonIdx+1..^1]
      input = "https://" & hostPart & "/" & pathPart
  
  if not input.startsWith("https://"):
    return none(RepoRef)
  
  let rest = input[8..^1]  # Remove https://
  let hostEnd = rest.find('/')
  if hostEnd < 0:
    return none(RepoRef)
  
  let hostname = rest[0..<hostEnd]
  let path = rest[hostEnd+1..^1]
  
  if path.len == 0 or path.count('/') < 1:
    return none(RepoRef)
  
  case hostname
  of "github.com":
    if path.count('/') == 1:
      result = some(RepoRef(host: vhGitHub, url: input, path: path))
  of "gitlab.com":
    result = some(RepoRef(host: vhGitLab, url: input, path: path, apiBase: "https://gitlab.com"))
  of "codeberg.org":
    if path.count('/') == 1:
      result = some(RepoRef(host: vhCodeberg, url: input, path: path))
  of "bitbucket.org":
    if path.count('/') == 1:
      result = some(RepoRef(host: vhBitbucket, url: input, path: path))
  of "git.sr.ht":
    if path.startsWith("~") and path.count('/') == 1:
      result = some(RepoRef(host: vhSourceHut, url: input, path: path))
  else:
    # Self-hosted GitLab or other unknown git host
    if hostname.contains("gitlab"):
      result = some(RepoRef(host: vhGitLab, url: input, path: path, apiBase: "https://" & hostname))
    else:
      result = some(RepoRef(host: vhGenericGit, url: input, path: path))

# --- HTTP Helpers ---

type
  CachedResponse = object
    etag*: string
    body*: string
    cachedAt*: DateTime

proc cachePath(cacheDir, key: string): string =
  let safeKey = key.replace("/", "_").replace(":", "_")
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
    if (getTime() - fromUnix(timestamp)).inHours > 1:
      return none(CachedResponse)
    result = some(CachedResponse(etag: etag, body: body, cachedAt: fromUnix(timestamp).utc()))
  except:
    return none(CachedResponse)

proc saveCache(cacheDir, key: string, etag, body: string) =
  createDir(cacheDir)
  let path = cachePath(cacheDir, key)
  writeFile(path, etag & "\n" & $getTime().toUnix & "\n" & body)

proc makeRequest(
  client: VcsClient,
  url: string,
  headers: seq[Header] = @[],
  etag: string = ""
): tuple[code: int, body: string, etag: string] =
  var reqHeaders = headers
  if client.token.len > 0:
    reqHeaders.add(Header(key: "Authorization", value: "Bearer " & client.token))
  if etag.len > 0:
    reqHeaders.add(Header(key: "If-None-Match", value: etag))
  
  let response = get(url, reqHeaders)
  
  var respEtag = ""
  for (key, value) in response.headers:
    if key.toLowerAscii == "etag":
      respEtag = value
      break
  
  result = (code: response.code, body: response.body, etag: respEtag)

proc getJson(client: VcsClient, url, cacheKey: string): JsonNode =
  let cached = loadCache(client.cacheDir, cacheKey)
  var etag = ""
  if cached.isSome:
    etag = cached.get.etag
  
  let (code, body, respEtag) = makeRequest(client, url, @[
    Header(key: "User-Agent", value: "nsheep-" & Version),
    Header(key: "Accept", value: "application/json")
  ], etag)
  
  if code == 304 and cached.isSome:
    result = parseJson(cached.get.body)
    return
  
  if code >= 400:
    raise newException(VcsError, "HTTP " & $code & ": " & body[0..<min(200, body.len)])
  
  result = parseJson(body)
  
  if respEtag.len > 0:
    saveCache(client.cacheDir, cacheKey, respEtag, body)

proc downloadHttp*(url, token: string): seq[byte] =
  var headers: seq[Header] = @[Header(key: "User-Agent", value: "nsheep-" & Version)]
  if token.len > 0:
    headers.add(Header(key: "Authorization", value: "Bearer " & token))
  let response = get(url, headers)
  if response.code != 200:
    raise newException(VcsError, "download failed: HTTP " & $response.code)
  result = newSeq[byte](response.body.len)
  if result.len > 0:
    copyMem(addr result[0], unsafeAddr response.body[0], response.body.len)

proc initVcsClient*(token, cacheDir: string): VcsClient =
  VcsClient(token: token, cacheDir: cacheDir)

# --- GitHub ---

proc githubFetchMeta(client: VcsClient, repo: RepoRef): (string, DateTime) =
  let url = "https://api.github.com/repos/" & repo.path
  let cacheKey = "gh:repo:" & repo.path
  let json = getJson(client, url, cacheKey)
  
  let desc = if json.hasKey("description") and json["description"].kind != JNull:
    json["description"].getStr() else: ""
  let updatedAt = if json.hasKey("updated_at"):
    try: parse(json["updated_at"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'") except: now()
    else: now()
  
  result = (desc, updatedAt)

proc githubFetchVersions(client: VcsClient, repo: RepoRef): seq[VersionInfo] =
  let url = "https://api.github.com/repos/" & repo.path & "/releases?per_page=100"
  let cacheKey = "gh:releases:" & repo.path
  let json = getJson(client, url, cacheKey)
  
  if json.kind != JArray:
    raise newException(VcsError, "expected array of releases")
  
  for item in json:
    if not item.hasKey("tag_name") or not item.hasKey("published_at"):
      continue
    let tag = item["tag_name"].getStr()
    let tarballUrl = if item.hasKey("tarball_url"): item["tarball_url"].getStr() else: ""
    let publishedAt = try:
      parse(item["published_at"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'")
    except: now()
    
    result.add(VersionInfo(tag: tag, tarballUrl: tarballUrl, publishedAt: publishedAt))

proc githubFetchNimbleFile(client: VcsClient, repo: RepoRef, tag: string): Option[string] =
  let parts = repo.path.split('/')
  let repoName = parts[^1]
  let url = "https://api.github.com/repos/" & repo.path & "/contents/" & repoName & ".nimble?ref=" & tag
  try:
    let (code, body, _) = makeRequest(client, url, @[
      Header(key: "User-Agent", value: "nsheep-" & Version),
      Header(key: "Accept", value: "application/vnd.github.v3+json")
    ])
    if code == 404:
      return none(string)
    if code != 200:
      raise newException(VcsError, "HTTP " & $code)
    let json = parseJson(body)
    if not json.hasKey("content"):
      return none(string)
    let content = json["content"].getStr().replace("\n", "")
    result = some(decode(content))
  except VcsNotFoundError:
    result = none(string)

proc githubFetchReadme(client: VcsClient, repo: RepoRef, tag: string): string =
  let url = "https://raw.githubusercontent.com/" & repo.path & "/" & tag & "/README.md"
  try:
    result = cast[string](downloadHttp(url, client.token))
  except:
    result = ""

# --- GitLab ---

proc gitlabEncodedPath(path: string): string =
  result = path.replace("/", "%2F")

proc gitlabFetchMeta(client: VcsClient, repo: RepoRef): (string, DateTime) =
  let url = repo.apiBase & "/api/v4/projects/" & gitlabEncodedPath(repo.path)
  let cacheKey = "gl:repo:" & repo.path
  let json = getJson(client, url, cacheKey)
  
  let desc = if json.hasKey("description") and json["description"].kind != JNull:
    json["description"].getStr() else: ""
  let updatedAt = if json.hasKey("last_activity_at"):
    try: parse(json["last_activity_at"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'") except: now()
    else: now()
  
  result = (desc, updatedAt)

proc gitlabFetchVersions(client: VcsClient, repo: RepoRef): seq[VersionInfo] =
  let url = repo.apiBase & "/api/v4/projects/" & gitlabEncodedPath(repo.path) & "/repository/tags?per_page=100"
  let cacheKey = "gl:tags:" & repo.path
  let json = getJson(client, url, cacheKey)
  
  if json.kind != JArray:
    return
  
  let repoName = repo.path.split('/')[^1]
  for item in json:
    if not item.hasKey("name"):
      continue
    let tag = item["name"].getStr()
    let tarballUrl = repo.apiBase & "/" & repo.path & "/-/archive/" & tag & "/" & repoName & "-" & tag & ".tar.gz"
    let publishedAt = if item.hasKey("commit") and item["commit"].hasKey("committed_date"):
      try: parse(item["commit"]["committed_date"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'") except: now()
      else: now()
    
    result.add(VersionInfo(tag: tag, tarballUrl: tarballUrl, publishedAt: publishedAt))

proc gitlabFetchFile(client: VcsClient, repo: RepoRef, tag, filename: string): Option[string] =
  let url = repo.apiBase & "/" & repo.path & "/-/raw/" & tag & "/" & filename
  try:
    let data = downloadHttp(url, client.token)
    result = some(cast[string](data))
  except:
    result = none(string)

proc gitlabFetchReadme(client: VcsClient, repo: RepoRef, tag: string): string =
  let opt = gitlabFetchFile(client, repo, tag, "README.md")
  if opt.isSome: result = opt.get() else: result = ""

# --- Codeberg (Gitea/Forgejo) ---

proc codebergFetchMeta(client: VcsClient, repo: RepoRef): (string, DateTime) =
  let url = "https://codeberg.org/api/v1/repos/" & repo.path
  let cacheKey = "cb:repo:" & repo.path
  let json = getJson(client, url, cacheKey)
  
  let desc = if json.hasKey("description") and json["description"].kind != JNull:
    json["description"].getStr() else: ""
  let updatedAt = if json.hasKey("updated_at"):
    try: parse(json["updated_at"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'") except: now()
    else: now()
  
  result = (desc, updatedAt)

proc codebergFetchVersions(client: VcsClient, repo: RepoRef): seq[VersionInfo] =
  let url = "https://codeberg.org/api/v1/repos/" & repo.path & "/tags?page=-1"
  let cacheKey = "cb:tags:" & repo.path
  let json = getJson(client, url, cacheKey)
  
  if json.kind != JArray:
    return
  
  for item in json:
    if not item.hasKey("name"):
      continue
    let tag = item["name"].getStr()
    let tarballUrl = "https://codeberg.org/" & repo.path & "/archive/" & tag & ".tar.gz"
    let publishedAt = if item.hasKey("commit") and item["commit"].hasKey("timestamp"):
      try: parse(item["commit"]["timestamp"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'") except: now()
      else: now()
    
    result.add(VersionInfo(tag: tag, tarballUrl: tarballUrl, publishedAt: publishedAt))

proc codebergFetchFile(client: VcsClient, repo: RepoRef, tag, filename: string): Option[string] =
  let url = "https://codeberg.org/" & repo.path & "/raw/tag/" & tag & "/" & filename
  try:
    let data = downloadHttp(url, client.token)
    result = some(cast[string](data))
  except:
    result = none(string)

proc codebergFetchReadme(client: VcsClient, repo: RepoRef, tag: string): string =
  let opt = codebergFetchFile(client, repo, tag, "README.md")
  if opt.isSome: result = opt.get() else: result = ""

# --- Bitbucket ---

proc bitbucketFetchMeta(client: VcsClient, repo: RepoRef): (string, DateTime) =
  let url = "https://api.bitbucket.org/2.0/repositories/" & repo.path
  let cacheKey = "bb:repo:" & repo.path
  let json = getJson(client, url, cacheKey)
  
  let desc = if json.hasKey("description") and json["description"].kind != JNull:
    json["description"].getStr() else: ""
  let updatedAt = if json.hasKey("updated_on"):
    try: parse(json["updated_on"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'") except: now()
    else: now()
  
  result = (desc, updatedAt)

proc bitbucketFetchVersions(client: VcsClient, repo: RepoRef): seq[VersionInfo] =
  let url = "https://api.bitbucket.org/2.0/repositories/" & repo.path & "/refs/tags?pagelen=100"
  let cacheKey = "bb:tags:" & repo.path
  let json = getJson(client, url, cacheKey)
  
  if not json.hasKey("values"):
    return
  
  for item in json["values"]:
    if not item.hasKey("name"):
      continue
    let tag = item["name"].getStr()
    let tarballUrl = "https://bitbucket.org/" & repo.path & "/get/" & tag & ".tar.gz"
    let publishedAt = if item.hasKey("target") and item["target"].hasKey("date"):
      try: parse(item["target"]["date"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'") except: now()
      else: now()
    
    result.add(VersionInfo(tag: tag, tarballUrl: tarballUrl, publishedAt: publishedAt))

proc bitbucketFetchFile(client: VcsClient, repo: RepoRef, tag, filename: string): Option[string] =
  let url = "https://bitbucket.org/" & repo.path & "/raw/" & tag & "/" & filename
  try:
    let data = downloadHttp(url, client.token)
    result = some(cast[string](data))
  except:
    result = none(string)

proc bitbucketFetchReadme(client: VcsClient, repo: RepoRef, tag: string): string =
  let opt = bitbucketFetchFile(client, repo, tag, "README.md")
  if opt.isSome: result = opt.get() else: result = ""

# --- Generic Git Fallback ---

proc genericGitFetchVersions*(repo: RepoRef): seq[VersionInfo] =
  ## List tags using git ls-remote; slow but works for any git host.
  let tempDir = createTempDir("nsheep", "git")
  defer: removeDir(tempDir)
  
  let cmd = "git ls-remote --tags " & repo.url.quoteShell & " 2>&1"
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    raise newException(VcsError, "git ls-remote failed: " & output)
  
  for line in output.splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    let parts = trimmed.split('\t')
    if parts.len < 2:
      continue
    let refName = parts[1]
    if not refName.startsWith("refs/tags/"):
      continue
    # Skip dereferenced annotated tags (^{})
    if refName.endsWith("^{}"):
      continue
    
    let tag = refName[10..^1]  # Remove "refs/tags/"
    result.add(VersionInfo(tag: tag, tarballUrl: "", publishedAt: now()))
  
  # Sort by semver-like ordering (newest first) where possible
  result.sort(proc (a, b: VersionInfo): int =
    # Simple string comparison fallback
    cmp(b.tag, a.tag)
  )

proc genericGitDownloadTarball*(repo: RepoRef, tag: string): seq[byte] =
  ## Clone and archive a specific tag. Slow but universal.
  let tempDir = createTempDir("nsheep", "gitdl")
  defer: removeDir(tempDir)
  
  let repoName = repo.path.split('/')[^1]
  let cloneDir = tempDir / repoName
  
  let cloneCmd = "git clone --depth 1 --branch " & tag.quoteShell & " " & repo.url.quoteShell & " " & cloneDir.quoteShell & " 2>&1"
  let (cloneOut, cloneExit) = execCmdEx(cloneCmd)
  if cloneExit != 0:
    raise newException(VcsError, "git clone failed: " & cloneOut)
  
  let tarPath = tempDir / "archive.tar.gz"
  let tarCmd = "tar czf " & tarPath.quoteShell & " -C " & tempDir.quoteShell & " " & repoName.quoteShell & " 2>&1"
  let (tarOut, tarExit) = execCmdEx(tarCmd)
  if tarExit != 0:
    raise newException(VcsError, "tar failed: " & tarOut)
  
  let fileSize = getFileSize(tarPath)
  result = newSeq[byte](fileSize)
  var f: File
  if open(f, tarPath, fmRead):
    defer: close(f)
    if fileSize > 0:
      discard f.readBuffer(addr result[0], fileSize)
  else:
    raise newException(VcsError, "cannot read tarball: " & tarPath)

proc genericGitFetchFile*(repo: RepoRef, tag, filename: string): Option[string] =
  ## Fetch a single file via shallow clone + read.
  let tempDir = createTempDir("nsheep", "gitfile")
  defer: removeDir(tempDir)
  
  let cloneCmd = "git clone --depth 1 --branch " & tag.quoteShell & " " & repo.url.quoteShell & " " & tempDir.quoteShell & " 2>&1"
  let (cloneOut, cloneExit) = execCmdEx(cloneCmd)
  if cloneExit != 0:
    return none(string)
  
  let filePath = tempDir / filename
  if fileExists(filePath):
    return some(readFile(filePath))
  
  # Fallback: find any .nimble file
  if filename.endsWith(".nimble"):
    for file in walkFiles(tempDir / "*.nimble"):
      return some(readFile(file))
  
  return none(string)

proc genericGitFetchReadme(repo: RepoRef, tag: string): string =
  let opt = genericGitFetchFile(repo, tag, "README.md")
  if opt.isSome: result = opt.get() else: result = ""

# --- SourceHut ---

proc sourcehutFetchVersions(repo: RepoRef): seq[VersionInfo] =
  ## SourceHut: use git ls-remote for tags; archive URLs are predictable.
  result = genericGitFetchVersions(repo)
  # Override tarball URLs to use SourceHut archive format
  for i in 0 ..< result.len:
    result[i].tarballUrl = "https://git.sr.ht/" & repo.path & "/archive/" & result[i].tag & ".tar.gz"

proc sourcehutFetchFile(repo: RepoRef, tag, filename: string): Option[string] =
  ## SourceHut raw file access via git show
  genericGitFetchFile(repo, tag, filename)

proc sourcehutFetchReadme(repo: RepoRef, tag: string): string =
  let opt = sourcehutFetchFile(repo, tag, "README.md")
  if opt.isSome: result = opt.get() else: result = ""

# --- Unified Public API ---

proc fetchRepoMeta*(client: VcsClient, repo: RepoRef): (string, DateTime) =
  ## Fetch repository description and last-updated time.
  try:
    case repo.host
    of vhGitHub: result = githubFetchMeta(client, repo)
    of vhGitLab: result = gitlabFetchMeta(client, repo)
    of vhCodeberg: result = codebergFetchMeta(client, repo)
    of vhBitbucket: result = bitbucketFetchMeta(client, repo)
    of vhSourceHut, vhGenericGit:
      result = ("", now())
  except CatchableError as e:
    warn "VCS metadata fetch failed", host = $repo.host, path = repo.path, error = e.msg
    result = ("", now())

proc fetchVersions*(client: VcsClient, repo: RepoRef): seq[VersionInfo] =
  ## Fetch all available versions/tags.
  try:
    case repo.host
    of vhGitHub: result = githubFetchVersions(client, repo)
    of vhGitLab: result = gitlabFetchVersions(client, repo)
    of vhCodeberg: result = codebergFetchVersions(client, repo)
    of vhBitbucket: result = bitbucketFetchVersions(client, repo)
    of vhSourceHut: result = sourcehutFetchVersions(repo)
    of vhGenericGit: result = genericGitFetchVersions(repo)
  except CatchableError as e:
    warn "VCS version fetch failed", host = $repo.host, path = repo.path, error = e.msg
    raise

proc downloadTarball*(client: VcsClient, repo: RepoRef, ver: VersionInfo): seq[byte] =
  ## Download tarball bytes for a specific version.
  case repo.host
  of vhGitHub:
    result = downloadHttp(ver.tarballUrl, client.token)
  of vhGitLab, vhCodeberg, vhBitbucket:
    if ver.tarballUrl.len > 0:
      result = downloadHttp(ver.tarballUrl, client.token)
    else:
      raise newException(VcsError, "no tarball URL for " & repo.path & " @ " & ver.tag)
  of vhSourceHut:
    if ver.tarballUrl.len > 0:
      result = downloadHttp(ver.tarballUrl, client.token)
    else:
      result = genericGitDownloadTarball(repo, ver.tag)
  of vhGenericGit:
    result = genericGitDownloadTarball(repo, ver.tag)

proc fetchNimbleFile*(client: VcsClient, repo: RepoRef, tag: string): Option[string] =
  ## Fetch the .nimble file content for a tag.
  let repoName = repo.path.split('/')[^1]
  let filename = repoName & ".nimble"
  
  try:
    case repo.host
    of vhGitHub: result = githubFetchNimbleFile(client, repo, tag)
    of vhGitLab: result = gitlabFetchFile(client, repo, tag, filename)
    of vhCodeberg: result = codebergFetchFile(client, repo, tag, filename)
    of vhBitbucket: result = bitbucketFetchFile(client, repo, tag, filename)
    of vhSourceHut, vhGenericGit:
      result = genericGitFetchFile(repo, tag, filename)
  except CatchableError as e:
    warn "Nimble file fetch failed", host = $repo.host, path = repo.path, tag = tag, error = e.msg
    result = none(string)

proc fetchReadme*(client: VcsClient, repo: RepoRef, tag: string): string =
  ## Fetch README.md content for a tag.
  try:
    case repo.host
    of vhGitHub: result = githubFetchReadme(client, repo, tag)
    of vhGitLab: result = gitlabFetchReadme(client, repo, tag)
    of vhCodeberg: result = codebergFetchReadme(client, repo, tag)
    of vhBitbucket: result = bitbucketFetchReadme(client, repo, tag)
    of vhSourceHut: result = sourcehutFetchReadme(repo, tag)
    of vhGenericGit: result = genericGitFetchReadme(repo, tag)
  except CatchableError as e:
    warn "README fetch failed", host = $repo.host, path = repo.path, tag = tag, error = e.msg
    result = ""

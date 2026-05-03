##
## VCS abstraction - GitHub, GitLab, Codeberg, SourceHut, Bitbucket, and generic git
## Host-specific APIs where available; git CLI fallback for everything else.
##

import std/[json, times, strutils, base64, os, options, osproc, tempfiles, algorithm, uri]
import chronicles
import puppy
import nsheep/types

# --- Types ---

type
  VcsHost* = enum
    vhGitHub
    vhGitLab
    vhCodeberg
    vhGitea
    vhSourceHut
    vhBitbucket
    vhGenericGit

  RepoRef* = object
    host*: VcsHost
    url*: string     # Canonical HTTPS URL
    path*: string    # Normalized path for APIs
    apiBase*: string # For self-hosted GitLab instances
    subdir*: string  # Subdirectory inside the repo (from ?subdir= query param)

  VersionInfo* = object
    tag*: string
    tarballUrl*: string
    publishedAt*: DateTime
    commitSha*: string ## Git commit SHA for this version (HEAD or tag)

  VcsError* = object of CatchableError
  VcsNotFoundError* = object of VcsError
  VcsRateLimitError* = object of VcsError

  VcsClient* = object
    githubToken*: string
    gitlabToken*: string
    codebergToken*: string
    bitbucketToken*: string
    sourcehutToken*: string
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

  # Upgrade http:// to https://
  if input.startsWith("http://"):
    input = "https://" & input[7..^1]

  # Strip fragment first, then extract ?subdir=...
  let fragmentIdx = input.find('#')
  if fragmentIdx >= 0:
    input = input[0..<fragmentIdx]

  var subdir = ""
  let queryIdx = input.find('?')
  if queryIdx >= 0:
    let query = input[queryIdx+1..^1]
    for part in query.split('&'):
      if part.startsWith("subdir="):
        subdir = part[7..^1]
        break
    input = input[0..<queryIdx]

  if not input.startsWith("https://"):
    return none(RepoRef)

  input = input.strip(leading = false, trailing = true, chars = {'/'})

  let rest = input[8..^1] # Remove https://
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
      result = some(RepoRef(host: vhGitHub, url: input, path: path, subdir: subdir))
  of "gitlab.com":
    result = some(RepoRef(host: vhGitLab, url: input, path: path, apiBase: "https://gitlab.com", subdir: subdir))
  of "codeberg.org":
    if path.count('/') == 1:
      result = some(RepoRef(host: vhCodeberg, url: input, path: path, subdir: subdir))
  of "bitbucket.org":
    if path.count('/') == 1:
      result = some(RepoRef(host: vhBitbucket, url: input, path: path, subdir: subdir))
  of "git.sr.ht":
    if path.startsWith("~") and path.count('/') == 1:
      result = some(RepoRef(host: vhSourceHut, url: input, path: path, subdir: subdir))
  else:
    # Self-hosted GitLab: only match *.gitlab.com and gitlab.com
    if hostname == "gitlab.com" or hostname.endsWith(".gitlab.com"):
      result = some(RepoRef(host: vhGitLab, url: input, path: path, apiBase: "https://" & hostname, subdir: subdir))
    else:
      result = some(RepoRef(host: vhGenericGit, url: input, path: path, subdir: subdir))

proc subdirPath*(repo: RepoRef, filename: string): string =
  ## Prepend repo.subdir to filename if present.
  if repo.subdir.len > 0:
    result = repo.subdir & "/" & filename
  else:
    result = filename

proc hostBaseUrl*(repo: RepoRef): string =
  ## Extract scheme + hostname from repo.url.
  let uri = parseUri(repo.url)
  result = uri.scheme & "://" & uri.hostname

proc detectHostType*(client: VcsClient, repo: RepoRef): RepoRef =
  ## For generic git repos, probe APIs to detect GitLab or Gitea.
  ## Returns the original repo if already known or detection fails.
  if repo.host != vhGenericGit:
    return repo

  let ua = Header(key: "User-Agent", value: "nsheep-" & Version)

  # Try GitLab API v4
  let glUrl = hostBaseUrl(repo) & "/api/v4/projects/" & repo.path.replace("/", "%2F")
  try:
    let resp = get(glUrl, @[ua], timeout = 10.float32)
    if resp.code == 200:
      let json = parseJson(resp.body)
      if json.hasKey("id"):
        return RepoRef(host: vhGitLab, url: repo.url, path: repo.path,
                       apiBase: hostBaseUrl(repo), subdir: repo.subdir)
  except:
    discard

  # Try Gitea API v1
  let gtUrl = hostBaseUrl(repo) & "/api/v1/repos/" & repo.path
  try:
    let resp = get(gtUrl, @[ua], timeout = 10.float32)
    if resp.code == 200:
      let json = parseJson(resp.body)
      if json.hasKey("id"):
        return RepoRef(host: vhGitea, url: repo.url, path: repo.path, subdir: repo.subdir)
  except:
    discard

  return repo

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
  try:
    writeFile(path, etag & "\n" & $getTime().toUnix & "\n" & body)
  except CatchableError:
    discard

proc isGitHubUrl(url: string): bool =
  url.startsWith("https://github.com") or
  url.startsWith("https://api.github.com") or
  url.startsWith("https://raw.githubusercontent.com") or
  url.startsWith("https://codeload.github.com")

proc isGitLabUrl(url: string): bool =
  let host = parseUri(url).hostname.toLowerAscii
  host == "gitlab.com" or host.endsWith(".gitlab.com")

proc isCodebergUrl(url: string): bool =
  url.startsWith("https://codeberg.org")

proc isBitbucketUrl(url: string): bool =
  url.startsWith("https://bitbucket.org")

proc isSourceHutUrl(url: string): bool =
  url.startsWith("https://git.sr.ht")

proc tokenForUrl(client: VcsClient, url: string): string =
  if isGitHubUrl(url): client.githubToken
  elif isGitLabUrl(url): client.gitlabToken
  elif isCodebergUrl(url): client.codebergToken
  elif isBitbucketUrl(url): client.bitbucketToken
  elif isSourceHutUrl(url): client.sourcehutToken
  else: ""

proc makeRequest(
  client: VcsClient,
  url: string,
  headers: seq[Header] = @[],
  etag: string = "",
  timeout: int = 10
): tuple[code: int, body: string, etag: string] =
  var reqHeaders = headers
  let token = tokenForUrl(client, url)
  if token.len > 0:
    reqHeaders.add(Header(key: "Authorization", value: "Bearer " & token))
  if etag.len > 0:
    reqHeaders.add(Header(key: "If-None-Match", value: etag))

  let response = get(url, reqHeaders, timeout = timeout.float32)

  var respEtag = ""
  for (key, value) in response.headers:
    if key.toLowerAscii == "etag":
      respEtag = value
      break

  result = (code: response.code, body: response.body, etag: respEtag)

proc gitlabGraphQL(client: VcsClient, apiBase, query: string): JsonNode =
  ## Query GitLab GraphQL API via POST (avoids %2F URL encoding issues).
  let payload = %*{"query": query}
  let req = newRequest(apiBase & "/api/graphql")
  req.verb = "POST"
  req.headers = @[
    Header(key: "Content-Type", value: "application/json"),
    Header(key: "Accept", value: "application/json")
  ]
  if client.gitlabToken.len > 0:
    req.headers.add(Header(key: "Authorization", value: "Bearer " & client.gitlabToken))
  req.body = $payload

  let resp = fetch(req)
  if resp.code != 200:
    raise newException(VcsError, "GraphQL failed: HTTP " & $resp.code)

  let json = parseJson(resp.body)
  if json.hasKey("errors"):
    let errors = json["errors"]
    if errors.len > 0:
      raise newException(VcsError, "GraphQL error: " & errors[0]["message"].getStr())
  result = json["data"]

proc getJson(client: VcsClient, url, cacheKey: string): JsonNode =
  let cached = loadCache(client.cacheDir, cacheKey)
  var etag = ""
  if cached.isSome:
    etag = cached.get.etag

  let (code, body, respEtag) = makeRequest(client, url, @[
    Header(key: "User-Agent", value: "nsheep-" & Version),
    Header(key: "Accept", value: "application/json"),
    Header(key: "Accept-Encoding", value: "identity")
  ], etag)

  if code == 304 and cached.isSome:
    try:
      result = parseJson(cached.get.body)
    except JsonParsingError:
      raise newException(VcsError, "cached JSON is corrupted for " & cacheKey)
    return

  if code == 404:
    raise newException(VcsNotFoundError, "HTTP 404: " & body[0..<min(200, body.len)])
  if code >= 400:
    raise newException(VcsError, "HTTP " & $code & ": " & body[0..<min(200, body.len)])

  try:
    result = parseJson(body)
  except JsonParsingError:
    raise newException(VcsError, "invalid JSON response from " & url)

  if respEtag.len > 0:
    saveCache(client.cacheDir, cacheKey, respEtag, body)

proc downloadHttp*(url, token: string, timeout: int = 120): seq[byte] =
  var headers: seq[Header] = @[Header(key: "User-Agent", value: "nsheep-" & Version)]
  if token.len > 0:
    headers.add(Header(key: "Authorization", value: "Bearer " & token))
  let response = get(url, headers, timeout = timeout.float32)
  if response.code != 200:
    raise newException(VcsError, "download failed: HTTP " & $response.code)
  result = newSeq[byte](response.body.len)
  if result.len > 0:
    copyMem(addr result[0], unsafeAddr response.body[0], response.body.len)

proc initVcsClient*(githubToken, gitlabToken, codebergToken, bitbucketToken, sourcehutToken,
    cacheDir: string): VcsClient =
  VcsClient(
    githubToken: githubToken,
    gitlabToken: gitlabToken,
    codebergToken: codebergToken,
    bitbucketToken: bitbucketToken,
    sourcehutToken: sourcehutToken,
    cacheDir: cacheDir
  )

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

proc githubFetchNimbleFile(client: VcsClient, repo: RepoRef, tag, filename: string): Option[string] =
  let refName = if tag == "#head": "HEAD" else: tag
  let url = "https://api.github.com/repos/" & repo.path & "/contents/" & filename & "?ref=" & refName
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

proc githubFetchReadme(client: VcsClient, repo: RepoRef, tag, path: string): string =
  let refName = if tag == "#head": "HEAD" else: tag
  let url = "https://raw.githubusercontent.com/" & repo.path & "/" & refName & "/" & path
  try:
    result = cast[string](downloadHttp(url, client.githubToken))
  except:
    result = ""

# --- GitLab ---

proc gitlabEncodedPath(path: string): string =
  result = path.replace("/", "%2F")

proc gitlabFetchMeta(client: VcsClient, repo: RepoRef): (string, DateTime) =
  let query = "query { project(fullPath: \"" & repo.path & "\") { description lastActivityAt } }"
  let gqlData = gitlabGraphQL(client, repo.apiBase, query)

  if gqlData.hasKey("project") and gqlData["project"].kind != JNull:
    let project = gqlData["project"]
    let desc = if project.hasKey("description") and project["description"].kind != JNull:
      project["description"].getStr() else: ""
    let updatedAt = if project.hasKey("lastActivityAt"):
      try: parse(project["lastActivityAt"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'") except: now()
      else: now()
    result = (desc, updatedAt)
  else:
    raise newException(VcsNotFoundError, "GitLab project not found: " & repo.path)

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
    let data = downloadHttp(url, client.gitlabToken)
    result = some(cast[string](data))
  except:
    result = none(string)

proc gitlabFetchReadme(client: VcsClient, repo: RepoRef, tag, path: string): string =
  let opt = gitlabFetchFile(client, repo, tag, path)
  if opt.isSome: result = opt.get() else: result = ""

# --- Codeberg / Gitea / Forgejo ---

proc giteaFetchMeta(client: VcsClient, repo: RepoRef): (string, DateTime) =
  let url = hostBaseUrl(repo) & "/api/v1/repos/" & repo.path
  let cacheKey = "gt:repo:" & repo.path
  let json = getJson(client, url, cacheKey)

  let desc = if json.hasKey("description") and json["description"].kind != JNull:
    json["description"].getStr() else: ""
  let updatedAt = if json.hasKey("updated_at"):
    try: parse(json["updated_at"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'") except: now()
    else: now()

  result = (desc, updatedAt)

proc giteaFetchVersions(client: VcsClient, repo: RepoRef): seq[VersionInfo] =
  let url = hostBaseUrl(repo) & "/api/v1/repos/" & repo.path & "/tags?page=-1"
  let cacheKey = "gt:tags:" & repo.path
  let json = getJson(client, url, cacheKey)

  if json.kind != JArray:
    return

  for item in json:
    if not item.hasKey("name"):
      continue
    let tag = item["name"].getStr()
    let tarballUrl = hostBaseUrl(repo) & "/" & repo.path & "/archive/" & tag & ".tar.gz"
    var publishedAt = now()
    if item.hasKey("commit"):
      let commit = item["commit"]
      let dateStr = if commit.hasKey("timestamp"):
        commit["timestamp"].getStr()
      elif commit.hasKey("created"):
        commit["created"].getStr()
      else:
        ""
      if dateStr.len > 0:
        try:
          publishedAt = parse(dateStr, "yyyy-MM-dd'T'HH:mm:ss'Z'")
        except:
          publishedAt = now()

    result.add(VersionInfo(tag: tag, tarballUrl: tarballUrl, publishedAt: publishedAt))

proc giteaFetchFile(client: VcsClient, repo: RepoRef, tag, filename: string): Option[string] =
  let url = hostBaseUrl(repo) & "/" & repo.path & "/raw/tag/" & tag & "/" & filename
  try:
    let data = downloadHttp(url, client.codebergToken)
    result = some(cast[string](data))
  except:
    result = none(string)

proc giteaFetchReadme(client: VcsClient, repo: RepoRef, tag, path: string): string =
  let opt = giteaFetchFile(client, repo, tag, path)
  if opt.isSome: result = opt.get() else: result = ""

proc giteaFetchHeadVersion(client: VcsClient, repo: RepoRef): Option[VersionInfo] =
  ## Fetch latest HEAD commit for Gitea/Codeberg/Forgejo.
  let base = hostBaseUrl(repo)
  let repoUrl = base & "/api/v1/repos/" & repo.path
  let cacheKey = "gt:head:" & repo.path
  try:
    # First get default branch from repo metadata
    let repoJson = getJson(client, repoUrl, cacheKey & ":repo")
    let defaultBranch = if repoJson.hasKey("default_branch"):
      repoJson["default_branch"].getStr() else: "main"

    let commitsUrl = base & "/api/v1/repos/" & repo.path & "/commits?limit=1"
    let json = getJson(client, commitsUrl, cacheKey)
    if json.kind != JArray or json.len == 0:
      return none(VersionInfo)
    let commit = json[0]
    let commitDate = if commit.hasKey("commit") and commit["commit"].hasKey("committer") and commit["commit"][
        "committer"].hasKey("date"):
      try: parse(commit["commit"]["committer"]["date"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'") except: now()
      else: now()
    let tarballUrl = base & "/" & repo.path & "/archive/" & defaultBranch & ".tar.gz"
    let sha = if commit.hasKey("sha"): commit["sha"].getStr() else: ""
    result = some(VersionInfo(tag: "#head", tarballUrl: tarballUrl, publishedAt: commitDate, commitSha: sha))
  except CatchableError as e:
    warn "Failed to fetch HEAD for Gitea repo", repo = repo.path, error = e.msg
    result = none(VersionInfo)

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
    let data = downloadHttp(url, client.bitbucketToken)
    result = some(cast[string](data))
  except:
    result = none(string)

proc bitbucketFetchReadme(client: VcsClient, repo: RepoRef, tag, path: string): string =
  let opt = bitbucketFetchFile(client, repo, tag, path)
  if opt.isSome: result = opt.get() else: result = ""

proc githubFetchHeadVersion(client: VcsClient, repo: RepoRef): Option[VersionInfo] =
  ## Fetch latest HEAD commit as a fallback for repos without releases.
  let url = "https://api.github.com/repos/" & repo.path & "/commits?per_page=1"
  let cacheKey = "gh:head:" & repo.path
  try:
    let json = getJson(client, url, cacheKey)
    if json.kind != JArray or json.len == 0:
      return none(VersionInfo)
    let commit = json[0]
    let commitDate = if commit.hasKey("commit") and commit["commit"].hasKey("committer") and commit["commit"][
        "committer"].hasKey("date"):
      try: parse(commit["commit"]["committer"]["date"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'") except: now()
      else: now()
    let tarballUrl = "https://api.github.com/repos/" & repo.path & "/tarball/HEAD"
    let sha = if commit.hasKey("sha"): commit["sha"].getStr() else: ""
    result = some(VersionInfo(tag: "#head", tarballUrl: tarballUrl, publishedAt: commitDate, commitSha: sha))
  except CatchableError as e:
    warn "Failed to fetch HEAD for GitHub repo", repo = repo.path, error = e.msg
    result = none(VersionInfo)

proc gitlabFetchHeadVersion(client: VcsClient, repo: RepoRef): Option[VersionInfo] =
  ## Fetch latest HEAD commit for GitLab.
  let url = repo.apiBase & "/api/v4/projects/" & gitlabEncodedPath(repo.path) & "/repository/commits?per_page=1"
  let cacheKey = "gl:head:" & repo.path
  try:
    let json = getJson(client, url, cacheKey)
    if json.kind != JArray or json.len == 0:
      return none(VersionInfo)
    let commit = json[0]
    let commitDate = if commit.hasKey("committed_date"):
      try: parse(commit["committed_date"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'") except: now()
      else: now()
    let repoName = repo.path.split('/')[^1]
    let tarballUrl = repo.apiBase & "/" & repo.path & "/-/archive/HEAD/" & repoName & "-HEAD.tar.gz"
    let sha = if commit.hasKey("id"): commit["id"].getStr() else: ""
    result = some(VersionInfo(tag: "#head", tarballUrl: tarballUrl, publishedAt: commitDate, commitSha: sha))
  except CatchableError as e:
    warn "Failed to fetch HEAD for GitLab repo", repo = repo.path, error = e.msg
    result = none(VersionInfo)

proc codebergFetchHeadVersion(client: VcsClient, repo: RepoRef): Option[VersionInfo] =
  ## Fetch latest HEAD commit for Codeberg.
  let url = "https://codeberg.org/api/v1/repos/" & repo.path & "/commits?limit=1"
  let cacheKey = "cb:head:" & repo.path
  try:
    let json = getJson(client, url, cacheKey)
    if json.kind != JArray or json.len == 0:
      return none(VersionInfo)
    let commit = json[0]
    let commitDate = if commit.hasKey("commit") and commit["commit"].hasKey("committer") and commit["commit"][
        "committer"].hasKey("date"):
      try: parse(commit["commit"]["committer"]["date"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'") except: now()
      else: now()
    let tarballUrl = "https://codeberg.org/" & repo.path & "/archive/main.tar.gz"
    let sha = if commit.hasKey("sha"): commit["sha"].getStr() else: ""
    result = some(VersionInfo(tag: "#head", tarballUrl: tarballUrl, publishedAt: commitDate, commitSha: sha))
  except CatchableError as e:
    warn "Failed to fetch HEAD for Codeberg repo", repo = repo.path, error = e.msg
    result = none(VersionInfo)

proc bitbucketFetchHeadVersion(client: VcsClient, repo: RepoRef): Option[VersionInfo] =
  ## Fetch latest HEAD commit for Bitbucket.
  let url = "https://api.bitbucket.org/2.0/repositories/" & repo.path & "/commits?pagelen=1"
  let cacheKey = "bb:head:" & repo.path
  try:
    let json = getJson(client, url, cacheKey)
    if not json.hasKey("values") or json["values"].len == 0:
      return none(VersionInfo)
    let commit = json["values"][0]
    let commitDate = if commit.hasKey("date"):
      try: parse(commit["date"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'") except: now()
      else: now()
    let tarballUrl = "https://bitbucket.org/" & repo.path & "/get/HEAD.tar.gz"
    let sha = if commit.hasKey("hash"): commit["hash"].getStr() else: ""
    result = some(VersionInfo(tag: "#head", tarballUrl: tarballUrl, publishedAt: commitDate, commitSha: sha))
  except CatchableError as e:
    warn "Failed to fetch HEAD for Bitbucket repo", repo = repo.path, error = e.msg
    result = none(VersionInfo)

proc genericGitFetchHeadVersion(repo: RepoRef): Option[VersionInfo] =
  ## Fetch HEAD commit via git ls-remote.
  let cmd = "GIT_TERMINAL_PROMPT=0 git ls-remote --heads " & repo.url.quoteShell & " HEAD 2>&1"
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    return none(VersionInfo)
  let parts = output.strip().split('\t')
  if parts.len < 2:
    return none(VersionInfo)
  let sha = parts[0].strip()
  result = some(VersionInfo(tag: "#head", tarballUrl: "", publishedAt: now(), commitSha: sha))

# --- Generic Git Fallback ---

proc makeTarballUrl*(repo: RepoRef, tag: string): string =
  ## Construct tarball download URL for a host + tag.
  case repo.host
  of vhGitHub:
    result = "https://github.com/" & repo.path & "/archive/refs/tags/" & tag & ".tar.gz"
  of vhGitLab:
    let repoName = repo.path.split('/')[^1]
    result = "https://gitlab.com/" & repo.path & "/-/archive/" & tag & "/" & repoName & "-" & tag & ".tar.gz"
  of vhCodeberg, vhGitea:
    result = hostBaseUrl(repo) & "/" & repo.path & "/archive/" & tag & ".tar.gz"
  of vhBitbucket:
    result = "https://bitbucket.org/" & repo.path & "/get/" & tag & ".tar.gz"
  of vhSourceHut:
    result = "https://git.sr.ht/" & repo.path & "/archive/" & tag & ".tar.gz"
  of vhGenericGit:
    result = ""

proc genericGitFetchVersions*(repo: RepoRef): seq[VersionInfo] =
  ## List tags using git ls-remote; works for any git host.
  ## Returns only the latest 2 semver tags.
  let cmd = "GIT_TERMINAL_PROMPT=0 git ls-remote --tags " & repo.url.quoteShell & " 2>&1"
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    # Repo may be private/deleted; return empty rather than fail the whole ingest
    warn "git ls-remote returned error, assuming no tags", repo = repo.path, error = output
    return

  var semverTags: seq[tuple[ver: SemVer, tag: string]] = @[]
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

    let tag = refName[10..^1] # Remove "refs/tags/"
    let optVer = parseSemVer(tag)
    if optVer.isSome:
      semverTags.add((ver: optVer.get(), tag: tag))

  # Sort by semver descending (newest first)
  semverTags.sort(proc (a, b: auto): int =
    result = cmp(b.ver.major, a.ver.major)
    if result != 0: return
    result = cmp(b.ver.minor, a.ver.minor)
    if result != 0: return
    result = cmp(b.ver.patch, a.ver.patch)
  )

  # Keep only latest 2
  let maxTags = min(2, semverTags.len)
  for i in 0..<maxTags:
    let t = semverTags[i]
    result.add(VersionInfo(
      tag: t.tag,
      tarballUrl: makeTarballUrl(repo, t.tag),
      publishedAt: now()
    ))

proc genericGitDownloadTarball*(repo: RepoRef, tag: string): seq[byte] =
  ## Clone and archive a specific tag. Slow but universal.
  let tempDir = createTempDir("nsheep", "gitdl")
  defer: removeDir(tempDir)

  let repoName = repo.path.split('/')[^1]
  let cloneDir = tempDir / repoName

  let cloneCmd = "GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch " & tag.quoteShell & " " & repo.url.quoteShell &
      " " & cloneDir.quoteShell & " 2>&1"
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

proc trimTarballToSubdir*(tarballBytes: seq[byte], repo: RepoRef, pkgName: string, tag: string): seq[byte] =
  ## For subdir packages, extract a full-repo tarball and re-archive only
  ## the subdir contents under a top-level directory named {pkgName}-{tag}/.
  ## Returns original bytes if repo.subdir is empty.
  if repo.subdir.len == 0:
    return tarballBytes

  let tempDir = createTempDir("nsheep", "trim")
  defer: removeDir(tempDir)

  # Write source tarball to disk
  let srcPath = tempDir / "source.tar.gz"
  var f: File
  if open(f, srcPath, fmWrite):
    defer: close(f)
    if tarballBytes.len > 0:
      discard f.writeBuffer(unsafeAddr tarballBytes[0], tarballBytes.len)
  else:
    raise newException(VcsError, "cannot write tarball: " & srcPath)

  # Extract
  let extractDir = tempDir / "extracted"
  createDir(extractDir)
  let extractCmd = "tar -C " & extractDir.quoteShell & " -xzf " & srcPath.quoteShell & " 2>&1"
  let (extractOut, extractExit) = execCmdEx(extractCmd)
  if extractExit != 0:
    raise newException(VcsError, "tar extract failed: " & extractOut)

  # Find single top-level directory
  var topDir = ""
  for kind, path in walkDir(extractDir):
    if kind == pcDir:
      if topDir.len > 0:
        raise newException(VcsError, "tarball has multiple top-level directories")
      topDir = path.extractFilename

  if topDir.len == 0:
    raise newException(VcsError, "no top-level directory in tarball")

  # Verify subdir exists inside top-level dir
  let srcSubdir = extractDir / topDir / repo.subdir
  if not dirExists(srcSubdir):
    raise newException(VcsError, "subdir not found in tarball: " & repo.subdir)

  # Create new top-level directory with desired name
  let tarName = if tag == "#head": pkgName & "-head" else: pkgName & "-" & tag
  let workDir = tempDir / "work"
  let destDir = workDir / tarName
  createDir(destDir)

  # Copy subdir contents using tar (preserves hidden files, symlinks, etc.)
  let copyCmd = "tar -C " & srcSubdir.quoteShell & " -cf - . | tar -C " & destDir.quoteShell & " -xf - 2>&1"
  let (copyOut, copyExit) = execCmdEx(copyCmd)
  if copyExit != 0:
    raise newException(VcsError, "tar copy failed: " & copyOut)

  # Create trimmed tarball
  let tarPath = tempDir / "trimmed.tar.gz"
  let tarCmd = "tar -C " & workDir.quoteShell & " -czf " & tarPath.quoteShell & " " & tarName.quoteShell & " 2>&1"
  let (tarOut, tarExit) = execCmdEx(tarCmd)
  if tarExit != 0:
    raise newException(VcsError, "tar create failed: " & tarOut)

  # Read trimmed tarball bytes
  let fileSize = getFileSize(tarPath)
  result = newSeq[byte](fileSize)
  if open(f, tarPath, fmRead):
    defer: close(f)
    if fileSize > 0:
      discard f.readBuffer(addr result[0], fileSize)
  else:
    raise newException(VcsError, "cannot read trimmed tarball: " & tarPath)

proc genericGitFetchFile*(repo: RepoRef, tag, filename: string): Option[string] =
  ## Fetch a single file via shallow clone + read.
  let tempDir = createTempDir("nsheep", "gitfile")
  defer: removeDir(tempDir)

  let cloneCmd = "GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch " & tag.quoteShell & " " & repo.url.quoteShell &
      " " & tempDir.quoteShell & " 2>&1"
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

proc genericGitFetchReadme(repo: RepoRef, tag, path: string): string =
  let opt = genericGitFetchFile(repo, tag, path)
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

proc sourcehutFetchReadme(repo: RepoRef, tag, path: string): string =
  let opt = sourcehutFetchFile(repo, tag, path)
  if opt.isSome: result = opt.get() else: result = ""

# --- Unified Public API ---

proc fetchRepoMeta*(client: VcsClient, repo: RepoRef): (string, DateTime) =
  ## Fetch repository description and last-updated time.
  ## Propagates VcsNotFoundError so callers know the repo is deleted/unreachable.
  try:
    case repo.host
    of vhGitHub: result = githubFetchMeta(client, repo)
    of vhGitLab: result = gitlabFetchMeta(client, repo)
    of vhCodeberg, vhGitea: result = giteaFetchMeta(client, repo)
    of vhBitbucket: result = bitbucketFetchMeta(client, repo)
    of vhSourceHut, vhGenericGit:
      result = ("", now())
  except VcsNotFoundError:
    raise
  except CatchableError as e:
    warn "VCS metadata fetch failed", host = $repo.host, path = repo.path, error = e.msg
    result = ("", now())

proc fetchVersions*(client: VcsClient, repo: RepoRef): seq[VersionInfo] =
  ## Fetch latest 2 semver tags via git ls-remote (works for any host).
  try:
    result = genericGitFetchVersions(repo)
  except CatchableError as e:
    warn "VCS version fetch failed", host = $repo.host, path = repo.path, error = e.msg
    raise

proc fetchHeadVersion*(client: VcsClient, repo: RepoRef): Option[VersionInfo] =
  ## Fetch the latest HEAD commit as a fallback when no releases exist.
  case repo.host
  of vhGitHub: result = githubFetchHeadVersion(client, repo)
  of vhGitLab: result = gitlabFetchHeadVersion(client, repo)
  of vhCodeberg, vhGitea: result = giteaFetchHeadVersion(client, repo)
  of vhBitbucket: result = bitbucketFetchHeadVersion(client, repo)
  of vhSourceHut: result = genericGitFetchHeadVersion(repo)
  of vhGenericGit: result = genericGitFetchHeadVersion(repo)

proc downloadTarball*(client: VcsClient, repo: RepoRef, ver: VersionInfo): seq[byte] =
  ## Download tarball bytes for a specific version.
  case repo.host
  of vhGitHub:
    result = downloadHttp(ver.tarballUrl, client.githubToken, timeout = 120)
  of vhGitLab:
    if ver.tarballUrl.len > 0:
      result = downloadHttp(ver.tarballUrl, client.gitlabToken, timeout = 120)
    else:
      raise newException(VcsError, "no tarball URL for " & repo.path & " @ " & ver.tag)
  of vhCodeberg, vhGitea:
    if ver.tarballUrl.len > 0:
      result = downloadHttp(ver.tarballUrl, client.codebergToken, timeout = 120)
    else:
      raise newException(VcsError, "no tarball URL for " & repo.path & " @ " & ver.tag)
  of vhBitbucket:
    if ver.tarballUrl.len > 0:
      result = downloadHttp(ver.tarballUrl, client.bitbucketToken, timeout = 120)
    else:
      raise newException(VcsError, "no tarball URL for " & repo.path & " @ " & ver.tag)
  of vhSourceHut:
    if ver.tarballUrl.len > 0:
      result = downloadHttp(ver.tarballUrl, client.sourcehutToken, timeout = 120)
    else:
      result = genericGitDownloadTarball(repo, ver.tag)
  of vhGenericGit:
    result = genericGitDownloadTarball(repo, ver.tag)

proc fetchNimbleFile*(client: VcsClient, repo: RepoRef, tag: string): Option[string] =
  ## Fetch the .nimble file content for a tag.
  let repoName = repo.path.split('/')[^1]
  let filename = subdirPath(repo, repoName & ".nimble")

  try:
    case repo.host
    of vhGitHub: result = githubFetchNimbleFile(client, repo, tag, filename)
    of vhGitLab: result = gitlabFetchFile(client, repo, tag, filename)
    of vhCodeberg, vhGitea: result = giteaFetchFile(client, repo, tag, filename)
    of vhBitbucket: result = bitbucketFetchFile(client, repo, tag, filename)
    of vhSourceHut, vhGenericGit:
      result = genericGitFetchFile(repo, tag, filename)
  except CatchableError as e:
    warn "Nimble file fetch failed", host = $repo.host, path = repo.path, tag = tag, error = e.msg
    result = none(string)

proc fetchReadme*(client: VcsClient, repo: RepoRef, tag: string): string =
  ## Fetch README.md content for a tag.
  let path = subdirPath(repo, "README.md")
  try:
    case repo.host
    of vhGitHub: result = githubFetchReadme(client, repo, tag, path)
    of vhGitLab: result = gitlabFetchReadme(client, repo, tag, path)
    of vhCodeberg, vhGitea: result = giteaFetchReadme(client, repo, tag, path)
    of vhBitbucket: result = bitbucketFetchReadme(client, repo, tag, path)
    of vhSourceHut: result = sourcehutFetchReadme(repo, tag, path)
    of vhGenericGit: result = genericGitFetchReadme(repo, tag, path)
  except CatchableError as e:
    warn "README fetch failed", host = $repo.host, path = repo.path, tag = tag, error = e.msg
    result = ""

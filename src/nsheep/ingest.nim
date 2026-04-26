##
## Package ingestion - orchestrates GitHub fetch + storage
## Pure logic, no HTTP, no side effects except explicit storage calls
##

import std/[times, tables, strutils, options]
import chronicles
import nsheep/[types, storage, vcs], puppy

# --- Errors ---

type
  IngestError* = object of CatchableError
  NoVersionsError* = object of IngestError
  InvalidRepositoryError* = object of IngestError

# --- Nimble file parsing ---

proc parseNimbleSimple*(nimbleContent: string): Table[string, string] =
  ## Fast line-based nimble field extraction. No subprocesses, no regex.
  ## Handles both `name = "foo"` and `name "foo"` styles.
  ## Falls back to empty values for complex expressions (multiline, concat, etc).
  result = initTable[string, string]()
  const fields = ["name", "version", "author", "description", "license"]
  for line in nimbleContent.splitLines():
    let trimmed = line.strip()
    for field in fields:
      if trimmed.startsWith(field):
        var pos = field.len
        # Skip whitespace and optional '='
        while pos < trimmed.len and (trimmed[pos] in {' ', '\t', '='}):
          pos.inc
        # Extract quoted string
        if pos < trimmed.len and trimmed[pos] == '"':
          pos.inc
          var value = ""
          while pos < trimmed.len and trimmed[pos] != '"':
            value.add(trimmed[pos])
            pos.inc
          if value.len > 0:
            result[field] = value
        break

# --- Core ingestion logic ---

proc ingest*(
  client: var VcsClient,
  store: DbStorage,
  repo: RepoRef,
  canonicalName: string = "",
  tags: seq[string] = @[]
): Package {.raises: [IngestError, VcsError, StorageError, PuppyError, CatchableError, Exception].} =
  ## Ingest a package from GitHub
  ## Raises on any failure - caller handles retry/display
  ## canonicalName: official name from nimble packages.json (not repo name)

  info "Starting ingestion", repo = repo.path

  # 1. Fetch repository metadata
  let (description, updatedAt) = fetchRepoMeta(client, repo)
  info "Fetched repository metadata"

  # 2. Fetch tags
  let releases = fetchVersions(client, repo)
  info "Fetched tags", count = releases.len

  # 3. Always fetch HEAD (in addition to tags)
  let headOpt = fetchHeadVersion(client, repo)
  if releases.len == 0 and headOpt.isNone:
    raise newException(NoVersionsError, "repository has no tags and no head: " & repo.path)
  info "Fetched head", repo = repo.path

  # 4. Fetch nimble file for metadata (description, author, license)
  let latestTag = if releases.len > 0: releases[0].tag else: "HEAD"
  let nimbleOpt = fetchNimbleFile(client, repo, latestTag)

  var nimbleData = initTable[string, string]()
  if nimbleOpt.isSome:
    nimbleData = parseNimbleSimple(nimbleOpt.get())

  # 5. Determine canonical package name — NEVER fall back to repo name
  let pkgName = if canonicalName.len > 0:
    initPackageName(sanitizePackageName(canonicalName))
  else:
    # No canonical name provided — try nimble file, or fail
    let nimbleName = nimbleData.getOrDefault("name", "")
    if nimbleName.len > 0:
      initPackageName(sanitizePackageName(nimbleName))
    else:
      raise newException(IngestError, "no canonical name provided and no name in nimble file: " & repo.path)

  # 6. Ensure package row exists BEFORE storing versions
  let placeholderPkg = Package(
    name: pkgName,
    description: nimbleData.getOrDefault("description", description),
    author: nimbleData.getOrDefault("author", repo.path.split('/')[^2]),
    license: nimbleData.getOrDefault("license", "Unknown"),
    url: repo.url,
    tags: tags,
    versions: @[],
    createdAt: now(),
    updatedAt: updatedAt
  )
  storePackage(store, placeholderPkg)

  # 7. Parse releases into versions
  var versions = newSeq[PackageVersion]()

  # Process semver releases
  for rel in releases:
    let optVer = parseSemVer(rel.tag)
    if optVer.isNone:
      continue # Skip non-semver tags silently

    let ver = optVer.get()

    # Check if already have this version
    if versionExists(store, pkgName, ver):
      # Already cached - just load metadata
      continue

    # Download tarball
    let tarballBytes = downloadTarball(client, repo, rel)

    # Compute checksum
    # TODO: use std/sha256
    let checksum = initChecksum("0" & repeat('0', 63)) # Placeholder

    # Store version with tarball
    storeVersion(store, pkgName, ver, tarballBytes, checksum, rel.publishedAt)

    versions.add(PackageVersion(
      version: ver,
      headCommit: "",
      tarballPath: "",
      checksum: checksum,
      size: int64(tarballBytes.len),
      publishedAt: rel.publishedAt
    ))

  # Process HEAD version
  if headOpt.isSome:
    let rel = headOpt.get()
    let headSemVer = initSemVer(99999, 99999, 99999)
    let headSha = rel.commitSha

    let storedSha = getHeadCommitSha(store, pkgName)
    if storedSha == headSha and headSha.len > 0:
      info "Head version unchanged, skipping download", repo = repo.path, sha = headSha
      versions.add(PackageVersion(
        version: headSemVer,
        headCommit: headSha,
        tarballPath: "",
        checksum: initChecksum("0" & repeat('0', 63)),
        size: 0,
        publishedAt: rel.publishedAt
      ))
    else:
      if storedSha.len > 0:
        info "Head version changed", repo = repo.path, oldSha = storedSha, newSha = headSha
        deleteHeadVersions(store, pkgName)
      let tarballBytes = downloadTarball(client, repo, rel)
      let checksum = initChecksum("0" & repeat('0', 63)) # Placeholder
      storeVersion(store, pkgName, headSemVer, tarballBytes, checksum, rel.publishedAt, headSha)
      versions.add(PackageVersion(
        version: headSemVer,
        headCommit: headSha,
        tarballPath: "",
        checksum: checksum,
        size: int64(tarballBytes.len),
        publishedAt: rel.publishedAt
      ))
      info "Updated head version", repo = repo.path, sha = headSha

  info "Downloaded versions", count = versions.len

  # 8. Build final package (versions only affect the return value; DB already has them)
  let pkg = Package(
    name: pkgName,
    description: placeholderPkg.description,
    author: placeholderPkg.author,
    license: placeholderPkg.license,
    url: repo.url,
    tags: tags,
    versions: versions,
    createdAt: placeholderPkg.createdAt,
    updatedAt: updatedAt
  )

  # 9. Fetch and store READMEs
  let readmeContent = fetchReadme(client, repo, "HEAD")
  if readmeContent != "":
    storeReadme(store, pkg.name.string, "#head", readmeContent)

  for rel in releases:
    let optVer = parseSemVer(rel.tag)
    if optVer.isNone:
      continue
    let ver = optVer.get()
    let readmeContent = fetchReadme(client, repo, rel.tag)
    if readmeContent != "":
      let versionStr = $ver.major & "." & $ver.minor & "." & $ver.patch
      storeReadme(store, pkg.name.string, versionStr, readmeContent)

  touchPackage(store, pkg.name)
  info "Ingestion complete", package = $pkg.name, versions = pkg.versions.len
  result = pkg

# --- Batch operations ---

proc updatePackage*(
  client: var VcsClient,
  store: DbStorage,
  name: PackageName
): Package {.raises: [IngestError, VcsError, StorageError, storage.NotFoundError, Exception].} =
  ## Update existing package

  # Load existing to get URL
  let existing = loadPackage(store, name)

  # Parse URL to get repo
  let repoOpt = vcs.parseRepoUrl(existing.url)
  if repoOpt.isNone:
    raise newException(IngestError, "cannot parse repository URL: " & existing.url)

  # Re-ingest using the existing canonical name and preserving tags
  result = ingest(client, store, repoOpt.get(), $name, existing.tags)

##
## Package ingestion - orchestrates GitHub fetch + storage
## Pure logic, no HTTP, no side effects except explicit storage calls
##

import std/[times, tables, strutils, json, os, osproc, tempfiles, options]
import chronicles
import nsheep/[types, storage, vcs], puppy

# --- Errors ---

type
  IngestError* = object of CatchableError
  NoVersionsError* = object of IngestError
  InvalidRepositoryError* = object of IngestError

# --- Nimble file parsing ---

proc parseNimbleDump*(nimbleContent: string, pkgName: string): Table[string, string] =
  ## Parse nimble file using 'nimble dump --json' for accuracy
  ## Returns table with name, version, author, description, license, etc.
  result = initTable[string, string]()
  
  # Create temp directory with minimal structure for nimble dump
  let tempDir = createTempDir("nsheep", "")
  defer: removeDir(tempDir)
  
  let nimblePath = tempDir / (pkgName & ".nimble")
  writeFile(nimblePath, nimbleContent)
  
  # Create minimal src dir to satisfy nimble
  createDir(tempDir / "src")
  writeFile(tempDir / "src" / (pkgName & ".nim"), "# dummy")
  
  # Run nimble dump --json
  let (output, exitCode) = execCmdEx("nimble dump --json " & nimblePath.quoteShell)
  if exitCode != 0:
    return result  # Return empty table on failure
  
  try:
    let json = parseJson(output)
    for key, val in json:
      if val.kind == JString:
        result[key] = val.getStr()
  except JsonParsingError:
    discard  # Return partial results on parse error

# --- Core ingestion logic ---

proc ingest*(
  client: var VcsClient,
  store: DbStorage,
  repo: RepoRef
): Package {.raises: [IngestError, VcsError, StorageError, PuppyError, CatchableError, Exception].} =
  ## Ingest a package from GitHub
  ## Raises on any failure - caller handles retry/display
  
  info "Starting ingestion", repo = repo.path
  
  # 1. Fetch repository metadata
  let (description, updatedAt) = fetchRepoMeta(client, repo)
  info "Fetched repository metadata"
  
  # 2. Fetch releases / tags
  let releases = fetchVersions(client, repo)
  info "Fetched releases", count = releases.len
  if releases.len == 0:
    raise newException(NoVersionsError, "repository has no releases: " & repo.path)
  
  # 3. Parse releases into versions
  var versions = newSeq[PackageVersion]()
  
  for rel in releases:
    let optVer = parseSemVer(rel.tag)
    if optVer.isNone:
      continue  # Skip non-semver tags silently
    
    let ver = optVer.get()
    let pkgName = initPackageName(repo.path.split('/')[^1])
    
    # Check if already have this version
    if versionExists(store, pkgName, ver):
      # Already cached - just load metadata
      # This is an optimization path
      continue
    
    # Download tarball
    let tarballBytes = downloadTarball(client, repo, rel)
    
    # Compute checksum
    # TODO: use std/sha256
    let checksum = initChecksum("0" & repeat('0', 63))  # Placeholder
    
    # Store version with tarball
    storeVersion(store, pkgName, ver, tarballBytes, checksum, rel.publishedAt)
    
    versions.add(PackageVersion(
      version: ver,
      tarballPath: "",
      checksum: checksum,
      size: int64(tarballBytes.len),
      publishedAt: rel.publishedAt
    ))
  
  if versions.len == 0:
    raise newException(NoVersionsError, "no valid semver releases found")
  
  info "Downloaded versions", count = versions.len
  
  # 4. Fetch nimble file for metadata
  let latestTag = releases[0].tag
  let nimbleOpt = fetchNimbleFile(client, repo, latestTag)
  
  var nimbleData = initTable[string, string]()
  if nimbleOpt.isSome:
    nimbleData = parseNimbleDump(nimbleOpt.get(), repo.path.split('/')[^1])
  
  # 5. Build package
  let repoName = repo.path.split('/')[^1]
  let pkgName = try:
    initPackageName(nimbleData.getOrDefault("name", repoName))
  except ValueError:
    initPackageName(repoName)
  
  let pkg = Package(
    name: pkgName,
    description: nimbleData.getOrDefault("description", description),
    author: nimbleData.getOrDefault("author", repo.path.split('/')[^2]),
    license: nimbleData.getOrDefault("license", "Unknown"),
    url: repo.url,
    tags: @[],
    versions: versions,
    createdAt: now(),
    updatedAt: updatedAt
  )
  
  # 6. Persist
  storePackage(store, pkg)
  
  # 7. Fetch and store READMEs for each version
  for rel in releases:
    let optVer = parseSemVer(rel.tag)
    if optVer.isNone:
      continue
    let ver = optVer.get()
    let readmeContent = fetchReadme(client, repo, rel.tag)
    if readmeContent != "":
      let versionStr = $ver.major & "." & $ver.minor & "." & $ver.patch
      storeReadme(store, pkg.name.string, versionStr, readmeContent)
  
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
  
  # Re-ingest
  result = ingest(client, store, repoOpt.get())

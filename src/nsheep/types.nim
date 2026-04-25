##
## Core domain types - immutable value objects
## No nil, no optional fields without explicit Option[T]
##

import std/[times, options, strutils, algorithm]

const Version* = "0.1.0"

type
  SemVer* = object
    ## Semantic version - always valid, parsed at construction
    major*, minor*, patch*: int

  PackageName* = distinct string
    ## Validated package name - no invalid chars

  Checksum* = distinct string
    ## SHA256 hash - always 64 hex chars

  PackageVersion* = object
    ## Immutable version info
    version*: SemVer
    tarballPath*: string
    checksum*: Checksum
    size*: int64
    publishedAt*: DateTime

  Package* = object
    ## Aggregate root - must have valid name and at least one version
    name*: PackageName
    description*: string
    author*: string
    license*: string
    url*: string
    tags*: seq[string]
    versions*: seq[PackageVersion]
    createdAt*: DateTime
    updatedAt*: DateTime

  IngestionError* = enum
    ieInvalidRepository
    ieNoVersions
    ieNetworkFailure
    ieStorageFailure
    ieParseError

  IngestionResult* = Result[Package, IngestionError]

  Result*[T, E] = object
    ## Explicit result type - no exceptions for expected errors
    case ok*: bool
    of true:
      value*: T
    of false:
      error*: E

# --- Constructors - enforce invariants ---

proc initSemVer*(major, minor, patch: int): SemVer {.raises: [ValueError].} =
  if major < 0 or minor < 0 or patch < 0:
    raise newException(ValueError, "version components must be non-negative")
  result = SemVer(major: major, minor: minor, patch: patch)

proc parseSemVer*(s: string): Option[SemVer] =
  ## Parse semver string - no guessing, no partial matches
  let parts = s.split('.')
  if parts.len != 3:
    return none(SemVer)
  
  try:
    let major = parseInt(parts[0])
    let minor = parseInt(parts[1])
    # Handle patch with possible pre-release (e.g., "1-rc1")
    let patchPart = parts[2]
    var patchStr = patchPart
    for i, c in patchPart:
      if c notin {'0'..'9'}:
        patchStr = patchPart[0..<i]
        break
    if patchStr.len == 0:
      return none(SemVer)
    let patch = parseInt(patchStr)
    result = some(initSemVer(major, minor, patch))
  except ValueError:
    result = none(SemVer)

proc initPackageName*(s: string): PackageName {.raises: [ValueError].} =
  ## Validate and create package name
  ## Rules: alphanumeric, hyphen, underscore only. Must start with letter.
  if s.len == 0 or s.len > 100:
    raise newException(ValueError, "package name length must be 1-100")
  
  if s[0] notin {'a'..'z', 'A'..'Z'}:
    raise newException(ValueError, "package name must start with letter")
  
  for c in s:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
      raise newException(ValueError, "invalid character in package name: " & c)
  
  result = PackageName(s)

proc `$`*(n: PackageName): string {.inline.} = string(n)

proc initChecksum*(hex: string): Checksum {.raises: [ValueError].} =
  if hex.len != 64:
    raise newException(ValueError, "SHA256 must be 64 hex characters")
  for c in hex:
    if c notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      raise newException(ValueError, "invalid hex character in checksum")
  result = Checksum(hex.toLowerAscii())

proc `$`*(c: Checksum): string {.inline.} = string(c)

# --- Package operations ---

proc latestVersion*(p: Package): PackageVersion =
  ## Precondition: versions.len > 0
  assert p.versions.len > 0, "package has no versions"
  result = p.versions[0]

proc compare*(a, b: SemVer): int =
  ## Semver comparison
  result = cmp(a.major, b.major)
  if result != 0: return
  result = cmp(a.minor, b.minor)
  if result != 0: return
  result = cmp(a.patch, b.patch)

proc `<`*(a, b: SemVer): bool = compare(a, b) < 0
proc `>`*(a, b: SemVer): bool = compare(a, b) > 0

proc sortVersions*(p: var Package) =
  ## Sort versions descending (newest first)
  p.versions.sort(proc (a, b: PackageVersion): int =
    result = compare(b.version, a.version)
  )



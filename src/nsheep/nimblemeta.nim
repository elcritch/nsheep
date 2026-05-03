import std/[os, paths, strutils, tables, tempfiles]

import basic/[deptypes, nimblecontext, pkgurls, versions]
import releaseinfo

proc processNimbleReleaseSafe(
    nc: var NimbleContext;
    pkg: Package;
    release: VersionTag
): NimbleRelease {.gcsafe.} =
  {.cast(gcsafe).}:
    nc.processNimbleRelease(pkg, release)

proc parseProjectInfoImpl(nimbleContent: string): Table[string, string] =
  ## Parse project metadata from a .nimble file using Atlas release parsing for
  ## release fields and a literal scanner for simple package metadata fields.
  result = initTable[string, string]()

  let tempDir = createTempDir("nsheep-", "")
  let nimblePath = tempDir / "pkg.nimble"
  writeFile(nimblePath, nimbleContent)

  let release = try:
    var nc = createUnfilledNimbleContext()
    let pkgUrl = createUrlSkipPatterns(tempDir)
    let pkg = Package(url: pkgUrl, ondisk: Path tempDir, isLocalOnly: true)
    processNimbleReleaseSafe(
      nc,
      pkg,
      VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
    )
  finally:
    removeDir(tempDir)

  if not release.isNil:
    let version = $release.version
    if version != "~" and version.len > 0:
      result["version"] = version
    let srcDir = $release.srcDir
    if srcDir.len > 0:
      result["srcDir"] = srcDir

  const fields = ["name", "version", "author", "description", "license", "backend"]
  for line in nimbleContent.splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"):
      continue
    if trimmed.startsWith("bin") and (trimmed.len == 3 or trimmed[3] in {' ', '\t', '='}):
      result["hasBin"] = "true"
      continue
    for field in fields:
      if trimmed.startsWith(field):
        var pos = field.len
        while pos < trimmed.len and (trimmed[pos] in {' ', '\t', '='}):
          pos.inc
        if pos < trimmed.len and trimmed[pos] == '"':
          pos.inc
          var value = ""
          while pos < trimmed.len and trimmed[pos] != '"':
            value.add(trimmed[pos])
            pos.inc
          if value.len > 0:
            result[field] = value
        break

proc parseProjectInfo*(nimbleContent: string): Table[string, string] {.gcsafe.} =
  {.cast(gcsafe).}:
    parseProjectInfoImpl(nimbleContent)
